import Foundation

private final class ConnectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false

    func start<Result>(_ body: () -> Result) -> Result? {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return nil
        }
        started = true
        let result = body()
        lock.unlock()
        return result
    }

    func cancel() -> Bool {
        lock.lock()
        cancelled = true
        let shouldDisconnect = started
        lock.unlock()
        return shouldDisconnect
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public actor FreeRDPSessionEngine: RdpSessionEngine {
    public nonisolated let frames: AsyncStream<RemoteFrame>
    public nonisolated let lifecycleUpdates: AsyncStream<RdpSessionLifecycleUpdate>
    public nonisolated let frameUpdates: AsyncStream<RdpSessionFrameUpdate>
    public nonisolated let certificateChallenges: AsyncStream<RdpCertificateChallengeUpdate>
    public nonisolated let clipboardUpdates: AsyncStream<RdpClipboardUpdate>

    private let bridge: any FreeRDPBridgeAPI
    private let frameContinuation: AsyncStream<RemoteFrame>.Continuation
    private let lifecycleContinuation: AsyncStream<RdpSessionLifecycleUpdate>.Continuation
    private let taggedFrameContinuation: AsyncStream<RdpSessionFrameUpdate>.Continuation
    private let certificateContinuation: AsyncStream<RdpCertificateChallengeUpdate>.Continuation
    private let clipboardContinuation: AsyncStream<RdpClipboardUpdate>.Continuation
    private var state: RdpSessionState = .idle
    private var eventTask: Task<Void, Never>?
    private var connectContinuation: CheckedContinuation<RdpSessionDescriptor, Error>?
    private var activeGeneration: UInt64?
    private var activeAttemptID: RdpConnectionAttemptID?
    private var activeCancellation: ConnectionCancellation?
    private var activeDescriptor: RdpSessionDescriptor?
    private var activeCertificateChallengeID: UInt64?
    private var disconnectingGeneration: UInt64?
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextGeneration: UInt64 = 0
    private var sequence = 0
    private var lastRequest: RdpConnectionRequest?
    private var lastViewport: RdpViewport?
    private(set) var receivedBridgeEventCount: UInt64 = 0

    public init(bridge: any FreeRDPBridgeAPI = NativeFreeRDPBridge()) {
        var installedContinuation: AsyncStream<RemoteFrame>.Continuation?
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            installedContinuation = continuation
        }
        guard let installedContinuation else {
            preconditionFailure("frame stream continuation was not installed")
        }
        frameContinuation = installedContinuation
        var installedLifecycleContinuation: AsyncStream<RdpSessionLifecycleUpdate>.Continuation?
        lifecycleUpdates = AsyncStream { continuation in
            installedLifecycleContinuation = continuation
        }
        guard let installedLifecycleContinuation else {
            preconditionFailure("lifecycle stream continuation was not installed")
        }
        lifecycleContinuation = installedLifecycleContinuation
        var installedTaggedFrameContinuation: AsyncStream<RdpSessionFrameUpdate>.Continuation?
        frameUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            installedTaggedFrameContinuation = continuation
        }
        guard let installedTaggedFrameContinuation else {
            preconditionFailure("tagged frame stream continuation was not installed")
        }
        taggedFrameContinuation = installedTaggedFrameContinuation
        var installedCertificateContinuation:
            AsyncStream<RdpCertificateChallengeUpdate>.Continuation?
        certificateChallenges = AsyncStream { continuation in
            installedCertificateContinuation = continuation
        }
        guard let installedCertificateContinuation else {
            preconditionFailure("certificate stream continuation was not installed")
        }
        certificateContinuation = installedCertificateContinuation
        var installedClipboardContinuation: AsyncStream<RdpClipboardUpdate>.Continuation?
        clipboardUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            installedClipboardContinuation = continuation
        }
        guard let installedClipboardContinuation else {
            preconditionFailure("clipboard stream continuation was not installed")
        }
        clipboardContinuation = installedClipboardContinuation
        self.bridge = bridge
    }

    deinit {
        eventTask?.cancel()
        bridge.disconnect()
        frameContinuation.finish()
        lifecycleContinuation.finish()
        taggedFrameContinuation.finish()
        certificateContinuation.finish()
        clipboardContinuation.finish()
    }

    public func currentState() async -> RdpSessionState {
        state
    }

    public func connect(
        _ request: RdpConnectionRequest,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport,
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        try Task.checkCancellation()
        let activeConnectionError = RdpSessionError.protocolFailure(
            code: -1, message: "A FreeRDP connection is already active"
        )
        if activeGeneration != nil {
            if disconnectingGeneration != nil || activeCancellation?.isCancelled == true {
                await waitForQuiescence()
                try Task.checkCancellation()
                guard activeGeneration == nil else { throw activeConnectionError }
            } else {
                throw activeConnectionError
            }
        }

        let host = request.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            state = .failed(.missingEndpoint)
            throw RdpSessionError.missingEndpoint
        }

        let requestedPort = request.port ?? 3_389
        guard let port = UInt16(exactly: requestedPort), port > 0 else {
            let error = RdpSessionError.invalidPort(requestedPort)
            state = .failed(error)
            throw error
        }
        guard UInt32(exactly: viewport.width) != nil,
              UInt32(exactly: viewport.height) != nil else {
            let error = RdpSessionError.invalidViewport(
                width: viewport.width, height: viewport.height
            )
            state = .failed(error)
            throw error
        }

        nextGeneration &+= 1
        precondition(nextGeneration != 0, "FreeRDP session generation exhausted")
        let generation = nextGeneration
        let cancellation = ConnectionCancellation()
        activeGeneration = generation
        activeAttemptID = attemptID
        activeCancellation = cancellation
        sequence += 1
        let descriptor = RdpSessionDescriptor(
            id: "freerdp-session-\(sequence)", request: request, transport: .freeRDP
        )
        activeDescriptor = descriptor
        lastRequest = request
        lastViewport = viewport
        publish(.connecting(request), attemptID: attemptID, sessionID: descriptor.id)

        // The transient credential is cleared immediately after the synchronous bridge start. It
        // is never captured by the event task or retained as reconnect state.
        var transientCredential = credential
        return try await withTaskCancellationHandler {
            let events = cancellation.start {
                let configuration = FreeRDPConfiguration(
                    host: host,
                    port: port,
                    username: transientCredential?.username ?? request.username,
                    domain: transientCredential?.domain ?? request.domain,
                    password: transientCredential?.password,
                    desktopWidth: UInt32(viewport.width),
                    desktopHeight: UInt32(viewport.height)
                )
                return bridge.connect(configuration: configuration)
            }
            transientCredential = nil
            guard let events else {
                completeTermination(
                    generation: generation,
                    connectError: CancellationError(),
                    state: .disconnected
                )
                throw CancellationError()
            }
            eventTask = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    await self.receive(
                        event,
                        generation: generation,
                        descriptor: descriptor,
                        cancellation: cancellation
                    )
                }
                guard let self else { return }
                await self.eventStreamEnded(
                    generation: generation, cancellation: cancellation
                )
            }
            return try await withCheckedThrowingContinuation { continuation in
                if activeGeneration == generation {
                    connectContinuation = continuation
                } else {
                    continuation.resume(throwing: RdpSessionError.notConnected)
                }
            }
        } onCancel: {
            let shouldDisconnect = cancellation.cancel()
            Task {
                await self.cancelConnection(
                    generation: generation,
                    shouldDisconnect: shouldDisconnect
                )
            }
        }
    }

    public func disconnect() async {
        guard let generation = activeGeneration else {
            state = .disconnected
            return
        }
        if case let .connected(descriptor) = state {
            if let activeAttemptID {
                publish(
                    .disconnecting(descriptor),
                    attemptID: activeAttemptID,
                    sessionID: descriptor.id
                )
            } else {
                state = .disconnected
            }
        } else {
            state = .disconnected
        }
        if disconnectingGeneration != generation {
            disconnectingGeneration = generation
            rejectPendingCertificate()
            bridge.disconnect()
        }
        await waitForQuiescence()
    }

    public func reconnect(
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        guard let lastRequest, let lastViewport else {
            state = .failed(.notConnected)
            throw RdpSessionError.notConnected
        }
        return try await connect(
            lastRequest,
            credential: nil,
            viewport: lastViewport,
            attemptID: attemptID
        )
    }

    public func resize(sessionID: String, width: Int, height: Int) async {
        guard case let .connected(descriptor) = state,
              descriptor.id == sessionID else { return }
        guard width > 0, height > 0,
              Int32(exactly: width) != nil,
              Int32(exactly: height) != nil else { return }
        bridge.resize(width: width, height: height)
    }

    public func sendPointer(sessionID: String, flags: UInt16, x: UInt16, y: UInt16) async {
        guard case let .connected(descriptor) = state,
              descriptor.id == sessionID else { return }
        bridge.sendPointer(flags: flags, x: x, y: y)
    }

    public func sendKey(sessionID: String, flags: UInt16, code: UInt16) async {
        guard case let .connected(descriptor) = state,
              descriptor.id == sessionID else { return }
        bridge.sendKey(flags: flags, code: code)
    }

    public func sendUnicode(sessionID: String, event: RemoteUnicodeKeyEvent) async {
        guard case let .connected(descriptor) = state,
              descriptor.id == sessionID else { return }
        bridge.sendUnicode(flags: event.flags, codeUnit: event.codeUnit)
    }

    public func sendSecureAttention(sessionID: String) async {
        guard case let .connected(descriptor) = state,
              descriptor.id == sessionID else { return }
        bridge.sendSecureAttention()
    }

    public func setClipboardText(sessionID: String, text: String) async {
        guard case let .connected(descriptor) = state,
              descriptor.id == sessionID,
              text.utf8.count <= 1_048_576 else { return }
        bridge.setClipboardText(text)
    }

    public func resolveCertificate(
        attemptID: RdpConnectionAttemptID,
        sessionID: String,
        challengeID: UInt64,
        decision: RdpCertificateDecision
    ) async {
        guard activeAttemptID == attemptID,
              activeDescriptor?.id == sessionID,
              activeGeneration != nil,
              activeCertificateChallengeID == challengeID else { return }
        activeCertificateChallengeID = nil
        bridge.resolveCertificate(challengeID: challengeID, decision: decision)
    }

    private func receive(
        _ event: FreeRDPBridgeEvent,
        generation: UInt64,
        descriptor: RdpSessionDescriptor,
        cancellation: ConnectionCancellation
    ) {
        receivedBridgeEventCount &+= 1
        guard activeGeneration == generation else { return }
        guard let activeAttemptID else { return }
        if cancellation.isCancelled || disconnectingGeneration == generation {
            switch event {
            case .disconnected, .failed:
                completeTermination(
                    generation: generation,
                    connectError: cancellation.isCancelled
                        ? CancellationError()
                        : RdpSessionError.notConnected,
                    state: .disconnected
                )
            case let .certificateChallenge(challenge):
                bridge.resolveCertificate(challengeID: challenge.id, decision: .reject)
            case .connecting, .connected, .frame, .clipboardText:
                break
            }
            return
        }
        switch event {
        case .connecting:
            publish(
                .connecting(descriptor.request),
                attemptID: activeAttemptID,
                sessionID: descriptor.id
            )
        case .connected:
            publish(
                .connected(descriptor),
                attemptID: activeAttemptID,
                sessionID: descriptor.id
            )
            finishConnect(with: .success(descriptor))
        case let .frame(frame):
            guard case .connected = state else { return }
            let copy = RemoteFrame(
                width: frame.width,
                height: frame.height,
                stride: frame.stride,
                bgraBytes: frame.bgraBytes
            )
            frameContinuation.yield(copy)
            taggedFrameContinuation.yield(.init(
                attemptID: activeAttemptID,
                sessionID: descriptor.id,
                frame: copy
            ))
        case let .clipboardText(text):
            guard case .connected = state else { return }
            clipboardContinuation.yield(.init(
                attemptID: activeAttemptID,
                sessionID: descriptor.id,
                text: text
            ))
        case let .certificateChallenge(challenge):
            let expectedEndpoint = RdpEndpoint(
                host: descriptor.request.host,
                port: UInt16(descriptor.request.port ?? 3_389)
            )
            guard challenge.endpoint == expectedEndpoint else {
                bridge.resolveCertificate(challengeID: challenge.id, decision: .reject)
                return
            }
            activeCertificateChallengeID = challenge.id
            certificateContinuation.yield(.init(
                attemptID: activeAttemptID,
                sessionID: descriptor.id,
                challenge: challenge
            ))
        case .disconnected:
            completeTermination(
                generation: generation,
                connectError: RdpSessionError.notConnected,
                state: .disconnected
            )
        case let .failed(code, message):
            let error = Self.mapError(code: code, message: message)
            completeTermination(
                generation: generation, connectError: error, state: .failed(error)
            )
        }
    }

    private func eventStreamEnded(generation: UInt64, cancellation: ConnectionCancellation) {
        guard activeGeneration == generation else { return }
        if cancellation.isCancelled {
            completeTermination(
                generation: generation,
                connectError: CancellationError(),
                state: .disconnected
            )
            return
        }
        if disconnectingGeneration == generation {
            completeTermination(
                generation: generation,
                connectError: RdpSessionError.notConnected,
                state: .disconnected
            )
            return
        }
        if connectContinuation != nil {
            let error = RdpSessionError.protocolFailure(
                code: -1, message: "FreeRDP event stream ended before connection completed"
            )
            completeTermination(
                generation: generation, connectError: error, state: .failed(error)
            )
        } else {
            completeTermination(
                generation: generation,
                connectError: RdpSessionError.notConnected,
                state: .disconnected
            )
        }
    }

    private func cancelConnection(generation: UInt64, shouldDisconnect: Bool) {
        guard activeGeneration == generation else { return }
        state = .disconnected
        guard shouldDisconnect, disconnectingGeneration != generation else { return }
        disconnectingGeneration = generation
        rejectPendingCertificate()
        bridge.disconnect()
    }

    private func completeTermination(
        generation: UInt64,
        connectError: any Error,
        state finalState: RdpSessionState
    ) {
        guard activeGeneration == generation else { return }
        // Resolve while the attempt/session/generation scope is still active. Active disconnect
        // may already have rejected and cleared this ID, making this path exactly once.
        rejectPendingCertificate()
        let sessionID = activeDescriptor?.id
        let attemptID = activeAttemptID
        activeGeneration = nil
        activeAttemptID = nil
        activeCancellation = nil
        activeCertificateChallengeID = nil
        disconnectingGeneration = nil
        eventTask = nil
        state = finalState
        if let attemptID, let sessionID {
            lifecycleContinuation.yield(.init(
                attemptID: attemptID,
                sessionID: sessionID,
                state: finalState
            ))
        }
        activeDescriptor = nil
        finishConnect(with: .failure(connectError))
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForQuiescence() async {
        guard activeGeneration != nil else { return }
        await withCheckedContinuation { continuation in
            quiescenceWaiters.append(continuation)
        }
    }

    private func finishConnect(with result: Result<RdpSessionDescriptor, any Error>) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        continuation.resume(with: result)
    }

    private func rejectPendingCertificate() {
        guard let challengeID = activeCertificateChallengeID else { return }
        activeCertificateChallengeID = nil
        bridge.resolveCertificate(challengeID: challengeID, decision: .reject)
    }

    private func publish(
        _ newState: RdpSessionState,
        attemptID: RdpConnectionAttemptID,
        sessionID: String
    ) {
        state = newState
        lifecycleContinuation.yield(.init(
            attemptID: attemptID,
            sessionID: sessionID,
            state: newState
        ))
    }

    static func mapError(code: Int32, message: String) -> RdpSessionError {
        let normalizedMessage = message.lowercased()
        if normalizedMessage.contains("certificate") &&
            (normalizedMessage.contains("reject") || normalizedMessage.contains("verify")) {
            return .certificateRejected
        }

        let unsignedCode = UInt32(bitPattern: code)
        let errorClass = (unsignedCode >> 16) & 0xffff
        let errorType = unsignedCode & 0xffff
        let authenticationTypes: Set<UInt32> = [
            0x09, 0x0A, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13,
            0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B
        ]
        if code == 20_009 || (errorClass == 2 && authenticationTypes.contains(errorType)) {
            let reason: RdpAuthenticationFailureReason = switch errorType {
            case 0x15: .wrongPassword
            case 0x14: .invalidCredentials
            case 0x12: .accountDisabled
            case 0x18: .accountLocked
            case 0x0E, 0x0F: .passwordExpired
            case 0x13: .passwordMustChange
            case 0x17: .accountRestriction
            case 0x19: .accountExpired
            default: .unknown
            }
            return .authenticationFailed(reason: reason, code: code)
        }

        let protocolTypes: Set<UInt32> = [0x01, 0x02, 0x03, 0x07, 0x08, 0x0C]
        if errorClass == 1 || (errorClass == 2 && protocolTypes.contains(errorType)) {
            return .protocolFailure(code: code, message: message)
        }
        if errorClass == 2 {
            return .network(code: code, message: message)
        }
        return .protocolFailure(code: code, message: message)
    }
}
