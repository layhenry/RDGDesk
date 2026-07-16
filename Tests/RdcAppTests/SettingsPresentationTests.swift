import XCTest
@testable import RdcApp
@testable import RdcCore

@MainActor
final class SettingsPresentationTests: XCTestCase {
    func testResourceMenuPoliciesHaveExactOrderAndRootSemantics() {
        XCTAssertEqual(ResourceMenuPolicy.items(for: .server, isConnected: false), [
            .connectOrDisconnect, .properties, .serverCredential, .separator,
            .moveServer, .deleteServer
        ])
        XCTAssertEqual(ResourceMenuPolicy.items(for: .group, isConnected: false), [
            .expandOrCollapse, .properties, .groupCredential, .newChildGroup,
            .moveGroup, .separator, .deleteGroup
        ])
        let root = ResourceMenuPolicy.items(for: .rootGroup, isConnected: false)
        XCTAssertEqual(root, [
            .expandOrCollapse, .properties, .groupCredential, .newChildGroup,
            .separator, .removeLibrary
        ])
        XCTAssertFalse(root.contains(.moveGroup))
        XCTAssertFalse(root.contains(.deleteGroup))
    }

    func testPendingGroupDeletionUsesExactRecursiveWarningCopy() {
        let coordinator = ResourcePropertySheetCoordinator()
        let lease = coordinator.register(host: .primaryWindow(id: UUID()))
        let snapshot = deletionSnapshotFixture()
        let pending = PendingResourceDeletion.group(
            id: "group-id",
            name: "测试组",
            impact: .init(groupCount: 3, serverCount: 12, containsSelectedServer: true),
            expectedSnapshot: snapshot,
            ownerLease: lease
        )
        XCTAssertEqual(pending.title, "删除群组“测试组”？")
        XCTAssertEqual(pending.destructiveButtonTitle, "删除群组")
        XCTAssertEqual(
            pending.message,
            "将删除 3 个群组和 12 台服务器，并断开当前连接。原始 .rdg 文件不会改变。"
        )
    }

    func testMoveDestinationsExcludeNoOpAndCyclicTargets() throws {
        let library = RdcImportedLibrary(
            document: RdcManDocument(programVersion: "2.7", schemaVersion: "3", root: RdcGroup(
                name: "Root", isExpanded: true, logonCredentials: nil,
                groups: [RdcGroup(
                    name: "Moving", isExpanded: true, logonCredentials: nil,
                    groups: [RdcGroup(
                        name: "Child", isExpanded: true, logonCredentials: nil,
                        groups: [], servers: []
                    )],
                    servers: [RdcServer(
                        displayName: "Inside", address: RdcServerAddress("inside.example.com"),
                        logonCredentials: nil
                    )]
                )], servers: []
            )),
            sourceID: "destination-fixture", sourceName: "temp2.rdg"
        )
        let root = try XCTUnwrap(library.groups.first { $0.parentID == nil })
        let moving = try XCTUnwrap(library.groups.first { $0.parentID == root.id })
        let child = try XCTUnwrap(library.groups.first { $0.parentID == moving.id })
        let server = try XCTUnwrap(library.servers.first { $0.groupPathIDs.last == moving.id })

        let serverIDs = ResourceMoveDestinationPolicy.serverDestinations(
            in: library, serverID: server.id
        ).map(\.id)
        XCTAssertFalse(serverIDs.contains(moving.id))
        XCTAssertTrue(serverIDs.contains(root.id))

        let groupIDs = ResourceMoveDestinationPolicy.groupDestinations(
            in: library, groupID: moving.id
        ).map(\.id)
        XCTAssertFalse(groupIDs.contains(root.id)) // current parent is a no-op
        XCTAssertFalse(groupIDs.contains(moving.id))
        XCTAssertFalse(groupIDs.contains(child.id))
    }

    func testDeletionPresentationHasSingleOwnerAndRejectsStaleCompletion() throws {
        let coordinator = ResourcePropertySheetCoordinator()
        let hostA = CredentialEditorHost.primaryWindow(id: UUID())
        let hostB = CredentialEditorHost.primaryWindow(id: UUID())
        let leaseA = coordinator.register(host: hostA)
        let leaseB = coordinator.register(host: hostB)
        let request = PendingResourceDeletion.server(
            id: "server-a", name: "A",
            impact: .init(groupCount: 0, serverCount: 1, containsSelectedServer: false),
            expectedSnapshot: deletionSnapshotFixture(),
            ownerLease: leaseA
        )

        XCTAssertEqual(coordinator.claimDeletion(request, lease: leaseA), .claimed)
        XCTAssertEqual(coordinator.claimDeletion(request, lease: leaseB), .ownedByAnotherWindow)
        let old = try XCTUnwrap(coordinator.deletionPresentation(requested: request, lease: leaseA))
        let token = try XCTUnwrap(coordinator.beginDeletion(for: old))
        XCTAssertTrue(coordinator.finishDeletion(
            token: token, presentation: old, succeeded: false,
            requestedStillCurrent: true
        ))
        let retry = try XCTUnwrap(coordinator.deletionPresentation(
            requested: request, lease: leaseA
        ))
        XCTAssertNotEqual(retry.id, old.id)

        XCTAssertTrue(coordinator.dismissDeletion(retry))
        XCTAssertEqual(coordinator.claimDeletion(request, lease: leaseA), .claimed)
        let replacement = try XCTUnwrap(coordinator.deletionPresentation(
            requested: request, lease: leaseA
        ))
        XCTAssertFalse(coordinator.finishDeletion(
            token: token, presentation: old, succeeded: true,
            requestedStillCurrent: true
        ))
        XCTAssertEqual(coordinator.deletionPresentation(requested: request, lease: leaseA), replacement)
    }

    func testDeletionCannotOverlapPropertyOrCredentialPresentation() throws {
        let coordinator = ResourcePropertySheetCoordinator()
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let lease = coordinator.register(host: host)
        let route = ResourceEditorRoute.server(id: "server-a")
        let request = PendingResourceDeletion.server(
            id: "server-a", name: "A",
            impact: .init(groupCount: 0, serverCount: 1, containsSelectedServer: false),
            expectedSnapshot: deletionSnapshotFixture(),
            ownerLease: lease
        )
        XCTAssertEqual(coordinator.claimPresentation(
            route: route, lease: lease, activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        ), .claimed)
        XCTAssertEqual(coordinator.claimDeletion(request, lease: lease), .blockedByCredentialEditor)
        let property = try XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: route, lease: lease
        ))
        XCTAssertNil(coordinator.completeResourceDismissal(
            presentation: property, activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        ))

        let credential = CredentialEditorPresentation(scope: .global, host: host)
        XCTAssertEqual(coordinator.claimDeletion(
            request, lease: lease, activeCredential: credential
        ), .blockedByCredentialEditor)
        XCTAssertEqual(coordinator.claimDeletion(request, lease: lease), .claimed)
    }

    func testSameHostRegistrationCreatesNewLeaseAndOldUnregisterCannotReleaseNewOwner() throws {
        let coordinator = ResourcePropertySheetCoordinator()
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let oldLease = coordinator.register(host: host)
        coordinator.unregister(lease: oldLease)
        let newLease = coordinator.register(host: host)
        XCTAssertNotEqual(oldLease, newLease)
        let route = ResourceEditorRoute.server(id: "server-a")
        XCTAssertEqual(coordinator.claimPresentation(
            route: route, lease: newLease, activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        ), .claimed)
        XCTAssertFalse(coordinator.unregister(lease: oldLease))
        XCTAssertNotNil(coordinator.resourcePresentation(
            requestedRoute: route, lease: newLease
        ))
    }

    func testDeletionCanOnlyBeClaimedByInitiatingLease() {
        let coordinator = ResourcePropertySheetCoordinator()
        let leaseA = coordinator.register(host: .primaryWindow(id: UUID()))
        let leaseB = coordinator.register(host: .primaryWindow(id: UUID()))
        let request = PendingResourceDeletion.server(
            id: "server-a", name: "A",
            impact: .init(groupCount: 0, serverCount: 1, containsSelectedServer: false),
            expectedSnapshot: deletionSnapshotFixture(), ownerLease: leaseA
        )
        XCTAssertEqual(coordinator.claimDeletion(request, lease: leaseB), .ownedByAnotherWindow)
        XCTAssertEqual(coordinator.claimDeletion(request, lease: leaseA), .claimed)
    }

    func testPropertyRequestIsVisibleOnlyToInitiatingActiveLease() async {
        let model = RdcAppModel()
        let leaseA = model.resourcePropertyCoordinator.register(
            host: .primaryWindow(id: UUID())
        )
        let leaseB = model.resourcePropertyCoordinator.register(
            host: .primaryWindow(id: UUID())
        )
        let route = ResourceEditorRoute.server(id: "server-a")
        XCTAssertTrue(model.requestResourceEditor(route, ownerLease: leaseA))
        XCTAssertEqual(model.resourceEditorRoute(for: leaseA), route)
        XCTAssertNil(model.resourceEditorRoute(for: leaseB))
        model.resourcePropertyCoordinator.unregister(lease: leaseA)
        XCTAssertNil(model.resourceEditorRoute(for: leaseA))
        XCTAssertFalse(model.requestResourceEditor(route, ownerLease: leaseA))
        await model.shutdownAndWait()
    }

    func testChildGroupPresentationIsSingleOwnerMutuallyExclusiveAndStaleSafe() throws {
        let coordinator = ResourcePropertySheetCoordinator()
        let leaseA = coordinator.register(host: .primaryWindow(id: UUID()))
        let leaseB = coordinator.register(host: .primaryWindow(id: UUID()))
        let request = NewChildGroupRequest(
            parentID: "root", parentName: "Root", ownerLease: leaseA
        )
        XCTAssertEqual(coordinator.claimNewChildGroup(request, lease: leaseB), .ownedByAnotherWindow)
        XCTAssertEqual(coordinator.claimNewChildGroup(request, lease: leaseA), .claimed)
        let old = try XCTUnwrap(coordinator.newChildGroupPresentation(
            requested: request, lease: leaseA
        ))
        XCTAssertEqual(coordinator.claimDeletion(
            .server(
                id: "server", name: "Server",
                impact: .init(groupCount: 0, serverCount: 1, containsSelectedServer: false),
                expectedSnapshot: deletionSnapshotFixture(), ownerLease: leaseA
            ),
            lease: leaseA
        ), .blockedByCredentialEditor)
        XCTAssertTrue(coordinator.dismissNewChildGroup(old))
        XCTAssertFalse(coordinator.dismissNewChildGroup(old))
    }

    func testDeletionDialogDismissesDuringOperationThenRePresentsFailure() throws {
        let coordinator = ResourcePropertySheetCoordinator()
        let lease = coordinator.register(host: .primaryWindow(id: UUID()))
        let request = PendingResourceDeletion.server(
            id: "server-a", name: "A",
            impact: .init(groupCount: 0, serverCount: 1, containsSelectedServer: false),
            expectedSnapshot: deletionSnapshotFixture(), ownerLease: lease
        )
        XCTAssertEqual(coordinator.claimDeletion(request, lease: lease), .claimed)
        let first = try XCTUnwrap(coordinator.deletionPresentation(
            requested: request, lease: lease
        ))
        let token = try XCTUnwrap(coordinator.beginDeletion(for: first))
        XCTAssertEqual(coordinator.deletionDialogDidDismiss(first), .operationInFlight)
        XCTAssertNil(coordinator.deletionPresentation(requested: request, lease: lease))
        XCTAssertTrue(coordinator.finishDeletion(
            token: token, presentation: first, succeeded: false,
            requestedStillCurrent: true
        ))
        let retry = try XCTUnwrap(coordinator.deletionPresentation(
            requested: request, lease: lease
        ))
        XCTAssertNotEqual(retry.id, first.id)
        XCTAssertFalse(coordinator.finishDeletion(
            token: token, presentation: first, succeeded: false,
            requestedStillCurrent: true
        ))
        XCTAssertEqual(coordinator.deletionPresentation(requested: request, lease: lease), retry)
    }

    func testUnregisterClearsDismissedInFlightDeletionToken() throws {
        let coordinator = ResourcePropertySheetCoordinator()
        let lease = coordinator.register(host: .primaryWindow(id: UUID()))
        let request = PendingResourceDeletion.server(
            id: "server-a", name: "A",
            impact: .init(groupCount: 0, serverCount: 1, containsSelectedServer: false),
            expectedSnapshot: deletionSnapshotFixture(), ownerLease: lease
        )
        XCTAssertEqual(coordinator.claimDeletion(request, lease: lease), .claimed)
        let presentation = try XCTUnwrap(coordinator.deletionPresentation(
            requested: request, lease: lease
        ))
        _ = try XCTUnwrap(coordinator.beginDeletion(for: presentation))
        XCTAssertEqual(coordinator.deletionDialogDidDismiss(presentation), .operationInFlight)
        XCTAssertTrue(coordinator.hasInFlightDeletion(ownedBy: lease))

        coordinator.unregister(lease: lease)

        XCTAssertFalse(coordinator.hasInFlightDeletion(ownedBy: lease))
    }

    func testScopedPropertyCallbacksCannotDismissReplacementWithSameRoute() async throws {
        let model = RdcAppModel()
        let coordinator = model.resourcePropertyCoordinator
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let route = ResourceEditorRoute.server(id: "same-server")
        let oldLease = coordinator.register(host: host)
        XCTAssertTrue(model.requestResourceEditor(route, ownerLease: oldLease))
        XCTAssertEqual(coordinator.claimPresentation(
            route: route, lease: oldLease, activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        ), .claimed)
        let oldPresentation = try XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: route, lease: oldLease
        ))
        let oldSave = try XCTUnwrap(coordinator.beginSave(for: oldPresentation))
        coordinator.unregister(lease: oldLease)
        model.releaseResourcePresentationRequests(ownedBy: oldLease)

        let newLease = coordinator.register(host: host)
        XCTAssertTrue(model.requestResourceEditor(route, ownerLease: newLease))
        XCTAssertEqual(coordinator.claimPresentation(
            route: route, lease: newLease, activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        ), .claimed)
        let newPresentation = try XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: route, lease: newLease
        ))

        XCTAssertFalse(coordinator.shouldCloseAfterSave(
            token: oldSave,
            currentPresentation: oldPresentation,
            currentRoute: model.resourceEditorRoute,
            currentOwnerLease: model.resourceEditorOwnerLease
        ))
        XCTAssertFalse(model.dismissResourceEditor(presentation: oldPresentation))
        XCTAssertEqual(model.resourceEditorRoute(for: newLease), route)

        XCTAssertFalse(coordinator.requestCredentialHandoff(
            scope: .server(id: "same-server", displayName: "Same"),
            lease: oldLease,
            from: route
        ))
        XCTAssertFalse(model.dismissResourceEditor(presentation: oldPresentation))
        XCTAssertEqual(model.resourceEditorRoute(for: newLease), route)

        XCTAssertTrue(model.dismissResourceEditor(presentation: newPresentation))
        XCTAssertNil(model.resourceEditorRoute)
        await model.shutdownAndWait()
    }

    func testSaveCloseRequiresCurrentModelOwnerLease() throws {
        let coordinator = ResourcePropertySheetCoordinator()
        let route = ResourceEditorRoute.server(id: "same-server")
        let leaseA = coordinator.register(host: .primaryWindow(id: UUID()))
        let leaseB = coordinator.register(host: .primaryWindow(id: UUID()))
        XCTAssertEqual(coordinator.claimPresentation(
            route: route, lease: leaseA, activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        ), .claimed)
        let presentation = try XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: route, lease: leaseA
        ))
        let token = try XCTUnwrap(coordinator.beginSave(for: presentation))

        XCTAssertFalse(coordinator.shouldCloseAfterSave(
            token: token,
            currentPresentation: presentation,
            currentRoute: route,
            currentOwnerLease: leaseB
        ))
    }

    func testConnectingServerPrimaryActionCannotStartAnotherConnection() {
        XCTAssertEqual(
            ResourceMenuPolicy.serverPrimaryAction(isConnected: false, isConnecting: true),
            .connectingDisabled
        )
    }

    func testServerPropertyEditorEnablesSaveOnlyForValidChangedValues() {
        let editor = ServerPropertyEditorModel(
            server: editableServerFixture(),
            credentialSummary: "继承自全局账户"
        )

        XCTAssertFalse(editor.canSave)
        editor.portText = "70000"
        XCTAssertEqual(editor.portError, "端口必须是 1–65535 之间的整数。")
        XCTAssertFalse(editor.canSave)
        editor.portText = "3390"
        XCTAssertTrue(editor.canSave)
    }

    func testServerPropertyEditorValidatesHostAndTreatsTrimmedValuesAsUnchanged() {
        let editor = ServerPropertyEditorModel(
            server: editableServerFixture(),
            credentialSummary: "继承自全局账户"
        )

        editor.host = "rdp example.com"
        XCTAssertEqual(editor.hostError, "请输入有效的 IP 地址或主机名。")
        editor.host = "https://rdp.example.com"
        XCTAssertEqual(editor.hostError, "请输入有效的 IP 地址或主机名。")
        editor.host = " /rdp.example.com "
        XCTAssertEqual(editor.hostError, "请输入有效的 IP 地址或主机名。")
        editor.host = "  rdp.example.com  "
        editor.name = "  测试服务器  "
        editor.portText = " 3389 "
        XCTAssertNil(editor.hostError)
        XCTAssertFalse(editor.canSave)
    }

    func testServerPropertyEditorDisablesSavingAndKeepsSafeFailureMessage() async {
        let editor = ServerPropertyEditorModel(
            server: editableServerFixture(),
            credentialSummary: "继承自全局账户"
        )
        editor.portText = "3390"

        let succeeded = await editor.save { _ in
            throw ResourceLibraryOperationError.configurationSaveFailed
        }

        XCTAssertFalse(succeeded)
        XCTAssertFalse(editor.isSaving)
        XCTAssertEqual(editor.saveError, "无法保存资源库，请检查磁盘权限后重试。")
        XCTAssertTrue(editor.canSave)
    }

    func testServerPropertyEditorClosesOnlyAfterSuccessfulSave() async {
        let editor = ServerPropertyEditorModel(
            server: editableServerFixture(),
            credentialSummary: "继承自全局账户"
        )
        editor.portText = "3390"
        var savedDraft: ServerPropertiesDraft?

        let succeeded = await editor.save { savedDraft = $0 }

        XCTAssertTrue(succeeded)
        XCTAssertEqual(savedDraft?.port, 3390)
        XCTAssertNil(editor.saveError)
    }

    func testGroupPropertyEditorRejectsDuplicateSiblingName() {
        let editor = GroupPropertyEditorModel(
            group: editableGroupFixture(),
            siblingNames: ["生产", "测试"]
        )

        editor.name = "测试"
        XCTAssertEqual(editor.nameError, "同一群组下已存在这个名称。")
        XCTAssertFalse(editor.canSave)
    }

    func testGroupPropertyEditorTrimsNameAndDisablesSaveWhileSaving() {
        let editor = GroupPropertyEditorModel(
            group: editableGroupFixture(),
            siblingNames: ["生产", "测试"]
        )

        editor.name = "  生产  "
        XCTAssertFalse(editor.canSave)
        editor.name = ""
        XCTAssertEqual(editor.nameError, "名称不能为空。")
        editor.name = "新名称"
        XCTAssertTrue(editor.canSave)
        editor.isSaving = true
        XCTAssertFalse(editor.canSave)
    }

    func testResourcePropertyRouteResolvesServerAndGroupContext() throws {
        let library = fixtureLibrary()
        let server = try XCTUnwrap(library.servers.first)
        let group = try XCTUnwrap(library.groups.first { $0.parentID != nil })

        let serverContext = ResourcePropertyPresentation.resolve(
            route: .server(id: server.id), library: library, configuration: .default
        )
        let groupContext = ResourcePropertyPresentation.resolve(
            route: .group(id: group.id), library: library, configuration: .default
        )

        XCTAssertEqual(serverContext?.resourceID, server.id)
        XCTAssertEqual(serverContext?.credentialSummary, "未设置凭据")
        XCTAssertEqual(groupContext?.resourceID, group.id)
        XCTAssertEqual(groupContext?.credentialSummary, "继承凭据")
    }

    func testResourceCredentialHandoffWaitsForDismissalAndConsumesOnce() {
        let coordinator = ResourcePropertySheetCoordinator()
        let route = ResourceEditorRoute.server(id: "server-a")
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let scope = CredentialEditScope.server(id: "server-a", displayName: "A")
        let lease = coordinator.register(host: host)
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: route,
                lease: lease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )

        var requestedRoute: ResourceEditorRoute? = route
        let resourcePresentation = try! XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: requestedRoute, lease: lease
        ))
        XCTAssertEqual(resourcePresentation.route, route)

        XCTAssertTrue(coordinator.requestCredentialHandoff(
            scope: scope, lease: lease, from: route
        ))
        XCTAssertFalse(coordinator.requestCredentialHandoff(
            scope: scope, lease: lease, from: route
        ))
        requestedRoute = nil
        XCTAssertNil(coordinator.resourcePresentation(
            requestedRoute: requestedRoute, lease: lease
        ))
        XCTAssertTrue(coordinator.hasActivePresentation)
        let delivered = coordinator.completeResourceDismissal(
            presentation: resourcePresentation,
            activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        )
        // The first onDismiss consumes the handoff exactly once and releases ownership.
        XCTAssertEqual(
            delivered,
            CredentialEditorPresentation(scope: scope, host: host)
        )
        XCTAssertFalse(coordinator.hasActivePresentation)
        XCTAssertNil(coordinator.completeResourceDismissal(
            presentation: resourcePresentation,
            activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        ))
    }

    func testStalePropertySaveCannotCloseReplacementRoute() {
        let coordinator = ResourcePropertySheetCoordinator()
        let routeA = ResourceEditorRoute.server(id: "server-a")
        let routeB = ResourceEditorRoute.group(id: "group-b")
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let lease = coordinator.register(host: host)
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: routeA,
                lease: lease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
        let presentationA = try! XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: routeA, lease: lease
        ))
        let staleToken = try! XCTUnwrap(coordinator.beginSave(for: presentationA))

        XCTAssertEqual(
            coordinator.claimPresentation(
                route: routeB,
                lease: lease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .waitingForCurrentDismissal
        )

        XCTAssertFalse(coordinator.shouldCloseAfterSave(
            token: staleToken,
            currentPresentation: presentationA,
            currentRoute: routeB,
            currentOwnerLease: lease
        ))
        XCTAssertNil(coordinator.completeResourceDismissal(
            presentation: presentationA,
            activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        ))
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: routeB,
                lease: lease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
        let presentationB = try! XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: routeB, lease: lease
        ))
        let currentToken = try! XCTUnwrap(coordinator.beginSave(for: presentationB))
        XCTAssertTrue(coordinator.shouldCloseAfterSave(
            token: currentToken,
            currentPresentation: presentationB,
            currentRoute: routeB,
            currentOwnerLease: lease
        ))
        XCTAssertFalse(coordinator.shouldCloseAfterSave(
            token: currentToken,
            currentPresentation: presentationB,
            currentRoute: routeB,
            currentOwnerLease: lease
        ))
    }

    func testDisappearingPropertySheetInvalidatesSaveCompletionAndPendingHandoff() {
        let coordinator = ResourcePropertySheetCoordinator()
        let routeA = ResourceEditorRoute.server(id: "server-a")
        let routeB = ResourceEditorRoute.server(id: "server-b")
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let oldLease = coordinator.register(host: host)
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: routeA,
                lease: oldLease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
        let presentationA = try! XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: routeA, lease: oldLease
        ))
        let token = try! XCTUnwrap(coordinator.beginSave(for: presentationA))
        XCTAssertTrue(coordinator.requestCredentialHandoff(
            scope: .server(id: "server-a", displayName: "A"),
            lease: oldLease,
            from: routeA
        ))

        coordinator.unregister(lease: oldLease)
        let newLease = coordinator.register(host: host)
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: routeB,
                lease: newLease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
        let presentationB = try! XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: routeB, lease: newLease
        ))

        XCTAssertFalse(coordinator.shouldCloseAfterSave(
            token: token,
            currentPresentation: presentationB,
            currentRoute: routeB,
            currentOwnerLease: newLease
        ))
        XCTAssertNil(coordinator.completeResourceDismissal(
            presentation: presentationB,
            activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        ))
    }

    func testResourcePresentationIsBlockedWhileCredentialEditorIsActive() {
        let coordinator = ResourcePropertySheetCoordinator()
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let credential = CredentialEditorPresentation(scope: .global, host: host)
        let lease = coordinator.register(host: host)

        XCTAssertEqual(
            coordinator.claimPresentation(
                route: .server(id: "server-a"),
                lease: lease,
                activeCredential: credential,
                isOneTimeCredentialPromptRequested: false
            ),
            .blockedByCredentialEditor
        )
        XCTAssertNil(coordinator.resourcePresentation(
            requestedRoute: .server(id: "server-a"), lease: lease
        ))
    }

    func testPendingHandoffNeverOverwritesExistingCredentialPresentation() {
        let coordinator = ResourcePropertySheetCoordinator()
        let route = ResourceEditorRoute.server(id: "server-a")
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let existing = CredentialEditorPresentation(scope: .global, host: host)
        let lease = coordinator.register(host: host)
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: route,
                lease: lease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
        let resourcePresentation = try! XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: route, lease: lease
        ))
        XCTAssertTrue(coordinator.requestCredentialHandoff(
            scope: .server(id: "server-a", displayName: "A"),
            lease: lease,
            from: route
        ))

        XCTAssertNil(coordinator.completeResourceDismissal(
            presentation: resourcePresentation,
            activeCredential: existing,
            isOneTimeCredentialPromptRequested: false
        ))
        XCTAssertNil(coordinator.completeResourceDismissal(
            presentation: resourcePresentation,
            activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        ))
    }

    func testOnlyOneWindowHostOwnsResourcePropertyPresentation() {
        let coordinator = ResourcePropertySheetCoordinator()
        let route = ResourceEditorRoute.group(id: "group-a")
        let hostA = CredentialEditorHost.primaryWindow(id: UUID())
        let hostB = CredentialEditorHost.primaryWindow(id: UUID())
        let leaseA = coordinator.register(host: hostA)
        let leaseB = coordinator.register(host: hostB)

        XCTAssertEqual(
            coordinator.claimPresentation(
                route: route,
                lease: leaseA,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: route,
                lease: leaseB,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .ownedByAnotherWindow
        )
        XCTAssertEqual(
            coordinator.resourcePresentation(requestedRoute: route, lease: leaseA)?.route,
            route
        )
        XCTAssertNil(coordinator.resourcePresentation(
            requestedRoute: route, lease: leaseB
        ))
    }

    func testDoubleSaveClaimCreatesOneTokenAndDisappearInvalidatesWholeRoute() {
        let coordinator = ResourcePropertySheetCoordinator()
        let route = ResourceEditorRoute.server(id: "server-a")
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let lease = coordinator.register(host: host)
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: route,
                lease: lease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
        let presentation = try! XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: route, lease: lease
        ))

        let first = coordinator.beginSave(for: presentation)
        let second = coordinator.beginSave(for: presentation)

        XCTAssertNotNil(first)
        XCTAssertNil(second)
        coordinator.invalidateSaves(for: presentation)
        XCTAssertFalse(coordinator.shouldCloseAfterSave(
            token: try! XCTUnwrap(first),
            currentPresentation: presentation,
            currentRoute: route,
            currentOwnerLease: lease
        ))
        XCTAssertNotNil(coordinator.beginSave(for: presentation))
    }

    func testSharedModalBindingHarnessFiltersSettingsAndOneTimeCredentialSheets() {
        let coordinator = ResourcePropertySheetCoordinator()
        let route = ResourceEditorRoute.server(id: "server-a")
        let primaryHost = CredentialEditorHost.primaryWindow(id: UUID())
        let settingsCredential = CredentialEditorPresentation(
            scope: .global, host: .settingsWindow
        )
        let primaryLease = coordinator.register(host: primaryHost)
        let settingsLease = coordinator.register(host: .settingsWindow)
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: route,
                lease: primaryLease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )

        XCTAssertNil(coordinator.credentialBindingPresentation(
            settingsCredential, lease: settingsLease
        ))
        XCTAssertNil(coordinator.oneTimeCredentialPresentation(
            requested: true, activeCredential: nil, lease: primaryLease
        ))

        let resourcePresentation = try! XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: route, lease: primaryLease
        ))
        XCTAssertNil(coordinator.completeResourceDismissal(
            presentation: resourcePresentation,
            activeCredential: settingsCredential,
            isOneTimeCredentialPromptRequested: true
        ))
        XCTAssertEqual(
            coordinator.credentialBindingPresentation(
                settingsCredential, lease: settingsLease
            ),
            settingsCredential
        )
        XCTAssertNil(coordinator.oneTimeCredentialPresentation(
            requested: true, activeCredential: settingsCredential, lease: primaryLease
        ))
        let prompt = coordinator.claimOneTimeCredentialPrompt(
            lease: primaryLease, requested: true, activeCredential: nil
        )
        XCTAssertNotNil(prompt)
        XCTAssertEqual(coordinator.oneTimeCredentialPresentation(
            requested: true, activeCredential: nil, lease: primaryLease
        ), prompt)
    }

    func testOneTimeCredentialPromptBlocksResourceClaim() {
        let coordinator = ResourcePropertySheetCoordinator()
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let lease = coordinator.register(host: host)

        XCTAssertEqual(
            coordinator.claimPresentation(
                route: .group(id: "group-a"),
                lease: lease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: true
            ),
            .blockedByCredentialEditor
        )
        XCTAssertNil(coordinator.resourcePresentation(
            requestedRoute: .group(id: "group-a"), lease: lease
        ))
    }

    func testQueuedCredentialAndRouteReplacementReleaseDismissedOwnerWithoutStarvation() {
        let coordinator = ResourcePropertySheetCoordinator()
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let routeA = ResourceEditorRoute.server(id: "server-a")
        let routeB = ResourceEditorRoute.server(id: "server-b")
        let queuedCredential = CredentialEditorPresentation(scope: .global, host: host)
        let lease = coordinator.register(host: host)
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: routeA,
                lease: lease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
        let presentationA = try! XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: routeA, lease: lease
        ))

        XCTAssertEqual(
            coordinator.claimPresentation(
                route: routeB,
                lease: lease,
                activeCredential: queuedCredential,
                isOneTimeCredentialPromptRequested: false
            ),
            .blockedByCredentialEditor
        )
        XCTAssertNil(coordinator.resourcePresentation(
            requestedRoute: routeB, lease: lease
        ))
        XCTAssertNil(coordinator.completeResourceDismissal(
            presentation: presentationA,
            activeCredential: queuedCredential,
            isOneTimeCredentialPromptRequested: false
        ))
        XCTAssertFalse(coordinator.hasActiveResourcePresentation)
        XCTAssertEqual(
            coordinator.credentialBindingPresentation(queuedCredential, lease: lease),
            queuedCredential
        )
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: routeB,
                lease: lease,
                activeCredential: queuedCredential,
                isOneTimeCredentialPromptRequested: false
            ),
            .blockedByCredentialEditor
        )
    }

    func testOneTimePromptHasExactlyOneWindowOwnerAndCanTransferAfterRelease() {
        let coordinator = ResourcePropertySheetCoordinator()
        let hostA = CredentialEditorHost.primaryWindow(id: UUID())
        let hostB = CredentialEditorHost.primaryWindow(id: UUID())
        let leaseA = coordinator.register(host: hostA)
        let leaseB = coordinator.register(host: hostB)

        let promptA = coordinator.claimOneTimeCredentialPrompt(
            lease: leaseA, requested: true, activeCredential: nil
        )
        XCTAssertNotNil(promptA)
        XCTAssertNil(coordinator.claimOneTimeCredentialPrompt(
            lease: leaseB, requested: true, activeCredential: nil
        ))
        XCTAssertEqual(coordinator.oneTimeCredentialPresentation(
            requested: true, activeCredential: nil, lease: leaseA
        ), promptA)
        XCTAssertNil(coordinator.oneTimeCredentialPresentation(
            requested: true, activeCredential: nil, lease: leaseB
        ))

        XCTAssertTrue(coordinator.dismissOneTimeCredentialPrompt(
            try! XCTUnwrap(promptA)
        ))

        let promptB = coordinator.claimOneTimeCredentialPrompt(
            lease: leaseB, requested: true, activeCredential: nil
        )
        XCTAssertNotNil(promptB)
        XCTAssertEqual(coordinator.oneTimeCredentialPresentation(
            requested: true, activeCredential: nil, lease: leaseB
        ), promptB)
    }

    func testUnregisteredHostCannotReclaimAfterLateDismissalCallbacks() {
        let coordinator = ResourcePropertySheetCoordinator()
        let hostA = CredentialEditorHost.primaryWindow(id: UUID())
        let hostB = CredentialEditorHost.primaryWindow(id: UUID())
        let leaseA = coordinator.register(host: hostA)
        let leaseB = coordinator.register(host: hostB)

        XCTAssertNotNil(coordinator.claimOneTimeCredentialPrompt(
            lease: leaseA, requested: true, activeCredential: nil
        ))
        coordinator.unregister(lease: leaseA)

        // A late onDismiss/revision callback from the vanished window must not
        // resurrect that host or steal the globally preserved prompt request.
        XCTAssertNil(coordinator.claimOneTimeCredentialPrompt(
            lease: leaseA, requested: true, activeCredential: nil
        ))
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: .server(id: "late-a"),
                lease: leaseA,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .hostInactive
        )
        XCTAssertNil(coordinator.credentialBindingPresentation(
            CredentialEditorPresentation(scope: .global, host: hostA),
            lease: leaseA
        ))
        XCTAssertFalse(coordinator.hasActivePresentation)
        let promptB = coordinator.claimOneTimeCredentialPrompt(
            lease: leaseB, requested: true, activeCredential: nil
        )
        XCTAssertNotNil(promptB)
        XCTAssertEqual(coordinator.oneTimeCredentialPresentation(
            requested: true, activeCredential: nil, lease: leaseB
        ), promptB)

        XCTAssertTrue(coordinator.dismissOneTimeCredentialPrompt(
            try! XCTUnwrap(promptB)
        ))
        let newLeaseA = coordinator.register(host: hostA)
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: .server(id: "new-lifecycle-a"),
                lease: newLeaseA,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
    }

    func testOldLeaseCannotClearNewOneTimeOrPersistentPresentation() throws {
        let coordinator = ResourcePropertySheetCoordinator()
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let oldLease = coordinator.register(host: host)
        let oldPrompt = try XCTUnwrap(coordinator.claimOneTimeCredentialPrompt(
            lease: oldLease, requested: true, activeCredential: nil
        ))
        coordinator.unregister(lease: oldLease)

        let newLease = coordinator.register(host: host)
        let newPrompt = try XCTUnwrap(coordinator.claimOneTimeCredentialPrompt(
            lease: newLease, requested: true, activeCredential: nil
        ))
        var isPromptRequested = true

        if coordinator.canDismissOneTimeCredentialPrompt(oldPrompt) {
            isPromptRequested = false
        }
        XCTAssertTrue(isPromptRequested)
        XCTAssertEqual(
            coordinator.oneTimeCredentialPresentation(
                requested: isPromptRequested,
                activeCredential: nil,
                lease: newLease
            ),
            newPrompt
        )
        XCTAssertNil(coordinator.oneTimeCredentialPresentation(
            requested: isPromptRequested,
            activeCredential: nil,
            lease: oldLease
        ))
        XCTAssertTrue(coordinator.canDismissOneTimeCredentialPrompt(newPrompt))
        isPromptRequested = false
        XCTAssertTrue(coordinator.dismissOneTimeCredentialPrompt(newPrompt))

        let persistent = CredentialEditorPresentation(scope: .global, host: host)
        XCTAssertNil(coordinator.credentialBindingPresentation(
            persistent, lease: oldLease
        ))
        XCTAssertFalse(coordinator.canDismissCredentialPresentation(
            persistent, lease: oldLease
        ))
        XCTAssertEqual(
            coordinator.credentialBindingPresentation(persistent, lease: newLease),
            persistent
        )
        XCTAssertFalse(isPromptRequested)
    }

    func testOldResourcePresentationCannotDismissNewLifecycleRoute() throws {
        let coordinator = ResourcePropertySheetCoordinator()
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let routeA = ResourceEditorRoute.server(id: "old-a")
        let routeB = ResourceEditorRoute.server(id: "new-b")
        let oldLease = coordinator.register(host: host)
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: routeA,
                lease: oldLease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
        let oldPresentation = try XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: routeA, lease: oldLease
        ))
        coordinator.unregister(lease: oldLease)

        let newLease = coordinator.register(host: host)
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: routeB,
                lease: newLease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
        let newPresentation = try XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: routeB, lease: newLease
        ))

        XCTAssertNil(coordinator.completeResourceDismissal(
            presentation: oldPresentation,
            activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        ))
        XCTAssertEqual(
            coordinator.resourcePresentation(requestedRoute: routeB, lease: newLease),
            newPresentation
        )
        XCTAssertNil(coordinator.claimOneTimeCredentialPrompt(
            lease: oldLease, requested: true, activeCredential: nil
        ))
        XCTAssertNil(coordinator.completeResourceDismissal(
            presentation: newPresentation,
            activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        ))
        XCTAssertNil(coordinator.resourcePresentation(
            requestedRoute: routeB, lease: newLease
        ))
    }

    func testOldPresentationCannotInvalidateNewSameRouteSave() throws {
        let coordinator = ResourcePropertySheetCoordinator()
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let route = ResourceEditorRoute.server(id: "same-server")
        let oldLease = coordinator.register(host: host)
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: route,
                lease: oldLease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
        let oldPresentation = try XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: route, lease: oldLease
        ))
        coordinator.unregister(lease: oldLease)

        let newLease = coordinator.register(host: host)
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: route,
                lease: newLease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
        let newPresentation = try XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: route, lease: newLease
        ))
        let newToken = try XCTUnwrap(coordinator.beginSave(for: newPresentation))
        XCTAssertNil(coordinator.beginSave(for: newPresentation))

        coordinator.invalidateSaves(for: oldPresentation)

        XCTAssertTrue(coordinator.shouldCloseAfterSave(
            token: newToken,
            currentPresentation: newPresentation,
            currentRoute: route,
            currentOwnerLease: newLease
        ))
        let invalidatedToken = try XCTUnwrap(coordinator.beginSave(for: newPresentation))
        coordinator.invalidateSaves(for: newPresentation)
        XCTAssertFalse(coordinator.shouldCloseAfterSave(
            token: invalidatedToken,
            currentPresentation: newPresentation,
            currentRoute: route,
            currentOwnerLease: newLease
        ))
    }

    func testRouteReplacementWaitsForActualPresentedRouteToDismiss() {
        let coordinator = ResourcePropertySheetCoordinator()
        let host = CredentialEditorHost.primaryWindow(id: UUID())
        let routeA = ResourceEditorRoute.server(id: "server-a")
        let routeB = ResourceEditorRoute.server(id: "server-b")
        let lease = coordinator.register(host: host)

        XCTAssertEqual(
            coordinator.claimPresentation(
                route: routeA,
                lease: lease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
        let presentationA = try! XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: routeA, lease: lease
        ))
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: routeB,
                lease: lease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .waitingForCurrentDismissal
        )
        XCTAssertEqual(presentationA.route, routeA)
        XCTAssertNil(coordinator.resourcePresentation(
            requestedRoute: routeB, lease: lease
        ))

        XCTAssertNil(coordinator.completeResourceDismissal(
            presentation: presentationA,
            activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        ))
        XCTAssertEqual(
            coordinator.claimPresentation(
                route: routeB,
                lease: lease,
                activeCredential: nil,
                isOneTimeCredentialPromptRequested: false
            ),
            .claimed
        )
        let presentationB = try! XCTUnwrap(coordinator.resourcePresentation(
            requestedRoute: routeB, lease: lease
        ))
        XCTAssertNil(coordinator.completeResourceDismissal(
            presentation: presentationA,
            activeCredential: nil,
            isOneTimeCredentialPromptRequested: false
        ))
        XCTAssertEqual(coordinator.resourcePresentation(
            requestedRoute: routeB, lease: lease
        ), presentationB)
    }

    func testHostDisappearanceCleanupIsScopedToMatchingPrimaryCredential() {
        let coordinator = ResourcePropertySheetCoordinator()
        let hostA = CredentialEditorHost.primaryWindow(id: UUID())
        let hostB = CredentialEditorHost.primaryWindow(id: UUID())
        let credentialA = CredentialEditorPresentation(
            scope: .server(id: "a", displayName: "A"), host: hostA
        )
        let credentialB = CredentialEditorPresentation(
            scope: .server(id: "b", displayName: "B"), host: hostB
        )
        let settingsCredential = CredentialEditorPresentation(
            scope: .global, host: .settingsWindow
        )
        let leaseA = coordinator.register(host: hostA)
        let leaseB = coordinator.register(host: hostB)
        let settingsLease = coordinator.register(host: .settingsWindow)

        XCTAssertTrue(coordinator.canDismissCredentialPresentation(
            credentialA, lease: leaseA
        ))
        XCTAssertFalse(coordinator.canDismissCredentialPresentation(
            credentialB, lease: leaseA
        ))
        XCTAssertFalse(coordinator.canDismissCredentialPresentation(
            settingsCredential, lease: leaseA
        ))
        XCTAssertTrue(coordinator.canDismissCredentialPresentation(
            credentialB, lease: leaseB
        ))
        XCTAssertTrue(coordinator.canDismissCredentialPresentation(
            settingsCredential, lease: settingsLease
        ))
        coordinator.unregister(lease: leaseA)
        XCTAssertFalse(coordinator.canDismissCredentialPresentation(
            credentialA, lease: leaseA
        ))
    }

    func testSettingsCategoriesAreExactlyApprovedOrder() {
        XCTAssertEqual(
            RdcSettingsCategory.allCases.map(\.title),
            ["通用", "全局凭据", "凭据覆盖", "证书", "关于"]
        )
    }

    func testCompactWindowChromeRemovesLargeTopDeadZones() {
        XCTAssertTrue(RdcCompactWindowLayout.extendsContentIntoTitlebar)
        XCTAssertEqual(RdcCompactWindowLayout.sidebarHeaderTopPadding, 32)
        XCTAssertEqual(RdcCompactWindowLayout.sessionHeaderBandHeight, 48)
        XCTAssertLessThanOrEqual(RdcCompactWindowLayout.workspaceToolbarTopPadding, 10)
        XCTAssertLessThanOrEqual(RdcCompactWindowLayout.workspaceCanvasTopPadding, 58)
        XCTAssertGreaterThanOrEqual(RdcCompactWindowLayout.sidebarHeaderTopPadding, 32)
        XCTAssertEqual(RdcCompactWindowLayout.minimumDragRegionWidth, 120)
        XCTAssertGreaterThanOrEqual(RdcCompactWindowLayout.dragRegionMinX, RdcCompactWindowLayout.trafficLightClearanceMaxX)
        XCTAssertLessThanOrEqual(RdcCompactWindowLayout.dragRegionMaxX, RdcCompactWindowLayout.toolbarMinX)
        XCTAssertLessThanOrEqual(RdcCompactWindowLayout.sidebarContentMaxX, RdcCompactWindowLayout.workspaceCanvasMinX)
        XCTAssertLessThanOrEqual(RdcCompactWindowLayout.toolbarMaxY, RdcCompactWindowLayout.workspaceCanvasTopPadding)
        XCTAssertEqual(RdcCompactWindowLayout.workspaceCanvasTopPadding, RdcCompactWindowLayout.workspaceCanvasMinY)
    }

    func testAdaptiveToolbarPolicyUsesExactWideMediumAndNarrowBoundaries() {
        XCTAssertEqual(SessionToolbarPolicy(width: SessionToolbarMetrics.wideBreakpoint).widthClass, .wide)
        XCTAssertEqual(SessionToolbarPolicy(width: SessionToolbarMetrics.wideBreakpoint - 0.01).widthClass, .medium)
        XCTAssertEqual(SessionToolbarPolicy(width: SessionToolbarMetrics.mediumBreakpoint).widthClass, .medium)
        XCTAssertEqual(SessionToolbarPolicy(width: SessionToolbarMetrics.mediumBreakpoint - 0.01).widthClass, .narrow)
    }

    func testAdaptiveToolbarPolicyKeepsExactActionOrderWithoutClipping() {
        let wide = SessionToolbarPolicy(width: 980)
        XCTAssertEqual(wide.visibleActions, [.fullscreen, .secureAttention, .clipboard, .more])
        XCTAssertEqual(wide.overflowActions, [])

        for width in [720.0, 820.0] {
            let compact = SessionToolbarPolicy(width: width)
            XCTAssertEqual(compact.visibleActions, [.fullscreen, .more])
            XCTAssertEqual(compact.overflowActions, [.secureAttention, .clipboard])
        }
    }

    func testAdaptiveToolbarPolicyUsesFixedTitleAndElapsedWidths() {
        XCTAssertEqual(SessionToolbarPolicy(width: 980).layout.titleWidth, SessionToolbarMetrics.wideTitleWidth)
        XCTAssertEqual(SessionToolbarPolicy(width: 820).layout.titleWidth, SessionToolbarMetrics.mediumTitleWidth)
        XCTAssertEqual(SessionToolbarPolicy(width: 720).layout.titleWidth, SessionToolbarMetrics.narrowTitleWidth)
        XCTAssertEqual(SessionToolbarPolicy(width: 720).layout.elapsedWidth, SessionToolbarMetrics.elapsedWidth)
    }

    func testLongChineseTitleUsesTheRealMiddleTruncatingTitleSlot() {
        let layout = SessionToolbarPolicy(width: 760).layout
        let title = layout.titlePresentation(for: "这是一个非常长的中文服务器名称-生产环境-华东区域")

        XCTAssertEqual(title.text, "这是一个非常长的中文服务器名称-生产环境-华东区域")
        XCTAssertEqual(title.width, SessionToolbarMetrics.mediumTitleWidth)
        XCTAssertEqual(title.truncation, .middle)
    }

    func testAdaptiveToolbarPoliciesFitAfterTheWindowDragRegion() {
        XCTAssertEqual(
            RdcCompactWindowLayout.toolbarContentLeadingInset,
            RdcCompactWindowLayout.toolbarMinX - RdcCompactWindowLayout.sidebarContentMaxX
        )
        for width in [
            SessionToolbarMetrics.wideBreakpoint,
            SessionToolbarMetrics.mediumBreakpoint,
            RdcCompactWindowLayout.workspaceWidthAtMinimumRoot
        ] {
            let policy = SessionToolbarPolicy(width: width)
            XCTAssertLessThanOrEqual(policy.layout.minimumRequiredWidth, width)
        }
        XCTAssertEqual(RdcCompactWindowLayout.workspaceWidthAtMinimumRoot, 753)
        XCTAssertEqual(
            SessionToolbarPolicy(width: RdcCompactWindowLayout.workspaceWidthAtMinimumRoot).widthClass,
            .narrow
        )
        XCTAssertEqual(
            SessionToolbarPolicy(width: SessionToolbarMetrics.wideBreakpoint).layout.actionWidths[.fullscreen],
            SessionToolbarMetrics.fullscreenWidth
        )
    }

    func testMoreMenuContainsOnlyOverflowAndUniqueCommands() {
        XCTAssertEqual(
            SessionToolbarPolicy(width: 980).menuCommands,
            [.copyServerAddress]
        )
        XCTAssertEqual(
            SessionToolbarPolicy(width: 820).menuCommands,
            [.secureAttention, .clipboard, .copyServerAddress]
        )
    }

    func testElapsedFormatterKeepsFixedDisplayCompactAtOneHundredHours() {
        XCTAssertEqual(SessionElapsedTimeFormatter.display(seconds: 359_999), "99:59:59")
        XCTAssertEqual(SessionElapsedTimeFormatter.display(seconds: 360_000), "99h+")
        XCTAssertEqual(SessionElapsedTimeFormatter.accessibility(seconds: 360_000), "100小时0分0秒")
    }

    func testConnectionAccessibilityDescriptorIncludesActionServerStateDurationAndSignal() {
        let connected = SessionConnectionAccessibilityDescriptor(
            serverName: "一台名称很长的生产服务器",
            isConnected: true,
            elapsedSeconds: 360_000
        )
        XCTAssertEqual(connected.label, "断开连接，一台名称很长的生产服务器")
        XCTAssertEqual(connected.value, "已连接，已连接时间100小时0分0秒，连接信号已显示")

        let disconnected = SessionConnectionAccessibilityDescriptor(
            serverName: "测试服务器",
            isConnected: false,
            elapsedSeconds: nil
        )
        XCTAssertEqual(disconnected.label, "连接，测试服务器")
        XCTAssertEqual(disconnected.value, "未连接，尚未开始计时，连接信号不可用")
    }

    func testCredentialEditorRoutesToExactlyOneWindowAndCannotDismissWhileSaving() {
        let windowA = CredentialEditorHost.primaryWindow(id: UUID())
        let windowB = CredentialEditorHost.primaryWindow(id: UUID())
        let presentation = CredentialEditorPresentation(
            scope: .server(id: "server", displayName: "Server"),
            host: windowA
        )

        XCTAssertTrue(presentation.isPresented(in: windowA))
        XCTAssertFalse(presentation.isPresented(in: windowB))
        XCTAssertFalse(presentation.isPresented(in: .settingsWindow))
        XCTAssertNotEqual(windowA, windowB)
        XCTAssertFalse(CredentialEditorDismissalPolicy.canDismiss(isSaving: true))
        XCTAssertTrue(CredentialEditorDismissalPolicy.canDismiss(isSaving: false))
    }

    func testGlobalDeletionFeedbackDistinguishesPreservedAndCommittedTransactions() {
        XCTAssertEqual(
            GlobalCredentialDeletionError.configurationCommitFailed.safeMessage,
            "无法删除全局凭据；原凭据已安全保留，请重试。"
        )
        XCTAssertEqual(
            GlobalCredentialDeletionError.committedRefreshFailed.safeMessage,
            "全局凭据已删除，但界面刷新失败；请重新打开设置或重启应用。"
        )
        XCTAssertFalse(GlobalCredentialDeletionError.rollbackFailed.safeMessage.contains("已安全保留"))
    }

    func testResizePreferenceGatesRemoteResizeCallbacks() {
        var received: [(Int, Int)] = []
        let coordinator = RemoteDesktopSurface.Coordinator(
            resizesWithWindow: false,
            onResize: { received.append(($0, $1)) },
            onPointer: { _ in }, onKey: { _ in }, onUnicode: { _ in }
        )

        coordinator.handleResize(width: 1280, height: 720)
        XCTAssertTrue(received.isEmpty)
        coordinator.resizesWithWindow = true
        coordinator.handleResize(width: 1440, height: 900)
        XCTAssertEqual(received.map { [$0.0, $0.1] }, [[1440, 900]])
    }

    func testWindowDisappearDoesNotTerminateSharedModelButApplicationTerminationDoes() {
        XCTAssertFalse(RdcAppLifecycle.shouldShutdown(for: .rootWindowDisappeared))
        XCTAssertTrue(RdcAppLifecycle.shouldShutdown(for: .applicationWillTerminate))
    }

    func testGlobalCredentialStateCountsInheritanceAndOverrides() throws {
        let library = fixtureLibrary()
        let firstGroup = try XCTUnwrap(library.groups.last?.id)
        let firstServer = try XCTUnwrap(library.servers.first { $0.groupPathIDs.contains(firstGroup) }?.id)
        let configuration = RdcAppConfiguration(
            globalCredentialID: "global",
            groupCredentialBindings: [firstGroup: "group"],
            serverCredentialBindings: [firstServer: "server"],
            credentialMetadata: [
                "global": CredentialMetadata(id: "global", username: "Administrator", domain: "LAB")
            ]
        )

        let state = GlobalCredentialSettingsState(configuration: configuration, library: library)

        XCTAssertEqual(state.username, "Administrator")
        XCTAssertEqual(state.domain, "LAB")
        XCTAssertEqual(state.keychainStatusText, "安全存储在 macOS 钥匙串")
        XCTAssertEqual(state.globalInheritanceCount, 1)
        XCTAssertEqual(state.groupOverrideCount, 1)
        XCTAssertEqual(state.serverOverrideCount, 1)
    }

    func testSharedGlobalDeletionCountsOnlyServersLosingGlobalInheritance() throws {
        let library = fixtureLibrary()
        let groupID = try XCTUnwrap(library.groups.last?.id)
        let groupedServerID = try XCTUnwrap(
            library.servers.first { $0.groupPathIDs.contains(groupID) }?.id
        )
        let configuration = RdcAppConfiguration(
            globalCredentialID: "shared",
            groupCredentialBindings: [groupID: "shared"],
            serverCredentialBindings: [groupedServerID: "server"],
            credentialMetadata: [
                "shared": CredentialMetadata(id: "shared", username: "global", domain: nil),
                "server": CredentialMetadata(id: "server", username: "override", domain: nil)
            ]
        )

        let presentation = GlobalCredentialDeletionPresentation(
            configuration: configuration,
            library: library
        )

        XCTAssertEqual(presentation.impactedServerCount, 1)
        XCTAssertTrue(presentation.keepsSharedCredential)
        XCTAssertTrue(presentation.confirmationMessage.contains("钥匙串密码会保留"))
        XCTAssertTrue(presentation.confirmationMessage.contains("独立覆盖不受影响"))
    }

    func testNoCredentialStateIsSafeAndEmpty() {
        let state = GlobalCredentialSettingsState(configuration: .default, library: nil)

        XCTAssertEqual(state.username, "")
        XCTAssertEqual(state.domain, "")
        XCTAssertEqual(state.keychainStatusText, "尚未保存全局凭据")
        XCTAssertEqual(state.globalInheritanceCount, 0)
        XCTAssertFalse(state.hasGlobalCredential)
    }

    func testOverrideRowsExposeSearchableKindAndSourceBadges() throws {
        let library = fixtureLibrary()
        let groupID = try XCTUnwrap(library.groups.first?.id)
        let serverID = try XCTUnwrap(library.servers.first?.id)
        let configuration = RdcAppConfiguration(
            globalCredentialID: "global",
            groupCredentialBindings: [groupID: "group"],
            serverCredentialBindings: [serverID: "server"]
        )

        let rows = CredentialOverrideRowState.makeRows(library: library, configuration: configuration)
        XCTAssertTrue(rows.contains { $0.kind == .group && $0.sourceBadge == "分组覆盖" })
        XCTAssertTrue(rows.contains { $0.kind == .server && $0.sourceBadge == "单台覆盖" })
        XCTAssertTrue(rows.allSatisfy { !$0.searchableText.isEmpty })
    }

    func testRealTemp2ReadOnlyImportHasExpectedProductionScaleAndNoImportedSecret() throws {
        guard let path = ProcessInfo.processInfo.environment["RDC_TEST_RDG_PATH"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set RDC_TEST_RDG_PATH to enable private large-library acceptance coverage")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("RDC_TEST_RDG_PATH does not point to a readable file")
        }
        let document = try RdcManParser().parse(fileAt: url)
        let library = RdcImportedLibrary(
            document: document,
            sourceID: "readonly-acceptance",
            sourceName: url.lastPathComponent
        )
        let snapshot = RdcLibrarySnapshot(
            sourceID: library.sourceID,
            sourceName: library.sourceName,
            document: document
        )

        // RdcImportedLibrary includes its synthetic document root in addition to the
        // 26 RDCMan groups shown to users.
        XCTAssertEqual(library.groups.count - 1, 26)
        XCTAssertEqual(library.servers.count, 564)
        func isSanitized(_ group: RdcGroup) -> Bool {
            group.logonCredentials == nil
                && group.servers.allSatisfy { $0.logonCredentials == nil }
                && group.groups.allSatisfy(isSanitized)
        }
        XCTAssertTrue(isSanitized(snapshot.makeDocument().root))
    }

    func testCertificatePresentationNeverDefaultsToTrustAlwaysAndShowsChangedFingerprints() throws {
        let challenge = try challenge(id: 7, host: "rdp.example.com", fingerprintSeed: 0)
        let old = CertificatePin(
            endpoint: challenge.endpoint,
            subject: "old.example.com",
            issuer: "Old CA",
            sha256Fingerprint: "AA:BB:CC",
            notBefore: nil,
            notAfter: nil,
            firstTrustedAt: .distantPast,
            lastConfirmedAt: .distantPast
        )
        let state = CertificateTrustSheetState(presentation: .changed(old: old, new: challenge))

        XCTAssertNotEqual(state.defaultDecision, .trustAlways)
        XCTAssertEqual(state.persistentActionTitle, "更新并始终信任")
        XCTAssertEqual(state.oldFingerprint, "AA:BB:CC")
        XCTAssertEqual(state.newFingerprint, challenge.sha256Fingerprint.uppercased())
    }

    func testSharedModalLeaseAllowsOnlyOneWindowAndIgnoresOldDismissal() {
        let coordinator = ResourcePropertySheetCoordinator()
        let leaseA = coordinator.register(host: .primaryWindow(id: UUID()))
        let leaseB = coordinator.register(host: .primaryWindow(id: UUID()))
        let attemptA = UUID()
        let attemptB = UUID()
        let kindA = ResourcePropertySheetCoordinator.SharedModalKind.certificate(
            attemptID: attemptA, challengeID: 7
        )
        XCTAssertEqual(
            coordinator.claimSharedModal(kind: kindA, lease: leaseA, activeCredential: nil),
            .claimed
        )
        XCTAssertEqual(
            coordinator.claimSharedModal(kind: .importer, lease: leaseB, activeCredential: nil),
            .ownedByAnotherWindow
        )
        let old = try! XCTUnwrap(coordinator.sharedModalPresentation(kind: kindA, lease: leaseA))
        XCTAssertTrue(coordinator.dismissSharedModal(old))

        let kindB = ResourcePropertySheetCoordinator.SharedModalKind.certificate(
            attemptID: attemptB, challengeID: 7
        )
        XCTAssertEqual(
            coordinator.claimSharedModal(kind: kindB, lease: leaseB, activeCredential: nil),
            .claimed
        )
        XCTAssertFalse(coordinator.dismissSharedModal(old))
        XCTAssertNotNil(coordinator.sharedModalPresentation(kind: kindB, lease: leaseB))
    }

    func testCertificateModalKindIsCapturedFromItsOwnAttemptToken() throws {
        let challenge = try challenge(id: 7, host: "rdp.example.com", fingerprintSeed: 0)
        let attemptA = RdpConnectionAttemptID()
        let attemptB = RdpConnectionAttemptID()
        let itemA = CertificateTrustSheetItem(
            .firstUse(challenge),
            token: .init(attemptID: attemptA, challengeID: challenge.id)
        )
        let itemB = CertificateTrustSheetItem(
            .firstUse(challenge),
            token: .init(attemptID: attemptB, challengeID: challenge.id)
        )

        XCTAssertEqual(
            itemA.sharedModalKind,
            ResourcePropertySheetCoordinator.SharedModalKind.certificate(
                attemptID: attemptA.rawValue, challengeID: challenge.id
            )
        )
        XCTAssertNotEqual(itemA.sharedModalKind, itemB.sharedModalKind)
    }

    func testServerPropertyEditorRejectsEmbeddedPortAndAcceptsBareIPv6() {
        let editor = ServerPropertyEditorModel(
            server: editableServerFixture(), credentialSummary: "继承凭据"
        )
        editor.host = "example.com:3390"
        XCTAssertNotNil(editor.hostError)
        XCTAssertFalse(editor.canSave)

        editor.host = "2001:db8::10"
        editor.portText = "3390"
        XCTAssertNil(editor.hostError)
        XCTAssertEqual(editor.draft?.host, "2001:db8::10")
    }

    private func fixtureLibrary() -> RdcImportedLibrary {
        let root = RdcGroup(
            name: "Root",
            isExpanded: true,
            logonCredentials: nil,
            groups: [
                RdcGroup(name: "Team", isExpanded: true, logonCredentials: nil, groups: [], servers: [
                    RdcServer(displayName: "Alpha", address: RdcServerAddress("alpha.example.com"), logonCredentials: nil),
                    RdcServer(displayName: "Beta", address: RdcServerAddress("beta.example.com"), logonCredentials: nil)
                ])
            ],
            servers: [
                RdcServer(displayName: "Gamma", address: RdcServerAddress("gamma.example.com"), logonCredentials: nil)
            ]
        )
        return RdcImportedLibrary(
            document: RdcManDocument(programVersion: "2.7", schemaVersion: "3", root: root),
            sourceID: "settings-fixture",
            sourceName: "temp2.rdg"
        )
    }

    private func deletionSnapshotFixture() -> RdcLibrarySnapshot {
        RdcLibrarySnapshot(
            sourceID: "deletion-presentation-fixture",
            sourceName: "temp2.rdg",
            document: fixtureLibrary().document
        )
    }

    private func editableServerFixture() -> RdcImportedServer {
        RdcImportedServer(
            id: "server-1",
            displayName: "测试服务器",
            address: RdcServerAddress("rdp.example.com:3389"),
            credentials: nil,
            groupPathIDs: ["root", "production"]
        )
    }

    private func editableGroupFixture() -> RdcImportedGroup {
        RdcImportedGroup(
            id: "group-1",
            name: "生产",
            path: ["根", "生产"],
            parentID: "root"
        )
    }

    private func challenge(id: UInt64, host: String, fingerprintSeed: UInt8) throws -> RdpCertificateChallenge {
        // RdcAppTests has no resources; use the stable certificate fixture from the core test bundle path.
        let fallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../RdcCoreTests/Fixtures/test-certificate.pem")
            .standardizedFileURL
        let data = try Data(contentsOf: fallback)
        return try RdpCertificateChallenge(
            id: id,
            endpoint: RdpEndpoint(host: host, port: 3389),
            pemData: data,
            flags: UInt32(fingerprintSeed) | 0x80
        )
    }
}
