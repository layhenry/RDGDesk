import Foundation
import RdcFreeRDPBridge

public struct FreeRDPConfiguration: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let username: String?
    public let domain: String?
    public let password: String?
    public let desktopWidth: UInt32
    public let desktopHeight: UInt32

    public init(
        host: String,
        port: UInt16,
        username: String?,
        domain: String?,
        password: String?,
        desktopWidth: UInt32,
        desktopHeight: UInt32
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.password = password
        self.desktopWidth = desktopWidth
        self.desktopHeight = desktopHeight
    }
}

public enum FreeRDPBridgeEvent: Equatable, Sendable {
    case connecting
    case connected
    case frame(RemoteFrame)
    case certificateChallenge(RdpCertificateChallenge)
    case clipboardText(String)
    case disconnected
    case failed(code: Int32, message: String)
}

public protocol FreeRDPBridgeAPI: Sendable {
    func connect(configuration: FreeRDPConfiguration) -> AsyncStream<FreeRDPBridgeEvent>
    func disconnect()
    func resolveCertificate(challengeID: UInt64, decision: RdpCertificateDecision)
    func resize(width: Int, height: Int)
    func sendPointer(flags: UInt16, x: UInt16, y: UInt16)
    func sendKey(flags: UInt16, code: UInt16)
    func sendUnicode(flags: UInt16, codeUnit: UInt16)
    func sendSecureAttention()
    func setClipboardText(_ text: String)
}

typealias NativeDestroyClient = @Sendable (OpaquePointer?) -> Void
typealias NativeResolveCertificate = @Sendable (
    OpaquePointer?, UInt64, RDCCertificateDecision
) -> Int32

private final class FreeRDPEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [FreeRDPBridgeEvent] = []
    private var waiter: CheckedContinuation<FreeRDPBridgeEvent?, Never>?
    private var finishesAfterDrain = false

    func push(_ event: FreeRDPBridgeEvent, finishing: Bool) {
        lock.lock()
        if finishing {
            finishesAfterDrain = true
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: event)
            return
        }
        if case .frame = event {
            pending.removeAll {
                if case .frame = $0 { return true }
                return false
            }
        }
        pending.append(event)
        lock.unlock()
    }

    func next() async -> FreeRDPBridgeEvent? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !pending.isEmpty {
                let event = pending.removeFirst()
                lock.unlock()
                continuation.resume(returning: event)
            } else if finishesAfterDrain {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                precondition(waiter == nil, "AsyncStream supports one active iterator")
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

final class FreeRDPCallbackBox: @unchecked Sendable {
    let lock = NSLock()
    private var buffer: FreeRDPEventBuffer?
    private var nextGeneration: UInt64 = 0
    private var currentGeneration: UInt64?
    private var nativeClient: OpaquePointer?
    private var nativeResolveCertificate: NativeResolveCertificate?

    func installNativeClient(
        _ client: OpaquePointer?,
        resolveCertificate: @escaping NativeResolveCertificate
    ) {
        lock.lock()
        nativeClient = client
        nativeResolveCertificate = resolveCertificate
        lock.unlock()
    }

    func clearNativeClient(_ expectedClient: OpaquePointer?) {
        lock.lock()
        if nativeClient == expectedClient {
            nativeClient = nil
            nativeResolveCertificate = nil
        }
        lock.unlock()
    }

    @discardableResult
    func resolveCertificate(
        challengeID: UInt64,
        decision: RDCCertificateDecision
    ) -> Int32 {
        lock.lock()
        let client = nativeClient
        let resolver = nativeResolveCertificate
        lock.unlock()
        guard let resolver else { return -1 }
        return resolver(client, challengeID, decision)
    }

    func makeStream(onCancel: @escaping @Sendable (UInt64) -> Void = { _ in })
        -> AsyncStream<FreeRDPBridgeEvent>? {
        lock.lock()
        guard buffer == nil else {
            lock.unlock()
            return nil
        }
        precondition(nextGeneration < UInt64.max, "FreeRDP stream generation exhausted")
        nextGeneration += 1
        let generation = nextGeneration
        currentGeneration = generation
        let buffer = FreeRDPEventBuffer()
        self.buffer = buffer
        lock.unlock()
        let cancellation = FreeRDPStreamCancellation(
            generation: generation, onCancel: onCancel
        )
        return AsyncStream(
            unfolding: {
                withExtendedLifetime(cancellation) {}
                return await buffer.next()
            },
            onCancel: { cancellation.cancel() }
        )
    }

    func performIfCurrentGeneration(_ generation: UInt64, _ action: () -> Void) {
        lock.lock()
        guard currentGeneration == generation else {
            lock.unlock()
            return
        }
        action()
        lock.unlock()
    }

    func yield(_ event: FreeRDPBridgeEvent, finishing: Bool = false) {
        lock.lock()
        let buffer = buffer
        if finishing {
            self.buffer = nil
        }
        lock.unlock()
        buffer?.push(event, finishing: finishing)
    }
}

private final class FreeRDPStreamCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let generation: UInt64
    private let onCancel: @Sendable (UInt64) -> Void
    private var didCancel = false

    init(generation: UInt64, onCancel: @escaping @Sendable (UInt64) -> Void) {
        self.generation = generation
        self.onCancel = onCancel
    }

    func cancel() {
        lock.lock()
        guard !didCancel else {
            lock.unlock()
            return
        }
        didCancel = true
        lock.unlock()
        onCancel(generation)
    }

    deinit {
        cancel()
    }
}

private let frameCallback: RDCFrameCallback = { context, bgra, width, height, stride in
    guard let context, let bgra else { return }
    let box = Unmanaged<FreeRDPCallbackBox>.fromOpaque(context).takeUnretainedValue()
    let byteCount = Int(stride) * Int(height)
    let copiedBytes = [UInt8](Data(bytes: bgra, count: byteCount))
    let frame = RemoteFrame(
        width: Int(width), height: Int(height), stride: Int(stride), bgraBytes: copiedBytes
    )
    box.yield(.frame(frame))
}

let certificateCallback: RDCCertificateCallback = { context, nativeChallenge in
    guard let context, let nativeChallenge else { return }
    let box = Unmanaged<FreeRDPCallbackBox>.fromOpaque(context).takeUnretainedValue()
    let native = nativeChallenge.pointee
    guard native.challenge_id != 0 else { return }
    guard let pem = native.pem,
          native.pem_length > 0,
          let host = native.host,
          let copiedHost = String(validatingCString: host) else {
        box.resolveCertificate(
            challengeID: native.challenge_id,
            decision: RDCCertificateDecisionReject
        )
        return
    }

    let copiedPEM = Data(bytes: pem, count: native.pem_length)
    guard let challenge = try? RdpCertificateChallenge(
        id: native.challenge_id,
        endpoint: RdpEndpoint(host: copiedHost, port: native.port),
        pemData: copiedPEM,
        flags: native.flags
    ) else {
        box.resolveCertificate(
            challengeID: native.challenge_id,
            decision: RDCCertificateDecisionReject
        )
        return
    }
    box.yield(.certificateChallenge(challenge))
}

private let clipboardTextCallback: RDCClipboardTextCallback = { context, utf8, length in
    guard let context, let utf8, length <= 1_048_576 else { return }
    let bytes = UnsafeBufferPointer(start: utf8, count: length)
    guard let text = String(bytes: bytes, encoding: .utf8) else { return }
    let box = Unmanaged<FreeRDPCallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.yield(.clipboardText(text))
}

private let stateCallback: RDCStateCallback = { context, state, errorCode, message in
    guard let context else { return }
    let box = Unmanaged<FreeRDPCallbackBox>.fromOpaque(context).takeUnretainedValue()
    switch state {
    case Int32(RDCFreeRDPStateConnecting.rawValue):
        box.yield(.connecting)
    case Int32(RDCFreeRDPStateConnected.rawValue):
        box.yield(.connected)
    case Int32(RDCFreeRDPStateDisconnected.rawValue):
        box.yield(.disconnected, finishing: true)
    default:
        let copiedMessage = message.map(String.init(cString:)) ?? "FreeRDP connection failed"
        box.yield(.failed(code: errorCode, message: copiedMessage), finishing: true)
    }
}

private final class NativeClientTeardown: @unchecked Sendable {
    private let client: OpaquePointer?
    private let callbackBox: FreeRDPCallbackBox
    private let destroyClient: NativeDestroyClient

    init(client: OpaquePointer?, callbackBox: FreeRDPCallbackBox,
         destroyClient: @escaping NativeDestroyClient) {
        self.client = client
        self.callbackBox = callbackBox
        self.destroyClient = destroyClient
    }

    func run() {
        destroyClient(client)
        callbackBox.clearNativeClient(client)
        withExtendedLifetime(callbackBox) {}
    }
}

public final class NativeFreeRDPBridge: FreeRDPBridgeAPI, @unchecked Sendable {
    private let lock = NSLock()
    private let callbackBox: FreeRDPCallbackBox
    private let destroyClient: NativeDestroyClient
    private let nativeResolveCertificate: NativeResolveCertificate
    private var client: OpaquePointer?

    public init() {
        destroyClient = { rdc_client_destroy($0) }
        nativeResolveCertificate = { rdc_client_resolve_certificate($0, $1, $2) }
        let callbackBox = FreeRDPCallbackBox()
        self.callbackBox = callbackBox
        let client = rdc_client_create(
            Unmanaged.passUnretained(callbackBox).toOpaque(), frameCallback, stateCallback,
            certificateCallback
        )
        _ = rdc_client_set_clipboard_callback(client, clipboardTextCallback)
        self.client = client
        callbackBox.installNativeClient(client, resolveCertificate: nativeResolveCertificate)
    }

    init(_ destroyClient: @escaping NativeDestroyClient) {
        self.destroyClient = destroyClient
        nativeResolveCertificate = { rdc_client_resolve_certificate($0, $1, $2) }
        let callbackBox = FreeRDPCallbackBox()
        self.callbackBox = callbackBox
        let client = rdc_client_create(
            Unmanaged.passUnretained(callbackBox).toOpaque(), frameCallback, stateCallback,
            certificateCallback
        )
        _ = rdc_client_set_clipboard_callback(client, clipboardTextCallback)
        self.client = client
        callbackBox.installNativeClient(client, resolveCertificate: nativeResolveCertificate)
    }

    init(
        resolveCertificate: @escaping NativeResolveCertificate,
        destroyClient: @escaping NativeDestroyClient = { rdc_client_destroy($0) }
    ) {
        self.destroyClient = destroyClient
        nativeResolveCertificate = resolveCertificate
        let callbackBox = FreeRDPCallbackBox()
        self.callbackBox = callbackBox
        let client = rdc_client_create(
            Unmanaged.passUnretained(callbackBox).toOpaque(), frameCallback, stateCallback,
            certificateCallback
        )
        _ = rdc_client_set_clipboard_callback(client, clipboardTextCallback)
        self.client = client
        callbackBox.installNativeClient(client, resolveCertificate: nativeResolveCertificate)
    }

    deinit {
        lock.lock()
        let client = client
        self.client = nil
        lock.unlock()
        let teardown = NativeClientTeardown(
            client: client, callbackBox: callbackBox, destroyClient: destroyClient
        )
        DispatchQueue.global(qos: .userInitiated).async {
            teardown.run()
        }
    }

    public func connect(configuration: FreeRDPConfiguration) -> AsyncStream<FreeRDPBridgeEvent> {
        guard let stream = callbackBox.makeStream(onCancel: { [weak self] generation in
            self?.disconnect(ifCurrentGeneration: generation)
        }) else {
            return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                continuation.yield(
                    .failed(code: -1, message: "A FreeRDP connection is already active")
                )
                continuation.finish()
            }
        }

        let result = withCConfiguration(configuration) { cConfiguration in
            lock.lock()
            let client = client
            lock.unlock()
            return rdc_client_connect(client, cConfiguration)
        }
        if result != 0 {
            callbackBox.yield(
                .failed(code: result, message: "Unable to start FreeRDP connection"),
                finishing: true
            )
        }
        return stream
    }

    public func disconnect() {
        lock.lock()
        let client = client
        lock.unlock()
        rdc_client_disconnect(client)
    }

    public func resolveCertificate(
        challengeID: UInt64,
        decision: RdpCertificateDecision
    ) {
        lock.lock()
        let client = client
        lock.unlock()
        let nativeDecision = RDCCertificateDecision(rawValue: UInt32(decision.rawValue))
        _ = nativeResolveCertificate(client, challengeID, nativeDecision)
    }

    private func disconnect(ifCurrentGeneration generation: UInt64) {
        callbackBox.performIfCurrentGeneration(generation) {
            disconnect()
        }
    }

    public func resize(width: Int, height: Int) {
        guard let signedWidth = Int32(exactly: width),
              let signedHeight = Int32(exactly: height),
              signedWidth > 0, signedHeight > 0 else {
            return
        }
        let width = UInt32(signedWidth)
        let height = UInt32(signedHeight)
        lock.lock()
        let client = client
        lock.unlock()
        _ = rdc_client_resize(client, width, height)
    }

    public func sendPointer(flags: UInt16, x: UInt16, y: UInt16) {
        lock.lock()
        let client = client
        lock.unlock()
        _ = rdc_client_send_pointer(client, flags, x, y)
    }

    public func sendKey(flags: UInt16, code: UInt16) {
        lock.lock()
        let client = client
        lock.unlock()
        _ = rdc_client_send_key(client, flags, code)
    }

    public func sendUnicode(flags: UInt16, codeUnit: UInt16) {
        lock.lock()
        let client = client
        lock.unlock()
        _ = rdc_client_send_unicode(client, flags, codeUnit)
    }

    public func sendSecureAttention() {
        lock.lock()
        let client = client
        lock.unlock()
        _ = rdc_client_send_secure_attention(client)
    }

    public func setClipboardText(_ text: String) {
        let data = Data(text.utf8)
        guard data.count <= 1_048_576 else { return }
        lock.lock()
        let client = client
        lock.unlock()
        data.withUnsafeBytes { bytes in
            _ = rdc_client_set_clipboard_text(
                client, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count
            )
        }
    }
}

private func withOptionalCString<Result>(
    _ value: String?, _ body: (UnsafePointer<CChar>?) -> Result
) -> Result {
    guard let value else { return body(nil) }
    return value.withCString(body)
}

func withCConfiguration<Result>(
    _ configuration: FreeRDPConfiguration,
    _ body: (UnsafePointer<RDCConnectionConfiguration>) -> Result
) -> Result {
    configuration.host.withCString { host in
        withOptionalCString(configuration.username) { username in
            withOptionalCString(configuration.domain) { domain in
                withOptionalCString(configuration.password) { password in
                    var configuration = RDCConnectionConfiguration(
                        host: host,
                        port: configuration.port,
                        username: username,
                        domain: domain,
                        password: password,
                        desktop_width: configuration.desktopWidth,
                        desktop_height: configuration.desktopHeight
                    )
                    return body(&configuration)
                }
            }
        }
    }
}
