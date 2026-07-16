import Foundation
import XCTest
@testable import RdcCore

private final class FakeFreeRDPBridge: FreeRDPBridgeAPI, @unchecked Sendable {
    struct ConfigurationSnapshot: Equatable {
        let host: String
        let port: UInt16
        let username: String?
        let domain: String?
        let passwordWasPresent: Bool
        let desktopWidth: UInt32
        let desktopHeight: UInt32
    }

    private let lock = NSLock()
    private var continuations: [Int: AsyncStream<FreeRDPBridgeEvent>.Continuation] = [:]
    private var activeGeneration: Int?
    private let automaticallyCompletesDisconnect: Bool
    private let eventsOnDisconnect: [FreeRDPBridgeEvent]
    private let keepsStreamsOpenAfterTerminal: Bool
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var resizeCalls: [(Int, Int)] = []
    private(set) var pointerCalls: [(UInt16, UInt16, UInt16)] = []
    private(set) var keyCalls: [(UInt16, UInt16)] = []
    private(set) var unicodeCalls: [(UInt16, UInt16)] = []
    private(set) var secureAttentionCallCount = 0
    private(set) var clipboardTexts: [String] = []
    private(set) var certificateResolutions: [(UInt64, RdpCertificateDecision)] = []
    private(set) var certificateOperations: [String] = []
    private(set) var configurationSnapshots: [ConfigurationSnapshot] = []

    init(
        automaticallyCompletesDisconnect: Bool = true,
        eventsOnDisconnect: [FreeRDPBridgeEvent] = [.disconnected],
        keepsStreamsOpenAfterTerminal: Bool = false
    ) {
        self.automaticallyCompletesDisconnect = automaticallyCompletesDisconnect
        self.eventsOnDisconnect = eventsOnDisconnect
        self.keepsStreamsOpenAfterTerminal = keepsStreamsOpenAfterTerminal
    }

    func connect(configuration: FreeRDPConfiguration) -> AsyncStream<FreeRDPBridgeEvent> {
        return AsyncStream { continuation in
            self.lock.lock()
            self.connectCallCount += 1
            let generation = self.connectCallCount
            guard self.activeGeneration == nil else {
                self.lock.unlock()
                continuation.yield(
                    .failed(code: -1, message: "A FreeRDP connection is already active")
                )
                continuation.finish()
                return
            }
            self.activeGeneration = generation
            self.configurationSnapshots.append(
                ConfigurationSnapshot(
                    host: configuration.host,
                    port: configuration.port,
                    username: configuration.username,
                    domain: configuration.domain,
                    passwordWasPresent: configuration.password != nil,
                    desktopWidth: configuration.desktopWidth,
                    desktopHeight: configuration.desktopHeight
                )
            )
            self.continuations[generation] = continuation
            self.lock.unlock()
        }
    }

    func disconnect() {
        lock.lock()
        disconnectCallCount += 1
        certificateOperations.append("disconnect")
        let generation = activeGeneration
        let continuation = generation.flatMap { continuations[$0] }
        let automaticallyCompletesDisconnect = automaticallyCompletesDisconnect
        let eventsOnDisconnect = eventsOnDisconnect
        lock.unlock()
        guard automaticallyCompletesDisconnect, let continuation else { return }
        eventsOnDisconnect.forEach { event in
            if event.isTerminal {
                lock.lock()
                if activeGeneration == generation {
                    activeGeneration = nil
                }
                lock.unlock()
            }
            continuation.yield(event)
        }
        lock.lock()
        if activeGeneration == generation {
            activeGeneration = nil
        }
        lock.unlock()
        if !keepsStreamsOpenAfterTerminal {
            continuation.finish()
        }
    }

    func resolveCertificate(challengeID: UInt64, decision: RdpCertificateDecision) {
        lock.lock()
        certificateResolutions.append((challengeID, decision))
        certificateOperations.append("resolve:\(challengeID):\(decision.rawValue)")
        lock.unlock()
    }

    func resize(width: Int, height: Int) {
        lock.lock()
        resizeCalls.append((width, height))
        lock.unlock()
    }

    func sendPointer(flags: UInt16, x: UInt16, y: UInt16) {
        lock.lock()
        pointerCalls.append((flags, x, y))
        lock.unlock()
    }

    func sendKey(flags: UInt16, code: UInt16) {
        lock.lock()
        keyCalls.append((flags, code))
        lock.unlock()
    }

    func sendUnicode(flags: UInt16, codeUnit: UInt16) {
        lock.lock()
        unicodeCalls.append((flags, codeUnit))
        lock.unlock()
    }

    func sendSecureAttention() {
        lock.lock()
        secureAttentionCallCount += 1
        lock.unlock()
    }

    func setClipboardText(_ text: String) {
        lock.lock()
        clipboardTexts.append(text)
        lock.unlock()
    }

    func yield(_ event: FreeRDPBridgeEvent, generation: Int? = nil) {
        lock.lock()
        let generation = generation ?? connectCallCount
        let continuation = continuations[generation]
        if event.isTerminal, activeGeneration == generation {
            activeGeneration = nil
        }
        lock.unlock()
        continuation?.yield(event)
        if event.isTerminal && !keepsStreamsOpenAfterTerminal {
            continuation?.finish()
        }
    }

    func finish(generation: Int? = nil) {
        lock.lock()
        let generation = generation ?? connectCallCount
        let continuation = continuations[generation]
        if activeGeneration == generation {
            activeGeneration = nil
        }
        lock.unlock()
        continuation?.finish()
    }

    var calls: (connect: Int, disconnect: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (connectCallCount, disconnectCallCount)
    }

    var snapshots: [ConfigurationSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return configurationSnapshots
    }

    var forwardedInput: (
        resize: [(Int, Int)],
        pointer: [(UInt16, UInt16, UInt16)],
        key: [(UInt16, UInt16)],
        unicode: [(UInt16, UInt16)],
        secureAttention: Int,
        clipboardTexts: [String]
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            resizeCalls, pointerCalls, keyCalls, unicodeCalls,
            secureAttentionCallCount, clipboardTexts
        )
    }

    var resolvedCertificates: [(UInt64, RdpCertificateDecision)] {
        lock.lock()
        defer { lock.unlock() }
        return certificateResolutions
    }

    var certificateOperationHistory: [String] {
        lock.lock()
        defer { lock.unlock() }
        return certificateOperations
    }
}

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func complete() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
}

private extension FreeRDPBridgeEvent {
    var isTerminal: Bool {
        switch self {
        case .disconnected, .failed:
            true
        case .connecting, .connected, .frame, .certificateChallenge, .clipboardText:
            false
        }
    }
}

final class FreeRDPSessionEngineTests: XCTestCase {
    private let request = RdpConnectionRequest(
        serverID: "group/server",
        host: "example.invalid",
        port: 3_390,
        username: "request-user",
        domain: "REQUEST"
    )
    private let viewport = RdpViewport(width: 1_440, height: 900)

    func testCertificateChallengesAreLosslessAndTaggedWithExactAttemptAndSession() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        var certificates = engine.certificateChallenges.makeAsyncIterator()
        let attemptID = RdpConnectionAttemptID()
        let request = request
        let viewport = viewport
        let connectTask = Task {
            try await engine.connect(
                request, credential: nil, viewport: viewport, attemptID: attemptID
            )
        }
        try await waitUntil { bridge.calls.connect == 1 }
        let first = try certificateChallenge(id: 71)
        let second = try certificateChallenge(id: 72)

        bridge.yield(.certificateChallenge(first))
        bridge.yield(.certificateChallenge(second))

        let firstUpdate = await certificates.next()
        let secondUpdate = await certificates.next()
        let sessionID = try XCTUnwrap(firstUpdate?.sessionID)
        XCTAssertEqual(firstUpdate, .init(
            attemptID: attemptID, sessionID: sessionID, challenge: first
        ))
        XCTAssertEqual(secondUpdate, .init(
            attemptID: attemptID, sessionID: sessionID, challenge: second
        ))

        connectTask.cancel()
        _ = await connectTask.result
    }

    func testCertificateResolutionRejectsStaleAttemptSessionAndDuplicateDecision() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        var certificates = engine.certificateChallenges.makeAsyncIterator()
        let attemptID = RdpConnectionAttemptID()
        let request = request
        let viewport = viewport
        let connectTask = Task {
            try await engine.connect(
                request, credential: nil, viewport: viewport, attemptID: attemptID
            )
        }
        try await waitUntil { bridge.calls.connect == 1 }
        let challenge = try certificateChallenge(id: 81)
        bridge.yield(.certificateChallenge(challenge))
        let receivedUpdate = await certificates.next()
        let update = try XCTUnwrap(receivedUpdate)

        await engine.resolveCertificate(
            attemptID: RdpConnectionAttemptID(),
            sessionID: update.sessionID,
            challengeID: challenge.id,
            decision: .trustOnce
        )
        await engine.resolveCertificate(
            attemptID: attemptID,
            sessionID: "stale-session",
            challengeID: challenge.id,
            decision: .trustOnce
        )
        await engine.resolveCertificate(
            attemptID: attemptID,
            sessionID: update.sessionID,
            challengeID: challenge.id,
            decision: .trustOnce
        )
        await engine.resolveCertificate(
            attemptID: attemptID,
            sessionID: update.sessionID,
            challengeID: challenge.id,
            decision: .trustAlways
        )

        XCTAssertEqual(bridge.resolvedCertificates.count, 1)
        XCTAssertEqual(bridge.resolvedCertificates.first?.0, challenge.id)
        XCTAssertEqual(bridge.resolvedCertificates.first?.1, .trustOnce)
        connectTask.cancel()
        _ = await connectTask.result
    }

    func testDisconnectRejectsPendingCertificateBeforeDisconnectingBridge() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        let connectTask = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }
        let challenge = try certificateChallenge(id: 91)
        bridge.yield(.certificateChallenge(challenge))
        try await waitUntilAsync { await engine.receivedBridgeEventCount == 1 }

        await engine.disconnect()
        _ = await connectTask.result

        XCTAssertEqual(
            bridge.certificateOperationHistory,
            ["resolve:91:0", "disconnect"]
        )
    }

    func testRemoteFailureRejectsPendingCertificateBeforePublishingTerminalState() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        var lifecycle = engine.lifecycleUpdates.makeAsyncIterator()
        var certificates = engine.certificateChallenges.makeAsyncIterator()
        let request = request
        let viewport = viewport
        let attemptID = RdpConnectionAttemptID()
        let connectTask = Task {
            try await engine.connect(
                request, credential: nil, viewport: viewport, attemptID: attemptID
            )
        }
        try await waitUntil { bridge.calls.connect == 1 }
        _ = await lifecycle.next()
        let challenge = try certificateChallenge(id: 93)
        bridge.yield(.certificateChallenge(challenge))
        let receivedUpdate = await certificates.next()
        let update = try XCTUnwrap(receivedUpdate)

        bridge.yield(.failed(code: 20_009, message: "authentication failed"))
        let terminal = await lifecycle.next()

        XCTAssertEqual(
            terminal?.state,
            .failed(.authenticationFailed(reason: .unknown, code: 20_009))
        )
        XCTAssertEqual(bridge.resolvedCertificates.map { $0.1 }, [.reject])
        await engine.resolveCertificate(
            attemptID: attemptID,
            sessionID: update.sessionID,
            challengeID: challenge.id,
            decision: .reject
        )
        XCTAssertEqual(bridge.resolvedCertificates.count, 1)
        _ = await connectTask.result
    }

    func testRemoteDisconnectRejectsPendingCertificateBeforePublishingTerminalState() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        var lifecycle = engine.lifecycleUpdates.makeAsyncIterator()
        var certificates = engine.certificateChallenges.makeAsyncIterator()
        let request = request
        let viewport = viewport
        let attemptID = RdpConnectionAttemptID()
        let connectTask = Task {
            try await engine.connect(
                request, credential: nil, viewport: viewport, attemptID: attemptID
            )
        }
        try await waitUntil { bridge.calls.connect == 1 }
        _ = await lifecycle.next()
        let challenge = try certificateChallenge(id: 94)
        bridge.yield(.certificateChallenge(challenge))
        let receivedUpdate = await certificates.next()
        let update = try XCTUnwrap(receivedUpdate)

        bridge.yield(.disconnected)
        let terminal = await lifecycle.next()

        XCTAssertEqual(terminal?.state, .disconnected)
        XCTAssertEqual(bridge.resolvedCertificates.map { $0.1 }, [.reject])
        await engine.resolveCertificate(
            attemptID: attemptID,
            sessionID: update.sessionID,
            challengeID: challenge.id,
            decision: .reject
        )
        XCTAssertEqual(bridge.resolvedCertificates.count, 1)
        _ = await connectTask.result
    }

    func testCertificateForDifferentEndpointIsRejectedWithoutPublishing() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        let connectTask = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }
        let challenge = try certificateChallenge(id: 92, host: "other.invalid", port: 3_390)

        bridge.yield(.certificateChallenge(challenge))
        try await waitUntil { bridge.resolvedCertificates.count == 1 }

        XCTAssertEqual(bridge.resolvedCertificates.first?.0, challenge.id)
        XCTAssertEqual(bridge.resolvedCertificates.first?.1, .reject)
        connectTask.cancel()
        _ = await connectTask.result
    }

    func testConnectPublishesConnectingConnectedAndCopiedFrame() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let credential = RdpConnectionCredential(
            username: "credential-user", domain: "CREDENTIAL", password: "transient-secret"
        )
        let request = request
        let viewport = viewport
        let frameTask = Task { () -> RemoteFrame? in
            var iterator = engine.frames.makeAsyncIterator()
            return await iterator.next()
        }
        let task = Task {
            try await engine.connect(request, credential: credential, viewport: viewport)
        }

        try await waitUntil { bridge.calls.connect == 1 }
        let connectingState = await engine.currentState()
        XCTAssertEqual(connectingState, .connecting(request))
        XCTAssertEqual(
            bridge.snapshots,
            [.init(host: "example.invalid", port: 3_390,
                   username: "credential-user", domain: "CREDENTIAL",
                   passwordWasPresent: true, desktopWidth: 1_440, desktopHeight: 900)]
        )

        bridge.yield(.connected)
        let descriptor = try await task.value
        XCTAssertEqual(descriptor.transport, .freeRDP)
        let connectedState = await engine.currentState()
        XCTAssertEqual(connectedState, .connected(descriptor))

        var source = [UInt8](repeating: 7, count: 16)
        bridge.yield(.frame(RemoteFrame(width: 2, height: 2, stride: 8, bgraBytes: source)))
        source[0] = 99
        let receivedFrame = await frameTask.value
        let copiedFrame = try XCTUnwrap(receivedFrame)
        XCTAssertEqual(copiedFrame.bgraBytes[0], 7)
    }

    func testGenerationTaggedStreamsPublishConnectedFrameAndTerminalFailure() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        var lifecycle = engine.lifecycleUpdates.makeAsyncIterator()
        var frames = engine.frameUpdates.makeAsyncIterator()
        let request = request
        let viewport = viewport
        let attemptID = RdpConnectionAttemptID()
        let connectTask = Task {
            try await engine.connect(
                request, credential: nil, viewport: viewport, attemptID: attemptID
            )
        }

        try await waitUntil { bridge.calls.connect == 1 }
        guard let connectingUpdate = await lifecycle.next(),
              case let .connecting(connectingRequest) = connectingUpdate.state else {
            XCTFail("expected tagged connecting update")
            return
        }
        XCTAssertEqual(connectingRequest, request)

        bridge.yield(.connected)
        let descriptor = try await connectTask.value
        let connectedUpdate = await lifecycle.next()
        XCTAssertEqual(
            connectedUpdate,
            .init(
                attemptID: attemptID,
                sessionID: descriptor.id,
                state: .connected(descriptor)
            )
        )
        XCTAssertEqual(connectingUpdate.attemptID, attemptID)
        XCTAssertEqual(connectingUpdate.sessionID, descriptor.id)

        let frame = RemoteFrame(width: 1, height: 1, stride: 4, bgraBytes: [1, 2, 3, 4])
        bridge.yield(.frame(frame))
        let frameUpdate = await frames.next()
        XCTAssertEqual(
            frameUpdate,
            .init(attemptID: attemptID, sessionID: descriptor.id, frame: frame)
        )

        bridge.yield(.failed(code: 20_009, message: "authentication failed"))
        let failedUpdate = await lifecycle.next()
        XCTAssertEqual(
            failedUpdate,
            .init(
                attemptID: attemptID,
                sessionID: descriptor.id,
                state: .failed(.authenticationFailed(reason: .unknown, code: 20_009))
            )
        )
    }

    func testLifecycleBacklogCannotBeEvictedByFrameBurstBeforeTerminal() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        let attemptID = RdpConnectionAttemptID()
        let connectTask = Task {
            try await engine.connect(
                request, credential: nil, viewport: viewport, attemptID: attemptID
            )
        }
        try await waitUntil { bridge.calls.connect == 1 }
        bridge.yield(.connected)
        let descriptor = try await connectTask.value
        for value in 0..<32 {
            bridge.yield(.frame(RemoteFrame(
                width: 1,
                height: 1,
                stride: 4,
                bgraBytes: [UInt8(value), 0, 0, 0]
            )))
        }
        bridge.yield(.failed(code: 20_009, message: "authentication failed"))

        var lifecycle = engine.lifecycleUpdates.makeAsyncIterator()
        let connecting = await lifecycle.next()
        let connected = await lifecycle.next()
        let failed = await lifecycle.next()
        XCTAssertEqual(connecting, .init(
            attemptID: attemptID, sessionID: descriptor.id, state: .connecting(request)
        ))
        XCTAssertEqual(connected, .init(
            attemptID: attemptID, sessionID: descriptor.id, state: .connected(descriptor)
        ))
        XCTAssertEqual(failed, .init(
            attemptID: attemptID,
            sessionID: descriptor.id,
            state: .failed(.authenticationFailed(reason: .unknown, code: 20_009))
        ))
    }

    func testFailureMapsNativeCodeAndDoesNotRetryInsideEngine() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        let task = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }

        bridge.yield(.failed(code: 20_009, message: "authentication failed"))
        do {
            _ = try await task.value
            XCTFail("expected authentication failure")
        } catch {
            XCTAssertEqual(
                error as? RdpSessionError,
                .authenticationFailed(reason: .unknown, code: 20_009)
            )
        }
        XCTAssertEqual(bridge.calls.connect, 1)
        let failedState = await engine.currentState()
        XCTAssertEqual(
            failedState,
            .failed(.authenticationFailed(reason: .unknown, code: 20_009))
        )
    }

    func testNativeConnectErrorsMapByFreeRDPClassAndType() {
        let detail = "safe-test-detail"
        XCTAssertEqual(
            FreeRDPSessionEngine.mapError(code: 0x0002_0008, message: detail),
            .protocolFailure(code: 0x0002_0008, message: detail)
        )
        XCTAssertEqual(
            FreeRDPSessionEngine.mapError(code: 0x0002_000C, message: detail),
            .protocolFailure(code: 0x0002_000C, message: detail)
        )
        XCTAssertEqual(
            FreeRDPSessionEngine.mapError(code: 0x0002_0005, message: detail),
            .network(code: 0x0002_0005, message: detail)
        )
        XCTAssertEqual(
            FreeRDPSessionEngine.mapError(code: 0x0002_001C, message: detail),
            .network(code: 0x0002_001C, message: detail)
        )
        let authenticationCases: [(Int32, RdpAuthenticationFailureReason)] = [
            (0x0002_0015, .wrongPassword),
            (0x0002_0014, .invalidCredentials),
            (0x0002_0012, .accountDisabled),
            (0x0002_0018, .accountLocked),
            (0x0002_000E, .passwordExpired),
            (0x0002_000F, .passwordExpired),
            (0x0002_0013, .passwordMustChange),
            (0x0002_0017, .accountRestriction),
            (0x0002_0019, .accountExpired),
            (0x0002_0009, .unknown)
        ]
        for (code, reason) in authenticationCases {
            XCTAssertEqual(
                FreeRDPSessionEngine.mapError(code: code, message: detail),
                .authenticationFailed(reason: reason, code: code)
            )
        }
    }

    func testAuthenticationMappingDiscardsRawRuntimeMessage() {
        let marker = "sensitive-auth-runtime-marker-\(UUID().uuidString)"
        let mappedError = FreeRDPSessionEngine.mapError(
            code: 0x0002_0015,
            message: marker
        )

        XCTAssertEqual(
            mappedError,
            .authenticationFailed(reason: .wrongPassword, code: 0x0002_0015)
        )
        XCTAssertFalse(String(describing: mappedError).contains(marker))
    }

    func testValidationRejectsMissingHostAndInvalidPortBeforeCallingBridge() async {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let missing = RdpConnectionRequest(
            serverID: "missing", host: "  ", port: 3_389, username: nil, domain: nil
        )
        let invalid = RdpConnectionRequest(
            serverID: "invalid", host: "example.invalid", port: 70_000,
            username: nil, domain: nil
        )

        await assertConnectError(.missingEndpoint) {
            try await engine.connect(missing, credential: nil, viewport: viewport)
        }
        await assertConnectError(.invalidPort(70_000)) {
            try await engine.connect(invalid, credential: nil, viewport: viewport)
        }
        XCTAssertEqual(bridge.calls.connect, 0)
    }

    func testCancellationDisconnectsAndIgnoresStaleEventsAndFrames() async throws {
        let bridge = FakeFreeRDPBridge(keepsStreamsOpenAfterTerminal: true)
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        let task = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        try await waitUntil { bridge.calls.disconnect > 0 }
        let cancelledState = await engine.currentState()
        XCTAssertEqual(cancelledState, .disconnected)

        let reconnectTask = Task { try await engine.reconnect() }
        try await waitUntil { bridge.calls.connect == 2 }
        bridge.yield(.connected, generation: 2)
        let replacement = try await reconnectTask.value
        var frameIterator = engine.frameUpdates.makeAsyncIterator()
        let receivedBeforeStaleCallbacks = await engine.receivedBridgeEventCount
        bridge.yield(.connected, generation: 1)
        bridge.yield(
            .frame(RemoteFrame(width: 1, height: 1, stride: 4, bgraBytes: [1, 1, 1, 1])),
            generation: 1
        )
        try await waitUntilAsync {
            await engine.receivedBridgeEventCount == receivedBeforeStaleCallbacks + 2
        }
        let stateAfterStaleCallbacks = await engine.currentState()
        XCTAssertEqual(stateAfterStaleCallbacks, .connected(replacement))

        let currentFrame = RemoteFrame(
            width: 1, height: 1, stride: 4, bgraBytes: [2, 2, 2, 2]
        )
        bridge.yield(.frame(currentFrame), generation: 2)
        let receivedFrame = await frameIterator.next()?.frame
        XCTAssertEqual(receivedFrame, currentFrame)
    }

    func testDisconnectTerminatesStreamAndReconnectIsGenerationScoped() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        let firstTask = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }
        bridge.yield(.connected, generation: 1)
        _ = try await firstTask.value
        await engine.disconnect()
        let disconnectedState = await engine.currentState()
        XCTAssertEqual(disconnectedState, .disconnected)

        let secondTask = Task { try await engine.reconnect() }
        try await waitUntil { bridge.calls.connect == 2 }
        bridge.yield(.failed(code: 20_009, message: "stale"), generation: 1)
        let stateAfterStaleFailure = await engine.currentState()
        XCTAssertEqual(stateAfterStaleFailure, .connecting(request))
        bridge.yield(.connected, generation: 2)
        let second = try await secondTask.value
        let reconnectedState = await engine.currentState()
        XCTAssertEqual(reconnectedState, .connected(second))
    }

    func testResizePointerAndKeyForwardOnlyWhileConnected() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        await engine.resize(sessionID: "none", width: 800, height: 600)
        await engine.sendPointer(sessionID: "none", flags: 0x0800, x: 10, y: 20)
        await engine.sendKey(sessionID: "none", flags: 0, code: 30)
        XCTAssertTrue(bridge.forwardedInput.resize.isEmpty)

        let task = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }
        bridge.yield(.connected)
        let descriptor = try await task.value

        await engine.resize(sessionID: descriptor.id, width: 800, height: 600)
        await engine.sendPointer(
            sessionID: descriptor.id, flags: 0x0800, x: 10, y: 20
        )
        await engine.sendKey(sessionID: descriptor.id, flags: 0, code: 30)
        XCTAssertEqual(bridge.forwardedInput.resize.map { [$0.0, $0.1] }, [[800, 600]])
        XCTAssertEqual(bridge.forwardedInput.pointer.map { [$0.0, $0.1, $0.2] }, [[0x0800, 10, 20]])
        XCTAssertEqual(bridge.forwardedInput.key.map { [$0.0, $0.1] }, [[0, 30]])
    }

    func testSecureAttentionAndClipboardForwardOnlyForActiveSession() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)

        await engine.sendSecureAttention(sessionID: "none")
        await engine.setClipboardText(sessionID: "none", text: "not-sent")
        XCTAssertEqual(bridge.forwardedInput.secureAttention, 0)
        XCTAssertTrue(bridge.forwardedInput.clipboardTexts.isEmpty)

        let request = request
        let viewport = viewport
        let task = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }
        bridge.yield(.connected)
        let descriptor = try await task.value

        await engine.sendSecureAttention(sessionID: descriptor.id)
        await engine.setClipboardText(sessionID: descriptor.id, text: "hello 你好")

        XCTAssertEqual(bridge.forwardedInput.secureAttention, 1)
        XCTAssertEqual(bridge.forwardedInput.clipboardTexts, ["hello 你好"])
    }

    func testRemoteClipboardUpdateIsTaggedToCurrentAttemptAndSession() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        var iterator = engine.clipboardUpdates.makeAsyncIterator()
        let updateTask = Task { await iterator.next() }

        let request = request
        let viewport = viewport
        let task = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }
        bridge.yield(.connected)
        let descriptor = try await task.value
        bridge.yield(.clipboardText("remote 文本"))

        let update = await updateTask.value
        XCTAssertEqual(update?.sessionID, descriptor.id)
        XCTAssertEqual(update?.text, "remote 文本")
        XCTAssertNotNil(update?.attemptID)
    }

    func testScopedInputRejectsPredecessorSessionAfterReplacement() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        let firstTask = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }
        bridge.yield(.connected, generation: 1)
        let predecessor = try await firstTask.value
        await engine.disconnect()

        let replacementTask = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 2 }
        bridge.yield(.connected, generation: 2)
        let replacement = try await replacementTask.value

        await engine.resize(sessionID: predecessor.id, width: 800, height: 600)
        await engine.sendPointer(
            sessionID: predecessor.id, flags: 0x0800, x: 10, y: 20
        )
        await engine.sendKey(sessionID: predecessor.id, flags: 0, code: 30)
        await engine.sendUnicode(
            sessionID: predecessor.id,
            event: RemoteUnicodeKeyEvent(codeUnit: 0x4E2D, phase: .down)
        )
        XCTAssertTrue(bridge.forwardedInput.resize.isEmpty)
        XCTAssertTrue(bridge.forwardedInput.pointer.isEmpty)
        XCTAssertTrue(bridge.forwardedInput.key.isEmpty)
        XCTAssertTrue(bridge.forwardedInput.unicode.isEmpty)

        await engine.resize(sessionID: replacement.id, width: 800, height: 600)
        await engine.sendPointer(
            sessionID: replacement.id, flags: 0x0800, x: 10, y: 20
        )
        await engine.sendKey(sessionID: replacement.id, flags: 0, code: 30)
        await engine.sendUnicode(
            sessionID: replacement.id,
            event: RemoteUnicodeKeyEvent(codeUnit: 0x4E2D, phase: .down)
        )
        XCTAssertEqual(bridge.forwardedInput.resize.map { [$0.0, $0.1] }, [[800, 600]])
        XCTAssertEqual(
            bridge.forwardedInput.pointer.map { [$0.0, $0.1, $0.2] },
            [[0x0800, 10, 20]]
        )
        XCTAssertEqual(bridge.forwardedInput.key.map { [$0.0, $0.1] }, [[0, 30]])
        XCTAssertEqual(bridge.forwardedInput.unicode.map { [$0.0, $0.1] }, [[0, 0x4E2D]])
    }

    func testDeinitDisconnectsBridge() async throws {
        let bridge = FakeFreeRDPBridge()
        weak var reference: FreeRDPSessionEngine?
        do {
            let engine = FreeRDPSessionEngine(bridge: bridge)
            reference = engine
            XCTAssertNotNil(reference)
        }

        try await waitUntil { bridge.calls.disconnect == 1 }
        XCTAssertNil(reference)
    }

    func testCancellationWinsWhenDisconnectQueuesConnectedBeforeStreamEnd() async throws {
        let bridge = FakeFreeRDPBridge(eventsOnDisconnect: [.connected, .disconnected])
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        let task = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancellation must win over a queued connected event")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let state = await engine.currentState()
        XCTAssertEqual(state, .disconnected)
    }

    func testReconnectWaitsForControlledTeardownBeforeOpeningReplacementStream() async throws {
        let bridge = FakeFreeRDPBridge(automaticallyCompletesDisconnect: false)
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        let connectTask = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }
        bridge.yield(.connected, generation: 1)
        _ = try await connectTask.value

        let disconnectTask = Task { await engine.disconnect() }
        try await waitUntil { bridge.calls.disconnect == 1 }
        let reconnectTask = Task { try await engine.reconnect() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(bridge.calls.connect, 1)

        bridge.yield(.disconnected, generation: 1)
        await disconnectTask.value
        try await waitUntil { bridge.calls.connect == 2 }
        bridge.yield(.connected, generation: 2)
        let replacement = try await reconnectTask.value
        let state = await engine.currentState()
        XCTAssertEqual(state, .connected(replacement))
    }

    func testConnectRejectsViewportThatCannotReachNativeConfigurationExactly() async {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let oversized = RdpViewport(width: Int(UInt32.max) + 1, height: 900)

        await assertConnectError(.invalidViewport(width: oversized.width, height: 900)) {
            try await engine.connect(request, credential: nil, viewport: oversized)
        }
        XCTAssertEqual(bridge.calls.connect, 0)
    }

    func testTwoConnectWaitersReleasedByOneTeardownOpenOnlyOneReplacement() async throws {
        let bridge = FakeFreeRDPBridge(automaticallyCompletesDisconnect: false)
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        let initialTask = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }
        bridge.yield(.connected, generation: 1)
        _ = try await initialTask.value

        let disconnectTask = Task { await engine.disconnect() }
        try await waitUntil { bridge.calls.disconnect == 1 }
        let firstWaiter = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        let secondWaiter = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        defer {
            firstWaiter.cancel()
            secondWaiter.cancel()
        }
        try await Task.sleep(for: .milliseconds(50))

        bridge.yield(.disconnected, generation: 1)
        await disconnectTask.value
        try await waitUntil { bridge.calls.connect >= 2 }
        try await Task.sleep(for: .milliseconds(50))
        guard bridge.calls.connect == 2 else {
            XCTFail("only one waiter may reserve the connection slot; calls: \(bridge.calls.connect)")
            return
        }
        bridge.yield(.connected, generation: 2)
        let results = await [firstWaiter.result, secondWaiter.result]
        XCTAssertEqual(results.filter { (try? $0.get()) != nil }.count, 1)
        XCTAssertEqual(results.filter {
            guard case let .failure(error) = $0 else { return false }
            return error as? RdpSessionError == .protocolFailure(
                code: -1, message: "A FreeRDP connection is already active"
            )
        }.count, 1)
    }

    func testInvalidConnectWhileConnectedPreservesSessionFramesAndInput() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        let connectTask = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }
        bridge.yield(.connected)
        let descriptor = try await connectTask.value

        let activeError = RdpSessionError.protocolFailure(
            code: -1, message: "A FreeRDP connection is already active"
        )
        let invalidRequests: [(RdpConnectionRequest, RdpSessionError, RdpViewport)] = [
            (.init(serverID: "empty", host: " ", port: 3_389, username: nil, domain: nil),
             activeError, viewport),
            (.init(serverID: "port", host: "example.invalid", port: 70_000,
                   username: nil, domain: nil),
             activeError, viewport),
            (request,
             activeError,
             RdpViewport(width: Int(UInt32.max) + 1, height: 900))
        ]
        for (invalidRequest, expectedError, invalidViewport) in invalidRequests {
            await assertConnectError(expectedError) {
                try await engine.connect(
                    invalidRequest, credential: nil, viewport: invalidViewport
                )
            }
            let state = await engine.currentState()
            guard state == .connected(descriptor) else {
                XCTFail("invalid connect changed active state to \(state)")
                return
            }
        }

        let frame = RemoteFrame(width: 1, height: 1, stride: 4, bgraBytes: [3, 3, 3, 3])
        var iterator = engine.frames.makeAsyncIterator()
        bridge.yield(.frame(frame), generation: 1)
        let receivedFrame = await iterator.next()
        XCTAssertEqual(receivedFrame, frame)
        await engine.resize(sessionID: descriptor.id, width: 800, height: 600)
        await engine.sendPointer(sessionID: descriptor.id, flags: 1, x: 2, y: 3)
        await engine.sendKey(sessionID: descriptor.id, flags: 4, code: 5)
        XCTAssertEqual(bridge.forwardedInput.resize.map { [$0.0, $0.1] }, [[800, 600]])
        XCTAssertEqual(bridge.forwardedInput.pointer.map { [$0.0, $0.1, $0.2] }, [[1, 2, 3]])
        XCTAssertEqual(bridge.forwardedInput.key.map { [$0.0, $0.1] }, [[4, 5]])
    }

    func testAlreadyCancelledConnectDoesNotStartBridge() async {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.connect(request, credential: nil, viewport: viewport)
        }

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(bridge.calls.connect, 0)
    }

    func testCancellationAfterBridgeStartWaitsForTerminalQuiescence() async throws {
        let bridge = FakeFreeRDPBridge(automaticallyCompletesDisconnect: false)
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        let completion = CompletionProbe()
        let task = Task {
            defer { completion.complete() }
            return try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }
        _ = await engine.currentState()

        task.cancel()
        try await waitUntil { bridge.calls.disconnect == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(completion.isCompleted)
        bridge.yield(.disconnected, generation: 1)
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(completion.isCompleted)
    }

    func testResizeRejectsNonPositiveAndUnrepresentableDimensions() async throws {
        let bridge = FakeFreeRDPBridge()
        let engine = FreeRDPSessionEngine(bridge: bridge)
        let request = request
        let viewport = viewport
        let task = Task {
            try await engine.connect(request, credential: nil, viewport: viewport)
        }
        try await waitUntil { bridge.calls.connect == 1 }
        bridge.yield(.connected)
        let descriptor = try await task.value

        await engine.resize(sessionID: descriptor.id, width: 0, height: 600)
        await engine.resize(sessionID: descriptor.id, width: 800, height: -1)
        await engine.resize(
            sessionID: descriptor.id, width: Int(Int32.max) + 1, height: 600
        )
        await engine.resize(
            sessionID: descriptor.id, width: 800, height: Int(Int32.max) + 1
        )
        await engine.resize(
            sessionID: descriptor.id, width: Int(UInt32.max) + 1, height: 600
        )
        await engine.resize(
            sessionID: descriptor.id, width: 800, height: Int(UInt32.max) + 1
        )
        XCTAssertTrue(bridge.forwardedInput.resize.isEmpty)

        await engine.resize(sessionID: descriptor.id, width: 800, height: 600)
        XCTAssertEqual(bridge.forwardedInput.resize.map { [$0.0, $0.1] }, [[800, 600]])
    }

    private struct WaitTimeout: Error {}

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @Sendable () -> Bool,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else { throw WaitTimeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func waitUntilAsync(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await predicate()) {
            guard clock.now < deadline else { throw WaitTimeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func assertConnectError(
        _ expected: RdpSessionError,
        operation: () async throws -> RdpSessionDescriptor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RdpSessionError, expected, file: file, line: line)
        }
    }

    private func certificateChallenge(
        id: UInt64,
        host: String = "example.invalid",
        port: UInt16 = 3_390
    ) throws -> RdpCertificateChallenge {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "test-certificate",
            withExtension: "pem",
            subdirectory: "Fixtures"
        ))
        return try RdpCertificateChallenge(
            id: id,
            endpoint: RdpEndpoint(host: host, port: port),
            pemData: Data(contentsOf: url),
            flags: 0
        )
    }
}
