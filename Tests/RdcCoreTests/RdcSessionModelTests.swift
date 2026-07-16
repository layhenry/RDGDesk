import XCTest
@testable import RdcCore

@MainActor
final class RdcSessionModelTests: XCTestCase {
    func testVerifiedDisconnectFailurePreservesActiveSessionState() async throws {
        let engine = FailingVerifiedDisconnectEngine()
        let model = RdcSessionModel(engine: engine)
        try await model.connect(
            server: testServer, credential: nil, viewport: .init(width: 800, height: 600)
        )
        let descriptor = try XCTUnwrap(model.descriptor)

        do {
            try await model.disconnectForResourceMutation()
            XCTFail("Expected verified disconnect to fail")
        } catch {
            XCTAssertEqual(error as? RdpSessionDisconnectError, .notDisconnected)
        }

        XCTAssertEqual(model.descriptor, descriptor)
        XCTAssertTrue(model.hasActiveEngineSession)
    }
    func testFirstUseCertificatePresentsAndDecisionIsExactlyOnce() async throws {
        let engine = CertificateRecordingEngine()
        let updates = SessionUpdateStreamFixture()
        let coordinator = CertificateTrustCoordinator(
            configurationRepository: RdcConfigurationRepository(
                store: ModelCertificateConfigurationStore()
            )
        )
        let model = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates,
            certificateChallenges: updates.certificateChallenges,
            certificateCoordinator: coordinator
        )
        try await model.connect(
            server: testServer, credential: nil, viewport: .init(width: 800, height: 600)
        )
        let attemptID = try XCTUnwrap(model.activeConnectionAttemptID)
        let sessionID = try XCTUnwrap(model.descriptor?.id)
        let challenge = try certificateChallenge(id: 201)

        updates.yieldCertificate(
            attemptID: attemptID, sessionID: sessionID, challenge: challenge
        )
        try await waitUntil { model.pendingCertificate == .firstUse(challenge) }
        await model.resolvePendingCertificate(decision: .trustOnce)
        await model.resolvePendingCertificate(decision: .trustAlways)

        XCTAssertNil(model.pendingCertificate)
        let resolutions = await engine.resolutions
        XCTAssertEqual(resolutions, [
            .init(attemptID: attemptID, sessionID: sessionID, challengeID: 201, decision: .trustOnce)
        ])
    }

    func testMatchingStoredPinAutomaticallyTrustsOnceWithoutPresentation() async throws {
        let challenge = try certificateChallenge(id: 202)
        let pin = certificatePin(for: challenge, fingerprint: challenge.sha256Fingerprint)
        let engine = CertificateRecordingEngine()
        let updates = SessionUpdateStreamFixture()
        let store = ModelCertificateConfigurationStore(
            configuration: .init(certificatePins: [challenge.endpoint: pin])
        )
        let model = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates,
            certificateChallenges: updates.certificateChallenges,
            certificateCoordinator: CertificateTrustCoordinator(
                configurationRepository: RdcConfigurationRepository(store: store)
            )
        )
        try await model.connect(
            server: testServer, credential: nil, viewport: .init(width: 800, height: 600)
        )
        let attemptID = try XCTUnwrap(model.activeConnectionAttemptID)
        let sessionID = try XCTUnwrap(model.descriptor?.id)

        updates.yieldCertificate(
            attemptID: attemptID, sessionID: sessionID, challenge: challenge
        )
        try await waitUntilAsync { await engine.resolutions.count == 1 }

        XCTAssertNil(model.pendingCertificate)
        let resolutions = await engine.resolutions
        XCTAssertEqual(resolutions.first?.decision, .trustOnce)
    }

    func testDisconnectRejectsVisibleCertificateAndLaterDecisionIsIgnored() async throws {
        let fixture = try await makeCertificateModel()
        let challenge = try certificateChallenge(id: 203)
        fixture.updates.yieldCertificate(
            attemptID: fixture.attemptID,
            sessionID: fixture.sessionID,
            challenge: challenge
        )
        try await waitUntil { fixture.model.pendingCertificate != nil }

        await fixture.model.disconnect()
        await fixture.model.resolvePendingCertificate(decision: .trustAlways)

        XCTAssertNil(fixture.model.pendingCertificate)
        let resolutions = await fixture.engine.resolutions
        XCTAssertEqual(resolutions.map(\.decision), [.reject])
    }

    func testRemoteFailureDismissesPendingCertificateAndRejectsExactlyOnce() async throws {
        let fixture = try await makeCertificateModel()
        let challenge = try certificateChallenge(id: 211)
        fixture.updates.yieldCertificate(
            attemptID: fixture.attemptID,
            sessionID: fixture.sessionID,
            challenge: challenge
        )
        try await waitUntil { fixture.model.pendingCertificate != nil }

        fixture.updates.yieldLifecycle(
            attemptID: fixture.attemptID,
            sessionID: fixture.sessionID,
            state: .failed(.network(code: 7, message: "remote terminal"))
        )
        try await waitUntil { fixture.model.pendingCertificate == nil }
        await fixture.model.resolvePendingCertificate(decision: .reject)

        let resolutions = await fixture.engine.resolutions
        XCTAssertEqual(resolutions.map(\.decision), [.reject])
        XCTAssertNil(fixture.model.descriptor)
    }

    func testCertificateTimeoutRejectsWithoutSleepingTestProcess() async throws {
        let clock = ManualCertificateChallengeClock()
        let fixture = try await makeCertificateModel(clock: clock)
        let challenge = try certificateChallenge(id: 204)
        fixture.updates.yieldCertificate(
            attemptID: fixture.attemptID,
            sessionID: fixture.sessionID,
            challenge: challenge
        )
        try await waitUntil { fixture.model.pendingCertificate != nil }
        try await waitUntilAsync { await clock.waiterCount == 1 }

        await clock.advance(by: .seconds(60))
        try await waitUntilAsync { await fixture.engine.resolutions.count == 1 }

        XCTAssertNil(fixture.model.pendingCertificate)
        let resolutions = await fixture.engine.resolutions
        XCTAssertEqual(resolutions.first?.decision, .reject)
    }

    func testStaleCertificateCannotReplaceCurrentPendingCertificate() async throws {
        let fixture = try await makeCertificateModel()
        let current = try certificateChallenge(id: 205)
        fixture.updates.yieldCertificate(
            attemptID: fixture.attemptID,
            sessionID: fixture.sessionID,
            challenge: current
        )
        try await waitUntil { fixture.model.pendingCertificate == .firstUse(current) }
        let consumed = fixture.model.consumedCertificateChallengeCount
        let stale = try certificateChallenge(id: 206)

        fixture.updates.yieldCertificate(
            attemptID: RdpConnectionAttemptID(),
            sessionID: "predecessor-session",
            challenge: stale
        )
        try await waitUntil {
            fixture.model.consumedCertificateChallengeCount == consumed + 1
        }

        XCTAssertEqual(fixture.model.pendingCertificate, .firstUse(current))
    }

    func testChangedCertificatePresentationIncludesPreservedOldPin() async throws {
        let challenge = try certificateChallenge(id: 207)
        let old = certificatePin(for: challenge, fingerprint: "OLD:FINGERPRINT")
        let engine = CertificateRecordingEngine()
        let updates = SessionUpdateStreamFixture()
        let model = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates,
            certificateChallenges: updates.certificateChallenges,
            certificateCoordinator: CertificateTrustCoordinator(
                configurationRepository: RdcConfigurationRepository(
                    store: ModelCertificateConfigurationStore(
                        configuration: .init(certificatePins: [challenge.endpoint: old])
                    )
                )
            )
        )
        try await model.connect(
            server: testServer, credential: nil, viewport: .init(width: 800, height: 600)
        )
        updates.yieldCertificate(
            attemptID: try XCTUnwrap(model.activeConnectionAttemptID),
            sessionID: try XCTUnwrap(model.descriptor?.id),
            challenge: challenge
        )

        try await waitUntil {
            model.pendingCertificate == .changed(old: old, new: challenge)
        }
    }

    func testTrustAlwaysSaveFailureRejectsAndSurfacesConfigurationError() async throws {
        let store = ModelCertificateConfigurationStore()
        await store.failNextSave()
        let engine = CertificateRecordingEngine()
        let updates = SessionUpdateStreamFixture()
        let model = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates,
            certificateChallenges: updates.certificateChallenges,
            certificateCoordinator: CertificateTrustCoordinator(
                configurationRepository: RdcConfigurationRepository(store: store)
            )
        )
        try await model.connect(
            server: testServer, credential: nil, viewport: .init(width: 800, height: 600)
        )
        let challenge = try certificateChallenge(id: 208)
        updates.yieldCertificate(
            attemptID: try XCTUnwrap(model.activeConnectionAttemptID),
            sessionID: try XCTUnwrap(model.descriptor?.id),
            challenge: challenge
        )
        try await waitUntil { model.pendingCertificate != nil }

        await model.resolvePendingCertificate(decision: .trustAlways)

        let resolutions = await engine.resolutions
        XCTAssertEqual(resolutions.map(\.decision), [.reject])
        XCTAssertEqual(model.presentedError, "无法保存证书信任设置。")
        let configuration = try await store.load()
        XCTAssertTrue(configuration.certificatePins.isEmpty)
    }

    func testDelayedAttemptACertificateCannotAffectPendingCertificateForAttemptC() async throws {
        let engine = ThreeAttemptSessionEngine()
        let updates = SessionUpdateStreamFixture()
        let model = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates,
            certificateChallenges: updates.certificateChallenges,
            certificateCoordinator: CertificateTrustCoordinator(
                configurationRepository: RdcConfigurationRepository(
                    store: ModelCertificateConfigurationStore()
                )
            )
        )
        let viewport = RdpViewport(width: 800, height: 600)
        try await model.connect(server: testServer, credential: nil, viewport: viewport)
        let attemptA = try XCTUnwrap(model.activeConnectionAttemptID)
        let sessionA = try XCTUnwrap(model.descriptor?.id)
        try await model.connect(server: testServer, credential: nil, viewport: viewport)
        let pendingC = Task {
            try await model.connect(server: testServer, credential: nil, viewport: viewport)
        }
        try await waitUntilAsync { await engine.connectCount == 3 }
        let attemptC = try XCTUnwrap(model.activeConnectionAttemptID)
        let current = try certificateChallenge(id: 209)
        updates.yieldCertificate(
            attemptID: attemptC, sessionID: "attempt-3", challenge: current
        )
        try await waitUntil { model.pendingCertificate == .firstUse(current) }
        let consumed = model.consumedCertificateChallengeCount

        updates.yieldCertificate(
            attemptID: attemptA,
            sessionID: sessionA,
            challenge: try certificateChallenge(id: 210)
        )
        try await waitUntil { model.consumedCertificateChallengeCount == consumed + 1 }

        XCTAssertEqual(model.activeConnectionAttemptID, attemptC)
        XCTAssertEqual(model.pendingCertificate, .firstUse(current))
        await model.resolvePendingCertificate(decision: .reject)
        await engine.completeThirdAttempt()
        try await pendingC.value
    }
    func testConnectReplacesWallpaperWithLiveSessionAndDisconnectRestoresIdle() async throws {
        let engine = MockRdpSessionEngine()
        let model = RdcSessionModel(engine: engine)
        let server = RdcImportedLibrary(
            document: ResourceLibrarySampleData.direction2Document,
            sourceName: "fixture.rdg"
        ).servers[0]
        let credential = RdpConnectionCredential(
            username: "tester", domain: "LAB", password: "transient"
        )

        try await model.connect(
            server: server,
            credential: credential,
            viewport: RdpViewport(width: 1_440, height: 900)
        )

        XCTAssertNotNil(model.descriptor)
        await model.disconnect()
        XCTAssertNil(model.descriptor)
    }

    func testReplacementConnectionCannotBeClearedByCancelledPredecessor() async throws {
        let engine = DelayedCancellationEngine()
        let model = RdcSessionModel(engine: engine)
        let server = RdcImportedLibrary(
            document: ResourceLibrarySampleData.direction2Document,
            sourceName: "fixture.rdg"
        ).servers[0]
        let viewport = RdpViewport(width: 1_440, height: 900)

        let first = Task {
            try? await model.connect(server: server, credential: nil, viewport: viewport)
        }
        try await waitUntilAsync { await engine.connectCount > 0 }
        try await model.connect(server: server, credential: nil, viewport: viewport)
        _ = await first.value

        XCTAssertEqual(model.descriptor?.id, "replacement-session")
    }

    func testCancellingConnectCallerCancelsEngineAttempt() async {
        let engine = DelayedCancellationEngine()
        let model = RdcSessionModel(engine: engine)
        let caller = Task {
            try await model.connect(
                server: testServer,
                credential: nil,
                viewport: RdpViewport(width: 1_440, height: 900)
            )
        }
        try? await waitUntilAsync { await engine.connectCount > 0 }

        caller.cancel()
        try? await waitUntilAsync { await engine.cancellationCount == 1 }
        let cancellationCountBeforeCleanup = await engine.cancellationCount
        await model.disconnect()
        _ = await caller.result

        XCTAssertEqual(cancellationCountBeforeCleanup, 1)
    }

    func testLateFrameAfterDisconnectCannotRepopulateIdleCanvas() async throws {
        let engine = MockRdpSessionEngine()
        let updates = SessionUpdateStreamFixture()
        let model = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates
        )
        let server = RdcImportedLibrary(
            document: ResourceLibrarySampleData.direction2Document,
            sourceName: "fixture.rdg"
        ).servers[0]
        let liveFrame = RemoteFrame(
            width: 1,
            height: 1,
            stride: 4,
            bgraBytes: [1, 2, 3, 4]
        )

        try await model.connect(
            server: server,
            credential: nil,
            viewport: RdpViewport(width: 1_440, height: 900)
        )
        let sessionID = try XCTUnwrap(model.descriptor?.id)
        let attemptID = try XCTUnwrap(model.activeConnectionAttemptID)
        updates.yieldFrame(attemptID: attemptID, sessionID: sessionID, frame: liveFrame)
        try await waitUntil { model.frame == liveFrame }
        await model.disconnect()
        let consumed = model.consumedFrameUpdateCount
        updates.yieldFrame(attemptID: attemptID, sessionID: sessionID, frame: liveFrame)
        try await waitUntil { model.consumedFrameUpdateCount == consumed + 1 }

        XCTAssertNil(model.frame)
    }

    func testReplacementIgnoresPredecessorFrameAndAcceptsCurrentFrame() async throws {
        let engine = MockRdpSessionEngine()
        let updates = SessionUpdateStreamFixture()
        let model = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates
        )
        let server = testServer
        let viewport = RdpViewport(width: 1_440, height: 900)
        let oldFrame = RemoteFrame(width: 1, height: 1, stride: 4, bgraBytes: [1, 1, 1, 1])
        let newFrame = RemoteFrame(width: 1, height: 1, stride: 4, bgraBytes: [2, 2, 2, 2])

        try await model.connect(server: server, credential: nil, viewport: viewport)
        let oldID = try XCTUnwrap(model.descriptor?.id)
        let oldAttemptID = try XCTUnwrap(model.activeConnectionAttemptID)
        try await model.connect(server: server, credential: nil, viewport: viewport)
        let newID = try XCTUnwrap(model.descriptor?.id)
        let newAttemptID = try XCTUnwrap(model.activeConnectionAttemptID)

        updates.yieldFrame(attemptID: oldAttemptID, sessionID: oldID, frame: oldFrame)
        try await waitUntil { model.consumedFrameUpdateCount == 1 }
        updates.yieldFrame(attemptID: newAttemptID, sessionID: newID, frame: newFrame)
        try await waitUntil { model.frame == newFrame }

        XCTAssertEqual(model.frame, newFrame)
    }

    func testRemoteDisconnectClearsLiveSessionAndFrame() async throws {
        let engine = MockRdpSessionEngine()
        let updates = SessionUpdateStreamFixture()
        let model = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates
        )
        try await model.connect(
            server: testServer,
            credential: nil,
            viewport: RdpViewport(width: 1_440, height: 900)
        )
        let descriptor = try XCTUnwrap(model.descriptor)
        let attemptID = try XCTUnwrap(model.activeConnectionAttemptID)
        let frame = RemoteFrame(width: 1, height: 1, stride: 4, bgraBytes: [1, 2, 3, 4])
        updates.yieldFrame(attemptID: attemptID, sessionID: descriptor.id, frame: frame)
        try await waitUntil { model.frame == frame }

        updates.yieldLifecycle(
            attemptID: attemptID, sessionID: descriptor.id, state: .disconnected
        )
        try await waitUntil { model.descriptor == nil }

        XCTAssertNil(model.descriptor)
        XCTAssertNil(model.frame)
    }

    func testRemoteFailureClearsSessionAndPresentsError() async throws {
        let engine = MockRdpSessionEngine()
        let updates = SessionUpdateStreamFixture()
        let model = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates
        )
        try await model.connect(
            server: testServer,
            credential: nil,
            viewport: RdpViewport(width: 1_440, height: 900)
        )
        let descriptor = try XCTUnwrap(model.descriptor)
        let attemptID = try XCTUnwrap(model.activeConnectionAttemptID)
        let error = RdpSessionError.network(code: 7, message: "connection lost")

        updates.yieldLifecycle(
            attemptID: attemptID, sessionID: descriptor.id, state: .failed(error)
        )
        try await waitUntil { model.presentedError != nil }

        XCTAssertNil(model.descriptor)
        XCTAssertNil(model.frame)
        XCTAssertEqual(model.presentedError, "connection lost")
    }

    func testDetailedAuthenticationFailureSurvivesSessionLifecycleUnchanged() async throws {
        let engine = MockRdpSessionEngine()
        let updates = SessionUpdateStreamFixture()
        let session = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates
        )
        try await session.connect(
            server: testServer,
            credential: nil,
            viewport: RdpViewport(width: 1_440, height: 900)
        )
        let descriptor = try XCTUnwrap(session.descriptor)
        let attemptID = try XCTUnwrap(session.activeConnectionAttemptID)
        let failure = RdpSessionError.authenticationFailed(
            reason: .wrongPassword,
            code: 0x0002_0015
        )

        updates.yieldLifecycle(
            attemptID: attemptID,
            sessionID: descriptor.id,
            state: .failed(failure)
        )
        try await waitUntil { session.lastError != nil }

        XCTAssertEqual(session.lastError, failure)
    }

    func testBufferedFrameBurstCannotHideTerminalLifecycleOrRestoreDescriptor() async throws {
        let engine = MockRdpSessionEngine()
        let updates = SessionUpdateStreamFixture()
        let model = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates
        )
        try await model.connect(
            server: testServer,
            credential: nil,
            viewport: RdpViewport(width: 1_440, height: 900)
        )
        let descriptor = try XCTUnwrap(model.descriptor)
        let attemptID = try XCTUnwrap(model.activeConnectionAttemptID)

        // Enqueue the entire burst synchronously so neither consumer can run mid-burst.
        updates.yieldLifecycle(
            attemptID: attemptID,
            sessionID: descriptor.id,
            state: .connected(descriptor)
        )
        for byte in UInt8(0)..<32 {
            updates.yieldFrame(
                attemptID: attemptID,
                sessionID: descriptor.id,
                frame: .init(width: 1, height: 1, stride: 4, bgraBytes: [byte, 0, 0, 0])
            )
        }
        updates.yieldLifecycle(
            attemptID: attemptID,
            sessionID: descriptor.id,
            state: .failed(.authenticationFailed(reason: .unknown, code: nil))
        )
        try await waitUntil { model.consumedLifecycleUpdateCount == 2 }

        XCTAssertNil(model.descriptor)
        XCTAssertNil(model.frame)
        XCTAssertEqual(model.presentedError, "用户名或密码不正确。")
    }

    func testStalePredecessorTerminalEventCannotClearReplacement() async throws {
        let engine = MockRdpSessionEngine()
        let updates = SessionUpdateStreamFixture()
        let model = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates
        )
        let viewport = RdpViewport(width: 1_440, height: 900)
        try await model.connect(server: testServer, credential: nil, viewport: viewport)
        let oldID = try XCTUnwrap(model.descriptor?.id)
        let oldAttemptID = try XCTUnwrap(model.activeConnectionAttemptID)
        try await model.connect(server: testServer, credential: nil, viewport: viewport)
        let replacement = try XCTUnwrap(model.descriptor)

        let consumed = model.consumedLifecycleUpdateCount
        updates.yieldLifecycle(
            attemptID: oldAttemptID, sessionID: oldID, state: .disconnected
        )
        try await waitUntil { model.consumedLifecycleUpdateCount == consumed + 1 }

        XCTAssertEqual(model.descriptor, replacement)
    }

    func testDelayedAttemptABacklogCannotAffectPendingAttemptC() async throws {
        let engine = ThreeAttemptSessionEngine()
        let updates = SessionUpdateStreamFixture()
        let model = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates
        )
        let viewport = RdpViewport(width: 1_440, height: 900)

        try await model.connect(server: testServer, credential: nil, viewport: viewport)
        let attemptADescriptor = try XCTUnwrap(model.descriptor)
        let attemptAID = try XCTUnwrap(model.activeConnectionAttemptID)
        try await model.connect(server: testServer, credential: nil, viewport: viewport)

        let pendingC = Task {
            try await model.connect(server: testServer, credential: nil, viewport: viewport)
        }
        try await waitUntilAsync { await engine.connectCount == 3 }
        let attemptCID = try XCTUnwrap(model.activeConnectionAttemptID)
        let lifecycleCount = model.consumedLifecycleUpdateCount
        let frameCount = model.consumedFrameUpdateCount
        let staleFrame = RemoteFrame(
            width: 1, height: 1, stride: 4, bgraBytes: [9, 9, 9, 9]
        )

        updates.yieldLifecycle(
            attemptID: attemptAID,
            sessionID: attemptADescriptor.id,
            state: .connected(attemptADescriptor)
        )
        updates.yieldFrame(
            attemptID: attemptAID,
            sessionID: attemptADescriptor.id,
            frame: staleFrame
        )
        updates.yieldLifecycle(
            attemptID: attemptAID,
            sessionID: attemptADescriptor.id,
            state: .failed(.authenticationFailed(reason: .unknown, code: nil))
        )
        try await waitUntil {
            model.consumedLifecycleUpdateCount == lifecycleCount + 2 &&
                model.consumedFrameUpdateCount == frameCount + 1
        }

        XCTAssertEqual(model.activeConnectionAttemptID, attemptCID)
        XCTAssertTrue(model.isConnecting)
        XCTAssertNil(model.descriptor)
        XCTAssertNil(model.frame)
        XCTAssertNil(model.presentedError)

        await engine.completeThirdAttempt()
        try await pendingC.value
        XCTAssertEqual(model.descriptor?.id, "attempt-3")
        XCTAssertEqual(model.activeConnectionAttemptID, attemptCID)
    }

    func testShutdownDisconnectsActiveEngineExactlyOnce() async throws {
        let engine = CountingSessionEngine()
        let updates = SessionUpdateStreamFixture()
        let model = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates
        )
        try await model.connect(
            server: testServer,
            credential: nil,
            viewport: RdpViewport(width: 1_440, height: 900)
        )
        await model.shutdown()
        await model.shutdown()

        let disconnectCount = await engine.disconnectCount
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertNil(model.frame)
    }

    func testActiveEngineSessionStateTracksConnectAndDisconnect() async throws {
        let model = RdcSessionModel(engine: CountingSessionEngine())
        XCTAssertFalse(model.hasActiveEngineSession)

        try await model.connect(
            server: testServer, credential: nil, viewport: .init(width: 800, height: 600)
        )
        XCTAssertTrue(model.hasActiveEngineSession)

        await model.disconnect()
        XCTAssertFalse(model.hasActiveEngineSession)
        XCTAssertNil(model.descriptor)
        XCTAssertFalse(model.isConnecting)
    }

    private var testServer: RdcImportedServer {
        RdcImportedLibrary(
            document: ResourceLibrarySampleData.direction2Document,
            sourceName: "fixture.rdg"
        ).servers[0]
    }

    private func makeCertificateModel(
        clock: (any CertificateChallengeClock)? = nil
    ) async throws -> (
        model: RdcSessionModel,
        engine: CertificateRecordingEngine,
        updates: SessionUpdateStreamFixture,
        attemptID: RdpConnectionAttemptID,
        sessionID: String
    ) {
        let engine = CertificateRecordingEngine()
        let updates = SessionUpdateStreamFixture()
        let model = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: updates.lifecycleUpdates,
            frameUpdates: updates.frameUpdates,
            certificateChallenges: updates.certificateChallenges,
            certificateCoordinator: CertificateTrustCoordinator(
                configurationRepository: RdcConfigurationRepository(
                    store: ModelCertificateConfigurationStore()
                )
            ),
            certificateClock: clock
        )
        try await model.connect(
            server: testServer,
            credential: nil,
            viewport: .init(width: 800, height: 600)
        )
        return (
            model, engine, updates,
            try XCTUnwrap(model.activeConnectionAttemptID),
            try XCTUnwrap(model.descriptor?.id)
        )
    }

    private func certificateChallenge(id: UInt64) throws -> RdpCertificateChallenge {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "test-certificate", withExtension: "pem", subdirectory: "Fixtures"
        ))
        let request = testServer.connectionRequest
        return try RdpCertificateChallenge(
            id: id,
            endpoint: .init(host: request.host, port: UInt16(request.port ?? 3_389)),
            pemData: Data(contentsOf: url),
            flags: 0
        )
    }

    private func certificatePin(
        for challenge: RdpCertificateChallenge,
        fingerprint: String
    ) -> CertificatePin {
        .init(
            endpoint: challenge.endpoint,
            subject: challenge.subject,
            issuer: challenge.issuer,
            sha256Fingerprint: fingerprint,
            notBefore: challenge.notBefore,
            notAfter: challenge.notAfter,
            firstTrustedAt: .distantPast,
            lastConfirmedAt: .distantPast
        )
    }

    private struct WaitTimeout: Error {}

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw WaitTimeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func waitUntilAsync(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else { throw WaitTimeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor FailingVerifiedDisconnectEngine: RdpSessionEngine {
    private var state: RdpSessionState = .idle

    func currentState() async -> RdpSessionState { state }

    func connect(
        _ request: RdpConnectionRequest,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport,
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        let descriptor = RdpSessionDescriptor(
            id: "failing-disconnect", request: request, transport: .mock
        )
        state = .connected(descriptor)
        return descriptor
    }

    func disconnect() async {}
    func disconnectVerified() async throws { throw RdpSessionDisconnectError.notDisconnected }
    func reconnect(attemptID: RdpConnectionAttemptID) async throws -> RdpSessionDescriptor {
        throw RdpSessionError.notConnected
    }
}

private final class SessionUpdateStreamFixture: @unchecked Sendable {
    let lifecycleUpdates: AsyncStream<RdpSessionLifecycleUpdate>
    let frameUpdates: AsyncStream<RdpSessionFrameUpdate>
    let certificateChallenges: AsyncStream<RdpCertificateChallengeUpdate>
    private let lifecycleContinuation: AsyncStream<RdpSessionLifecycleUpdate>.Continuation
    private let frameContinuation: AsyncStream<RdpSessionFrameUpdate>.Continuation
    private let certificateContinuation: AsyncStream<RdpCertificateChallengeUpdate>.Continuation

    init() {
        var installedLifecycle: AsyncStream<RdpSessionLifecycleUpdate>.Continuation?
        lifecycleUpdates = AsyncStream { installedLifecycle = $0 }
        lifecycleContinuation = installedLifecycle!

        var installedFrames: AsyncStream<RdpSessionFrameUpdate>.Continuation?
        frameUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            installedFrames = $0
        }
        frameContinuation = installedFrames!

        var installedCertificates: AsyncStream<RdpCertificateChallengeUpdate>.Continuation?
        certificateChallenges = AsyncStream { installedCertificates = $0 }
        certificateContinuation = installedCertificates!
    }

    func yieldLifecycle(
        attemptID: RdpConnectionAttemptID,
        sessionID: String,
        state: RdpSessionState
    ) {
        lifecycleContinuation.yield(.init(
            attemptID: attemptID, sessionID: sessionID, state: state
        ))
    }

    func yieldFrame(
        attemptID: RdpConnectionAttemptID,
        sessionID: String,
        frame: RemoteFrame
    ) {
        frameContinuation.yield(.init(
            attemptID: attemptID, sessionID: sessionID, frame: frame
        ))
    }

    func yieldCertificate(
        attemptID: RdpConnectionAttemptID,
        sessionID: String,
        challenge: RdpCertificateChallenge
    ) {
        certificateContinuation.yield(.init(
            attemptID: attemptID, sessionID: sessionID, challenge: challenge
        ))
    }
}

private struct CertificateResolution: Equatable, Sendable {
    let attemptID: RdpConnectionAttemptID
    let sessionID: String
    let challengeID: UInt64
    let decision: RdpCertificateDecision
}

private actor CertificateRecordingEngine: RdpSessionEngine {
    private var sequence = 0
    private(set) var resolutions: [CertificateResolution] = []

    func currentState() async -> RdpSessionState { .idle }

    func connect(
        _ request: RdpConnectionRequest,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport,
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        sequence += 1
        return .init(id: "certificate-session-\(sequence)", request: request, transport: .mock)
    }

    func disconnect() async {}
    func reconnect(attemptID: RdpConnectionAttemptID) async throws -> RdpSessionDescriptor {
        throw RdpSessionError.notConnected
    }

    func resolveCertificate(
        attemptID: RdpConnectionAttemptID,
        sessionID: String,
        challengeID: UInt64,
        decision: RdpCertificateDecision
    ) async {
        resolutions.append(.init(
            attemptID: attemptID,
            sessionID: sessionID,
            challengeID: challengeID,
            decision: decision
        ))
    }
}

private actor ModelCertificateConfigurationStore: RdcConfigurationStore {
    private var configuration: RdcAppConfiguration
    private var shouldFailNextSave = false
    init(configuration: RdcAppConfiguration = .default) { self.configuration = configuration }
    func load() async throws -> RdcAppConfiguration { configuration }
    func save(_ configuration: RdcAppConfiguration) async throws {
        if shouldFailNextSave {
            shouldFailNextSave = false
            throw ModelCertificateStoreError.saveFailed
        }
        self.configuration = configuration
    }
    func failNextSave() { shouldFailNextSave = true }
}

private enum ModelCertificateStoreError: Error { case saveFailed }

private actor ManualCertificateChallengeClock: CertificateChallengeClock {
    private var elapsed: Duration = .zero
    private var waiters: [(Duration, CheckedContinuation<Void, Error>)] = []
    var waiterCount: Int { waiters.count }

    func sleep(for duration: Duration) async throws {
        let deadline = elapsed + duration
        if elapsed >= deadline { return }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append((deadline, continuation))
        }
    }

    func advance(by duration: Duration) {
        elapsed += duration
        let ready = waiters.filter { $0.0 <= elapsed }
        waiters.removeAll { $0.0 <= elapsed }
        ready.forEach { $0.1.resume() }
    }
}

private actor CountingSessionEngine: RdpSessionEngine {
    private(set) var disconnectCount = 0
    private var descriptor: RdpSessionDescriptor?

    func currentState() async -> RdpSessionState {
        descriptor.map(RdpSessionState.connected) ?? .disconnected
    }

    func connect(
        _ request: RdpConnectionRequest,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport,
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        let descriptor = RdpSessionDescriptor(
            id: "counting-session",
            request: request,
            transport: .mock
        )
        self.descriptor = descriptor
        return descriptor
    }

    func disconnect() async {
        disconnectCount += 1
        descriptor = nil
    }

    func reconnect(
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        throw RdpSessionError.notConnected
    }
}

private actor DelayedCancellationEngine: RdpSessionEngine {
    private(set) var connectCount = 0
    private(set) var cancellationCount = 0
    private var firstContinuation: CheckedContinuation<RdpSessionDescriptor, Error>?

    func currentState() async -> RdpSessionState { .idle }

    func connect(
        _ request: RdpConnectionRequest,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport,
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        connectCount += 1
        if connectCount == 1 {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    firstContinuation = continuation
                }
            } onCancel: {
                Task { await self.cancelFirstAttempt() }
            }
        }
        return RdpSessionDescriptor(
            id: "replacement-session",
            request: request,
            transport: .mock
        )
    }

    func disconnect() async {
        guard let continuation = firstContinuation else { return }
        firstContinuation = nil
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            continuation.resume(throwing: CancellationError())
        }
    }

    func reconnect(
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        throw RdpSessionError.notConnected
    }

    private func cancelFirstAttempt() {
        cancellationCount += 1
        firstContinuation?.resume(throwing: CancellationError())
        firstContinuation = nil
    }
}

private actor ThreeAttemptSessionEngine: RdpSessionEngine {
    private(set) var connectCount = 0
    private var thirdContinuation: CheckedContinuation<RdpSessionDescriptor, Never>?
    private var thirdDescriptor: RdpSessionDescriptor?

    func currentState() async -> RdpSessionState { .idle }

    func connect(
        _ request: RdpConnectionRequest,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport,
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        connectCount += 1
        let descriptor = RdpSessionDescriptor(
            id: "attempt-\(connectCount)", request: request, transport: .mock
        )
        guard connectCount == 3 else { return descriptor }
        thirdDescriptor = descriptor
        return await withCheckedContinuation { continuation in
            thirdContinuation = continuation
        }
    }

    func disconnect() async {}

    func reconnect(
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        throw RdpSessionError.notConnected
    }

    func completeThirdAttempt() {
        guard let descriptor = thirdDescriptor else { return }
        thirdDescriptor = nil
        thirdContinuation?.resume(returning: descriptor)
        thirdContinuation = nil
    }
}
