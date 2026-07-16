import Foundation
import XCTest
@testable import RdcCore
import RdcFreeRDPBridge

private final class BridgeLifecycleProbe: @unchecked Sendable {
    let didStartConnecting = DispatchSemaphore(value: 0)
    let allowFirstAttemptToProceed = DispatchSemaphore(value: 0)
    let didReachTerminalState = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldBlockConnecting = true
    private let terminalCallbackDelay: TimeInterval

    init(terminalCallbackDelay: TimeInterval = 0) {
        self.terminalCallbackDelay = terminalCallbackDelay
    }

    func handle(state: Int32) {
        if state == Int32(RDCFreeRDPStateConnecting.rawValue) {
            lock.lock()
            let shouldBlock = shouldBlockConnecting
            shouldBlockConnecting = false
            lock.unlock()
            didStartConnecting.signal()
            if shouldBlock {
                _ = allowFirstAttemptToProceed.wait(timeout: .now() + 5)
            }
        } else if state == Int32(RDCFreeRDPStateDisconnected.rawValue) ||
                    state == Int32(RDCFreeRDPStateFailed.rawValue) {
            didReachTerminalState.signal()
            if terminalCallbackDelay > 0 {
                Thread.sleep(forTimeInterval: terminalCallbackDelay)
            }
        }
    }
}

private final class NativeClientReference: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }
}

private final class DestructionProbe: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var destructionWasOnMainThread = true
    private var destructionCount = 0

    func record() {
        lock.lock()
        destructionWasOnMainThread = Thread.isMainThread
        destructionCount += 1
        lock.unlock()
        completed.signal()
    }

    var wasOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return destructionWasOnMainThread
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return destructionCount
    }
}

private final class CommandResultProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int32] = []

    func record(_ value: Int32) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var results: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class NativeCertificateDecisionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var decision: RDCCertificateDecision?
    private var challengeID: UInt64?

    lazy var resolve: NativeResolveCertificate = { [weak self] _, challengeID, decision in
        guard let self else { return -1 }
        lock.lock()
        self.challengeID = challengeID
        self.decision = decision
        lock.unlock()
        return 0
    }

    var lastDecision: RDCCertificateDecision? {
        lock.lock()
        defer { lock.unlock() }
        return decision
    }

    var lastChallengeID: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return challengeID
    }
}

private final class NativeCertificateProbe: @unchecked Sendable {
    struct Snapshot: Equatable {
        let id: UInt64
        let pem: Data
        let host: String
        let port: UInt16
        let flags: UInt32
    }

    let received = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var values: [Snapshot] = []

    func record(_ challenge: UnsafePointer<RDCCertificateChallenge>?) {
        guard let challenge else { return }
        let value = challenge.pointee
        guard let pem = value.pem,
              let host = value.host,
              let copiedHost = String(validatingCString: host) else { return }
        let snapshot = Snapshot(
            id: value.challenge_id,
            pem: Data(bytes: pem, count: value.pem_length),
            host: copiedHost,
            port: value.port,
            flags: value.flags
        )
        lock.lock()
        values.append(snapshot)
        lock.unlock()
        received.signal()
    }

    var snapshots: [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private let nativeCertificateCallback: RDCCertificateCallback = { context, challenge in
    guard let context else { return }
    Unmanaged<NativeCertificateProbe>.fromOpaque(context)
        .takeUnretainedValue()
        .record(challenge)
}

private let lifecycleStateCallback: RDCStateCallback = { context, state, _, _ in
    guard let context else { return }
    Unmanaged<BridgeLifecycleProbe>.fromOpaque(context).takeUnretainedValue().handle(state: state)
}

final class FreeRDPBridgeAPITests: XCTestCase {
    func testBridgeReportsPinnedMajorMinorVersion() {
        XCTAssertEqual(rdc_freerdp_bridge_version(), 30_260)
    }

    func testFrameCopiesBytesBeforeReturningFromCallback() {
        var source = [UInt8](repeating: 7, count: 16)
        let frame = RemoteFrame(width: 2, height: 2, stride: 8, bgraBytes: source)
        source[0] = 99
        XCTAssertEqual(frame.bgraBytes[0], 7)
    }

    func testCertificateCallbackCopiesChallengeAndRoutesDecision() async throws {
        let box = FreeRDPCallbackBox()
        let events = try XCTUnwrap(box.makeStream())
        let pem = try fixturePEM(named: "test-certificate")
        var callbackPEM = Data(pem.utf8)

        emitCertificateCallback(
            box: box, id: 41, host: "203.0.113.120", port: 3389,
            pem: callbackPEM, flags: 0
        )
        callbackPEM.resetBytes(in: callbackPEM.indices)

        let challenge = try await firstCertificateChallenge(from: events)
        XCTAssertEqual(challenge.id, 41)
        XCTAssertEqual(
            challenge.endpoint,
            RdpEndpoint(host: "203.0.113.120", port: 3389)
        )
        XCTAssertEqual(challenge.pemData, Data(pem.utf8))

        let recorder = NativeCertificateDecisionRecorder()
        let bridge = NativeFreeRDPBridge(resolveCertificate: recorder.resolve)
        bridge.resolveCertificate(challengeID: 41, decision: .trustOnce)
        XCTAssertEqual(recorder.lastChallengeID, 41)
        XCTAssertEqual(
            recorder.lastDecision,
            RDCCertificateDecision(rawValue: UInt32(RdpCertificateDecision.trustOnce.rawValue))
        )
    }

    func testCertificateEventsAreNeverCoalescedWithFramesOrEachOther() async throws {
        let box = FreeRDPCallbackBox()
        let events = try XCTUnwrap(box.makeStream())
        let pem = Data(try fixturePEM(named: "test-certificate").utf8)

        box.yield(.frame(RemoteFrame(width: 1, height: 1, stride: 4, bgraBytes: [1, 1, 1, 1])))
        emitCertificateCallback(box: box, id: 1, host: "localhost", port: 3389, pem: pem, flags: 0)
        box.yield(.frame(RemoteFrame(width: 1, height: 1, stride: 4, bgraBytes: [2, 2, 2, 2])))
        emitCertificateCallback(box: box, id: 2, host: "localhost", port: 3389, pem: pem, flags: 0)
        box.yield(.disconnected, finishing: true)

        let received = await events.reduce(into: [UInt64]()) { ids, event in
            if case let .certificateChallenge(challenge) = event {
                ids.append(challenge.id)
            }
        }
        XCTAssertEqual(received, [1, 2])
    }

    func testCertificateCallbackSafelyDropsInvalidUTF8HostAndNilPEM() async throws {
        let box = FreeRDPCallbackBox()
        let events = try XCTUnwrap(box.makeStream())
        let pem = Data(try fixturePEM(named: "test-certificate").utf8)
        let invalidHost: [CChar] = [-1, 0]

        invalidHost.withUnsafeBufferPointer { host in
            pem.withUnsafeBytes { bytes in
                var invalidUTF8 = RDCCertificateChallenge(
                    challenge_id: 10,
                    pem: bytes.bindMemory(to: UInt8.self).baseAddress,
                    pem_length: pem.count,
                    host: host.baseAddress,
                    port: 3389,
                    flags: 0
                )
                certificateCallback(Unmanaged.passUnretained(box).toOpaque(), &invalidUTF8)
            }
        }
        "localhost".withCString { host in
            var nilPEM = RDCCertificateChallenge(
                challenge_id: 11,
                pem: nil,
                pem_length: 1,
                host: host,
                port: 3389,
                flags: 0
            )
            certificateCallback(Unmanaged.passUnretained(box).toOpaque(), &nilPEM)
        }
        box.yield(.disconnected, finishing: true)

        let certificateCount = await events.reduce(into: 0) { count, event in
            if case .certificateChallenge = event {
                count += 1
            }
        }
        XCTAssertEqual(certificateCount, 0)
    }

    func testNativeCertificateCallbackRejectsMalformedChallengeWithoutHanging() throws {
        let validPEM = Data(try fixturePEM(named: "test-certificate").utf8)

        try assertNativeSwiftCertificateRejection(
            pem: validPEM,
            host: [-1, 0],
            message: "invalid UTF-8 host"
        )
        try assertNativeSwiftCertificateRejection(
            pem: nil,
            host: Array("localhost".utf8CString),
            pemLength: 1,
            message: "nil PEM"
        )
        try assertNativeSwiftCertificateRejection(
            pem: Data(),
            host: Array("localhost".utf8CString),
            message: "empty PEM"
        )
        try assertNativeSwiftCertificateRejection(
            pem: Data("-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n".utf8),
            host: Array("localhost".utf8CString),
            message: "Security certificate parse failure"
        )
    }

    func testNativeCertificateCallbackReturnsExactDecisionAndRejectsDuplicates() throws {
        for expected in [
            RDCCertificateDecisionReject,
            RDCCertificateDecisionTrustAlways,
            RDCCertificateDecisionTrustOnce,
        ] {
            let probe = NativeCertificateProbe()
            let client = try makeNativeCertificateClient(probe: probe)
            defer { rdc_client_destroy(client) }
            let invocation = invokeNativeCertificate(
                client: client,
                pem: Data(try fixturePEM(named: "test-certificate").utf8),
                host: "localhost",
                port: 3389,
                flags: 0x80
            )

            XCTAssertEqual(probe.received.wait(timeout: .now() + 2), .success)
            let snapshot = try XCTUnwrap(probe.snapshots.last)
            XCTAssertEqual(snapshot.host, "localhost")
            XCTAssertEqual(snapshot.port, 3389)
            XCTAssertEqual(snapshot.flags, 0x80)
            XCTAssertEqual(
                rdc_client_resolve_certificate(client, snapshot.id + 1, expected),
                -1
            )
            XCTAssertEqual(rdc_client_resolve_certificate(client, snapshot.id, expected), 0)
            XCTAssertEqual(rdc_client_resolve_certificate(client, snapshot.id, expected), -1)
            XCTAssertEqual(invocation.completed.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(invocation.result, Int32(expected.rawValue))
        }
    }

    func testNativeCertificateWaitIsCancelledByDisconnect() throws {
        let probe = NativeCertificateProbe()
        let client = try makeNativeCertificateClient(probe: probe)
        defer { rdc_client_destroy(client) }
        let invocation = invokeNativeCertificate(
            client: client,
            pem: Data(try fixturePEM(named: "test-certificate").utf8),
            host: "localhost", port: 3389, flags: 0
        )

        XCTAssertEqual(probe.received.wait(timeout: .now() + 2), .success)
        rdc_client_disconnect(client)
        XCTAssertEqual(invocation.completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(invocation.result, 0)
    }

    func testDestroyCancelsNativeCertificateWaitBeforeFreeingClient() throws {
        let probe = NativeCertificateProbe()
        let client = try makeNativeCertificateClient(probe: probe)
        let invocation = invokeNativeCertificate(
            client: client,
            pem: Data(try fixturePEM(named: "test-certificate").utf8),
            host: "localhost", port: 3389, flags: 0
        )

        XCTAssertEqual(probe.received.wait(timeout: .now() + 2), .success)
        rdc_client_destroy(client)
        XCTAssertEqual(invocation.completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(invocation.result, 0)
    }

    func testDestroyRacingCertificateCallbackCompletionIsStable() throws {
        let pem = Data(try fixturePEM(named: "test-certificate").utf8)

        for iteration in 0..<200 {
            let probe = NativeCertificateProbe()
            let client = try makeNativeCertificateClient(probe: probe)
            let invocation = invokeNativeCertificate(
                client: client, pem: pem, host: "localhost", port: 3389, flags: 0
            )

            XCTAssertEqual(
                probe.received.wait(timeout: .now() + 2), .success,
                "callback was not reached at iteration \(iteration)"
            )
            rdc_client_destroy(client)
            XCTAssertEqual(
                invocation.completed.wait(timeout: .now() + 2), .success,
                "callback did not finish at iteration \(iteration)"
            )
            XCTAssertEqual(invocation.result, 0, "iteration \(iteration)")
        }
    }

    func testOldCertificateIDCannotResolveReplacementChallenge() throws {
        let probe = NativeCertificateProbe()
        let client = try makeNativeCertificateClient(probe: probe)
        defer { rdc_client_destroy(client) }
        let pem = Data(try fixturePEM(named: "test-certificate").utf8)

        let first = invokeNativeCertificate(
            client: client, pem: pem, host: "localhost", port: 3389, flags: 0
        )
        XCTAssertEqual(probe.received.wait(timeout: .now() + 2), .success)
        let firstID = try XCTUnwrap(probe.snapshots.last?.id)
        XCTAssertEqual(
            rdc_client_resolve_certificate(client, firstID, RDCCertificateDecisionTrustOnce),
            0
        )
        XCTAssertEqual(first.completed.wait(timeout: .now() + 2), .success)

        let replacement = invokeNativeCertificate(
            client: client, pem: pem, host: "localhost", port: 3389, flags: 0
        )
        XCTAssertEqual(probe.received.wait(timeout: .now() + 2), .success)
        let replacementID = try XCTUnwrap(probe.snapshots.last?.id)
        XCTAssertGreaterThan(replacementID, firstID)
        XCTAssertEqual(
            rdc_client_resolve_certificate(client, firstID, RDCCertificateDecisionTrustAlways),
            -1
        )
        XCTAssertEqual(
            rdc_client_resolve_certificate(
                client, replacementID, RDCCertificateDecisionTrustAlways
            ),
            0
        )
        XCTAssertEqual(replacement.completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(replacement.result, 1)
    }

    func testTrustAlwaysUsesExternalManagementWithoutFreeRDPStorePersistence() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("rdc-certificate-store-\(UUID().uuidString)")
        let serverDirectory = root.appendingPathComponent("server")
        let configDirectory = root.appendingPathComponent("config")
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let script = try XCTUnwrap(
            Bundle.module.url(
                forResource: "fake_rdp_tls_server",
                withExtension: "py",
                subdirectory: "Fixtures"
            )
        )
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script.path, serverDirectory.path]
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning {
                server.terminate()
                server.waitUntilExit()
            }
        }

        let ready = serverDirectory.appendingPathComponent("ready")
        XCTAssertTrue(
            waitForFile(ready, timeout: 5),
            "loopback RDP/TLS server did not become ready"
        )
        let port = try XCTUnwrap(
            UInt16(try String(contentsOf: ready, encoding: .utf8))
        )
        let probe = NativeCertificateProbe()
        let client = try makeNativeCertificateClient(probe: probe)
        var clientToDestroy: OpaquePointer? = client
        defer { rdc_client_destroy(clientToDestroy) }
        XCTAssertEqual(
            configDirectory.path.withCString {
                rdc_client_test_set_config_path(client, $0)
            },
            0
        )

        let connectResult = "127.0.0.1".withCString { host in
            var configuration = RDCConnectionConfiguration(
                host: host, port: port, username: nil, domain: nil, password: nil,
                desktop_width: 1024, desktop_height: 768
            )
            return rdc_client_connect(client, &configuration)
        }
        XCTAssertEqual(connectResult, 0)
        XCTAssertEqual(probe.received.wait(timeout: .now() + 5), .success)
        let challenge = try XCTUnwrap(probe.snapshots.last)
        XCTAssertEqual(challenge.host, "127.0.0.1")
        XCTAssertEqual(
            rdc_client_resolve_certificate(
                client, challenge.id, RDCCertificateDecisionTrustAlways
            ),
            0
        )

        let handshake = serverDirectory.appendingPathComponent("handshake-complete")
        XCTAssertTrue(
            waitForFile(handshake, timeout: 5),
            "FreeRDP did not complete the loopback TLS handshake"
        )
        rdc_client_destroy(client)
        clientToDestroy = nil

        XCTAssertEqual(
            try fileManager.subpathsOfDirectory(atPath: configDirectory.path),
            [],
            "FreeRDP external certificate management must not write known_hosts or cert files"
        )
    }

    func testBridgeConfigurationCarriesEndpointCredentialAndInitialViewportToCSeam() {
        let configuration = FreeRDPConfiguration(
            host: "example.invalid", port: 3390,
            username: "user", domain: "DOMAIN", password: "secret",
            desktopWidth: 1_440, desktopHeight: 900
        )
        XCTAssertEqual(configuration.port, 3390)
        XCTAssertEqual(configuration.password, "secret")
        withCConfiguration(configuration) { native in
            XCTAssertEqual(native.pointee.desktop_width, 1_440)
            XCTAssertEqual(native.pointee.desktop_height, 900)
        }
    }

    func testNativeClientRejectsOverlappingConnectAndAllowsReconnectAfterCompletion() {
        let probe = BridgeLifecycleProbe(terminalCallbackDelay: 0.2)
        guard let client = rdc_client_create(
            Unmanaged.passUnretained(probe).toOpaque(), nil, lifecycleStateCallback, nil
        ) else {
            return XCTFail("Expected native client allocation to succeed")
        }
        defer { rdc_client_destroy(client) }

        "example.invalid".withCString { host in
            var configuration = RDCConnectionConfiguration(
                host: host, port: 3390, username: nil, domain: nil, password: nil,
                desktop_width: 1024, desktop_height: 768
            )

            XCTAssertEqual(rdc_client_connect(client, &configuration), 0)
            XCTAssertEqual(probe.didStartConnecting.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(rdc_client_connect(client, &configuration), -1)

            rdc_client_disconnect(client)
            probe.allowFirstAttemptToProceed.signal()
            XCTAssertEqual(probe.didReachTerminalState.wait(timeout: .now() + 5), .success)

            XCTAssertEqual(rdc_client_connect(client, &configuration), 0)
            rdc_client_disconnect(client)
        }
    }

    func testNativeResizeAcceptsValidDimensionsBeforeConnection() {
        guard let client = rdc_client_create(nil, nil, nil, nil) else {
            return XCTFail("Expected native client allocation to succeed")
        }
        defer { rdc_client_destroy(client) }

        XCTAssertEqual(rdc_client_resize(client, 1_200, 800), 0)
    }

    func testNativeResizeValidatesSignedMonitorBoundaryBeforeCasting() {
        guard let client = rdc_client_create(nil, nil, nil, nil) else {
            return XCTFail("Expected native client allocation to succeed")
        }
        defer { rdc_client_destroy(client) }

        XCTAssertEqual(rdc_client_resize(client, UInt32(Int32.max), UInt32(Int32.max)), 0)
        XCTAssertEqual(rdc_client_resize(client, UInt32(Int32.max) + 1, 800), -1)
        XCTAssertEqual(rdc_client_resize(client, 1_200, UInt32(Int32.max) + 1), -1)
    }

    func testNativeConnectPreparationEnablesDisplayControlChannel() {
        guard let client = rdc_client_create(nil, nil, nil, nil) else {
            return XCTFail("Expected native client allocation to succeed")
        }
        defer { rdc_client_destroy(client) }

        XCTAssertEqual(rdc_client_test_prepare_display_control(client), 0)
        XCTAssertEqual(rdc_client_test_display_control_supported(client), 1)
        XCTAssertEqual(rdc_client_test_dynamic_resolution_enabled(client), 1)
    }

    func testNativeResizeNoOpsUntilDisplayControlCapabilitiesArrive() {
        guard let client = rdc_client_create(nil, nil, nil, nil) else {
            return XCTFail("Expected native client allocation to succeed")
        }
        defer { rdc_client_destroy(client) }

        XCTAssertEqual(rdc_client_test_dispatch_resize(client, 1_440, 900), 0)
        XCTAssertEqual(rdc_client_test_sent_display_layout_count(client), 0)
    }

    func testNativeResizeQueuedBeforeCapabilitiesIsSentWhenCapabilitiesArrive() {
        guard let client = rdc_client_create(nil, nil, nil, nil) else {
            return XCTFail("Expected native client allocation to succeed")
        }
        defer { rdc_client_destroy(client) }

        XCTAssertEqual(rdc_client_test_dispatch_resize(client, 1_440, 900), 0)
        XCTAssertEqual(rdc_client_test_attach_display_control(client), 0)
        XCTAssertEqual(rdc_client_test_receive_display_control_caps(client, 16, 8_192, 8_192), 0)
        XCTAssertEqual(rdc_client_test_sent_display_layout_count(client), 1)
        XCTAssertEqual(rdc_client_test_sent_display_layout_width(client), 1_440)
        XCTAssertEqual(rdc_client_test_sent_display_layout_height(client), 900)
    }

    func testNativeResizeBeforeCapabilitiesSendsOnlyLatestPendingLayoutOnce() {
        guard let client = rdc_client_create(nil, nil, nil, nil) else {
            return XCTFail("Expected native client allocation to succeed")
        }
        defer { rdc_client_destroy(client) }

        XCTAssertEqual(rdc_client_test_dispatch_resize(client, 1_200, 800), 0)
        XCTAssertEqual(rdc_client_test_dispatch_resize(client, 1_600, 1_000), 0)
        XCTAssertEqual(rdc_client_test_sent_display_layout_count(client), 0)
        XCTAssertEqual(rdc_client_test_attach_display_control(client), 0)
        XCTAssertEqual(rdc_client_test_receive_display_control_caps(client, 16, 8_192, 8_192), 0)
        XCTAssertEqual(rdc_client_test_sent_display_layout_count(client), 1)
        XCTAssertEqual(rdc_client_test_sent_display_layout_width(client), 1_600)
        XCTAssertEqual(rdc_client_test_sent_display_layout_height(client), 1_000)
    }

    func testNativeResizeUsesDisplayControlChannelAfterCapabilitiesArrive() {
        guard let client = rdc_client_create(nil, nil, nil, nil) else {
            return XCTFail("Expected native client allocation to succeed")
        }
        defer { rdc_client_destroy(client) }

        XCTAssertEqual(rdc_client_test_attach_display_control(client), 0)
        XCTAssertEqual(rdc_client_test_receive_display_control_caps(client, 16, 8_192, 8_192), 0)
        XCTAssertEqual(rdc_client_test_dispatch_resize(client, 1_440, 900), 0)
        XCTAssertEqual(rdc_client_test_sent_display_layout_count(client), 1)
        XCTAssertEqual(rdc_client_test_sent_display_layout_width(client), 1_440)
        XCTAssertEqual(rdc_client_test_sent_display_layout_height(client), 900)
    }

    func testNativeDisplayControlDisconnectMakesFutureResizeANoop() {
        guard let client = rdc_client_create(nil, nil, nil, nil) else {
            return XCTFail("Expected native client allocation to succeed")
        }
        defer { rdc_client_destroy(client) }

        XCTAssertEqual(rdc_client_test_attach_display_control(client), 0)
        XCTAssertEqual(rdc_client_test_receive_display_control_caps(client, 16, 8_192, 8_192), 0)
        XCTAssertEqual(rdc_client_test_detach_display_control(client), 0)
        XCTAssertEqual(rdc_client_test_dispatch_resize(client, 1_600, 1_000), 0)
        XCTAssertEqual(rdc_client_test_sent_display_layout_count(client), 0)
    }

    func testNativeDisplayControlResizeClampsProtocolDimensions() {
        guard let client = rdc_client_create(nil, nil, nil, nil) else {
            return XCTFail("Expected native client allocation to succeed")
        }
        defer { rdc_client_destroy(client) }

        XCTAssertEqual(rdc_client_test_attach_display_control(client), 0)
        XCTAssertEqual(rdc_client_test_receive_display_control_caps(client, 16, 8_192, 8_192), 0)
        XCTAssertEqual(rdc_client_test_dispatch_resize(client, 100, 9_000), 0)
        XCTAssertEqual(rdc_client_test_sent_display_layout_width(client), 200)
        XCTAssertEqual(rdc_client_test_sent_display_layout_height(client), 8_192)
    }

    func testNativeDisplayControlResizeHonorsServerAreaLimit() {
        guard let client = rdc_client_create(nil, nil, nil, nil) else {
            return XCTFail("Expected native client allocation to succeed")
        }
        defer { rdc_client_destroy(client) }

        XCTAssertEqual(rdc_client_test_attach_display_control(client), 0)
        XCTAssertEqual(rdc_client_test_receive_display_control_caps(client, 16, 1_000, 1_000), 0)
        XCTAssertEqual(rdc_client_test_dispatch_resize(client, 1_600, 1_000), 0)
        let width = rdc_client_test_sent_display_layout_width(client)
        let height = rdc_client_test_sent_display_layout_height(client)
        XCTAssertLessThanOrEqual(UInt64(width) * UInt64(height), 1_000_000)
        XCTAssertGreaterThanOrEqual(width, 200)
        XCTAssertGreaterThanOrEqual(height, 200)
    }

    func testConcurrentCommandsWaitForWorkerAndCompleteWhenDisconnectCancelsAttempt() {
        let probe = BridgeLifecycleProbe()
        guard let client = rdc_client_create(
            Unmanaged.passUnretained(probe).toOpaque(), nil, lifecycleStateCallback, nil
        ) else {
            return XCTFail("Expected native client allocation to succeed")
        }
        let reference = NativeClientReference(client)
        defer { rdc_client_destroy(client) }

        "example.invalid".withCString { host in
            var configuration = RDCConnectionConfiguration(
                host: host, port: 3390, username: nil, domain: nil, password: nil,
                desktop_width: 1024, desktop_height: 768
            )
            XCTAssertEqual(rdc_client_connect(client, &configuration), 0)
            XCTAssertEqual(probe.didStartConnecting.wait(timeout: .now() + 2), .success)

            let commandCount = 32
            let commandsCompleted = DispatchGroup()
            let results = CommandResultProbe()
            let queue = DispatchQueue(label: "FreeRDPBridgeAPITests.commands", attributes: .concurrent)
            for index in 0..<commandCount {
                commandsCompleted.enter()
                queue.async {
                    let result: Int32
                    switch index % 3 {
                    case 0:
                        result = rdc_client_resize(reference.pointer, 1_200, 800)
                    case 1:
                        result = rdc_client_send_pointer(reference.pointer, 0x0800, 10, 20)
                    default:
                        result = rdc_client_send_key(reference.pointer, 0, 30)
                    }
                    results.record(result)
                    commandsCompleted.leave()
                }
            }

            XCTAssertEqual(commandsCompleted.wait(timeout: .now() + 0.05), .timedOut)
            queue.async { rdc_client_disconnect(reference.pointer) }
            probe.allowFirstAttemptToProceed.signal()
            XCTAssertEqual(probe.didReachTerminalState.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(commandsCompleted.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(results.results.count, commandCount)
            XCTAssertTrue(results.results.allSatisfy { $0 == -1 }, "results: \(results.results)")
        }
    }

    @MainActor
    func testDeinitSchedulesNativeDestructionOffMainThreadWithoutBlockingRelease() {
        let probe = DestructionProbe()
        var bridge: NativeFreeRDPBridge? = NativeFreeRDPBridge { client in
            Thread.sleep(forTimeInterval: 0.2)
            rdc_client_destroy(client)
            probe.record()
        }
        XCTAssertNotNil(bridge)

        let started = Date()
        bridge = nil
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        XCTAssertEqual(probe.completed.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(probe.wasOnMainThread)
        XCTAssertEqual(probe.count, 1)
    }

    func testBoundedFrameBufferCoalescesFramesButPreservesTerminalEvent() async {
        let box = FreeRDPCallbackBox()
        guard let stream = box.makeStream() else {
            return XCTFail("Expected stream installation to succeed")
        }
        box.yield(.connecting)
        for value in UInt8(0)..<100 {
            box.yield(
                .frame(RemoteFrame(width: 1, height: 1, stride: 4,
                                   bgraBytes: [value, value, value, value]))
            )
        }
        box.yield(.connected)
        for value in UInt8(100)..<200 {
            box.yield(
                .frame(RemoteFrame(width: 1, height: 1, stride: 4,
                                   bgraBytes: [value, value, value, value]))
            )
        }
        box.yield(.disconnected, finishing: true)

        var events: [FreeRDPBridgeEvent] = []
        for await event in stream {
            events.append(event)
        }
        XCTAssertEqual(events.last, .disconnected)
        XCTAssertEqual(events.filter {
            if case .connecting = $0 { return true }
            if case .connected = $0 { return true }
            if case .disconnected = $0 { return true }
            return false
        }, [.connecting, .connected, .disconnected])
        XCTAssertLessThanOrEqual(events.filter {
            if case .frame = $0 { return true }
            return false
        }.count, 1)
    }

    func testNativeBridgeRejectsReplacementStreamWithoutTerminatingActiveStream() async {
        let bridge = NativeFreeRDPBridge()
        let configuration = FreeRDPConfiguration(
            host: "example.invalid", port: 3390,
            username: nil, domain: nil, password: nil,
            desktopWidth: 1_024, desktopHeight: 768
        )
        let firstStream = bridge.connect(configuration: configuration)
        let replacementStream = bridge.connect(configuration: configuration)

        var replacementIterator = replacementStream.makeAsyncIterator()
        let replacementEvent = await replacementIterator.next()
        XCTAssertEqual(
            replacementEvent,
            .failed(code: -1, message: "A FreeRDP connection is already active")
        )

        var firstIterator = firstStream.makeAsyncIterator()
        let firstEvent = await firstIterator.next()
        XCTAssertNotNil(firstEvent)
        bridge.disconnect()
    }

    func testDeallocatingFinishedStreamDoesNotCancelNewGeneration() async {
        let box = FreeRDPCallbackBox()
        let cancellations = CancellationProbe()
        var firstStream: AsyncStream<FreeRDPBridgeEvent>? = box.makeStream(onCancel: { generation in
            box.performIfCurrentGeneration(generation) {
                cancellations.record()
            }
        })
        guard firstStream != nil else {
            return XCTFail("Expected first stream installation to succeed")
        }

        box.yield(.disconnected, finishing: true)
        await assertDisconnectedAndFinished(firstStream!)

        guard let secondStream = box.makeStream(onCancel: { generation in
            box.performIfCurrentGeneration(generation) {
                cancellations.record()
            }
        }) else {
            return XCTFail("Expected second stream installation to succeed")
        }

        firstStream = nil
        XCTAssertEqual(cancellations.count, 0)

        box.yield(.connected)
        var secondIterator = secondStream.makeAsyncIterator()
        let secondEvent = await secondIterator.next()
        XCTAssertEqual(secondEvent, .connected)
        XCTAssertEqual(cancellations.count, 0)
        box.yield(.disconnected, finishing: true)
    }

    private func assertDisconnectedAndFinished(_ stream: AsyncStream<FreeRDPBridgeEvent>) async {
        var iterator = stream.makeAsyncIterator()
        let terminal = await iterator.next()
        let finished = await iterator.next()
        XCTAssertEqual(terminal, .disconnected)
        XCTAssertNil(finished)
    }

    private func fixturePEM(named name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: "pem",
                subdirectory: "Fixtures"
            )
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func firstCertificateChallenge(
        from events: AsyncStream<FreeRDPBridgeEvent>
    ) async throws -> RdpCertificateChallenge {
        for await event in events {
            if case let .certificateChallenge(challenge) = event {
                return challenge
            }
        }
        throw CertificateChallengeTestError.streamEnded
    }

    private func emitCertificateCallback(
        box: FreeRDPCallbackBox,
        id: UInt64,
        host: String,
        port: UInt16,
        pem: Data,
        flags: UInt32
    ) {
        host.withCString { hostPointer in
            pem.withUnsafeBytes { bytes in
                var challenge = RDCCertificateChallenge(
                    challenge_id: id,
                    pem: bytes.bindMemory(to: UInt8.self).baseAddress,
                    pem_length: pem.count,
                    host: hostPointer,
                    port: port,
                    flags: flags
                )
                certificateCallback(Unmanaged.passUnretained(box).toOpaque(), &challenge)
            }
        }
    }

    private func makeNativeCertificateClient(
        probe: NativeCertificateProbe
    ) throws -> OpaquePointer {
        try XCTUnwrap(
            rdc_client_create(
                Unmanaged.passUnretained(probe).toOpaque(), nil, nil,
                nativeCertificateCallback
            )
        )
    }

    private func invokeNativeCertificate(
        client: OpaquePointer,
        pem: Data,
        host: String,
        port: UInt16,
        flags: UInt32
    ) -> NativeCertificateInvocation {
        let invocation = NativeCertificateInvocation()
        let clientReference = NativeClientReference(client)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = host.withCString { hostPointer in
                pem.withUnsafeBytes { bytes in
                    rdc_client_test_invoke_certificate(
                        clientReference.pointer,
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        pem.count,
                        hostPointer,
                        port,
                        flags
                    )
                }
            }
            invocation.finish(result)
        }
        return invocation
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private func assertNativeSwiftCertificateRejection(
        pem: Data?,
        host: [CChar],
        pemLength: Int? = nil,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let box = FreeRDPCallbackBox()
        let client = try XCTUnwrap(
            rdc_client_create(
                Unmanaged.passUnretained(box).toOpaque(), nil, nil, certificateCallback
            ),
            file: file, line: line
        )
        box.installNativeClient(
            client,
            resolveCertificate: { rdc_client_resolve_certificate($0, $1, $2) }
        )
        let invocation = invokeNativeCertificate(
            client: client,
            pem: pem,
            pemLength: pemLength,
            host: host,
            port: 3389,
            flags: 0
        )

        let completed = invocation.completed.wait(timeout: .now() + 1)
        rdc_client_destroy(client)
        box.clearNativeClient(client)
        if completed != .success {
            _ = invocation.completed.wait(timeout: .now() + 2)
        }
        XCTAssertEqual(completed, .success, "hung for \(message)", file: file, line: line)
        XCTAssertEqual(invocation.result, 0, message, file: file, line: line)
    }

    private func invokeNativeCertificate(
        client: OpaquePointer,
        pem: Data?,
        pemLength: Int? = nil,
        host: [CChar],
        port: UInt16,
        flags: UInt32
    ) -> NativeCertificateInvocation {
        let invocation = NativeCertificateInvocation()
        let clientReference = NativeClientReference(client)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = host.withUnsafeBufferPointer { hostBuffer in
                if let pem {
                    return pem.withUnsafeBytes { bytes in
                        rdc_client_test_invoke_certificate(
                            clientReference.pointer,
                            bytes.bindMemory(to: UInt8.self).baseAddress,
                            pemLength ?? pem.count,
                            hostBuffer.baseAddress,
                            port,
                            flags
                        )
                    }
                }
                return rdc_client_test_invoke_certificate(
                    clientReference.pointer,
                    nil,
                    pemLength ?? 0,
                    hostBuffer.baseAddress,
                    port,
                    flags
                )
            }
            invocation.finish(result)
        }
        return invocation
    }
}

private enum CertificateChallengeTestError: Error {
    case streamEnded
}

private final class NativeCertificateInvocation: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedResult: Int32?

    func finish(_ result: Int32) {
        lock.lock()
        storedResult = result
        lock.unlock()
        completed.signal()
    }

    var result: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }
}
