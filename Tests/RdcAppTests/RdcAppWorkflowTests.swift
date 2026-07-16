import XCTest
@testable import RdcApp
@testable import RdcCore

@MainActor
final class RdcAppWorkflowTests: XCTestCase {
    func testProductionDefaultAppModelConstructsAndShutsDown() async {
        let model = RdcAppModel()

        XCTAssertEqual(model.configuration, .default)
        XCTAssertNil(model.library)
        await model.shutdownAndWait()
    }

    func testClipboardRequiresExplicitClickAndSecureAttentionUsesActiveSession() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "clipboard-source", sourceName: "temp2.rdg", document: testDocument()
        )
        let engine = AppRecordingSessionEngine()
        let pasteboard = AppTextPasteboard(text: "hello 你好")
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(
                store: AppMemoryConfigurationStore(
                    configuration: RdcAppConfiguration(lastLibrary: snapshot)
                )
            ),
            passwordStore: AppMemoryPasswordStore(),
            engine: engine,
            textPasteboard: pasteboard
        )
        await model.loadPersistedState()
        let server = try XCTUnwrap(model.selectedServer)
        try await model.session.connect(
            server: server, credential: nil, viewport: RdpViewport(width: 800, height: 600)
        )

        var capture = await engine.capture()
        XCTAssertEqual(capture.clipboardTexts, [])
        XCTAssertEqual(capture.secureAttentionCount, 0)

        XCTAssertTrue(model.sendLocalClipboardText())
        model.sendSecureAttention()
        try await waitUntilAsync {
            let capture = await engine.capture()
            return capture.clipboardTexts == ["hello 你好"] && capture.secureAttentionCount == 1
        }
        capture = await engine.capture()
        XCTAssertEqual(capture.clipboardTexts, ["hello 你好"])
        XCTAssertEqual(capture.secureAttentionCount, 1)
        await model.shutdownAndWait()
    }

    func testRemoteClipboardIsScopedAndWrittenToInjectedPasteboard() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "remote-clipboard", sourceName: "temp2.rdg", document: testDocument()
        )
        let engine = AppRecordingSessionEngine()
        let pasteboard = AppTextPasteboard()
        var continuation: AsyncStream<RdpClipboardUpdate>.Continuation?
        let updates = AsyncStream<RdpClipboardUpdate> { continuation = $0 }
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(
                store: AppMemoryConfigurationStore(
                    configuration: RdcAppConfiguration(lastLibrary: snapshot)
                )
            ),
            passwordStore: AppMemoryPasswordStore(),
            engine: engine,
            clipboardUpdates: updates,
            textPasteboard: pasteboard
        )
        await model.loadPersistedState()
        let server = try XCTUnwrap(model.selectedServer)
        try await model.session.connect(
            server: server, credential: nil, viewport: RdpViewport(width: 800, height: 600)
        )
        let engineCapture = await engine.capture()
        let attemptID = try XCTUnwrap(engineCapture.attemptID)
        continuation?.yield(.init(
            attemptID: RdpConnectionAttemptID(),
            sessionID: "app-workflow-session",
            text: "stale"
        ))
        continuation?.yield(.init(
            attemptID: attemptID,
            sessionID: "app-workflow-session",
            text: "remote text"
        ))
        try await waitUntil { pasteboard.text == "remote text" }
        XCTAssertEqual(pasteboard.writes, ["remote text"])
        continuation?.finish()
        await model.shutdownAndWait()
    }

    func testClipboardRejectsOversizeTextWithoutForwarding() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "large-clipboard", sourceName: "temp2.rdg", document: testDocument()
        )
        let engine = AppRecordingSessionEngine()
        let pasteboard = AppTextPasteboard(text: String(repeating: "a", count: 1_048_577))
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(
                store: AppMemoryConfigurationStore(
                    configuration: RdcAppConfiguration(lastLibrary: snapshot)
                )
            ),
            passwordStore: AppMemoryPasswordStore(),
            engine: engine,
            textPasteboard: pasteboard
        )
        await model.loadPersistedState()
        let server = try XCTUnwrap(model.selectedServer)
        try await model.session.connect(
            server: server, credential: nil, viewport: RdpViewport(width: 800, height: 600)
        )

        XCTAssertFalse(model.sendLocalClipboardText())
        try await Task.sleep(for: .milliseconds(10))
        let capture = await engine.capture()
        XCTAssertEqual(capture.clipboardTexts, [])
        XCTAssertEqual(model.clipboardStatusMessage, "文本超过 1 MB，未发送")
        await model.shutdownAndWait()
    }

    func testLaunchRestoresSanitizedLibraryAndGlobalCredentialConnectsWithoutPrompt() async throws {
        let document = testDocument()
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-restart",
            sourceName: "temp2.rdg",
            document: document
        )
        let credentialID = "global-credential"
        let configuration = RdcAppConfiguration(
            globalCredentialID: credentialID,
            credentialMetadata: [
                credentialID: CredentialMetadata(
                    id: credentialID,
                    username: "Administrator",
                    domain: "LAB"
                )
            ],
            lastLibrary: snapshot
        )
        let configurationStore = AppMemoryConfigurationStore(configuration: configuration)
        let repository = RdcConfigurationRepository(store: configurationStore)
        let passwordStore = AppMemoryPasswordStore(
            passwords: [credentialID: UUID().uuidString]
        )
        let engine = AppRecordingSessionEngine()
        let model = RdcAppModel(
            configurationRepository: repository,
            passwordStore: passwordStore,
            engine: engine
        )

        await model.loadPersistedState()
        await model.connectSelectedServer()

        XCTAssertEqual(model.library?.sourceID, snapshot.sourceID)
        XCTAssertEqual(model.library?.servers.count, 1)
        XCTAssertFalse(model.isShowingCredentialSheet)
        let capture = await engine.capture()
        XCTAssertEqual(capture.username, "Administrator")
        XCTAssertEqual(capture.domain, "LAB")
        await model.shutdownAndWait()
    }

    func testLaunchLoadsSettingsButHonorsRestoreLastLibraryDisabled() async {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-restore-disabled",
            sourceName: "temp2.rdg",
            document: testDocument()
        )
        let preferences = RdcGeneralPreferences(
            restoresLastLibrary: false,
            doubleClickConnects: false,
            resizesRemoteDesktopWithWindow: false
        )
        let configuration = RdcAppConfiguration(
            lastLibrary: snapshot,
            preferences: preferences
        )
        let model = makeModel(
            configuration: configuration,
            engine: AppRecordingSessionEngine()
        )

        await model.loadPersistedState()

        XCTAssertEqual(model.configuration.preferences, preferences)
        XCTAssertNil(model.library)
        await model.shutdownAndWait()
    }

    func testPersistedSourceIDSidebarRowsSelectRealServersImmediately() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "persisted-source-that-is-not-the-compatibility-id",
            sourceName: "temp2.rdg",
            document: twoServerDocument()
        )
        let model = makeModel(
            configuration: RdcAppConfiguration(lastLibrary: snapshot),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let servers = try XCTUnwrap(model.library?.servers)
        let target = try XCTUnwrap(servers.last)
        let sidebar = try XCTUnwrap(model.resourceLibrarySidebarState(
            expandedGroupIDs: Set(model.library?.groups.map(\.id) ?? []),
            searchText: target.displayName
        ))
        let row = try XCTUnwrap(sidebar.rows.first { $0.representedServerID != nil })

        XCTAssertEqual(row.representedServerID, target.id)
        model.selectServer(id: try XCTUnwrap(row.representedServerID))
        XCTAssertEqual(model.selectedServerID, target.id)
        XCTAssertEqual(model.selectedServer?.id, target.id)

        model.selectServer(id: "not-a-real-server")
        XCTAssertEqual(model.selectedServerID, target.id)
        await model.waitForPendingOperations()
        await model.shutdownAndWait()
    }

    func testResourceOperationsPersistOnceAndKeepSelectionStable() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "resource-edits", sourceName: "temp2.rdg", document: nestedDocument()
        )
        let store = AppControlledConfigurationStore(
            configuration: RdcAppConfiguration(lastLibrary: snapshot)
        )
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let selectedID = try XCTUnwrap(model.selectedServerID)
        let groupID = try XCTUnwrap(model.selectedServer?.groupPathIDs.last)

        try await model.updateServer(
            id: selectedID,
            draft: .init(displayName: "  New Server  ", host: "203.0.113.44", port: 3390)
        )

        XCTAssertEqual(model.selectedServerID, selectedID)
        XCTAssertEqual(model.selectedServer?.displayName, "New Server")
        XCTAssertEqual(model.selectedServer?.connectionRequest.host, "203.0.113.44")
        let firstSaveCount = await store.savedCount()
        XCTAssertEqual(firstSaveCount, 1)

        try await model.createChildGroup(parentID: groupID, name: "Child")
        XCTAssertEqual(model.selectedServerID, selectedID)
        let secondSaveCount = await store.savedCount()
        XCTAssertEqual(secondSaveCount, 2)
        await model.shutdownAndWait()
    }

    func testEveryPropertyAndMoveOperationPersistsOnceAndPreservesBindings() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "all-resource-edits", sourceName: "temp2.rdg", document: nestedDocument()
        )
        let serverID = try XCTUnwrap(snapshot.root.groups.first?.servers.first?.id)
        let groupID = try XCTUnwrap(snapshot.root.groups.first?.id)
        let rootID = try XCTUnwrap(snapshot.root.id)
        let store = AppControlledConfigurationStore(configuration: RdcAppConfiguration(
            groupCredentialBindings: [groupID: "group-binding"],
            serverCredentialBindings: [serverID: "server-binding"],
            lastLibrary: snapshot
        ))
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        try await model.updateGroup(id: groupID, draft: .init(name: "Renamed Team"))
        try await model.createChildGroup(parentID: rootID, name: "Destination")
        let destinationID = try XCTUnwrap(
            model.configuration.lastLibrary?.root.groups.first { $0.name == "Destination" }?.id
        )
        try await model.moveServer(id: serverID, destinationGroupID: destinationID)
        try await model.moveGroup(id: groupID, destinationGroupID: destinationID)

        let saveCount = await store.savedCount()
        XCTAssertEqual(saveCount, 4)
        XCTAssertEqual(model.selectedServerID, serverID)
        XCTAssertEqual(model.configuration.groupCredentialBindings[groupID], "group-binding")
        XCTAssertEqual(model.configuration.serverCredentialBindings[serverID], "server-binding")
        XCTAssertTrue(model.selectedServer?.groupPathIDs.contains(destinationID) ?? false)
        await model.shutdownAndWait()
    }

    func testEditingConnectedServerDoesNotDisconnectAndUpdatesNextRequest() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "connected-edit", sourceName: "temp2.rdg", document: testDocument()
        )
        let engine = AppRecordingSessionEngine()
        let model = makeModel(
            configuration: RdcAppConfiguration(lastLibrary: snapshot), engine: engine
        )
        await model.loadPersistedState()
        let serverID = try XCTUnwrap(model.selectedServerID)
        try await model.session.connect(
            server: try XCTUnwrap(model.selectedServer), credential: nil,
            viewport: .init(width: 800, height: 600)
        )

        try await model.updateServer(
            id: serverID,
            draft: .init(displayName: "New Name", host: "203.0.113.55", port: 3391)
        )

        let disconnectCount = await engine.disconnectCount()
        XCTAssertEqual(disconnectCount, 0)
        XCTAssertNotNil(model.session.descriptor)
        XCTAssertEqual(model.selectedServer?.displayName, "New Name")
        XCTAssertEqual(model.selectedServer?.connectionRequest.host, "203.0.113.55")
        XCTAssertEqual(model.selectedServer?.connectionRequest.port, 3391)
        await model.shutdownAndWait()
    }

    func testDeleteActiveServerDisconnectsBeforePersistingAndCleansBinding() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "delete-active", sourceName: "temp2.rdg", document: nestedDocument()
        )
        let serverID = try XCTUnwrap(snapshot.root.groups.first?.servers.first?.id)
        let credentialID = "deleted-only-credential"
        let store = AppControlledConfigurationStore(configuration: RdcAppConfiguration(
            serverCredentialBindings: [serverID: credentialID],
            credentialMetadata: [credentialID: .init(id: credentialID, username: "operator", domain: nil)],
            lastLibrary: snapshot
        ))
        let passwordStore = AppMemoryPasswordStore(passwords: [credentialID: "test-password"])
        let engine = AppRecordingSessionEngine()
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: engine
        )
        await model.loadPersistedState()
        try await model.session.connect(
            server: try XCTUnwrap(model.selectedServer), credential: nil,
            viewport: .init(width: 800, height: 600)
        )

        try await model.deleteServer(id: serverID)

        let disconnectCount = await engine.disconnectCount()
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertNil(model.session.descriptor)
        XCTAssertFalse(model.session.hasActiveEngineSession)
        XCTAssertNil(model.configuration.serverCredentialBindings[serverID])
        XCTAssertNil(model.configuration.credentialMetadata[credentialID])
        XCTAssertFalse(model.library?.servers.contains { $0.id == serverID } ?? true)
        let deletedCredentialIDs = await passwordStore.deletedCredentialIDs()
        let saveCount = await store.savedCount()
        XCTAssertEqual(deletedCredentialIDs, [credentialID])
        XCTAssertEqual(saveCount, 1)
        await model.shutdownAndWait()
    }

    func testFailedVerifiedDisconnectKeepsSessionAndPreventsDeletionCommit() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "disconnect-fail", sourceName: "temp2.rdg", document: testDocument()
        )
        let store = AppControlledConfigurationStore(configuration: .init(lastLibrary: snapshot))
        let engine = AppRecordingSessionEngine(failsVerifiedDisconnect: true)
        let model = RdcAppModel(
            configurationRepository: .init(store: store),
            passwordStore: AppMemoryPasswordStore(), engine: engine
        )
        await model.loadPersistedState()
        let server = try XCTUnwrap(model.selectedServer)
        try await model.session.connect(
            server: server, credential: nil, viewport: .init(width: 800, height: 600)
        )
        let descriptor = model.session.descriptor

        let error = await captureError { try await model.deleteServer(id: server.id) }

        XCTAssertEqual(error as? ResourceLibraryOperationError, .sessionDisconnectFailed)
        XCTAssertEqual(model.session.descriptor, descriptor)
        XCTAssertTrue(model.session.hasActiveEngineSession)
        let saveCount = await store.savedCount()
        XCTAssertEqual(saveCount, 0)
        XCTAssertNotNil(model.library?.servers.first { $0.id == server.id })
        await model.shutdownAndWait()
    }

    func testDeleteInactiveServerDoesNotDisconnectAndSharedCredentialSurvives() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "delete-shared", sourceName: "temp2.rdg", document: twoServerDocument()
        )
        let ids = snapshot.root.servers.compactMap(\.id)
        let credentialID = "shared-credential"
        let passwordStore = AppMemoryPasswordStore(passwords: [credentialID: "test-password"])
        let engine = AppRecordingSessionEngine()
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: AppMemoryConfigurationStore(
                configuration: RdcAppConfiguration(
                    serverCredentialBindings: Dictionary(uniqueKeysWithValues: ids.map { ($0, credentialID) }),
                    credentialMetadata: [credentialID: .init(id: credentialID, username: "operator", domain: nil)],
                    lastLibrary: snapshot
                )
            )),
            passwordStore: passwordStore,
            engine: engine
        )
        await model.loadPersistedState()

        try await model.deleteServer(id: try XCTUnwrap(ids.first))

        let disconnectCount = await engine.disconnectCount()
        XCTAssertEqual(disconnectCount, 0)
        XCTAssertNotNil(model.configuration.credentialMetadata[credentialID])
        let deletedCredentialIDs = await passwordStore.deletedCredentialIDs()
        XCTAssertEqual(deletedCredentialIDs, [])
        await model.shutdownAndWait()
    }

    func testRecursiveGroupDeletionAndLibraryRemovalCleanEveryBinding() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "recursive-delete", sourceName: "temp2.rdg", document: nestedDocument()
        )
        let groupID = try XCTUnwrap(snapshot.root.groups.first?.id)
        let serverID = try XCTUnwrap(snapshot.root.groups.first?.servers.first?.id)
        let model = makeModel(
            configuration: RdcAppConfiguration(
                groupCredentialBindings: [groupID: "group-credential"],
                serverCredentialBindings: [serverID: "server-credential"],
                credentialMetadata: metadata(
                    ("group-credential", "group-user"), ("server-credential", "server-user")
                ),
                lastLibrary: snapshot
            ),
            passwords: ["group-credential": "one", "server-credential": "two"],
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        try await model.deleteGroup(id: groupID)
        XCTAssertTrue(model.configuration.groupCredentialBindings.isEmpty)
        XCTAssertTrue(model.configuration.serverCredentialBindings.isEmpty)

        try await model.removeLibrary()
        XCTAssertNil(model.library)
        XCTAssertNil(model.configuration.lastLibrary)
        await model.shutdownAndWait()
    }

    func testResourceDeleteKeychainFailureAndConfigurationFailureAreAtomic() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "atomic-delete", sourceName: "temp2.rdg", document: testDocument()
        )
        let serverID = try XCTUnwrap(snapshot.root.servers.first?.id)
        let credentialID = "atomic-credential"
        let initial = RdcAppConfiguration(
            serverCredentialBindings: [serverID: credentialID],
            credentialMetadata: [credentialID: .init(id: credentialID, username: "operator", domain: nil)],
            lastLibrary: snapshot
        )

        let failingPasswordStore = AppMemoryPasswordStore(
            passwords: [credentialID: "test-password"], failingDeleteIDs: [credentialID]
        )
        let firstStore = AppControlledConfigurationStore(configuration: initial)
        let firstModel = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: firstStore),
            passwordStore: failingPasswordStore,
            engine: AppRecordingSessionEngine()
        )
        await firstModel.loadPersistedState()
        await XCTAssertThrowsErrorAsync { try await firstModel.deleteServer(id: serverID) }
        XCTAssertEqual(firstModel.configuration, initial)
        let firstSaveCount = await firstStore.savedCount()
        XCTAssertEqual(firstSaveCount, 0)
        await firstModel.shutdownAndWait()

        let secondStore = AppControlledConfigurationStore(
            configuration: initial, failingSaveNumbers: [1]
        )
        let secondPasswordStore = AppMemoryPasswordStore(passwords: [credentialID: "test-password"])
        let secondModel = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: secondStore),
            passwordStore: secondPasswordStore,
            engine: AppRecordingSessionEngine()
        )
        await secondModel.loadPersistedState()
        let selectedBeforeFailure = secondModel.selectedServerID
        let libraryBeforeFailure = secondModel.library
        await XCTAssertThrowsErrorAsync { try await secondModel.deleteServer(id: serverID) }
        XCTAssertEqual(secondModel.configuration, initial)
        XCTAssertEqual(secondModel.selectedServerID, selectedBeforeFailure)
        XCTAssertEqual(secondModel.library, libraryBeforeFailure)
        let remainingCredentialIDs = await secondPasswordStore.allCredentialIDs()
        XCTAssertEqual(remainingCredentialIDs, [credentialID])
        await secondModel.shutdownAndWait()
    }

    func testDeletionRequestDoesNotOptimisticallyRemoveAndFailureKeepsRequest() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "confirm-delete", sourceName: "temp2.rdg", document: testDocument()
        )
        let serverID = try XCTUnwrap(snapshot.root.servers.first?.id)
        let initial = RdcAppConfiguration(lastLibrary: snapshot)
        let store = AppControlledConfigurationStore(
            configuration: initial, failingSaveNumbers: [1]
        )
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let lease = model.resourcePropertyCoordinator.register(
            host: .primaryWindow(id: UUID())
        )

        XCTAssertTrue(model.requestServerDeletion(id: serverID, ownerLease: lease))
        let request = try XCTUnwrap(model.pendingResourceDeletion)
        XCTAssertTrue(model.library?.servers.contains { $0.id == serverID } ?? false)

        let succeeded = await model.confirmResourceDeletion(request)
        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.pendingResourceDeletion, request)
        XCTAssertTrue(model.library?.servers.contains { $0.id == serverID } ?? false)
        XCTAssertEqual(model.configuration, initial)
        XCTAssertEqual(
            model.resourceOperationMessage,
            ResourceLibraryOperationError.configurationSaveFailed.safeMessage
        )
        await model.shutdownAndWait()
    }

    func testFailedDeletionAfterOwnerDisappearsDoesNotRestoreInvisibleRequest() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "owner-disappeared-delete", sourceName: "temp2.rdg",
            document: testDocument()
        )
        let serverID = try XCTUnwrap(snapshot.root.servers.first?.id)
        let checkpoint = AppResourceOperationCheckpoint()
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(
                store: AppControlledConfigurationStore(
                    configuration: RdcAppConfiguration(lastLibrary: snapshot),
                    failingSaveNumbers: [1]
                )
            ),
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine(),
            resourceOperationCheckpoint: { await checkpoint.pause() }
        )
        await model.loadPersistedState()
        let oldLease = model.resourcePropertyCoordinator.register(
            host: .primaryWindow(id: UUID())
        )
        XCTAssertTrue(model.requestServerDeletion(id: serverID, ownerLease: oldLease))
        let request = try XCTUnwrap(model.pendingResourceDeletion)
        XCTAssertEqual(model.resourcePropertyCoordinator.claimDeletion(
            request, lease: oldLease
        ), .claimed)
        let presentation = try XCTUnwrap(
            model.resourcePropertyCoordinator.deletionPresentation(
                requested: request, lease: oldLease
            )
        )
        let token = try XCTUnwrap(
            model.resourcePropertyCoordinator.beginDeletion(for: presentation)
        )
        XCTAssertEqual(
            model.resourcePropertyCoordinator.deletionDialogDidDismiss(presentation),
            .operationInFlight
        )

        let confirmation = Task { await model.confirmResourceDeletion(request) }
        await checkpoint.waitUntilPaused()
        model.resourcePropertyCoordinator.unregister(lease: oldLease)
        model.releaseResourcePresentationRequests(ownedBy: oldLease)
        XCTAssertFalse(model.resourcePropertyCoordinator.hasInFlightDeletion(ownedBy: oldLease))
        await checkpoint.resume()

        let succeeded = await confirmation.value
        XCTAssertFalse(succeeded)
        XCTAssertNil(model.pendingResourceDeletion)
        XCTAssertEqual(
            model.resourceOperationMessage,
            ResourceLibraryOperationError.configurationSaveFailed.safeMessage
        )
        XCTAssertFalse(model.resourcePropertyCoordinator.finishDeletion(
            token: token,
            presentation: presentation,
            succeeded: false,
            requestedStillCurrent: false
        ))

        let newLease = model.resourcePropertyCoordinator.register(
            host: .primaryWindow(id: UUID())
        )
        XCTAssertTrue(model.requestServerDeletion(id: serverID, ownerLease: newLease))
        let newRequest = try XCTUnwrap(model.pendingResourceDeletion)
        XCTAssertEqual(model.resourcePropertyCoordinator.claimDeletion(
            newRequest, lease: newLease
        ), .claimed)
        await model.shutdownAndWait()
    }

    func testPersistentCredentialEditorBlocksButDoesNotLosePendingDeletion() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "credential-blocked-delete", sourceName: "temp2.rdg",
            document: testDocument()
        )
        let model = makeModel(
            configuration: RdcAppConfiguration(lastLibrary: snapshot),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let lease = model.resourcePropertyCoordinator.register(host: host)
        let serverID = try XCTUnwrap(model.selectedServerID)
        XCTAssertTrue(model.requestServerDeletion(id: serverID, ownerLease: lease))
        let request = try XCTUnwrap(model.pendingResourceDeletion)
        model.editCredential(for: .global, host: host)

        XCTAssertEqual(model.resourcePropertyCoordinator.claimDeletion(
            request,
            lease: lease,
            activeCredential: model.credentialEditorPresentation
        ), .blockedByCredentialEditor)
        XCTAssertEqual(model.pendingResourceDeletion, request)
        model.dismissCredentialEditor(host: host)
        XCTAssertEqual(model.resourcePropertyCoordinator.claimDeletion(
            request, lease: lease, activeCredential: model.credentialEditorPresentation
        ), .claimed)
        XCTAssertEqual(model.pendingResourceDeletion, request)
        model.resourcePropertyCoordinator.unregister(lease: lease)
        model.releaseResourcePresentationRequests(ownedBy: lease)
        XCTAssertNil(model.pendingResourceDeletion)
        await model.shutdownAndWait()
    }

    func testCompletedOldDeletionDoesNotClearNewerConfirmationRequest() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "rapid-confirm-delete", sourceName: "temp2.rdg",
            document: twoServerDocument()
        )
        let ids = snapshot.root.servers.compactMap(\.id)
        let checkpoint = AppResourceOperationCheckpoint()
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(
                store: AppMemoryConfigurationStore(
                    configuration: RdcAppConfiguration(lastLibrary: snapshot)
                )
            ),
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine(),
            resourceOperationCheckpoint: { await checkpoint.pause() }
        )
        await model.loadPersistedState()
        let lease = model.resourcePropertyCoordinator.register(
            host: .primaryWindow(id: UUID())
        )
        let firstID = try XCTUnwrap(ids.first)
        let secondID = try XCTUnwrap(ids.last)
        XCTAssertTrue(model.requestServerDeletion(id: firstID, ownerLease: lease))
        let firstRequest = try XCTUnwrap(model.pendingResourceDeletion)

        let firstConfirmation = Task {
            await model.confirmResourceDeletion(firstRequest)
        }
        await checkpoint.waitUntilPaused()
        XCTAssertTrue(model.requestServerDeletion(id: secondID, ownerLease: lease))
        let newerRequest = try XCTUnwrap(model.pendingResourceDeletion)
        await checkpoint.resume()

        let firstSucceeded = await firstConfirmation.value
        XCTAssertTrue(firstSucceeded)
        XCTAssertEqual(model.pendingResourceDeletion, newerRequest)
        XCTAssertFalse(model.library?.servers.contains { $0.id == firstID } ?? true)
        XCTAssertTrue(model.library?.servers.contains { $0.id == secondID } ?? false)
        await model.shutdownAndWait()
    }

    func testLibraryReplacementAfterConfirmationCannotRemoveNewLibrary() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "stale-library-original", sourceName: "temp2.rdg",
            document: testDocument()
        )
        let replacement = RdcLibrarySnapshot(
            sourceID: "stale-library-replacement", sourceName: "replacement.rdg",
            document: twoServerDocument()
        )
        let store = AppMemoryConfigurationStore(
            configuration: RdcAppConfiguration(lastLibrary: original)
        )
        let repository = RdcConfigurationRepository(store: store)
        let model = RdcAppModel(
            configurationRepository: repository,
            passwordStore: AppMemoryPasswordStore(), engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let lease = model.resourcePropertyCoordinator.register(host: .primaryWindow(id: UUID()))
        XCTAssertTrue(model.requestLibraryRemoval(ownerLease: lease))
        let request = try XCTUnwrap(model.pendingResourceDeletion)
        try await repository.update { $0.lastLibrary = replacement }

        let succeeded = await model.confirmResourceDeletion(request)
        let persisted = await store.current()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(persisted.lastLibrary, replacement)
        XCTAssertNil(model.pendingResourceDeletion)
        XCTAssertEqual(model.resourceOperationMessage,
                       ResourceLibraryOperationError.confirmationStale.safeMessage)
        await model.shutdownAndWait()
    }

    func testGroupDescendantAddedAfterConfirmationRequiresFreshConfirmation() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "stale-group", sourceName: "temp2.rdg", document: nestedDocument()
        )
        let groupID = try XCTUnwrap(original.root.groups.first?.id)
        let changed = try ResourceLibraryEditor.createChildGroup(
            in: original, parentID: groupID, name: "Late Child"
        )
        let store = AppMemoryConfigurationStore(
            configuration: RdcAppConfiguration(lastLibrary: original)
        )
        let repository = RdcConfigurationRepository(store: store)
        let model = RdcAppModel(
            configurationRepository: repository,
            passwordStore: AppMemoryPasswordStore(), engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let lease = model.resourcePropertyCoordinator.register(host: .primaryWindow(id: UUID()))
        XCTAssertTrue(model.requestGroupDeletion(id: groupID, ownerLease: lease))
        let request = try XCTUnwrap(model.pendingResourceDeletion)
        try await repository.update { $0.lastLibrary = changed }

        let succeeded = await model.confirmResourceDeletion(request)
        let persisted = await store.current()
        XCTAssertFalse(succeeded)
        XCTAssertEqual(persisted.lastLibrary, changed)
        XCTAssertNil(model.pendingResourceDeletion)
        await model.shutdownAndWait()
    }

    func testServerChangedAfterConfirmationRequiresFreshConfirmation() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "stale-server", sourceName: "temp2.rdg", document: testDocument()
        )
        let serverID = try XCTUnwrap(original.root.servers.first?.id)
        let changed = try ResourceLibraryEditor.updateServer(
            in: original, id: serverID,
            draft: .init(displayName: "Changed", host: "203.0.113.250", port: 3390)
        )
        let store = AppMemoryConfigurationStore(
            configuration: RdcAppConfiguration(lastLibrary: original)
        )
        let repository = RdcConfigurationRepository(store: store)
        let model = RdcAppModel(
            configurationRepository: repository,
            passwordStore: AppMemoryPasswordStore(), engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let lease = model.resourcePropertyCoordinator.register(host: .primaryWindow(id: UUID()))
        XCTAssertTrue(model.requestServerDeletion(id: serverID, ownerLease: lease))
        let request = try XCTUnwrap(model.pendingResourceDeletion)
        try await repository.update { $0.lastLibrary = changed }

        let succeeded = await model.confirmResourceDeletion(request)
        let persisted = await store.current()
        XCTAssertFalse(succeeded)
        XCTAssertEqual(persisted.lastLibrary, changed)
        XCTAssertNil(model.pendingResourceDeletion)
        await model.shutdownAndWait()
    }

    func testSupersededDurableEditReconcilesModelAndPersistedConfiguration() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "superseded-edit", sourceName: "temp2.rdg", document: twoServerDocument()
        )
        let store = AppControlledConfigurationStore(
            configuration: RdcAppConfiguration(lastLibrary: snapshot), suspendedSaveNumber: 1
        )
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let firstID = try XCTUnwrap(model.selectedServerID)
        let secondID = try XCTUnwrap(model.library?.servers.last?.id)

        let editTask = Task {
            try await model.updateServer(
                id: firstID,
                draft: .init(displayName: "Committed Edit", host: "203.0.113.80", port: 3390)
            )
        }
        await store.waitUntilSuspendedSaveStarts()
        model.selectServer(id: secondID)
        await store.resumeSuspendedSave()
        try await editTask.value
        await model.waitForPendingOperations()

        let persisted = await store.current()
        XCTAssertEqual(model.configuration, persisted)
        XCTAssertEqual(model.library, persisted.lastLibrary?.makeLibrary(selectedServerID: secondID))
        XCTAssertEqual(model.selectedServerID, secondID)
        XCTAssertEqual(
            persisted.lastLibrary?.root.servers.first { $0.id == firstID }?.displayName,
            "Committed Edit"
        )
        await model.shutdownAndWait()
    }

    func testSupersededDeleteRollbackFailureSurfacesPasswordStoreFailure() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "superseded-rollback", sourceName: "temp2.rdg", document: twoServerDocument()
        )
        let firstID = try XCTUnwrap(snapshot.root.servers.first?.id)
        let secondID = try XCTUnwrap(snapshot.root.servers.last?.id)
        let credentialID = "rollback-failure-credential"
        let initial = RdcAppConfiguration(
            serverCredentialBindings: [firstID: credentialID],
            credentialMetadata: [credentialID: .init(id: credentialID, username: "operator", domain: nil)],
            lastLibrary: snapshot
        )
        let store = AppControlledConfigurationStore(
            configuration: initial, failingSaveNumbers: [1], suspendedSaveNumber: 1
        )
        let passwordStore = AppMemoryPasswordStore(
            passwords: [credentialID: "rollback-password"],
            failingSaveIDs: [credentialID]
        )
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        let deleteTask = Task { () -> Error? in
            do {
                try await model.deleteServer(id: firstID)
                return nil
            } catch {
                return error
            }
        }
        await store.waitUntilSuspendedSaveStarts()
        model.selectServer(id: secondID)
        await store.resumeSuspendedSave()
        let error = await deleteTask.value
        await model.waitForPendingOperations()

        XCTAssertEqual(error as? ResourceLibraryOperationError, .passwordRollbackFailed)
        XCTAssertEqual(model.resourceOperationMessage,
                       ResourceLibraryOperationError.passwordRollbackFailed.safeMessage)
        XCTAssertEqual(model.configuration, initial)
        let persisted = await store.current()
        XCTAssertEqual(persisted, initial)
        await model.shutdownAndWait()
    }

    func testLegacyLoadPersistsMigrationAndSurvivesEditRestartAndReimport() async throws {
        var legacy = RdcLibrarySnapshot(
            sourceID: "legacy-durable", sourceName: "legacy.rdg",
            sourceLocatorAliases: ["path-hash:legacy"], document: testDocument()
        )
        legacy.root.id = nil
        legacy.root.sourceFingerprint = nil
        legacy.root.servers[0].id = nil
        legacy.root.servers[0].sourceFingerprint = nil
        let store = AppMemoryConfigurationStore(configuration: .init(lastLibrary: legacy))
        let first = RdcAppModel(
            configurationRepository: .init(store: store),
            passwordStore: AppMemoryPasswordStore(), engine: AppRecordingSessionEngine()
        )
        await first.loadPersistedState()
        let migratedConfiguration = await store.current()
        let stableID = try XCTUnwrap(
            migratedConfiguration.lastLibrary?.root.servers[0].id
        )
        try await first.updateServer(
            id: stableID,
            draft: .init(displayName: "本地改名", host: "2001:db8::20", port: 3_390)
        )
        await first.shutdownAndWait()

        let second = RdcAppModel(
            configurationRepository: .init(store: store),
            passwordStore: AppMemoryPasswordStore(), engine: AppRecordingSessionEngine()
        )
        await second.loadPersistedState()
        XCTAssertEqual(second.library?.servers.first?.id, stableID)
        XCTAssertEqual(second.library?.servers.first?.address.rawValue, "[2001:db8::20]:3390")
        await second.importLibrary(
            document: testDocument(), sourceName: "legacy.rdg",
            sourceLocatorAliases: ["path-hash:legacy"]
        )
        XCTAssertEqual(second.library?.servers.first?.id, stableID)
        XCTAssertEqual(second.library?.servers.first?.displayName, "本地改名")
        await second.shutdownAndWait()
    }

    func testLegacyMigrationSaveFailureKeepsDiskUntouchedButTreeEditableForRetry() async throws {
        var legacy = RdcLibrarySnapshot(
            sourceID: "legacy-failure", sourceName: "legacy.rdg", document: testDocument()
        )
        legacy.root.id = nil
        legacy.root.servers[0].id = nil
        let initial = RdcAppConfiguration(lastLibrary: legacy)
        let store = AppControlledConfigurationStore(
            configuration: initial, failingSaveNumbers: [1]
        )
        let model = RdcAppModel(
            configurationRepository: .init(store: store),
            passwordStore: AppMemoryPasswordStore(), engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let persistedBeforeRetry = await store.current()
        XCTAssertEqual(persistedBeforeRetry, initial)
        XCTAssertNotNil(model.library?.servers.first?.id)
        XCTAssertNotNil(model.importError)

        let serverID = try XCTUnwrap(model.library?.servers.first?.id)
        try await model.updateServer(
            id: serverID,
            draft: .init(displayName: "retry", host: "retry.example", port: 3_389)
        )
        let persistedAfterRetry = await store.current()
        XCTAssertEqual(persistedAfterRetry.lastLibrary?.root.servers[0].id, serverID)
        await model.shutdownAndWait()
    }

    func testLegacyMigrationSaveFailureStillAllowsConfirmedDeletionRetry() async throws {
        var legacy = RdcLibrarySnapshot(
            sourceID: "legacy-delete", sourceName: "legacy.rdg", document: testDocument()
        )
        legacy.root.id = nil
        legacy.root.servers[0].id = nil
        let store = AppControlledConfigurationStore(
            configuration: .init(lastLibrary: legacy), failingSaveNumbers: [1]
        )
        let model = RdcAppModel(
            configurationRepository: .init(store: store),
            passwordStore: AppMemoryPasswordStore(), engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let serverID = try XCTUnwrap(model.library?.servers.first?.id)
        let lease = model.resourcePropertyCoordinator.register(host: .primaryWindow(id: UUID()))
        XCTAssertTrue(model.requestServerDeletion(id: serverID, ownerLease: lease))
        let request = try XCTUnwrap(model.pendingResourceDeletion)

        let succeeded = await model.confirmResourceDeletion(request)
        let persisted = await store.current()
        XCTAssertTrue(succeeded)
        XCTAssertFalse(model.library?.servers.contains { $0.id == serverID } ?? true)
        XCTAssertNotNil(persisted.lastLibrary?.root.id)
        await model.shutdownAndWait()
    }

    func testPartialKeychainDeleteAndFailedRestoreSurfacesHighSeverityWithoutCommit() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "rollback-partial", sourceName: "a.rdg", document: twoServerDocument()
        )
        let ids = snapshot.root.servers.compactMap(\.id)
        let initial = RdcAppConfiguration(
            serverCredentialBindings: [ids[0]: "a", ids[1]: "b"],
            credentialMetadata: [
                "a": .init(id: "a", username: "a", domain: nil),
                "b": .init(id: "b", username: "b", domain: nil)
            ],
            lastLibrary: snapshot
        )
        let passwordStore = AppMemoryPasswordStore(
            passwords: ["a": "secret-a", "b": "secret-b"],
            failingDeleteIDs: ["b"], failingSaveIDs: ["a"]
        )
        let store = AppMemoryConfigurationStore(configuration: initial)
        let model = RdcAppModel(
            configurationRepository: .init(store: store), passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let error = await captureError { try await model.removeLibrary() }
        XCTAssertEqual(error as? ResourceLibraryOperationError, .passwordRollbackFailed)
        let persisted = await store.current()
        let passwordA = try await passwordStore.password(credentialID: "a")
        let passwordB = try await passwordStore.password(credentialID: "b")
        XCTAssertEqual(persisted, initial)
        XCTAssertNil(passwordA)
        XCTAssertEqual(passwordB, "secret-b")
        XCTAssertEqual(model.resourceOperationMessage,
                       ResourceLibraryOperationError.passwordRollbackFailed.safeMessage)
        await model.shutdownAndWait()
    }

    func testImportPartialKeychainRollbackFailureKeepsConfigurationAndWarns() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "import-rollback", sourceName: "a.rdg", document: twoServerDocument()
        )
        let ids = snapshot.root.servers.compactMap(\.id)
        let initial = RdcAppConfiguration(
            serverCredentialBindings: [ids[0]: "a", ids[1]: "b"],
            credentialMetadata: [
                "a": .init(id: "a", username: "a", domain: nil),
                "b": .init(id: "b", username: "b", domain: nil)
            ], lastLibrary: snapshot
        )
        let passwordStore = AppMemoryPasswordStore(
            passwords: ["a": "secret-a", "b": "secret-b"],
            failingDeleteIDs: ["b"], failingSaveIDs: ["a"]
        )
        let store = AppMemoryConfigurationStore(configuration: initial)
        let model = RdcAppModel(
            configurationRepository: .init(store: store), passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        await model.importLibrary(
            document: nestedDocument(), sourceName: "b.rdg", sourceIdentity: "file-id:b"
        )
        let persisted = await store.current()
        XCTAssertEqual(persisted, initial)
        XCTAssertEqual(model.importError,
                       ResourceLibraryOperationError.passwordRollbackFailed.safeMessage)
        let passwordA = try await passwordStore.password(credentialID: "a")
        let passwordB = try await passwordStore.password(credentialID: "b")
        XCTAssertNil(passwordA)
        XCTAssertEqual(passwordB, "secret-b")
        await model.shutdownAndWait()
    }

    func testCertificatePinsAreRemovedOnlyAfterFinalEndpointReferenceAndAcrossImport() async throws {
        var snapshot = RdcLibrarySnapshot(
            sourceID: "pins", sourceName: "pins.rdg", document: twoServerDocument()
        )
        snapshot.root.servers[1].address = snapshot.root.servers[0].address
        let endpoint = RdpEndpoint(host: "rdp.example.invalid", port: 3_389)
        let pin = CertificatePin(
            endpoint: endpoint, subject: "s", issuer: "i", sha256Fingerprint: "AA",
            notBefore: nil, notAfter: nil, firstTrustedAt: .distantPast,
            lastConfirmedAt: .distantPast
        )
        let model = makeModel(configuration: .init(
            certificatePins: [endpoint: pin], lastLibrary: snapshot
        ), engine: AppRecordingSessionEngine())
        await model.loadPersistedState()
        try await model.deleteServer(id: try XCTUnwrap(snapshot.root.servers[0].id))
        XCTAssertNotNil(model.configuration.certificatePins[endpoint])
        try await model.deleteServer(id: try XCTUnwrap(snapshot.root.servers[1].id))
        XCTAssertNil(model.configuration.certificatePins[endpoint])

        let imported = RdcLibrarySnapshot(
            sourceID: "pins-2", sourceName: "pins2.rdg", document: testDocument()
        )
        let importModel = makeModel(configuration: .init(
            certificatePins: [endpoint: pin], lastLibrary: imported
        ), engine: AppRecordingSessionEngine())
        await importModel.loadPersistedState()
        await importModel.importLibrary(
            document: nestedDocument(), sourceName: "different.rdg",
            sourceIdentity: "file-id:different"
        )
        XCTAssertNil(importModel.configuration.certificatePins[endpoint])
        await model.shutdownAndWait()
        await importModel.shutdownAndWait()
    }

    func testGroupAndRootRemovalClearTheirUnreferencedCertificatePins() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "pin-group", sourceName: "g.rdg", document: nestedDocument()
        )
        let endpoint = RdpEndpoint(host: "nested.example.invalid", port: 3_389)
        let pin = CertificatePin(
            endpoint: endpoint, subject: "s", issuer: "i", sha256Fingerprint: "AA",
            notBefore: nil, notAfter: nil, firstTrustedAt: .distantPast,
            lastConfirmedAt: .distantPast
        )
        let groupModel = makeModel(configuration: .init(
            certificatePins: [endpoint: pin], lastLibrary: snapshot
        ), engine: AppRecordingSessionEngine())
        await groupModel.loadPersistedState()
        try await groupModel.deleteGroup(id: try XCTUnwrap(snapshot.root.groups.first?.id))
        XCTAssertNil(groupModel.configuration.certificatePins[endpoint])
        await groupModel.shutdownAndWait()

        let rootModel = makeModel(configuration: .init(
            certificatePins: [endpoint: pin], lastLibrary: snapshot
        ), engine: AppRecordingSessionEngine())
        await rootModel.loadPersistedState()
        try await rootModel.removeLibrary()
        XCTAssertNil(rootModel.configuration.certificatePins[endpoint])
        await rootModel.shutdownAndWait()
    }

    func testExpansionPersistsAcrossRestartReimportAndSharedModelViews() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "expanded", sourceName: "a.rdg",
            sourceLocatorAliases: ["path-hash:expanded"], document: nestedDocument()
        )
        let groupID = try XCTUnwrap(snapshot.root.groups.first?.id)
        let store = AppMemoryConfigurationStore(configuration: .init(lastLibrary: snapshot))
        let first = RdcAppModel(
            configurationRepository: .init(store: store),
            passwordStore: AppMemoryPasswordStore(), engine: AppRecordingSessionEngine()
        )
        await first.loadPersistedState()
        await first.setGroupExpanded(id: groupID, isExpanded: false)
        XCTAssertFalse(first.persistedExpandedGroupIDs.contains(groupID))
        // Every window observes this same model-backed set rather than independent defaults.
        XCTAssertFalse(first.persistedExpandedGroupIDs.contains(groupID))
        await first.shutdownAndWait()

        let second = RdcAppModel(
            configurationRepository: .init(store: store),
            passwordStore: AppMemoryPasswordStore(), engine: AppRecordingSessionEngine()
        )
        await second.loadPersistedState()
        XCTAssertFalse(second.persistedExpandedGroupIDs.contains(groupID))
        await second.importLibrary(
            document: nestedDocument(), sourceName: "a.rdg",
            sourceLocatorAliases: ["path-hash:expanded"]
        )
        XCTAssertFalse(second.persistedExpandedGroupIDs.contains(groupID))
        await second.shutdownAndWait()
    }

    func testActiveToolbarServerDoesNotFollowNewSelectionUntilDescriptorEnds() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "toolbar-active", sourceName: "a.rdg", document: twoServerDocument()
        )
        let ids = snapshot.root.servers.compactMap(\.id)
        let credentialID = "toolbar-credential"
        let model = makeModel(
            configuration: .init(
                globalCredentialID: credentialID,
                credentialMetadata: [credentialID: .init(
                    id: credentialID, username: "operator", domain: nil
                )], lastLibrary: snapshot
            ),
            passwords: [credentialID: "secret"], engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        await model.connectSelectedServer()
        XCTAssertEqual(model.activeSessionServer?.id, ids[0])

        model.selectServer(id: ids[1])

        XCTAssertEqual(model.selectedServerID, ids[1])
        XCTAssertEqual(model.activeSessionServer?.id, ids[0])
        await model.shutdownAndWait()
    }

    func testDeletingPreviouslyActiveServerDuringSelectionRaceDisconnectsBeforeSave() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "active-selection-race", sourceName: "temp2.rdg", document: twoServerDocument()
        )
        let credentialID = "race-global-credential"
        let store = AppControlledConfigurationStore(
            configuration: RdcAppConfiguration(
                globalCredentialID: credentialID,
                credentialMetadata: [credentialID: .init(
                    id: credentialID, username: "operator", domain: nil
                )],
                lastLibrary: snapshot
            ),
            suspendedSaveNumber: 1
        )
        let engine = AppSuspendingDisconnectSessionEngine()
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: AppMemoryPasswordStore(passwords: [credentialID: "race-password"]),
            engine: engine
        )
        await model.loadPersistedState()
        let activeID = try XCTUnwrap(model.selectedServerID)
        let secondID = try XCTUnwrap(model.library?.servers.last?.id)
        await model.connectSelectedServer()

        let editTask = Task { () -> Error? in
            do {
                try await model.updateServer(
                    id: secondID,
                    draft: .init(displayName: "Queued Edit", host: "203.0.113.91", port: 3389)
                )
                return nil
            } catch {
                return error
            }
        }
        await store.waitUntilSuspendedSaveStarts()
        model.selectServer(id: secondID)
        let deleteTask = Task { try await model.deleteServer(id: activeID) }
        await store.resumeSuspendedSave()
        _ = await editTask.value
        try await waitUntilAsync {
            let didStart = await engine.didDisconnectStart()
            let saveCount = await store.savedCount()
            return didStart || saveCount >= 2
        }
        let savesBeforeDisconnect = await store.savedCount()
        let didDisconnectStart = await engine.didDisconnectStart()
        XCTAssertTrue(didDisconnectStart)
        XCTAssertEqual(savesBeforeDisconnect, 1)

        await engine.resumeDisconnect()
        try await deleteTask.value
        let disconnectCount = await engine.disconnectCount()
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertFalse(model.library?.servers.contains { $0.id == activeID } ?? true)
        let saveCount = await store.savedCount()
        XCTAssertEqual(saveCount, 2)
        await model.shutdownAndWait()
    }

    func testResourceAPINeverThrowsRawStoreErrorDetails() async throws {
        let sentinel = "sensitive-path-/Users/private/config.json"
        let snapshot = RdcLibrarySnapshot(
            sourceID: "safe-error", sourceName: "temp2.rdg", document: testDocument()
        )
        let store = AppDetailedFailingConfigurationStore(
            configuration: RdcAppConfiguration(lastLibrary: snapshot), detail: sentinel
        )
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let serverID = try XCTUnwrap(model.selectedServerID)

        let error = await captureError {
            try await model.updateServer(
                id: serverID,
                draft: .init(displayName: "Safe", host: "203.0.113.90", port: 3389)
            )
        }

        XCTAssertEqual(error as? ResourceLibraryOperationError, .configurationSaveFailed)
        XCTAssertFalse(String(describing: error).contains(sentinel))
        XCTAssertFalse(model.resourceOperationMessage?.contains(sentinel) ?? true)
        await model.shutdownAndWait()
    }

    func testRemoveWholeLibraryDirectlyCleansRootAndDescendantBindings() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "direct-remove", sourceName: "temp2.rdg", document: nestedDocument()
        )
        let rootID = try XCTUnwrap(snapshot.root.id)
        let groupID = try XCTUnwrap(snapshot.root.groups.first?.id)
        let serverID = try XCTUnwrap(snapshot.root.groups.first?.servers.first?.id)
        let model = makeModel(
            configuration: RdcAppConfiguration(
                groupCredentialBindings: [rootID: "root", groupID: "child"],
                serverCredentialBindings: [serverID: "server"],
                credentialMetadata: metadata(
                    ("root", "root-user"), ("child", "child-user"), ("server", "server-user")
                ),
                lastLibrary: snapshot
            ),
            passwords: ["root": "one", "child": "two", "server": "three"],
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        try await model.removeLibrary()

        XCTAssertNil(model.library)
        XCTAssertNil(model.configuration.lastLibrary)
        XCTAssertTrue(model.configuration.groupCredentialBindings.isEmpty)
        XCTAssertTrue(model.configuration.serverCredentialBindings.isEmpty)
        XCTAssertTrue(model.configuration.credentialMetadata.isEmpty)
        await model.shutdownAndWait()
    }

    func testResourceEditPreservesConcurrentPreferencesAndCertificatePin() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "concurrent-edit", sourceName: "temp2.rdg", document: testDocument()
        )
        let store = AppMemoryConfigurationStore(
            configuration: RdcAppConfiguration(lastLibrary: snapshot)
        )
        let repository = RdcConfigurationRepository(store: store)
        let checkpoint = AppResourceOperationCheckpoint()
        let model = RdcAppModel(
            configurationRepository: repository,
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine(),
            resourceOperationCheckpoint: { await checkpoint.pause() }
        )
        await model.loadPersistedState()
        let serverID = try XCTUnwrap(model.selectedServerID)
        let endpoint = RdpEndpoint(host: "pin.example.invalid", port: 3390)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pin = CertificatePin(
            endpoint: endpoint,
            subject: "CN=pin",
            issuer: "CN=test",
            sha256Fingerprint: String(repeating: "A", count: 64),
            notBefore: nil,
            notAfter: nil,
            firstTrustedAt: now,
            lastConfirmedAt: now
        )
        var preferences = RdcGeneralPreferences.default
        preferences.doubleClickConnects = false
        let concurrentPreferences = preferences

        let editTask = Task {
            try await model.updateServer(
                id: serverID,
                draft: .init(displayName: "Concurrent Edit", host: "203.0.113.92", port: 3390)
            )
        }
        await checkpoint.waitUntilPaused()
        try await repository.update { configuration in
            configuration.preferences = concurrentPreferences
            configuration.certificatePins[endpoint] = pin
        }
        await checkpoint.resume()
        try await editTask.value

        let persisted = await store.current()
        XCTAssertEqual(persisted.preferences, concurrentPreferences)
        XCTAssertEqual(persisted.certificatePins[endpoint], pin)
        XCTAssertEqual(persisted.lastLibrary?.root.servers.first?.displayName, "Concurrent Edit")
        XCTAssertEqual(model.configuration, persisted)
        await model.shutdownAndWait()
    }

    func testDeleteDoesNotRemoveCredentialThatGainsConcurrentReference() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "concurrent-reference", sourceName: "temp2.rdg", document: twoServerDocument()
        )
        let firstID = try XCTUnwrap(snapshot.root.servers.first?.id)
        let secondID = try XCTUnwrap(snapshot.root.servers.last?.id)
        let credentialID = "concurrently-shared-credential"
        let initial = RdcAppConfiguration(
            serverCredentialBindings: [firstID: credentialID],
            credentialMetadata: [credentialID: .init(id: credentialID, username: "operator", domain: nil)],
            lastLibrary: snapshot
        )
        let store = AppMemoryConfigurationStore(configuration: initial)
        let repository = RdcConfigurationRepository(store: store)
        let passwordStore = AppMemoryPasswordStore(passwords: [credentialID: "shared-password"])
        let checkpoint = AppResourceOperationCheckpoint()
        let model = RdcAppModel(
            configurationRepository: repository,
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine(),
            resourceOperationCheckpoint: { await checkpoint.pause() }
        )
        await model.loadPersistedState()

        let deleteTask = Task { try await model.deleteServer(id: firstID) }
        await checkpoint.waitUntilPaused()
        try await repository.update { configuration in
            configuration.serverCredentialBindings[secondID] = credentialID
        }
        await checkpoint.resume()
        try await deleteTask.value

        let persisted = await store.current()
        XCTAssertEqual(persisted.serverCredentialBindings[secondID], credentialID)
        XCTAssertNotNil(persisted.credentialMetadata[credentialID])
        let deletedIDs = await passwordStore.deletedCredentialIDs()
        XCTAssertEqual(deletedIDs, [])
        XCTAssertEqual(model.configuration, persisted)
        await model.shutdownAndWait()
    }

    func testEditedSnapshotSidebarKeepsPersistedSelectionAndCredentialScope() async throws {
        var snapshot = RdcLibrarySnapshot(
            sourceID: "editable-sidebar-source",
            sourceName: "temp2.rdg",
            document: nestedDocument()
        )
        let groupID = try XCTUnwrap(snapshot.root.groups.first?.id)
        let serverID = try XCTUnwrap(snapshot.root.groups.first?.servers.first?.id)
        snapshot.root.groups[0].name = "Renamed Team"
        snapshot.root.groups[0].servers[0].displayName = "Renamed Server"
        snapshot.root.groups[0].servers[0].address = "198.51.100.44:3391"

        let configuration = RdcAppConfiguration(
            groupCredentialBindings: [groupID: "team-credential"],
            lastLibrary: snapshot
        )
        let model = makeModel(
            configuration: configuration,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let sidebar = try XCTUnwrap(model.resourceLibrarySidebarState(
            expandedGroupIDs: Set(model.library?.groups.map(\.id) ?? []),
            searchText: ""
        ))
        let groupRow = try XCTUnwrap(sidebar.rows.first { $0.title == "Renamed Team" })
        let serverRow = try XCTUnwrap(sidebar.rows.first { $0.title == "Renamed Server" })

        XCTAssertEqual(groupRow.representedGroupID, groupID)
        XCTAssertEqual(serverRow.representedServerID, serverID)
        XCTAssertTrue(serverRow.isSelected)
        XCTAssertEqual(
            CredentialResolver.resolve(
                server: try XCTUnwrap(model.selectedServer),
                configuration: model.configuration
            ),
            CredentialResolution(
                credentialID: "team-credential",
                source: .group(groupID: groupID)
            )
        )
        model.selectServer(id: try XCTUnwrap(serverRow.representedServerID))
        XCTAssertEqual(model.selectedServerID, serverID)
        await model.waitForPendingOperations()
        await model.shutdownAndWait()
    }

    func testDisappearingOneOrAllRootWindowsDoesNotPermanentlyShutdownSharedModel() async throws {
        let store = AppMemoryConfigurationStore(configuration: .default)
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine()
        )

        model.handleLifecycleEvent(.rootWindowDisappeared)
        model.handleLifecycleEvent(.rootWindowDisappeared)
        var preferences = RdcGeneralPreferences.default
        preferences.doubleClickConnects = false
        try await model.updatePreferences(preferences)

        let persisted = await store.current()
        XCTAssertEqual(model.configuration.preferences, preferences)
        XCTAssertEqual(persisted.preferences, preferences)
        await model.shutdownAndWait()
    }

    func testSettingsOperationFailurePublishesSafeActionableFeedback() async {
        let store = AppControlledConfigurationStore(
            configuration: .default,
            failingSaveNumbers: [1]
        )
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine()
        )
        let secret = UUID().uuidString

        let succeeded = await model.performSettingsOperation(
            host: .settingsWindow,
            failureMessage: "无法保存通用设置，请检查磁盘权限后重试。"
        ) {
            try await model.updatePreferences(.default)
        }

        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.settingsOperationError, "无法保存通用设置，请检查磁盘权限后重试。")
        XCTAssertFalse(model.settingsOperationError?.contains(secret) ?? true)
        await model.shutdownAndWait()
    }

    func testNoBindingPromptsForOneTimeCredentialWithoutStartingConnection() async {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-no-binding",
            sourceName: "temp2.rdg",
            document: testDocument()
        )
        let engine = AppRecordingSessionEngine()
        let model = makeModel(
            configuration: RdcAppConfiguration(lastLibrary: snapshot),
            engine: engine
        )

        await model.loadPersistedState()
        model.connectionErrorPresentation = .remoteDisconnect
        await model.connectSelectedServer()

        XCTAssertTrue(model.isShowingCredentialSheet)
        XCTAssertNil(model.connectionErrorPresentation)
        let capture = await engine.capture()
        XCTAssertEqual(capture.connectionCount, 0)
        await model.shutdownAndWait()
    }

    func testMissingKeychainItemPromptsWithSafeActionableWarning() async {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-missing-keychain",
            sourceName: "temp2.rdg",
            document: testDocument()
        )
        let credentialID = "missing-keychain-item"
        let configuration = RdcAppConfiguration(
            globalCredentialID: credentialID,
            credentialMetadata: [
                credentialID: CredentialMetadata(
                    id: credentialID,
                    username: "Administrator",
                    domain: nil
                )
            ],
            lastLibrary: snapshot
        )
        let engine = AppRecordingSessionEngine()
        let model = makeModel(configuration: configuration, engine: engine)

        await model.loadPersistedState()
        await model.connectSelectedServer()

        XCTAssertTrue(model.isShowingCredentialSheet)
        XCTAssertEqual(model.connectionErrorPresentation, .keychain)
        XCTAssertFalse(model.connectionErrorMessage?.contains(credentialID) ?? true)
        let capture = await engine.capture()
        XCTAssertEqual(capture.connectionCount, 0)
        await model.shutdownAndWait()
    }

    func testServerAndNearestGroupBindingsOverrideInheritedScopes() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-precedence",
            sourceName: "temp2.rdg",
            document: nestedDocument()
        )
        let library = RdcImportedLibrary(
            document: snapshot.makeDocument(),
            sourceID: snapshot.sourceID,
            sourceName: snapshot.sourceName
        )
        let server = try XCTUnwrap(library.servers.first)
        let nearestGroup = try XCTUnwrap(server.groupPathIDs.last)
        var configuration = RdcAppConfiguration(
            globalCredentialID: "global-id",
            groupCredentialBindings: [nearestGroup: "group-id"],
            serverCredentialBindings: [server.id: "server-id"],
            credentialMetadata: metadata(
                ("global-id", "global-user"),
                ("group-id", "group-user"),
                ("server-id", "server-user")
            ),
            lastLibrary: snapshot
        )
        let passwords = Dictionary(
            uniqueKeysWithValues: configuration.credentialMetadata.keys.map {
                ($0, UUID().uuidString)
            }
        )
        let engine = AppRecordingSessionEngine()
        var model = makeModel(
            configuration: configuration,
            passwords: passwords,
            engine: engine
        )

        await model.loadPersistedState()
        await model.connectSelectedServer()
        let serverCapture = await engine.capture()
        XCTAssertEqual(serverCapture.username, "server-user")
        await model.shutdownAndWait()

        configuration.serverCredentialBindings = [:]
        let groupEngine = AppRecordingSessionEngine()
        model = makeModel(
            configuration: configuration,
            passwords: passwords,
            engine: groupEngine
        )
        await model.loadPersistedState()
        await model.connectSelectedServer()
        let groupCapture = await groupEngine.capture()
        XCTAssertEqual(groupCapture.username, "group-user")
        await model.shutdownAndWait()
    }

    func testImportReusesStableSourceAndPersistsSanitizedSnapshotPreservingBindings() async throws {
        let sourceID = "source-import-stable"
        let sourceName = "temp2.rdg"
        let originalDocument = testDocument()
        let originalSnapshot = RdcLibrarySnapshot(
            sourceID: sourceID,
            sourceName: sourceName,
            document: originalDocument
        )
        let originalLibrary = RdcImportedLibrary(
            document: originalDocument,
            sourceID: sourceID,
            sourceName: sourceName
        )
        let serverID = try XCTUnwrap(originalLibrary.servers.first?.id)
        var configuration = RdcAppConfiguration(lastLibrary: originalSnapshot)
        configuration.serverCredentialBindings[serverID] = "bound-id"
        let store = AppMemoryConfigurationStore(configuration: configuration)
        let repository = RdcConfigurationRepository(store: store)
        let model = RdcAppModel(
            configurationRepository: repository,
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine()
        )
        let importedDocument = documentWithSensitiveSourceCredential()

        await model.importLibrary(document: importedDocument, sourceName: sourceName)

        XCTAssertEqual(model.library?.sourceID, sourceID)
        XCTAssertEqual(model.library?.selectedServer?.id, serverID)
        let persisted = await store.current()
        XCTAssertEqual(persisted.lastLibrary?.sourceID, sourceID)
        XCTAssertNil(persisted.lastLibrary?.makeDocument().root.logonCredentials)
        XCTAssertEqual(persisted.serverCredentialBindings[serverID], "bound-id")
        await model.shutdownAndWait()
    }

    func testReimportPreservesLocalRenameCredentialBindingAndDeletedTombstone() async throws {
        let sourceID = "source-reimport-workflow"
        let original = reimportWorkflowDocument(includeNewServer: false)
        var snapshot = RdcLibrarySnapshot(
            sourceID: sourceID,
            sourceName: "temp2.rdg",
            sourceLocatorFingerprint: StableLibraryID.sourceLocatorFingerprint(
                for: "file:///Imported/temp2.rdg"
            ),
            document: original
        )
        snapshot.root.groups[0].isExpanded = false
        let keptID = try XCTUnwrap(snapshot.root.groups[0].servers[0].id)
        let deletedID = try XCTUnwrap(snapshot.root.groups[0].servers[1].id)
        let rootID = try XCTUnwrap(snapshot.root.id)
        let credentialID = "bound-reimport-credential"
        let store = AppMemoryConfigurationStore(configuration: RdcAppConfiguration(
            serverCredentialBindings: [keptID: credentialID],
            credentialMetadata: [credentialID: .init(
                id: credentialID, username: "Administrator", domain: nil
            )],
            lastLibrary: snapshot
        ))
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: AppMemoryPasswordStore(passwords: [credentialID: "test-secret"]),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        try await model.updateServer(
            id: keptID,
            draft: .init(displayName: "本地名称", host: "203.0.113.9", port: 3_390)
        )
        try await model.createChildGroup(parentID: rootID, name: "Mac 专用")
        let macGroupID = try XCTUnwrap(
            model.library?.groups.first(where: { $0.name == "Mac 专用" })?.id
        )
        try await model.moveServer(id: keptID, destinationGroupID: macGroupID)
        try await model.deleteServer(id: deletedID)

        await model.importLibrary(
            document: reimportWorkflowDocument(includeNewServer: true),
            sourceName: "temp2.rdg",
            sourceIdentity: "file:///Imported/temp2.rdg"
        )

        let reimported = try XCTUnwrap(model.library)
        let kept = try XCTUnwrap(reimported.servers.first(where: { $0.id == keptID }))
        XCTAssertEqual(kept.displayName, "本地名称")
        XCTAssertEqual(kept.address.rawValue, "203.0.113.9:3390")
        XCTAssertEqual(kept.groupPathIDs.last, macGroupID)
        XCTAssertTrue(reimported.groups.contains { $0.id == macGroupID && $0.name == "Mac 专用" })
        XCTAssertEqual(
            model.configuration.lastLibrary?.root.groups.first(where: { $0.name == "Imported" })?.isExpanded,
            false
        )
        XCTAssertFalse(reimported.servers.contains { $0.id == deletedID })
        XCTAssertTrue(reimported.servers.contains { $0.displayName == "Upstream New" })
        XCTAssertEqual(model.selectedServerID, keptID)

        let persisted = await store.current()
        XCTAssertEqual(persisted.serverCredentialBindings[keptID], credentialID)
        XCTAssertFalse(persisted.lastLibrary?.deletedSourceItems.isEmpty ?? true)
        await model.shutdownAndWait()
    }

    func testReimportRestoresDeletedItemsOnlyWhenExplicitlyRequested() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "source-restore-reimport",
            sourceName: "temp2.rdg",
            document: reimportWorkflowDocument(includeNewServer: false)
        )
        let deletedID = try XCTUnwrap(original.root.groups[0].servers[1].id)
        let model = makeModel(
            configuration: RdcAppConfiguration(lastLibrary: original),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        try await model.deleteServer(id: deletedID)

        await model.importLibrary(
            document: reimportWorkflowDocument(includeNewServer: false),
            sourceName: "temp2.rdg"
        )
        XCTAssertFalse(model.library?.servers.contains { $0.id == deletedID } ?? true)
        XCTAssertEqual(model.deletedImportRestoreCount, 1)

        await model.restoreDeletedItemsFromLastImport()
        XCTAssertTrue(model.library?.servers.contains { $0.id == deletedID } ?? false)
        XCTAssertTrue(model.configuration.lastLibrary?.deletedSourceItems.isEmpty ?? false)
        XCTAssertNil(model.deletedImportRestoreCount)
        await model.shutdownAndWait()
    }

    func testRestoreOfferCannotOverwriteLibraryEditedAfterOfferWasCommitted() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "stale-restore-source", sourceName: "temp2.rdg",
            document: reimportWorkflowDocument(includeNewServer: false)
        )
        let keptID = try XCTUnwrap(original.root.groups[0].servers[0].id)
        let deletedID = try XCTUnwrap(original.root.groups[0].servers[1].id)
        let model = makeModel(
            configuration: RdcAppConfiguration(lastLibrary: original),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        try await model.deleteServer(id: deletedID)
        await model.importLibrary(
            document: reimportWorkflowDocument(includeNewServer: false),
            sourceName: "temp2.rdg"
        )
        XCTAssertEqual(model.deletedImportRestoreCount, 1)
        try await model.updateServer(
            id: keptID,
            draft: .init(displayName: "Offer 后编辑", host: "203.0.113.44", port: 3_389)
        )

        await model.restoreDeletedItemsFromLastImport()

        XCTAssertEqual(
            model.library?.servers.first(where: { $0.id == keptID })?.displayName,
            "Offer 后编辑"
        )
        XCTAssertFalse(model.library?.servers.contains { $0.id == deletedID } ?? true)
        XCTAssertNil(model.deletedImportRestoreCount)
        XCTAssertNotNil(model.importError)
        await model.shutdownAndWait()
    }

    func testNewReimportReplacesRestoreOfferWithExactLatestDocument() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "latest-offer-source", sourceName: "temp2.rdg",
            sourceLocatorFingerprint: StableLibraryID.sourceLocatorFingerprint(
                for: "file-id:latest-offer"
            ),
            document: reimportWorkflowDocument(includeNewServer: false)
        )
        let deletedID = try XCTUnwrap(original.root.groups[0].servers[1].id)
        let model = makeModel(
            configuration: RdcAppConfiguration(lastLibrary: original),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        try await model.deleteServer(id: deletedID)
        await model.importLibrary(
            document: reimportWorkflowDocument(includeNewServer: false),
            sourceName: "temp2.rdg",
            sourceIdentity: "file-id:latest-offer"
        )
        await model.importLibrary(
            document: reimportWorkflowDocument(includeNewServer: true),
            sourceName: "temp2.rdg",
            sourceIdentity: "file-id:latest-offer"
        )

        await model.restoreDeletedItemsFromLastImport()

        XCTAssertTrue(model.library?.servers.contains { $0.id == deletedID } ?? false)
        XCTAssertTrue(model.library?.servers.contains { $0.displayName == "Upstream New" } ?? false)
        await model.shutdownAndWait()
    }

    func testImportFromDifferentSourceReplacesInsteadOfMergingLocalResources() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "source-a", sourceName: "temp2.rdg",
            sourceLocatorFingerprint: StableLibraryID.sourceLocatorFingerprint(
                for: "file:///Library-A/temp2.rdg"
            ),
            document: reimportWorkflowDocument(includeNewServer: false)
        )
        let model = makeModel(
            configuration: RdcAppConfiguration(lastLibrary: original),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let rootID = try XCTUnwrap(original.root.id)
        try await model.createChildGroup(parentID: rootID, name: "Mac 专用")

        await model.importLibrary(
            document: testDocument(),
            sourceName: "temp2.rdg",
            sourceIdentity: "file:///Library-B/temp2.rdg"
        )

        XCTAssertNotEqual(model.library?.sourceID, original.sourceID)
        XCTAssertEqual(model.library?.sourceName, "temp2.rdg")
        XCTAssertFalse(model.library?.groups.contains { $0.name == "Mac 专用" } ?? true)
        XCTAssertEqual(model.library?.servers.map(\.displayName), ["Server"])
        await model.shutdownAndWait()
    }

    func testLegacySameNameWithoutIdentityDoesNotMergeDifferentContentWithSameRoot() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "legacy-source", sourceName: "temp2.rdg",
            document: reimportWorkflowDocument(includeNewServer: false)
        )
        let rootID = try XCTUnwrap(original.root.id)
        let model = makeModel(
            configuration: RdcAppConfiguration(lastLibrary: original),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        try await model.createChildGroup(parentID: rootID, name: "Local Only")

        await model.importLibrary(document: testDocument(), sourceName: "temp2.rdg")

        XCTAssertNotEqual(model.library?.sourceID, original.sourceID)
        XCTAssertFalse(model.library?.groups.contains { $0.name == "Local Only" } ?? true)
        XCTAssertEqual(model.library?.servers.map(\.displayName), ["Server"])
        await model.shutdownAndWait()
    }

    func testPersistedIdentityNeverFallsBackToSameNameWhenIncomingIdentityIsMissing() async {
        let original = RdcLibrarySnapshot(
            sourceID: "identified-source", sourceName: "temp2.rdg",
            sourceLocatorFingerprint: StableLibraryID.sourceLocatorFingerprint(for: "file-id:a"),
            document: testDocument()
        )
        let model = makeModel(
            configuration: RdcAppConfiguration(lastLibrary: original),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        await model.importLibrary(document: testDocument(), sourceName: "temp2.rdg")

        XCTAssertNotEqual(model.library?.sourceID, original.sourceID)
        XCTAssertNil(model.configuration.lastLibrary?.sourceLocatorFingerprint)
        await model.shutdownAndWait()
    }

    func testFileSourceIdentitySurvivesMoveAndSymlinkAlias() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("temp2.rdg")
        try Data("fixture".utf8).write(to: original)
        let originalIdentity = RdcAppModel.sourceIdentity(for: original)

        let moved = directory.appendingPathComponent("renamed.rdg")
        try FileManager.default.moveItem(at: original, to: moved)
        XCTAssertEqual(RdcAppModel.sourceIdentity(for: moved), originalIdentity)

        let alias = directory.appendingPathComponent("alias.rdg")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: moved)
        XCTAssertEqual(RdcAppModel.sourceIdentity(for: alias), originalIdentity)
        XCTAssertTrue(originalIdentity.hasPrefix("file-id:"))
    }

    func testSourceLocatorAliasesHandleAtomicReplacementMoveAndSameNameIsolation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("temp2.rdg")
        try Data("one".utf8).write(to: original)
        let originalAliases = RdcAppModel.sourceLocatorAliases(for: original)

        try FileManager.default.removeItem(at: original)
        try Data("replacement".utf8).write(to: original)
        let replacementAliases = RdcAppModel.sourceLocatorAliases(for: original)
        XCTAssertFalse(originalAliases.isDisjoint(with: replacementAliases))

        let moved = directory.appendingPathComponent("renamed.rdg")
        try FileManager.default.moveItem(at: original, to: moved)
        XCTAssertFalse(replacementAliases.isDisjoint(
            with: RdcAppModel.sourceLocatorAliases(for: moved)
        ))

        let otherDirectory = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        let sameNameElsewhere = otherDirectory.appendingPathComponent("temp2.rdg")
        try Data("other".utf8).write(to: sameNameElsewhere)
        XCTAssertTrue(originalAliases.isDisjoint(
            with: RdcAppModel.sourceLocatorAliases(for: sameNameElsewhere)
        ))
    }

    func testFingerprintOnlyLegacySourceMismatchStopsBeforeDestructiveReplacement() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "legacy-fingerprint-only", sourceName: "temp2.rdg",
            sourceLocatorFingerprint: StableLibraryID.sourceLocatorFingerprint(for: "file-id:old"),
            document: testDocument()
        )
        let model = makeModel(
            configuration: .init(lastLibrary: snapshot), engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        await model.importLibrary(
            document: nestedDocument(), sourceName: "temp2.rdg",
            sourceIdentity: "file-id:replacement",
            sourceLocatorAliases: ["path-hash:same-path-but-not-previously-persisted"]
        )

        XCTAssertEqual(model.library?.sourceID, snapshot.sourceID)
        XCTAssertEqual(
            model.importError,
            ResourceLibraryOperationError.sourceIdentityMigrationRequired.safeMessage
        )
        await model.shutdownAndWait()
    }

    func testSourceIdentityComponentsUseOnlyDeterministicSupportedEncodings() {
        let fileIdentifier = Data([0x00, 0x7f, 0xff])
        let volumeIdentifier = UUID(uuidString: "A9C5799E-4478-45C4-908A-4B5CB0B49340")!

        let first = RdcAppModel.sourceIdentity(
            fileIdentifier: fileIdentifier,
            volumeIdentifier: volumeIdentifier,
            fallbackPath: "/private/tmp/should-not-be-persisted.rdg"
        )
        let second = RdcAppModel.sourceIdentity(
            fileIdentifier: fileIdentifier,
            volumeIdentifier: volumeIdentifier,
            fallbackPath: "/private/tmp/should-not-be-persisted.rdg"
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("file-id:"))
        XCTAssertFalse(first.contains("should-not-be-persisted"))
    }

    func testUnknownOpaqueSourceIdentityComponentFallsBackToHashedPath() {
        let rawPath = "/private/tmp/opaque-source.rdg"
        let identity = RdcAppModel.sourceIdentity(
            fileIdentifier: AppOpaqueResourceIdentifier(),
            volumeIdentifier: NSNumber(value: 42),
            fallbackPath: rawPath
        )

        XCTAssertTrue(identity.hasPrefix("path-fallback:"))
        XCTAssertFalse(identity.contains(rawPath))
        XCTAssertFalse(identity.hasPrefix("file-id:"))
    }

    func testCrossSourceImportCleansOrphanBindingMetadataAndKeychainPassword() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "cleanup-source", sourceName: "first.rdg", document: testDocument()
        )
        let serverID = try XCTUnwrap(original.allServers.first?.id)
        let credentialID = "orphan-import-credential"
        let initial = RdcAppConfiguration(
            serverCredentialBindings: [serverID: credentialID],
            credentialMetadata: [credentialID: .init(
                id: credentialID, username: "operator", domain: nil
            )],
            lastLibrary: original
        )
        let store = AppMemoryConfigurationStore(configuration: initial)
        let passwordStore = AppMemoryPasswordStore(passwords: [credentialID: "synthetic"])
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        await model.importLibrary(document: nestedDocument(), sourceName: "second.rdg")

        let persisted = await store.current()
        let passwordFingerprint = await passwordStore.passwordFingerprint(
            credentialID: credentialID
        )
        XCTAssertNil(persisted.serverCredentialBindings[serverID])
        XCTAssertNil(persisted.credentialMetadata[credentialID])
        XCTAssertNil(passwordFingerprint)
        await model.shutdownAndWait()
    }

    func testCrossSourceImportKeepsCredentialSharedByGlobalScope() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "shared-cleanup-source", sourceName: "first.rdg", document: testDocument()
        )
        let serverID = try XCTUnwrap(original.allServers.first?.id)
        let credentialID = "shared-import-credential"
        let initial = RdcAppConfiguration(
            globalCredentialID: credentialID,
            serverCredentialBindings: [serverID: credentialID],
            credentialMetadata: [credentialID: .init(
                id: credentialID, username: "operator", domain: nil
            )],
            lastLibrary: original
        )
        let store = AppMemoryConfigurationStore(configuration: initial)
        let passwordStore = AppMemoryPasswordStore(passwords: [credentialID: "synthetic"])
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        await model.importLibrary(document: nestedDocument(), sourceName: "second.rdg")

        let persisted = await store.current()
        let passwordFingerprint = await passwordStore.passwordFingerprint(
            credentialID: credentialID
        )
        XCTAssertNil(persisted.serverCredentialBindings[serverID])
        XCTAssertEqual(persisted.globalCredentialID, credentialID)
        XCTAssertNotNil(persisted.credentialMetadata[credentialID])
        XCTAssertNotNil(passwordFingerprint)
        await model.shutdownAndWait()
    }

    func testSameSourceUpstreamRemovalCleansBindingAgainstFinalMergedIDs() async throws {
        let identity = "file-id:upstream-removal"
        let original = RdcLibrarySnapshot(
            sourceID: "upstream-removal-source", sourceName: "temp2.rdg",
            sourceLocatorFingerprint: StableLibraryID.sourceLocatorFingerprint(for: identity),
            document: reimportWorkflowDocument(includeNewServer: false)
        )
        let removedID = try XCTUnwrap(original.root.groups[0].servers[1].id)
        let credentialID = "upstream-removed-credential"
        let store = AppMemoryConfigurationStore(configuration: RdcAppConfiguration(
            serverCredentialBindings: [removedID: credentialID],
            credentialMetadata: [credentialID: .init(
                id: credentialID, username: "operator", domain: nil
            )],
            lastLibrary: original
        ))
        let passwordStore = AppMemoryPasswordStore(passwords: [credentialID: "synthetic"])
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        await model.importLibrary(
            document: testDocument(), sourceName: "temp2.rdg", sourceIdentity: identity
        )

        let persisted = await store.current()
        let passwordFingerprint = await passwordStore.passwordFingerprint(
            credentialID: credentialID
        )
        XCTAssertNil(persisted.serverCredentialBindings[removedID])
        XCTAssertNil(persisted.credentialMetadata[credentialID])
        XCTAssertNil(passwordFingerprint)
        await model.shutdownAndWait()
    }

    func testImportKeychainCleanupFailureLeavesConfigurationAndPasswordUntouched() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "keychain-fail-import", sourceName: "first.rdg", document: testDocument()
        )
        let serverID = try XCTUnwrap(original.allServers.first?.id)
        let credentialID = "failing-import-credential"
        let initial = RdcAppConfiguration(
            serverCredentialBindings: [serverID: credentialID],
            credentialMetadata: [credentialID: .init(
                id: credentialID, username: "operator", domain: nil
            )],
            lastLibrary: original
        )
        let store = AppMemoryConfigurationStore(configuration: initial)
        let passwordStore = AppMemoryPasswordStore(
            passwords: [credentialID: "synthetic"], failingDeleteIDs: [credentialID]
        )
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        await model.importLibrary(document: nestedDocument(), sourceName: "second.rdg")

        let persisted = await store.current()
        let passwordFingerprint = await passwordStore.passwordFingerprint(
            credentialID: credentialID
        )
        XCTAssertEqual(persisted, initial)
        XCTAssertEqual(model.configuration, initial)
        XCTAssertNotNil(passwordFingerprint)
        XCTAssertNotNil(model.importError)
        await model.shutdownAndWait()
    }

    func testImportSaveFailureRestoresDeletedPasswordAndKeepsOriginalConfiguration() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "save-fail-import", sourceName: "first.rdg", document: testDocument()
        )
        let serverID = try XCTUnwrap(original.allServers.first?.id)
        let credentialID = "rollback-import-credential"
        let initial = RdcAppConfiguration(
            serverCredentialBindings: [serverID: credentialID],
            credentialMetadata: [credentialID: .init(
                id: credentialID, username: "operator", domain: nil
            )],
            lastLibrary: original
        )
        let store = AppControlledConfigurationStore(
            configuration: initial, failingSaveNumbers: [1]
        )
        let passwordStore = AppMemoryPasswordStore(passwords: [credentialID: "synthetic"])
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        await model.importLibrary(document: nestedDocument(), sourceName: "second.rdg")

        let persisted = await store.current()
        let passwordFingerprint = await passwordStore.passwordFingerprint(
            credentialID: credentialID
        )
        XCTAssertEqual(persisted, initial)
        XCTAssertEqual(model.configuration, initial)
        XCTAssertNotNil(passwordFingerprint)
        XCTAssertNotNil(model.importError)
        await model.shutdownAndWait()
    }

    func testReimportCommitsAgainstLatestConfigurationWithoutOverwritingConcurrentDelta() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "source-concurrent-import", sourceName: "temp2.rdg",
            document: reimportWorkflowDocument(includeNewServer: false)
        )
        let store = AppMemoryConfigurationStore(
            configuration: RdcAppConfiguration(lastLibrary: original)
        )
        let repository = RdcConfigurationRepository(store: store)
        let checkpoint = AppResourceOperationCheckpoint()
        let model = RdcAppModel(
            configurationRepository: repository,
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine(),
            resourceOperationCheckpoint: { await checkpoint.pause() }
        )
        await model.loadPersistedState()

        let importTask = Task { @MainActor in
            await model.importLibrary(
                document: reimportWorkflowDocument(includeNewServer: true),
                sourceName: "temp2.rdg"
            )
        }
        await checkpoint.waitUntilPaused()
        let concurrentPreferences = RdcGeneralPreferences(
            restoresLastLibrary: false,
            doubleClickConnects: false,
            resizesRemoteDesktopWithWindow: false
        )
        try await repository.update { configuration in
            configuration.preferences = concurrentPreferences
        }
        await checkpoint.resume()
        await importTask.value

        let persisted = await store.current()
        XCTAssertEqual(persisted.preferences, concurrentPreferences)
        XCTAssertTrue(persisted.lastLibrary?.allServers.contains {
            $0.displayName == "Upstream New"
        } ?? false)
        XCTAssertEqual(model.configuration, persisted)
        await model.shutdownAndWait()
    }

    func testCommittedImportReconcilesModelAfterSupersedingSelection() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "durable-import-source", sourceName: "temp2.rdg",
            sourceLocatorFingerprint: StableLibraryID.sourceLocatorFingerprint(
                for: "file-id:durable-import-source"
            ),
            document: reimportWorkflowDocument(includeNewServer: false)
        )
        let store = AppControlledConfigurationStore(
            configuration: RdcAppConfiguration(lastLibrary: original),
            suspendedSaveNumber: 1
        )
        let repository = RdcConfigurationRepository(store: store)
        let model = RdcAppModel(
            configurationRepository: repository,
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let secondServerID = try XCTUnwrap(model.library?.servers.last?.id)

        let importTask = Task { @MainActor in
            await model.importLibrary(
                document: reimportWorkflowDocument(includeNewServer: true),
                sourceName: "temp2.rdg",
                sourceIdentity: "file-id:durable-import-source"
            )
        }
        await store.waitUntilSuspendedSaveStarts()
        model.selectServer(id: secondServerID)
        await store.resumeSuspendedSave()
        await importTask.value
        await model.waitForPendingOperations()

        let persisted = await store.current()
        XCTAssertEqual(model.configuration, persisted)
        XCTAssertEqual(model.library?.sourceID, persisted.lastLibrary?.sourceID)
        XCTAssertEqual(
            Set(model.library?.servers.map(\.id) ?? []),
            Set(persisted.lastLibrary?.allServers.compactMap(\.id) ?? [])
        )
        XCTAssertEqual(model.selectedServerID, secondServerID)
        XCTAssertEqual(model.selectedServer?.id, secondServerID)
        await model.shutdownAndWait()
    }

    func testCrossSourceCommittedImportNeverPublishesMissingSelection() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "selection-source-a", sourceName: "first.rdg",
            sourceLocatorFingerprint: StableLibraryID.sourceLocatorFingerprint(
                for: "file-id:selection-source-a"
            ),
            document: reimportWorkflowDocument(includeNewServer: false)
        )
        let store = AppControlledConfigurationStore(
            configuration: RdcAppConfiguration(lastLibrary: original),
            suspendedSaveNumber: 1
        )
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let oldSelection = try XCTUnwrap(model.library?.servers.last?.id)

        let importTask = Task { @MainActor in
            await model.importLibrary(
                document: testDocument(),
                sourceName: "second.rdg",
                sourceIdentity: "file-id:selection-source-b"
            )
        }
        await store.waitUntilSuspendedSaveStarts()
        model.selectServer(id: oldSelection)
        await store.resumeSuspendedSave()
        await importTask.value
        await model.waitForPendingOperations()

        XCTAssertNotEqual(model.selectedServerID, oldSelection)
        XCTAssertEqual(model.selectedServerID, model.selectedServer?.id)
        XCTAssertTrue(model.library?.servers.contains {
            $0.id == model.selectedServerID
        } ?? false)
        await model.shutdownAndWait()
    }

    func testCommittedTombstoneImportPublishesRestoreOfferAfterSelectionSupersedes() async throws {
        let original = RdcLibrarySnapshot(
            sourceID: "durable-offer-source", sourceName: "temp2.rdg",
            sourceLocatorFingerprint: StableLibraryID.sourceLocatorFingerprint(
                for: "file-id:durable-offer-source"
            ),
            document: reimportWorkflowDocument(includeNewServer: false)
        )
        let store = AppControlledConfigurationStore(
            configuration: RdcAppConfiguration(lastLibrary: original),
            suspendedSaveNumber: 2
        )
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: AppMemoryPasswordStore(),
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        let keptID = try XCTUnwrap(model.library?.servers.first?.id)
        let deletedID = try XCTUnwrap(model.library?.servers.last?.id)
        try await model.deleteServer(id: deletedID)

        let importTask = Task { @MainActor in
            await model.importLibrary(
                document: reimportWorkflowDocument(includeNewServer: false),
                sourceName: "temp2.rdg",
                sourceIdentity: "file-id:durable-offer-source"
            )
        }
        await store.waitUntilSuspendedSaveStarts()
        model.selectServer(id: keptID)
        await store.resumeSuspendedSave()
        await importTask.value
        await model.waitForPendingOperations()

        XCTAssertEqual(model.deletedImportRestoreCount, 1)
        XCTAssertFalse(model.library?.servers.contains { $0.id == deletedID } ?? true)
        XCTAssertEqual(model.selectedServerID, model.selectedServer?.id)

        await model.restoreDeletedItemsFromLastImport()

        XCTAssertTrue(model.library?.servers.contains { $0.id == deletedID } ?? false)
        XCTAssertNil(model.deletedImportRestoreCount)
        await model.shutdownAndWait()
    }

    func testCredentialScopesPersistBindingsAndRestoreInheritanceRemovesOnlyBinding() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-editor",
            sourceName: "temp2.rdg",
            document: nestedDocument()
        )
        let library = RdcImportedLibrary(
            document: snapshot.makeDocument(),
            sourceID: snapshot.sourceID,
            sourceName: snapshot.sourceName
        )
        let server = try XCTUnwrap(library.servers.first)
        let groupID = try XCTUnwrap(server.groupPathIDs.last)
        let store = AppMemoryConfigurationStore(
            configuration: RdcAppConfiguration(lastLibrary: snapshot)
        )
        let repository = RdcConfigurationRepository(store: store)
        let passwordStore = AppMemoryPasswordStore()
        let model = RdcAppModel(
            configurationRepository: repository,
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        var transientSecret = UUID().uuidString

        try await model.saveCredential(
            scope: .global,
            username: "global-user",
            domain: nil,
            password: transientSecret
        )
        try await model.saveCredential(
            scope: .group(id: groupID, displayName: "Team"),
            username: "group-user",
            domain: "LAB",
            password: transientSecret
        )
        try await model.saveCredential(
            scope: .server(id: server.id, displayName: server.displayName),
            username: "server-user",
            domain: nil,
            password: transientSecret
        )
        transientSecret.removeAll(keepingCapacity: false)

        let beforeRestore = await store.current()
        let serverCredentialID = try XCTUnwrap(beforeRestore.serverCredentialBindings[server.id])
        XCTAssertNotNil(beforeRestore.globalCredentialID)
        XCTAssertNotNil(beforeRestore.groupCredentialBindings[groupID])
        XCTAssertEqual(beforeRestore.credentialMetadata[serverCredentialID]?.username, "server-user")
        let savedCredentialIDs = await passwordStore.savedCredentialIDs()
        XCTAssertEqual(savedCredentialIDs.count, 3)

        try await model.restoreCredentialInheritance(
            scope: .server(id: server.id, displayName: server.displayName)
        )

        let restored = await store.current()
        XCTAssertNil(restored.serverCredentialBindings[server.id])
        XCTAssertNotNil(restored.globalCredentialID)
        XCTAssertNotNil(restored.groupCredentialBindings[groupID])
        XCTAssertNotNil(restored.credentialMetadata[serverCredentialID])
        await model.shutdownAndWait()
    }

    func testNewPersistentCredentialRollsBackPasswordMetadataAndBindingWhenBindingSaveFails() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-new-rollback",
            sourceName: "temp2.rdg",
            document: testDocument()
        )
        let initial = RdcAppConfiguration(lastLibrary: snapshot)
        let store = AppControlledConfigurationStore(
            configuration: initial,
            failingSaveNumbers: [2]
        )
        let passwordStore = AppMemoryPasswordStore()
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        var transientSecret = UUID().uuidString

        do {
            try await model.saveCredential(
                scope: .global,
                username: "new-user",
                domain: nil,
                password: transientSecret
            )
            XCTFail("Expected the binding save to fail")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .configurationSaveFailed)
        }
        transientSecret.removeAll(keepingCapacity: false)

        let persisted = await store.current()
        let credentialIDs = await passwordStore.allCredentialIDs()
        XCTAssertEqual(persisted, initial)
        XCTAssertTrue(credentialIDs.isEmpty)
        await model.shutdownAndWait()
    }

    func testExistingPersistentCredentialRollsBackPriorMaterialWhenBindingSaveFails() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-existing-rollback",
            sourceName: "temp2.rdg",
            document: testDocument()
        )
        let credentialID = "existing-credential"
        let oldMetadata = CredentialMetadata(
            id: credentialID,
            username: "old-user",
            domain: "OLD"
        )
        let initial = RdcAppConfiguration(
            globalCredentialID: credentialID,
            credentialMetadata: [credentialID: oldMetadata],
            lastLibrary: snapshot
        )
        let store = AppControlledConfigurationStore(
            configuration: initial,
            failingSaveNumbers: [2]
        )
        var oldSecret = UUID().uuidString
        var newSecret = UUID().uuidString
        let passwordStore = AppMemoryPasswordStore(passwords: [credentialID: oldSecret])
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )

        do {
            try await model.saveCredential(
                scope: .global,
                username: "new-user",
                domain: "NEW",
                password: newSecret
            )
            XCTFail("Expected the binding save to fail")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .configurationSaveFailed)
        }

        let persisted = await store.current()
        let passwordFingerprint = await passwordStore.passwordFingerprint(
            credentialID: credentialID
        )
        XCTAssertEqual(persisted, initial)
        XCTAssertEqual(passwordFingerprint, oldSecret.hashValue)
        oldSecret.removeAll(keepingCapacity: false)
        newSecret.removeAll(keepingCapacity: false)
        await model.shutdownAndWait()
    }

    func testDeleteSharedGlobalCredentialOnlyUnbindsGlobalAndKeepsOverridesMetadataAndSecret() async throws {
        let credentialID = "shared-global"
        let secret = UUID().uuidString
        let initial = RdcAppConfiguration(
            globalCredentialID: credentialID,
            groupCredentialBindings: ["group-a": credentialID, "group-b": "other"],
            serverCredentialBindings: ["server-a": credentialID, "server-b": "other"],
            credentialMetadata: [
                credentialID: CredentialMetadata(id: credentialID, username: "global", domain: nil),
                "other": CredentialMetadata(id: "other", username: "other", domain: nil)
            ]
        )
        let store = AppMemoryConfigurationStore(configuration: initial)
        let passwordStore = AppMemoryPasswordStore(passwords: [credentialID: secret, "other": "other-secret"])
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        try await model.deleteGlobalCredential()

        let current = await store.current()
        XCTAssertNil(current.globalCredentialID)
        XCTAssertEqual(current.groupCredentialBindings["group-a"], credentialID)
        XCTAssertEqual(current.serverCredentialBindings["server-a"], credentialID)
        XCTAssertEqual(current.groupCredentialBindings["group-b"], "other")
        XCTAssertNotNil(current.credentialMetadata[credentialID])
        let deletedPassword = await passwordStore.passwordFingerprint(credentialID: credentialID)
        let deletedIDs = await passwordStore.deletedCredentialIDs()
        XCTAssertEqual(deletedPassword, secret.hashValue)
        XCTAssertEqual(deletedIDs, [])
        await model.shutdownAndWait()
    }

    func testDeleteUnreferencedGlobalCredentialRemovesMetadataAndSecret() async throws {
        let credentialID = "global-only"
        let initial = RdcAppConfiguration(
            globalCredentialID: credentialID,
            credentialMetadata: [credentialID: CredentialMetadata(id: credentialID, username: "global", domain: nil)]
        )
        let store = AppMemoryConfigurationStore(configuration: initial)
        let passwordStore = AppMemoryPasswordStore(passwords: [credentialID: "secret"])
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        try await model.deleteGlobalCredential()

        let current = await store.current()
        let passwordFingerprint = await passwordStore.passwordFingerprint(credentialID: credentialID)
        let deletedIDs = await passwordStore.deletedCredentialIDs()
        XCTAssertNil(current.globalCredentialID)
        XCTAssertNil(current.credentialMetadata[credentialID])
        XCTAssertNil(passwordFingerprint)
        XCTAssertEqual(deletedIDs, [credentialID])
        await model.shutdownAndWait()
    }

    func testDeleteGlobalCredentialConfigFailureLeavesSecretAndAllConfigurationUntouched() async throws {
        let credentialID = "global-config-failure"
        let secret = UUID().uuidString
        let initial = RdcAppConfiguration(
            globalCredentialID: credentialID,
            groupCredentialBindings: ["group": credentialID],
            credentialMetadata: [credentialID: CredentialMetadata(id: credentialID, username: "user", domain: nil)]
        )
        let store = AppControlledConfigurationStore(configuration: initial, failingSaveNumbers: [1])
        let passwordStore = AppMemoryPasswordStore(passwords: [credentialID: secret])
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        do {
            try await model.deleteGlobalCredential()
            XCTFail("Expected configuration failure")
        } catch {
            XCTAssertEqual(error as? GlobalCredentialDeletionError, .configurationCommitFailed)
        }

        let current = await store.current()
        let passwordFingerprint = await passwordStore.passwordFingerprint(credentialID: credentialID)
        XCTAssertEqual(current, initial)
        XCTAssertEqual(passwordFingerprint, secret.hashValue)
        await model.shutdownAndWait()
    }

    func testDeleteGlobalCredentialKeychainFailureRollsBackAllConfiguration() async throws {
        let credentialID = "global-keychain-failure"
        let secret = UUID().uuidString
        let initial = RdcAppConfiguration(
            globalCredentialID: credentialID,
            credentialMetadata: [credentialID: CredentialMetadata(id: credentialID, username: "user", domain: nil)]
        )
        let store = AppMemoryConfigurationStore(configuration: initial)
        let passwordStore = AppMemoryPasswordStore(
            passwords: [credentialID: secret],
            failingDeleteIDs: [credentialID]
        )
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        do {
            try await model.deleteGlobalCredential()
            XCTFail("Expected Keychain failure")
        } catch {
            XCTAssertEqual(error as? GlobalCredentialDeletionError, .keychainDeleteFailedRolledBack)
        }

        let current = await store.current()
        let passwordFingerprint = await passwordStore.passwordFingerprint(credentialID: credentialID)
        XCTAssertEqual(current, initial)
        XCTAssertEqual(passwordFingerprint, secret.hashValue)
        await model.shutdownAndWait()
    }

    func testDeleteGlobalCredentialRefreshFailureReportsCommittedDeletion() async throws {
        let credentialID = "global-refresh-failure"
        let initial = RdcAppConfiguration(
            globalCredentialID: credentialID,
            credentialMetadata: [credentialID: CredentialMetadata(id: credentialID, username: "user", domain: nil)]
        )
        let store = AppControlledConfigurationStore(
            configuration: initial,
            failingLoadNumbers: [2]
        )
        let passwordStore = AppMemoryPasswordStore(passwords: [credentialID: "secret"])
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        await model.performGlobalCredentialDeletion()

        let current = await store.current()
        let passwordFingerprint = await passwordStore.passwordFingerprint(credentialID: credentialID)
        XCTAssertNil(current.globalCredentialID)
        XCTAssertNil(current.credentialMetadata[credentialID])
        XCTAssertNil(passwordFingerprint)
        XCTAssertEqual(
            model.settingsOperationError,
            GlobalCredentialDeletionError.committedRefreshFailed.safeMessage
        )
        await model.shutdownAndWait()
    }

    func testDeleteGlobalCredentialRollbackFailureDoesNotClaimCredentialWasPreserved() async throws {
        let credentialID = "global-rollback-failure"
        let initial = RdcAppConfiguration(
            globalCredentialID: credentialID,
            credentialMetadata: [credentialID: CredentialMetadata(id: credentialID, username: "user", domain: nil)]
        )
        let store = AppControlledConfigurationStore(configuration: initial, failingSaveNumbers: [2])
        let passwordStore = AppMemoryPasswordStore(
            passwords: [credentialID: "secret"],
            failingDeleteIDs: [credentialID]
        )
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()

        await model.performGlobalCredentialDeletion()

        XCTAssertEqual(model.settingsOperationError, GlobalCredentialDeletionError.rollbackFailed.safeMessage)
        XCTAssertFalse(model.settingsOperationError?.contains("已安全保留") ?? true)
        await model.shutdownAndWait()
    }

    func testSelectionCancellationRollsBackCompletedPersistentCredentialPhasesAndThrows() async throws {
        try await assertPersistentSaveCancellationRollsBack(shutdown: false)
    }

    func testShutdownCancellationRollsBackCompletedPersistentCredentialPhasesAndThrows() async throws {
        try await assertPersistentSaveCancellationRollsBack(shutdown: true)
    }

    func testOneTimeCredentialConnectsWithoutWritingConfigurationOrPasswordStore() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-one-time",
            sourceName: "temp2.rdg",
            document: testDocument()
        )
        let initial = RdcAppConfiguration(lastLibrary: snapshot)
        let store = AppMemoryConfigurationStore(configuration: initial)
        let repository = RdcConfigurationRepository(store: store)
        let passwordStore = AppMemoryPasswordStore()
        let engine = AppRecordingSessionEngine()
        let model = RdcAppModel(
            configurationRepository: repository,
            passwordStore: passwordStore,
            engine: engine
        )
        await model.loadPersistedState()
        let serverID = try XCTUnwrap(model.selectedServerID)
        var transientSecret = UUID().uuidString

        try await model.saveCredential(
            scope: .oneTime(serverID: serverID),
            username: "one-time-user",
            domain: nil,
            password: transientSecret
        )
        transientSecret.removeAll(keepingCapacity: false)

        let capture = await engine.capture()
        XCTAssertEqual(capture.username, "one-time-user")
        let savedCredentialIDs = await passwordStore.savedCredentialIDs()
        let persisted = await store.current()
        XCTAssertEqual(savedCredentialIDs, [])
        XCTAssertEqual(persisted, initial)
        await model.shutdownAndWait()
    }

    func testOneTimeAuthenticationFailureRemainsActionableAndRetryClosesSheet() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-one-time-retry",
            sourceName: "temp2.rdg",
            document: testDocument()
        )
        let engine = AppRetrySessionEngine(
            firstFailure: .authenticationFailed(reason: .unknown, code: nil)
        )
        let model = makeModel(
            configuration: RdcAppConfiguration(lastLibrary: snapshot),
            engine: engine
        )
        await model.loadPersistedState()
        model.requestCredentialPrompt()
        let serverID = try XCTUnwrap(model.selectedServerID)
        var transientSecret = UUID().uuidString

        do {
            try await model.saveCredential(
                scope: .oneTime(serverID: serverID),
                username: "retry-user",
                domain: nil,
                password: transientSecret
            )
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(
                error as? RdpSessionError,
                .authenticationFailed(reason: .unknown, code: nil)
            )
        }
        guard case let .authentication(_, actions) = model.connectionErrorPresentation else {
            return XCTFail("Expected actionable authentication presentation")
        }
        XCTAssertTrue(actions.contains(.retry))
        XCTAssertTrue(actions.contains(.editCredential(.oneTime(serverID: serverID))))
        XCTAssertTrue(model.isShowingCredentialSheet)

        try await model.saveCredential(
            scope: .oneTime(serverID: serverID),
            username: "retry-user",
            domain: nil,
            password: transientSecret
        )
        transientSecret.removeAll(keepingCapacity: false)

        XCTAssertFalse(model.isShowingCredentialSheet)
        XCTAssertNil(model.connectionErrorPresentation)
        let connectionCount = await engine.connectionCount()
        XCTAssertEqual(connectionCount, 2)
        await model.shutdownAndWait()
    }

    func testOneTimeNetworkAndCertificateFailuresKeepSafeActionablePresentations() async throws {
        let cases: [(RdpSessionError, ConnectionErrorPresentation)] = [
            (.network(code: -1_003, message: UUID().uuidString), .dns),
            (.certificateRejected, .certificateRejected)
        ]

        for (failure, expectedPresentation) in cases {
            let snapshot = RdcLibrarySnapshot(
                sourceID: UUID().uuidString,
                sourceName: "temp2.rdg",
                document: testDocument()
            )
            let model = makeModel(
                configuration: RdcAppConfiguration(lastLibrary: snapshot),
                engine: AppRetrySessionEngine(firstFailure: failure)
            )
            await model.loadPersistedState()
            model.requestCredentialPrompt()
            let serverID = try XCTUnwrap(model.selectedServerID)
            var transientSecret = UUID().uuidString

            do {
                try await model.saveCredential(
                    scope: .oneTime(serverID: serverID),
                    username: "operator",
                    domain: nil,
                    password: transientSecret
                )
                XCTFail("Expected the one-time connection to fail")
            } catch {
                XCTAssertEqual(error as? RdpSessionError, failure)
            }
            transientSecret.removeAll(keepingCapacity: false)

            XCTAssertEqual(model.connectionErrorPresentation, expectedPresentation)
            XCTAssertTrue(model.isShowingCredentialSheet)
            await model.shutdownAndWait()
        }
    }

    func testSelectedServerRetriesOneTransientTransportFailure() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-transport-retry",
            sourceName: "temp2.rdg",
            document: testDocument()
        )
        let credentialID = "transport-retry-credential"
        let engine = AppRetrySessionEngine(
            firstFailure: .network(
                code: Int32(bitPattern: 0x0002_000D),
                message: "transport connect failed"
            )
        )
        let model = makeModel(
            configuration: RdcAppConfiguration(
                globalCredentialID: credentialID,
                credentialMetadata: [
                    credentialID: CredentialMetadata(
                        id: credentialID,
                        username: "operator",
                        domain: nil
                    )
                ],
                lastLibrary: snapshot
            ),
            passwords: [credentialID: UUID().uuidString],
            engine: engine
        )

        await model.loadPersistedState()
        await model.connectSelectedServer()

        let connectionCount = await engine.connectionCount()
        XCTAssertEqual(connectionCount, 2)
        XCTAssertNotNil(model.session.descriptor)
        XCTAssertNil(model.connectionErrorPresentation)
        await model.shutdownAndWait()
    }

    func testTransientTransportRetryWaitsExactlyOnceAndKeepsAttemptSemantics() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-controlled-retry", sourceName: "temp2.rdg",
            document: testDocument()
        )
        let credentialID = "controlled-retry-credential"
        let failure = RdpSessionError.network(
            code: Int32(bitPattern: 0x0002_000D), message: "synthetic transport failure"
        )
        let engine = AppSequencedRetrySessionEngine(failures: [failure, failure])
        let sleeper = AppManualRetrySleeper()
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(
                store: AppMemoryConfigurationStore(configuration: RdcAppConfiguration(
                    globalCredentialID: credentialID,
                    credentialMetadata: [credentialID: .init(
                        id: credentialID, username: "operator", domain: "LAB"
                    )],
                    lastLibrary: snapshot
                ))
            ),
            passwordStore: AppMemoryPasswordStore(passwords: [credentialID: "synthetic"]),
            engine: engine,
            connectionRetrySleeper: sleeper
        )
        await model.loadPersistedState()

        let connectTask = Task { @MainActor in await model.connectSelectedServer() }
        await sleeper.waitUntilSleepCount(1)
        let durations = await sleeper.recordedDurations()
        XCTAssertEqual(durations, [.milliseconds(800)])
        await sleeper.resume()
        await connectTask.value

        let attempts = await engine.recordedAttempts()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0].request, attempts[1].request)
        XCTAssertEqual(attempts[0].credential, attempts[1].credential)
        XCTAssertEqual(attempts[0].viewport, attempts[1].viewport)
        let sleepCount = await sleeper.sleepCount()
        XCTAssertEqual(sleepCount, 1)
        XCTAssertNil(model.session.descriptor)
        XCTAssertEqual(model.connectionDiagnosticCode, "RDP-0002000D")
        await model.shutdownAndWait()
    }

    func testCredentialEditorPreventsRestoreInheritanceWhileSaveIsInFlight() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-editor-mutual-exclusion",
            sourceName: "temp2.rdg",
            document: testDocument()
        )
        let store = AppMemoryConfigurationStore(
            configuration: RdcAppConfiguration(lastLibrary: snapshot)
        )
        let passwordStore = AppSuspendingPasswordStore()
        let appModel = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        let editor = CredentialEditorModel(scope: .global, username: "operator")
        editor.password = UUID().uuidString

        let saveTask = Task { await editor.save(using: appModel) }
        await passwordStore.waitUntilSaveStarts()
        XCTAssertTrue(editor.isSaving)

        let invocation = AppAsyncSignal()
        let restoreResult = AppAsyncValue<Bool>()
        let restoreTask = Task {
            await invocation.signal()
            let result = await editor.restoreInheritance(using: appModel)
            await restoreResult.set(result)
        }
        await invocation.wait()
        let earlyRestoreResult = await restoreResult.value(
            before: ContinuousClock.now + .milliseconds(100)
        )
        XCTAssertEqual(earlyRestoreResult, false)

        await passwordStore.resumeSave()
        let didSave = await saveTask.value
        await restoreTask.value
        let persisted = await store.current()
        XCTAssertTrue(didSave)
        XCTAssertFalse(editor.isSaving)
        XCTAssertNotNil(persisted.globalCredentialID)
        await appModel.shutdownAndWait()
    }

    func testRapidSelectionCancelsInFlightConnectAndIgnoresLateLifecycle() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-rapid-selection",
            sourceName: "temp2.rdg",
            document: twoServerDocument()
        )
        let credentialID = "rapid-selection-credential"
        let configuration = RdcAppConfiguration(
            globalCredentialID: credentialID,
            credentialMetadata: [
                credentialID: CredentialMetadata(
                    id: credentialID,
                    username: "operator",
                    domain: nil
                )
            ],
            lastLibrary: snapshot
        )
        let engine = AppSuspendingSessionEngine()
        let model = makeModel(
            configuration: configuration,
            passwords: [credentialID: UUID().uuidString],
            engine: engine
        )
        await model.loadPersistedState()
        let secondServerID = try XCTUnwrap(model.library?.servers.last?.id)

        let connectTask = Task { await model.connectSelectedServer() }
        await engine.waitUntilConnectStarts()
        model.selectServer(id: secondServerID)
        await model.waitForPendingOperations()
        await connectTask.value

        XCTAssertEqual(model.selectedServerID, secondServerID)
        XCTAssertNil(model.session.descriptor)
        XCTAssertNil(model.connectionStartedAt)
        let cancellationCount = await engine.cancelledConnectCount()
        XCTAssertEqual(cancellationCount, 1)
        await model.shutdownAndWait()
    }

    func testAuthenticationFailureOffersEveryCredentialEditingScopeWithoutRawErrorData() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-auth-error",
            sourceName: "temp2.rdg",
            document: nestedDocument()
        )
        let library = RdcImportedLibrary(
            document: snapshot.makeDocument(),
            sourceID: snapshot.sourceID,
            sourceName: snapshot.sourceName
        )
        let server = try XCTUnwrap(library.servers.first)
        let credentialID = "auth-credential"
        let usernameSensitiveValue = "operator"
        let domainSensitiveValue = "AUTH-DOMAIN-SENSITIVE"
        let passwordSensitiveValue = UUID().uuidString
        let configuration = RdcAppConfiguration(
            globalCredentialID: credentialID,
            credentialMetadata: [
                credentialID: CredentialMetadata(
                    id: credentialID,
                    username: usernameSensitiveValue,
                    domain: domainSensitiveValue
                )
            ],
            lastLibrary: snapshot
        )
        let engine = AppRecordingSessionEngine(
            failure: .authenticationFailed(reason: .wrongPassword, code: 0x0002_0015)
        )
        let model = makeModel(
            configuration: configuration,
            passwords: [credentialID: passwordSensitiveValue],
            engine: engine
        )

        await model.loadPersistedState()
        await model.connectSelectedServer()

        guard case let .authentication(_, actions) = model.connectionErrorPresentation else {
            return XCTFail("Expected actionable authentication presentation")
        }
        XCTAssertTrue(actions.contains(.editCredential(.global)))
        XCTAssertTrue(actions.contains(.editCredential(
            .server(id: server.id, displayName: server.displayName)
        )))
        XCTAssertTrue(actions.contains(.editCredential(.oneTime(serverID: server.id))))
        for groupID in server.groupPathIDs {
            let name = try XCTUnwrap(library.groups.first { $0.id == groupID }?.name)
            XCTAssertTrue(actions.contains(.editCredential(
                .group(id: groupID, displayName: name)
            )))
        }
        let visibleMessage = try XCTUnwrap(model.connectionErrorMessage)
        XCTAssertTrue(visibleMessage.contains("密码错误"))
        XCTAssertTrue(visibleMessage.contains("RDP-00020015"))
        XCTAssertFalse(visibleMessage.contains(credentialID))
        XCTAssertFalse(visibleMessage.contains(usernameSensitiveValue))
        XCTAssertFalse(visibleMessage.contains(domainSensitiveValue))
        XCTAssertFalse(visibleMessage.contains(passwordSensitiveValue))
        await model.shutdownAndWait()
    }

    func testTLSFailureSurfacesSpecificSafeMessageAndDiagnosticCode() async {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-tls-error",
            sourceName: "temp2.rdg",
            document: testDocument()
        )
        let credentialID = "tls-credential"
        let rawDetail = "The connection failed at TLS connect. secret-runtime-detail"
        let model = makeModel(
            configuration: RdcAppConfiguration(
                globalCredentialID: credentialID,
                credentialMetadata: [
                    credentialID: CredentialMetadata(
                        id: credentialID,
                        username: "operator",
                        domain: nil
                    )
                ],
                lastLibrary: snapshot
            ),
            passwords: [credentialID: UUID().uuidString],
            engine: AppRecordingSessionEngine(
                failure: .protocolFailure(code: 0x0002_0008, message: rawDetail)
            )
        )

        await model.loadPersistedState()
        await model.connectSelectedServer()

        XCTAssertEqual(model.connectionErrorPresentation, .tlsOrProtocol)
        XCTAssertEqual(model.connectionDiagnosticCode, "RDP-00020008")
        XCTAssertTrue(model.connectionErrorMessage?.contains("TLS") ?? false)
        XCTAssertTrue(model.connectionErrorMessage?.contains("RDP-00020008") ?? false)
        XCTAssertFalse(model.connectionErrorMessage?.contains(rawDetail) ?? true)
        XCTAssertFalse(model.connectionErrorMessage?.contains("已断开连接") ?? true)
        await model.shutdownAndWait()
    }

    func testAuthenticationFailureReasonsUsePreciseSafeMessagesAndCodes() {
        let cases: [(RdpAuthenticationFailureReason, Int32, String)] = [
            (.wrongPassword, 0x0002_0015, "密码错误，请重新输入。"),
            (.invalidCredentials, 0x0002_0014, "用户名或密码错误，请重新输入。"),
            (.accountDisabled, 0x0002_0012, "账户已被禁用，请联系管理员。"),
            (.accountLocked, 0x0002_0018, "账户已被锁定，请稍后重试或联系管理员。"),
            (.passwordExpired, 0x0002_000E, "密码已过期，请先修改密码。"),
            (.passwordExpired, 0x0002_000F, "密码已过期，请先修改密码。"),
            (.passwordMustChange, 0x0002_0013, "账户要求先修改密码。"),
            (.accountRestriction, 0x0002_0017, "账户受到登录限制，请检查远程登录权限或登录时段。"),
            (.accountExpired, 0x0002_0019, "账户已过期，请联系管理员。"),
            (.unknown, 0x0002_0009, "身份验证失败，请检查账户、密码和登录权限。")
        ]

        for (reason, code, message) in cases {
            let error = RdpSessionError.authenticationFailed(reason: reason, code: code)
            let presentation = ConnectionErrorPresentation.classify(
                error: error,
                authenticationActions: []
            )
            XCTAssertEqual(presentation.message, message)
            XCTAssertEqual(RdcAppModel.diagnosticCode(for: error),
                           String(format: "RDP-%08X", UInt32(bitPattern: code)))
        }
    }

    func testPreciseAuthenticationReasonsRequireMatchingFreeRDPCode() {
        let cases: [(RdpAuthenticationFailureReason, [Int32], Int32)] = [
            (.wrongPassword, [0x0002_0015], 0x0002_0014),
            (.invalidCredentials, [0x0002_0014], 0x0002_0015),
            (.accountDisabled, [0x0002_0012], 0x0002_0015),
            (.accountLocked, [0x0002_0018], 0x0002_0015),
            (.passwordExpired, [0x0002_000E, 0x0002_000F], 0x0002_0015),
            (.passwordMustChange, [0x0002_0013], 0x0002_0015),
            (.accountRestriction, [0x0002_0017], 0x0002_0015),
            (.accountExpired, [0x0002_0019], 0x0002_0015)
        ]

        for (reason, validCodes, otherReasonCode) in cases {
            let validType = validCodes[0] & 0x0000_FFFF
            let invalidCodes: [Int32?] = [
                nil,
                otherReasonCode,
                0x0002_0009,
                0x0001_0000 | validType
            ]

            for code in invalidCodes {
                let error = RdpSessionError.authenticationFailed(
                    reason: reason,
                    code: code
                )
                XCTAssertEqual(
                    ConnectionErrorPresentation.classify(
                        error: error,
                        authenticationActions: []
                    ),
                    .authentication(reason: .unknown, actions: [])
                )
                XCTAssertEqual(
                    RdcAppModel.diagnosticCode(for: error),
                    code.map { String(format: "RDP-%08X", UInt32(bitPattern: $0)) }
                )
            }
        }
    }

    func testUnknownAuthenticationReasonAlwaysUsesGenericSafeMessage() {
        let codes: [Int32?] = [nil, 0x0002_0015, 0x1234_5678]

        for code in codes {
            let presentation = ConnectionErrorPresentation.classify(
                error: .authenticationFailed(reason: .unknown, code: code),
                authenticationActions: []
            )

            XCTAssertEqual(
                presentation,
                .authentication(reason: .unknown, actions: [])
            )
            XCTAssertEqual(
                presentation.message,
                "身份验证失败，请检查账户、密码和登录权限。"
            )
        }
    }

    func testConnectionErrorClassificationsUseFixedSafeMessages() {
        let untrustedDetail = "untrusted-runtime-detail-\(UUID().uuidString)"
        let cases: [(RdpSessionError, ConnectionErrorPresentation)] = [
            (.network(code: -1_003, message: untrustedDetail), .dns),
            (.network(code: -1_001, message: untrustedDetail), .timeout),
            (.network(code: 61, message: untrustedDetail), .refused),
            (.network(code: 0x0002_0005, message: untrustedDetail), .dns),
            (.network(code: 0x0002_001C, message: untrustedDetail), .timeout),
            (.network(code: 999, message: untrustedDetail), .transport),
            (.protocolFailure(code: 1, message: untrustedDetail), .tlsOrProtocol),
            (.certificateRejected, .certificateRejected),
            (.notConnected, .remoteDisconnect)
        ]

        for (error, expected) in cases {
            let presentation = ConnectionErrorPresentation.classify(
                error: error,
                authenticationActions: []
            )
            XCTAssertEqual(presentation, expected)
            XCTAssertFalse(presentation.message.contains(untrustedDetail))
        }
        XCTAssertFalse(ConnectionErrorPresentation.certificateChanged.message.contains("PEM"))
        XCTAssertEqual(
            RdcAppModel.diagnosticCode(for: .protocolFailure(
                code: 0x0002_0008, message: untrustedDetail
            )),
            "RDP-00020008"
        )
        XCTAssertNil(RdcAppModel.diagnosticCode(
            for: .authenticationFailed(reason: .unknown, code: nil)
        ))
    }

    func testProductionSessionWiringRejectsCertificateAfterInjectedSixtySecondClock() async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-certificate-wiring",
            sourceName: "temp2.rdg",
            document: testDocument()
        )
        let credentialID = "certificate-wiring-credential"
        let configuration = RdcAppConfiguration(
            globalCredentialID: credentialID,
            credentialMetadata: [
                credentialID: CredentialMetadata(
                    id: credentialID,
                    username: "operator",
                    domain: nil
                )
            ],
            lastLibrary: snapshot
        )
        let engine = AppRecordingSessionEngine()
        let certificateUpdates = AsyncStream<RdpCertificateChallengeUpdate>.makeStream()
        let clock = AppManualCertificateClock()
        let repository = RdcConfigurationRepository(
            store: AppMemoryConfigurationStore(configuration: configuration)
        )
        let model = RdcAppModel(
            configurationRepository: repository,
            passwordStore: AppMemoryPasswordStore(
                passwords: [credentialID: UUID().uuidString]
            ),
            engine: engine,
            certificateChallenges: certificateUpdates.stream,
            certificateClock: clock
        )
        await model.loadPersistedState()
        await model.connectSelectedServer()
        let capture = await engine.capture()
        let attemptID = try XCTUnwrap(capture.attemptID)
        let challenge = try certificateChallenge(id: 700)

        certificateUpdates.continuation.yield(
            RdpCertificateChallengeUpdate(
                attemptID: attemptID,
                sessionID: "app-workflow-session",
                challenge: challenge
            )
        )
        try await waitUntil { model.pendingCertificate != nil }
        try await waitUntilAsync { await clock.waiterCount() == 1 }

        await clock.advance(by: .seconds(60))
        try await waitUntilAsync { await engine.resolutionDecisions().count == 1 }

        XCTAssertNil(model.pendingCertificate)
        let decisions = await engine.resolutionDecisions()
        XCTAssertEqual(decisions, [.reject])
        certificateUpdates.continuation.finish()
        await model.shutdownAndWait()
    }

    private func assertPersistentSaveCancellationRollsBack(shutdown: Bool) async throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: shutdown ? "source-shutdown-cancel" : "source-selection-cancel",
            sourceName: "temp2.rdg",
            document: twoServerDocument()
        )
        let initial = RdcAppConfiguration(lastLibrary: snapshot)
        let store = AppControlledConfigurationStore(
            configuration: initial,
            suspendedSaveNumber: 2
        )
        let passwordStore = AppMemoryPasswordStore()
        let model = RdcAppModel(
            configurationRepository: RdcConfigurationRepository(store: store),
            passwordStore: passwordStore,
            engine: AppRecordingSessionEngine()
        )
        await model.loadPersistedState()
        var transientSecret = UUID().uuidString

        let saveTask = Task { [password = transientSecret] () -> Error? in
            do {
                try await model.saveCredential(
                    scope: .global,
                    username: "cancelled-user",
                    domain: nil,
                    password: password
                )
                return nil
            } catch {
                return error
            }
        }
        transientSecret.removeAll(keepingCapacity: false)
        await store.waitUntilSuspendedSaveStarts()

        if shutdown {
            model.shutdown()
        } else {
            let secondServerID = try XCTUnwrap(model.library?.servers.last?.id)
            model.selectServer(id: secondServerID)
        }
        await store.resumeSuspendedSave()
        let error = await saveTask.value

        XCTAssertTrue(error is CancellationError)
        let persisted = await store.current()
        let credentialIDs = await passwordStore.allCredentialIDs()
        XCTAssertEqual(persisted, initial)
        XCTAssertTrue(credentialIDs.isEmpty)
        await model.shutdownAndWait()
    }

    private func testDocument() -> RdcManDocument {
        RdcManDocument(
            programVersion: "2.7",
            schemaVersion: "3",
            root: RdcGroup(
                name: "Root",
                isExpanded: true,
                logonCredentials: nil,
                groups: [],
                servers: [
                    RdcServer(
                        displayName: "Server",
                        address: RdcServerAddress("rdp.example.invalid"),
                        logonCredentials: nil
                    )
                ]
            )
        )
    }

    private func nestedDocument() -> RdcManDocument {
        RdcManDocument(
            programVersion: "2.7",
            schemaVersion: "3",
            root: RdcGroup(
                name: "Root",
                isExpanded: true,
                logonCredentials: nil,
                groups: [
                    RdcGroup(
                        name: "Team",
                        isExpanded: true,
                        logonCredentials: nil,
                        groups: [],
                        servers: [
                            RdcServer(
                                displayName: "Nested Server",
                                address: RdcServerAddress("nested.example.invalid"),
                                logonCredentials: nil
                            )
                        ]
                    )
                ],
                servers: []
            )
        )
    }

    private func twoServerDocument() -> RdcManDocument {
        let original = testDocument()
        return RdcManDocument(
            programVersion: original.programVersion,
            schemaVersion: original.schemaVersion,
            root: RdcGroup(
                name: original.root.name,
                isExpanded: original.root.isExpanded,
                logonCredentials: nil,
                groups: [],
                servers: original.root.servers + [
                    RdcServer(
                        displayName: "Second Server",
                        address: RdcServerAddress("second.example.invalid"),
                        logonCredentials: nil
                    )
                ]
            )
        )
    }

    private func reimportWorkflowDocument(includeNewServer: Bool) -> RdcManDocument {
        var servers = [
            RdcServer(
                displayName: "Kept", address: RdcServerAddress("kept.example:3389"),
                logonCredentials: nil
            ),
            RdcServer(
                displayName: "Deleted", address: RdcServerAddress("deleted.example:3389"),
                logonCredentials: nil
            )
        ]
        if includeNewServer {
            servers.append(RdcServer(
                displayName: "Upstream New", address: RdcServerAddress("new.example:3389"),
                logonCredentials: nil
            ))
        }
        return RdcManDocument(
            programVersion: "2.7", schemaVersion: "3",
            root: RdcGroup(
                name: "Root", isExpanded: true, logonCredentials: nil,
                groups: [RdcGroup(
                    name: "Imported", isExpanded: true, logonCredentials: nil,
                    groups: [], servers: servers
                )],
                servers: []
            )
        )
    }

    private func documentWithSensitiveSourceCredential() -> RdcManDocument {
        let original = testDocument()
        return RdcManDocument(
            programVersion: original.programVersion,
            schemaVersion: original.schemaVersion,
            root: RdcGroup(
                name: original.root.name,
                isExpanded: original.root.isExpanded,
                logonCredentials: RdcLogonCredentials(
                    inheritance: .none,
                    profileName: nil,
                    userName: "legacy-user",
                    domain: nil,
                    password: .windowsDPAPIEncrypted(UUID().uuidString)
                ),
                groups: original.root.groups,
                servers: original.root.servers
            )
        )
    }

    private func metadata(
        _ pairs: (String, String)...
    ) -> [String: CredentialMetadata] {
        Dictionary(uniqueKeysWithValues: pairs.map { id, username in
            (id, CredentialMetadata(id: id, username: username, domain: nil))
        })
    }

    private func makeModel(
        configuration: RdcAppConfiguration,
        passwords: [String: String] = [:],
        engine: any RdpSessionEngine
    ) -> RdcAppModel {
        RdcAppModel(
            configurationRepository: RdcConfigurationRepository(
                store: AppMemoryConfigurationStore(configuration: configuration)
            ),
            passwordStore: AppMemoryPasswordStore(passwords: passwords),
            engine: engine
        )
    }

    private func certificateChallenge(id: UInt64) throws -> RdpCertificateChallenge {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RdcCoreTests/Fixtures/test-certificate.pem")
        return try RdpCertificateChallenge(
            id: id,
            endpoint: RdpEndpoint(host: "rdp.example.invalid", port: 3_389),
            pemData: try Data(contentsOf: fixtureURL),
            flags: 0
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        throw AppWorkflowWaitError.timedOut
    }

    private func waitUntilAsync(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<10_000 {
            if await predicate() { return }
            await Task.yield()
        }
        throw AppWorkflowWaitError.timedOut
    }
}

private enum AppWorkflowWaitError: Error {
    case timedOut
}

@MainActor private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}

@MainActor private func captureError(
    _ expression: () async throws -> Void
) async -> Error {
    do {
        try await expression()
        return AppWorkflowWaitError.timedOut
    } catch {
        return error
    }
}

private actor AppAsyncSignal {
    private var didSignal = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        didSignal = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !didSignal else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor AppResourceOperationCheckpoint {
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters.removeAll()
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor AppAsyncValue<Value: Sendable> {
    private var storedValue: Value?

    func set(_ value: Value) {
        storedValue = value
    }

    func value(before deadline: ContinuousClock.Instant) async -> Value? {
        while ContinuousClock.now < deadline {
            if let storedValue { return storedValue }
            await Task.yield()
        }
        return storedValue
    }
}

private actor AppMemoryConfigurationStore: RdcConfigurationStore {
    private var configuration: RdcAppConfiguration

    init(configuration: RdcAppConfiguration) {
        self.configuration = configuration
    }

    func load() async throws -> RdcAppConfiguration { configuration }

    func save(_ configuration: RdcAppConfiguration) async throws {
        self.configuration = configuration
    }

    func current() -> RdcAppConfiguration { configuration }
}

private enum AppControlledStoreError: Error {
    case injected
}

private final class AppOpaqueResourceIdentifier: NSObject {
    override var description: String {
        "opaque-at-\(Unmanaged.passUnretained(self).toOpaque())"
    }
}

private actor AppControlledConfigurationStore: RdcConfigurationStore {
    private var configuration: RdcAppConfiguration
    private let failingSaveNumbers: Set<Int>
    private let failingLoadNumbers: Set<Int>
    private var loadCount = 0
    private let suspendedSaveNumber: Int?
    private var saveCount = 0
    private var suspendedSaveStarted = false
    private var suspendedSaveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendedSaveContinuation: CheckedContinuation<Void, Never>?

    init(
        configuration: RdcAppConfiguration,
        failingSaveNumbers: Set<Int> = [],
        failingLoadNumbers: Set<Int> = [],
        suspendedSaveNumber: Int? = nil
    ) {
        self.configuration = configuration
        self.failingSaveNumbers = failingSaveNumbers
        self.failingLoadNumbers = failingLoadNumbers
        self.suspendedSaveNumber = suspendedSaveNumber
    }

    func load() async throws -> RdcAppConfiguration {
        loadCount += 1
        if failingLoadNumbers.contains(loadCount) { throw AppControlledStoreError.injected }
        return configuration
    }

    func save(_ configuration: RdcAppConfiguration) async throws {
        saveCount += 1
        let currentSave = saveCount
        if currentSave == suspendedSaveNumber {
            suspendedSaveStarted = true
            suspendedSaveStartWaiters.forEach { $0.resume() }
            suspendedSaveStartWaiters.removeAll()
            await withCheckedContinuation { continuation in
                suspendedSaveContinuation = continuation
            }
        }
        if failingSaveNumbers.contains(currentSave) {
            throw AppControlledStoreError.injected
        }
        self.configuration = configuration
    }

    func waitUntilSuspendedSaveStarts() async {
        guard !suspendedSaveStarted else { return }
        await withCheckedContinuation { continuation in
            suspendedSaveStartWaiters.append(continuation)
        }
    }

    func resumeSuspendedSave() {
        suspendedSaveContinuation?.resume()
        suspendedSaveContinuation = nil
    }

    func current() -> RdcAppConfiguration { configuration }

    func savedCount() -> Int { saveCount }
}

private struct AppDetailedStoreError: Error, CustomStringConvertible {
    let detail: String
    var description: String { detail }
}

private actor AppDetailedFailingConfigurationStore: RdcConfigurationStore {
    private var configuration: RdcAppConfiguration
    private let detail: String

    init(configuration: RdcAppConfiguration, detail: String) {
        self.configuration = configuration
        self.detail = detail
    }

    func load() async throws -> RdcAppConfiguration { configuration }

    func save(_ configuration: RdcAppConfiguration) async throws {
        throw AppDetailedStoreError(detail: detail)
    }
}

private actor AppMemoryPasswordStore: PasswordStore {
    private var passwords: [String: String]
    private var savedIDs: [String] = []
    private var deletedIDs: [String] = []
    private let failingDeleteIDs: Set<String>
    private let failingSaveIDs: Set<String>

    init(
        passwords: [String: String] = [:],
        failingDeleteIDs: Set<String> = [],
        failingSaveIDs: Set<String> = []
    ) {
        self.passwords = passwords
        self.failingDeleteIDs = failingDeleteIDs
        self.failingSaveIDs = failingSaveIDs
    }

    func save(password: String, credentialID: String) async throws {
        if failingSaveIDs.contains(credentialID) { throw AppControlledStoreError.injected }
        passwords[credentialID] = password
        savedIDs.append(credentialID)
    }

    func password(credentialID: String) async throws -> String? {
        passwords[credentialID]
    }

    func delete(credentialID: String) async throws {
        if failingDeleteIDs.contains(credentialID) { throw AppControlledStoreError.injected }
        passwords.removeValue(forKey: credentialID)
        deletedIDs.append(credentialID)
    }

    func savedCredentialIDs() -> [String] { savedIDs }

    func deletedCredentialIDs() -> [String] { deletedIDs }

    func allCredentialIDs() -> [String] { Array(passwords.keys) }

    func passwordFingerprint(credentialID: String) -> Int? {
        passwords[credentialID]?.hashValue
    }
}

private actor AppSuspendingPasswordStore: PasswordStore {
    private var passwords: [String: String] = [:]
    private var saveStarted = false
    private var saveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveContinuation: CheckedContinuation<Void, Never>?

    func save(password: String, credentialID: String) async throws {
        saveStarted = true
        saveStartWaiters.forEach { $0.resume() }
        saveStartWaiters.removeAll()
        await withCheckedContinuation { continuation in
            saveContinuation = continuation
        }
        passwords[credentialID] = password
    }

    func password(credentialID: String) async throws -> String? {
        passwords[credentialID]
    }

    func delete(credentialID: String) async throws {
        passwords.removeValue(forKey: credentialID)
    }

    func waitUntilSaveStarts() async {
        guard !saveStarted else { return }
        await withCheckedContinuation { continuation in
            saveStartWaiters.append(continuation)
        }
    }

    func resumeSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }
}

private actor AppRecordingSessionEngine: RdpSessionEngine {
    struct Capture: Sendable {
        var username: String?
        var domain: String?
        var connectionCount = 0
        var attemptID: RdpConnectionAttemptID?
        var secureAttentionCount = 0
        var clipboardTexts: [String] = []
    }

    private var lastCapture = Capture()
    private let failure: RdpSessionError?
    private var decisions: [RdpCertificateDecision] = []
    private var disconnects = 0
    private let failsVerifiedDisconnect: Bool

    init(failure: RdpSessionError? = nil, failsVerifiedDisconnect: Bool = false) {
        self.failure = failure
        self.failsVerifiedDisconnect = failsVerifiedDisconnect
    }

    func currentState() async -> RdpSessionState { .idle }

    func connect(
        _ request: RdpConnectionRequest,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport,
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        lastCapture = Capture(
            username: credential?.username,
            domain: credential?.domain,
            connectionCount: lastCapture.connectionCount + 1,
            attemptID: attemptID,
            secureAttentionCount: lastCapture.secureAttentionCount,
            clipboardTexts: lastCapture.clipboardTexts
        )
        if let failure { throw failure }
        return RdpSessionDescriptor(
            id: "app-workflow-session",
            request: request,
            transport: .mock
        )
    }

    func disconnect() async { disconnects += 1 }

    func disconnectVerified() async throws {
        if failsVerifiedDisconnect { throw RdpSessionDisconnectError.notDisconnected }
        await disconnect()
    }

    func reconnect(attemptID: RdpConnectionAttemptID) async throws -> RdpSessionDescriptor {
        throw CancellationError()
    }

    func capture() -> Capture { lastCapture }

    func resolveCertificate(
        attemptID: RdpConnectionAttemptID,
        sessionID: String,
        challengeID: UInt64,
        decision: RdpCertificateDecision
    ) async {
        decisions.append(decision)
    }

    func resolutionDecisions() -> [RdpCertificateDecision] { decisions }

    func disconnectCount() -> Int { disconnects }

    func sendSecureAttention(sessionID: String) async {
        guard sessionID == "app-workflow-session" else { return }
        lastCapture.secureAttentionCount += 1
    }

    func setClipboardText(sessionID: String, text: String) async {
        guard sessionID == "app-workflow-session" else { return }
        lastCapture.clipboardTexts.append(text)
    }
}

@MainActor
private final class AppTextPasteboard: TextPasteboard {
    var text: String?
    private(set) var writes: [String] = []

    init(text: String? = nil) { self.text = text }

    func readText() -> String? { text }

    func writeText(_ text: String) {
        self.text = text
        writes.append(text)
    }
}

private actor AppRetrySessionEngine: RdpSessionEngine {
    private let firstFailure: RdpSessionError
    private var attempts = 0

    init(firstFailure: RdpSessionError) {
        self.firstFailure = firstFailure
    }

    func currentState() async -> RdpSessionState { .idle }

    func connect(
        _ request: RdpConnectionRequest,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport,
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        attempts += 1
        if attempts == 1 { throw firstFailure }
        return RdpSessionDescriptor(
            id: "retry-session",
            request: request,
            transport: .mock
        )
    }

    func disconnect() async {}

    func reconnect(attemptID: RdpConnectionAttemptID) async throws -> RdpSessionDescriptor {
        throw CancellationError()
    }

    func connectionCount() -> Int { attempts }
}

private actor AppManualRetrySleeper: ConnectionRetrySleeper {
    private var durations: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var sleepContinuation: CheckedContinuation<Void, Error>?

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        try await withCheckedThrowingContinuation { continuation in
            sleepContinuation = continuation
        }
    }

    func waitUntilSleepCount(_ count: Int) async {
        while durations.count < count {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func resume() {
        sleepContinuation?.resume()
        sleepContinuation = nil
    }

    func recordedDurations() -> [Duration] { durations }
    func sleepCount() -> Int { durations.count }
}

private actor AppSequencedRetrySessionEngine: RdpSessionEngine {
    struct Attempt: Sendable {
        let request: RdpConnectionRequest
        let credential: RdpConnectionCredential?
        let viewport: RdpViewport
    }

    private let failures: [RdpSessionError]
    private var attempts: [Attempt] = []

    init(failures: [RdpSessionError]) { self.failures = failures }

    func currentState() async -> RdpSessionState { .idle }

    func connect(
        _ request: RdpConnectionRequest,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport,
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        attempts.append(.init(request: request, credential: credential, viewport: viewport))
        if attempts.count <= failures.count { throw failures[attempts.count - 1] }
        return .init(id: "sequenced-retry", request: request, transport: .mock)
    }

    func disconnect() async {}

    func reconnect(attemptID: RdpConnectionAttemptID) async throws -> RdpSessionDescriptor {
        throw CancellationError()
    }

    func recordedAttempts() -> [Attempt] { attempts }
}

private actor AppSuspendingDisconnectSessionEngine: RdpSessionEngine {
    private var disconnectStarted = false
    private var disconnects = 0
    private var disconnectContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspend = true

    func currentState() async -> RdpSessionState { .idle }

    func connect(
        _ request: RdpConnectionRequest,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport,
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        RdpSessionDescriptor(id: "suspending-disconnect", request: request, transport: .mock)
    }

    func disconnect() async {
        disconnectStarted = true
        disconnects += 1
        guard shouldSuspend else { return }
        await withCheckedContinuation { continuation in
            disconnectContinuation = continuation
        }
    }

    func reconnect(attemptID: RdpConnectionAttemptID) async throws -> RdpSessionDescriptor {
        throw CancellationError()
    }

    func didDisconnectStart() -> Bool { disconnectStarted }

    func disconnectCount() -> Int { disconnects }

    func resumeDisconnect() {
        shouldSuspend = false
        disconnectContinuation?.resume()
        disconnectContinuation = nil
    }
}

private actor AppManualCertificateClock: CertificateChallengeClock {
    private var elapsed: Duration = .zero
    private var waiters: [(Duration, CheckedContinuation<Void, Error>)] = []

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

    func waiterCount() -> Int { waiters.count }
}

private actor AppSuspendingSessionEngine: RdpSessionEngine {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationCount = 0

    func currentState() async -> RdpSessionState { .idle }

    func connect(
        _ request: RdpConnectionRequest,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport,
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            cancellationCount += 1
            throw CancellationError()
        }
        return RdpSessionDescriptor(
            id: "late-session",
            request: request,
            transport: .mock
        )
    }

    func disconnect() async {}

    func reconnect(attemptID: RdpConnectionAttemptID) async throws -> RdpSessionDescriptor {
        throw CancellationError()
    }

    func waitUntilConnectStarts() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func cancelledConnectCount() -> Int { cancellationCount }
}
