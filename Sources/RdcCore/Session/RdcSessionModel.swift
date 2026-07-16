import Combine
import Foundation

public protocol CertificateChallengeClock: Sendable {
    func sleep(for duration: Duration) async throws
}

private struct SystemCertificateChallengeClock: CertificateChallengeClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

@MainActor
public final class RdcSessionModel: ObservableObject {
    @Published public private(set) var descriptor: RdpSessionDescriptor?
    @Published public private(set) var frame: RemoteFrame?
    @Published public private(set) var isConnecting = false
    @Published public private(set) var presentedError: String?
    @Published public private(set) var lastError: RdpSessionError?
    @Published public private(set) var pendingCertificate: CertificateTrustPresentation?
    @Published public private(set) var clipboardText: String?

    // Internal consumption acknowledgements make stream-ordering tests causal.
    private(set) var consumedLifecycleUpdateCount: UInt64 = 0
    private(set) var consumedFrameUpdateCount: UInt64 = 0
    private(set) var consumedCertificateChallengeCount: UInt64 = 0
    private(set) var consumedClipboardUpdateCount: UInt64 = 0

    private let engine: any RdpSessionEngine
    private var connectionTask: Task<RdpSessionDescriptor, Error>?
    private var lifecycleTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var certificateTask: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    private var certificateTimeoutTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0
    public private(set) var hasActiveEngineSession = false
    private var isShutDown = false
    private(set) var activeConnectionAttemptID: RdpConnectionAttemptID?
    private var activeEngineSessionID: String?
    private var activeEndpoint: RdpEndpoint?
    private let certificateCoordinator: CertificateTrustCoordinator?
    private let certificateClock: any CertificateChallengeClock
    private var pendingCertificateContext: PendingCertificateContext?

    private struct PendingCertificateContext: Equatable, Sendable {
        let attemptID: RdpConnectionAttemptID
        let sessionID: String
        let challenge: RdpCertificateChallenge
    }

    public struct PendingCertificateToken: Equatable, Sendable {
        public let attemptID: RdpConnectionAttemptID
        public let challengeID: UInt64

        public init(attemptID: RdpConnectionAttemptID, challengeID: UInt64) {
            self.attemptID = attemptID
            self.challengeID = challengeID
        }
    }

    public var pendingCertificateToken: PendingCertificateToken? {
        guard let context = pendingCertificateContext else { return nil }
        return PendingCertificateToken(
            attemptID: context.attemptID,
            challengeID: context.challenge.id
        )
    }

    public init(
        engine: any RdpSessionEngine,
        lifecycleUpdates: AsyncStream<RdpSessionLifecycleUpdate>? = nil,
        frameUpdates: AsyncStream<RdpSessionFrameUpdate>? = nil,
        certificateChallenges: AsyncStream<RdpCertificateChallengeUpdate>? = nil,
        clipboardUpdates: AsyncStream<RdpClipboardUpdate>? = nil,
        certificateCoordinator: CertificateTrustCoordinator? = nil,
        certificateClock: (any CertificateChallengeClock)? = nil
    ) {
        self.engine = engine
        self.certificateCoordinator = certificateCoordinator
        self.certificateClock = certificateClock ?? SystemCertificateChallengeClock()
        if let lifecycleUpdates {
            lifecycleTask = Task { [weak self] in
                for await update in lifecycleUpdates {
                    guard !Task.isCancelled else { return }
                    self?.consumedLifecycleUpdateCount &+= 1
                    await self?.receiveLifecycle(update)
                }
            }
        }
        if let frameUpdates {
            frameTask = Task { [weak self] in
                for await update in frameUpdates {
                    guard !Task.isCancelled else { return }
                    self?.consumedFrameUpdateCount &+= 1
                    self?.receiveFrame(update)
                }
            }
        }
        if let certificateChallenges {
            certificateTask = Task { [weak self] in
                for await update in certificateChallenges {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.consumedCertificateChallengeCount &+= 1
                    await self.receiveCertificate(update)
                }
            }
        }
        if let clipboardUpdates {
            clipboardTask = Task { [weak self] in
                for await update in clipboardUpdates {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.consumedClipboardUpdateCount &+= 1
                    self.receiveClipboard(update)
                }
            }
        }
    }

    deinit {
        connectionTask?.cancel()
        lifecycleTask?.cancel()
        frameTask?.cancel()
        certificateTask?.cancel()
        clipboardTask?.cancel()
        certificateTimeoutTask?.cancel()
    }

    public func connect(
        server: RdcImportedServer,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport
    ) async throws {
        guard !isShutDown else { throw CancellationError() }
        if hasActiveEngineSession || connectionTask != nil || descriptor != nil {
            await disconnect()
        }

        presentedError = nil
        lastError = nil
        frame = nil
        clipboardText = nil
        isConnecting = true
        hasActiveEngineSession = true
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let attemptID = RdpConnectionAttemptID()
        activeConnectionAttemptID = attemptID
        activeEngineSessionID = nil
        let request = server.connectionRequest
        activeEndpoint = UInt16(exactly: request.port ?? 3_389).map {
            RdpEndpoint(host: request.host, port: $0)
        }
        let engine = self.engine
        let task = Task {
            try await engine.connect(
                server.connectionRequest,
                credential: credential,
                viewport: viewport,
                attemptID: attemptID
            )
        }
        connectionTask = task

        do {
            let connectedDescriptor = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard generation == connectionGeneration else {
                throw CancellationError()
            }
            guard activeConnectionAttemptID == attemptID else {
                throw CancellationError()
            }
            descriptor = connectedDescriptor
            activeEngineSessionID = connectedDescriptor.id
            connectionTask = nil
            isConnecting = false
        } catch {
            if generation == connectionGeneration {
                connectionTask = nil
                activeConnectionAttemptID = nil
                activeEngineSessionID = nil
                activeEndpoint = nil
                isConnecting = false
                hasActiveEngineSession = false
                descriptor = nil
                frame = nil
                clipboardText = nil
                if !(error is CancellationError) {
                    lastError = error as? RdpSessionError
                    presentedError = Self.message(for: error)
                }
            }
            throw error
        }
    }

    public func disconnect() async {
        await rejectPendingCertificate()
        connectionGeneration &+= 1
        activeConnectionAttemptID = nil
        activeEngineSessionID = nil
        activeEndpoint = nil
        let shouldDisconnectEngine = hasActiveEngineSession || connectionTask != nil
        connectionTask?.cancel()
        connectionTask = nil
        if shouldDisconnectEngine {
            await engine.disconnect()
        }
        hasActiveEngineSession = false
        descriptor = nil
        frame = nil
        clipboardText = nil
        lastError = nil
        isConnecting = false
    }

    /// Disconnects for a destructive operation and preserves the visible active
    /// session state when the engine cannot verify termination.
    public func disconnectForResourceMutation() async throws {
        await rejectPendingCertificate()
        let shouldDisconnectEngine = hasActiveEngineSession || connectionTask != nil
        guard shouldDisconnectEngine else {
            await disconnect()
            return
        }
        try await engine.disconnectVerified()
        connectionGeneration &+= 1
        activeConnectionAttemptID = nil
        activeEngineSessionID = nil
        activeEndpoint = nil
        connectionTask?.cancel()
        connectionTask = nil
        hasActiveEngineSession = false
        descriptor = nil
        frame = nil
        clipboardText = nil
        lastError = nil
        isConnecting = false
    }

    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        await disconnect()
        let lifecycleTask = lifecycleTask
        let frameTask = frameTask
        let certificateTask = certificateTask
        let clipboardTask = clipboardTask
        self.lifecycleTask = nil
        self.frameTask = nil
        self.certificateTask = nil
        self.clipboardTask = nil
        lifecycleTask?.cancel()
        frameTask?.cancel()
        certificateTask?.cancel()
        clipboardTask?.cancel()
        certificateTimeoutTask?.cancel()
        await lifecycleTask?.value
        await frameTask?.value
        await certificateTask?.value
        await clipboardTask?.value
    }

    public func clearPresentedError() {
        presentedError = nil
        lastError = nil
    }

    public func resolvePendingCertificate(decision: RdpCertificateDecision) async {
        await resolvePendingCertificate(decision: decision, expectedToken: nil)
    }

    public func resolvePendingCertificate(
        decision: RdpCertificateDecision,
        expectedToken: PendingCertificateToken?
    ) async {
        if let expectedToken, pendingCertificateToken != expectedToken { return }
        guard let context = takePendingCertificate() else { return }
        guard let certificateCoordinator else {
            await resolveCertificate(context: context, decision: .reject)
            return
        }
        do {
            let prepared = try await certificateCoordinator.prepareResolution(
                challenge: context.challenge,
                decision: decision
            )
            guard activeConnectionAttemptID == context.attemptID,
                  activeEngineSessionID == context.sessionID else { return }
            await resolveCertificate(context: context, decision: prepared)
        } catch {
            await resolveCertificate(context: context, decision: .reject)
            presentedError = "无法保存证书信任设置。"
        }
    }

    public func resize(width: Int, height: Int) {
        guard let sessionID = descriptor?.id else { return }
        Task { await engine.resize(sessionID: sessionID, width: width, height: height) }
    }

    public func sendPointer(_ event: RemotePointerEvent) {
        guard let sessionID = descriptor?.id else { return }
        guard let x = UInt16(exactly: event.point.x),
              let y = UInt16(exactly: event.point.y) else { return }
        Task {
            await engine.sendPointer(
                sessionID: sessionID, flags: event.flags, x: x, y: y
            )
        }
    }

    public func sendKey(_ event: RemoteKeyEvent) {
        guard let sessionID = descriptor?.id else { return }
        Task {
            await engine.sendKey(
                sessionID: sessionID, flags: event.flags, code: event.scanCode
            )
        }
    }

    public func sendUnicode(_ event: RemoteUnicodeKeyEvent) {
        guard let sessionID = descriptor?.id else { return }
        Task {
            await engine.sendUnicode(sessionID: sessionID, event: event)
        }
    }

    public func sendSecureAttention() {
        guard let sessionID = descriptor?.id else { return }
        Task { await engine.sendSecureAttention(sessionID: sessionID) }
    }

    public func setClipboardText(_ text: String) {
        guard let sessionID = descriptor?.id,
              text.utf8.count <= 1_048_576 else { return }
        Task { await engine.setClipboardText(sessionID: sessionID, text: text) }
    }

    private func receiveFrame(_ update: RdpSessionFrameUpdate) {
        guard !isShutDown else { return }
        guard activeConnectionAttemptID == update.attemptID,
              descriptor?.id == update.sessionID else { return }
        frame = update.frame
    }

    private func receiveClipboard(_ update: RdpClipboardUpdate) {
        guard !isShutDown,
              activeConnectionAttemptID == update.attemptID,
              descriptor?.id == update.sessionID else { return }
        clipboardText = update.text
    }

    private func receiveCertificate(_ update: RdpCertificateChallengeUpdate) async {
        guard !isShutDown,
              activeConnectionAttemptID == update.attemptID,
              bindActiveSessionID(update.sessionID),
              activeEndpoint == update.challenge.endpoint else {
            await engine.resolveCertificate(
                attemptID: update.attemptID,
                sessionID: update.sessionID,
                challengeID: update.challenge.id,
                decision: .reject
            )
            return
        }
        if let pendingCertificateContext {
            if pendingCertificateContext.challenge.id != update.challenge.id {
                await engine.resolveCertificate(
                    attemptID: update.attemptID,
                    sessionID: update.sessionID,
                    challengeID: update.challenge.id,
                    decision: .reject
                )
            }
            return
        }
        guard let certificateCoordinator else {
            await engine.resolveCertificate(
                attemptID: update.attemptID,
                sessionID: update.sessionID,
                challengeID: update.challenge.id,
                decision: .reject
            )
            return
        }

        do {
            let presentation = try await certificateCoordinator.presentation(
                for: update.challenge
            )
            guard !isShutDown,
                  activeConnectionAttemptID == update.attemptID,
                  activeEngineSessionID == update.sessionID,
                  activeEndpoint == update.challenge.endpoint else {
                await engine.resolveCertificate(
                    attemptID: update.attemptID,
                    sessionID: update.sessionID,
                    challengeID: update.challenge.id,
                    decision: .reject
                )
                return
            }
            let context = PendingCertificateContext(
                attemptID: update.attemptID,
                sessionID: update.sessionID,
                challenge: update.challenge
            )
            if let presentation {
                pendingCertificateContext = context
                pendingCertificate = presentation
                startCertificateTimeout(for: context)
            } else {
                await resolveCertificate(context: context, decision: .trustOnce)
            }
        } catch {
            await engine.resolveCertificate(
                attemptID: update.attemptID,
                sessionID: update.sessionID,
                challengeID: update.challenge.id,
                decision: .reject
            )
            presentedError = "无法读取证书信任设置。"
        }
    }

    private func bindActiveSessionID(_ sessionID: String) -> Bool {
        if let activeEngineSessionID {
            return activeEngineSessionID == sessionID
        }
        activeEngineSessionID = sessionID
        return true
    }

    private func startCertificateTimeout(for context: PendingCertificateContext) {
        certificateTimeoutTask?.cancel()
        let clock = certificateClock
        certificateTimeoutTask = Task { [weak self] in
            do {
                try await clock.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.expireCertificate(context)
        }
    }

    private func expireCertificate(_ context: PendingCertificateContext) async {
        guard pendingCertificateContext == context else { return }
        _ = takePendingCertificate()
        await resolveCertificate(context: context, decision: .reject)
    }

    private func rejectPendingCertificate() async {
        guard let context = takePendingCertificate() else { return }
        await resolveCertificate(context: context, decision: .reject)
    }

    private func takePendingCertificate() -> PendingCertificateContext? {
        guard let context = pendingCertificateContext else { return nil }
        pendingCertificateContext = nil
        pendingCertificate = nil
        certificateTimeoutTask?.cancel()
        certificateTimeoutTask = nil
        return context
    }

    private func resolveCertificate(
        context: PendingCertificateContext,
        decision: RdpCertificateDecision
    ) async {
        await engine.resolveCertificate(
            attemptID: context.attemptID,
            sessionID: context.sessionID,
            challengeID: context.challenge.id,
            decision: decision
        )
    }

    private func receiveLifecycle(_ update: RdpSessionLifecycleUpdate) async {
        guard activeConnectionAttemptID == update.attemptID else { return }
        guard bindActiveSessionID(update.sessionID) else { return }
        switch update.state {
        case let .connected(incomingDescriptor):
            guard incomingDescriptor.id == update.sessionID,
                  isConnecting || descriptor?.id == update.sessionID else { return }
            descriptor = incomingDescriptor
            isConnecting = false
            hasActiveEngineSession = true
        case .disconnected:
            await completeRemoteTermination(update: update, error: nil)
        case let .failed(error):
            await completeRemoteTermination(update: update, error: error)
        case .idle, .connecting, .disconnecting:
            break
        }
    }

    private func completeRemoteTermination(
        update: RdpSessionLifecycleUpdate,
        error: RdpSessionError?
    ) async {
        guard activeConnectionAttemptID == update.attemptID else { return }
        if let descriptor, descriptor.id != update.sessionID { return }
        await rejectPendingCertificate()
        activeConnectionAttemptID = nil
        activeEngineSessionID = nil
        activeEndpoint = nil
        connectionGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        hasActiveEngineSession = false
        descriptor = nil
        frame = nil
        clipboardText = nil
        isConnecting = false
        if let error {
            lastError = error
            presentedError = Self.message(for: error)
        }
    }

    private static func message(for error: any Error) -> String {
        switch error as? RdpSessionError {
        case .authenticationFailed(_, _):
            return "用户名或密码不正确。"
        case .certificateRejected:
            return "远程服务器证书未被接受。"
        case .missingEndpoint:
            return "服务器地址为空。"
        case .invalidPort:
            return "服务器端口无效。"
        case .invalidViewport:
            return "远程桌面尺寸无效。"
        case let .network(_, message), let .protocolFailure(_, message),
             let .simulatedFailure(message):
            return message
        case .notConnected:
            return "远程会话已断开。"
        case nil:
            return error.localizedDescription
        }
    }
}
