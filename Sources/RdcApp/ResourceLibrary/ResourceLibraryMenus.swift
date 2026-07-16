import Foundation
import RdcCore
import SwiftUI

enum ResourceMenuTarget: Equatable {
    case server
    case group
    case rootGroup
}

enum ResourceMenuItem: Equatable {
    case connectOrDisconnect
    case expandOrCollapse
    case properties
    case serverCredential
    case groupCredential
    case newChildGroup
    case moveServer
    case moveGroup
    case separator
    case deleteServer
    case deleteGroup
    case removeLibrary
}

enum ResourceMenuPolicy {
    enum ServerPrimaryAction: Equatable {
        case connect
        case disconnect
        case connectingDisabled
    }

    static func items(
        for target: ResourceMenuTarget,
        isConnected: Bool
    ) -> [ResourceMenuItem] {
        switch target {
        case .server:
            [.connectOrDisconnect, .properties, .serverCredential, .separator,
             .moveServer, .deleteServer]
        case .group:
            [.expandOrCollapse, .properties, .groupCredential, .newChildGroup,
             .moveGroup, .separator, .deleteGroup]
        case .rootGroup:
            [.expandOrCollapse, .properties, .groupCredential, .newChildGroup,
             .separator, .removeLibrary]
        }
    }

    static func serverPrimaryAction(
        isConnected: Bool,
        isConnecting: Bool
    ) -> ServerPrimaryAction {
        if isConnected { return .disconnect }
        if isConnecting { return .connectingDisabled }
        return .connect
    }
}

struct ResourceMoveDestination: Identifiable, Equatable {
    let id: String
    let title: String
    let depth: Int
    let path: [String]

    var menuTitle: String {
        String(repeating: "  ", count: depth) + title
    }

    var accessibilityLabel: String {
        RdcAccessibilityProfile.direction2.moveDestinationLabel(path: path)
    }
}

enum ResourceMoveDestinationPolicy {
    static func serverDestinations(
        in library: RdcImportedLibrary,
        serverID: String
    ) -> [ResourceMoveDestination] {
        guard let server = library.servers.first(where: { $0.id == serverID }) else {
            return []
        }
        let currentParentID = server.groupPathIDs.last
        return orderedGroups(in: library).filter { $0.id != currentParentID }
    }

    static func groupDestinations(
        in library: RdcImportedLibrary,
        groupID: String
    ) -> [ResourceMoveDestination] {
        guard let moving = library.groups.first(where: { $0.id == groupID }),
              moving.parentID != nil else { return [] }
        let excluded = descendantIDs(of: groupID, in: library).union([groupID])
        return orderedGroups(in: library).filter {
            $0.id != moving.parentID && !excluded.contains($0.id)
        }
    }

    private static func orderedGroups(
        in library: RdcImportedLibrary
    ) -> [ResourceMoveDestination] {
        library.groups.map { group in
            ResourceMoveDestination(
                id: group.id,
                title: group.name,
                depth: max(0, group.path.count - 1),
                path: group.path
            )
        }
    }

    private static func descendantIDs(
        of groupID: String,
        in library: RdcImportedLibrary
    ) -> Set<String> {
        var result = Set<String>()
        var frontier = [groupID]
        while let parent = frontier.popLast() {
            for child in library.groups where child.parentID == parent {
                if result.insert(child.id).inserted {
                    frontier.append(child.id)
                }
            }
        }
        return result
    }
}

extension PendingResourceDeletion: Identifiable {
    var id: String {
        switch target {
        case let .server(id, _): "server:\(id)"
        case let .group(id, _): "group:\(id)"
        case let .library(name): "library:\(name)"
        }
    }

    var title: String {
        switch target {
        case let .server(_, name): "删除服务器“\(name)”？"
        case let .group(_, name): "删除群组“\(name)”？"
        case let .library(name): "移除整个资源库“\(name)”？"
        }
    }

    var destructiveButtonTitle: String {
        switch target {
        case .server: "删除服务器"
        case .group: "删除群组"
        case .library: "移除整个资源库"
        }
    }

    var destructiveAccessibilityLabel: String {
        let name: String
        switch target {
        case let .server(_, resourceName),
             let .group(_, resourceName),
             let .library(resourceName):
            name = resourceName
        }
        return RdcAccessibilityProfile.direction2.destructiveResourceActionLabel(
            resourceName: name,
            groupCount: impact.groupCount,
            serverCount: impact.serverCount
        )
    }

    var message: String {
        let scope: String
        switch target {
        case .server:
            scope = "将删除 1 台服务器"
        case .group, .library:
            scope = "将删除 \(impact.groupCount) 个群组和 \(impact.serverCount) 台服务器"
        }
        let disconnect = impact.containsSelectedServer ? "，并断开当前连接" : ""
        return "\(scope)\(disconnect)。原始 .rdg 文件不会改变。"
    }
}

struct NewChildGroupRequest: Identifiable, Equatable {
    let parentID: String
    let parentName: String
    let ownerLease: ResourcePropertySheetCoordinator.HostLease
    let id = UUID()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.parentID == rhs.parentID
            && lhs.parentName == rhs.parentName && lhs.ownerLease == rhs.ownerLease
    }
}

struct ResourceMoveDestinationPicker: View {
    let title: String
    let emptyTitle: String
    let destinations: [ResourceMoveDestination]
    let move: (ResourceMoveDestination) -> Void

    var body: some View {
        Menu(title) {
            if destinations.isEmpty {
                Text(emptyTitle)
            } else {
                ForEach(destinations) { destination in
                    Button(destination.menuTitle) { move(destination) }
                        .accessibilityLabel(destination.accessibilityLabel)
                }
            }
        }
        .disabled(destinations.isEmpty)
    }
}

struct ResourceLibraryRowMenu: View {
    let row: ResourceLibrarySidebarRow
    @ObservedObject var model: RdcAppModel
    let credentialEditorHost: CredentialEditorHost
    let ownerLease: ResourcePropertySheetCoordinator.HostLease
    let toggleExpansion: () -> Void

    var body: some View {
        if let serverID = row.representedServerID {
            serverMenu(serverID: serverID)
        } else if let groupID = row.representedGroupID,
                  let group = model.library?.groups.first(where: { $0.id == groupID }) {
            groupMenu(group: group)
        }
    }

    @ViewBuilder
    private func serverMenu(serverID: String) -> some View {
        let primaryAction = ResourceMenuPolicy.serverPrimaryAction(
            isConnected: isConnected(serverID),
            isConnecting: isConnecting(serverID)
        )
        Button(primaryAction == .disconnect ? "断开连接" :
            (primaryAction == .connectingDisabled ? "连接中…" : "连接")) {
            if primaryAction == .disconnect {
                model.closeSession()
            } else if primaryAction == .connect {
                Task {
                    model.selectServer(id: serverID)
                    await model.waitForPendingOperations()
                    await model.connectSelectedServer()
                }
            }
        }
        .disabled(primaryAction == .connectingDisabled)
        Button("属性…") {
            model.requestResourceEditor(.server(id: serverID), ownerLease: ownerLease)
        }
        credentialMenu(
            title: "设置服务器凭据…",
            scope: .server(id: serverID, displayName: row.title),
            hasBinding: model.configuration.serverCredentialBindings[serverID] != nil
        )
        Divider()
        moveServerMenu(serverID: serverID)
        Button("删除服务器…", role: .destructive) {
            _ = model.requestServerDeletion(id: serverID, ownerLease: ownerLease)
        }
    }

    @ViewBuilder
    private func groupMenu(group: RdcImportedGroup) -> some View {
        Button(row.disclosureState == .expanded ? "折叠" : "展开") {
            toggleExpansion()
        }
        Button("属性…") {
            model.requestResourceEditor(.group(id: group.id), ownerLease: ownerLease)
        }
        credentialMenu(
            title: "设置分组凭据…",
            scope: .group(id: group.id, displayName: group.name),
            hasBinding: model.configuration.groupCredentialBindings[group.id] != nil
        )
        Button("新建子群组…") {
            _ = model.requestNewChildGroup(
                parentID: group.id, parentName: group.name, ownerLease: ownerLease
            )
        }
        if group.parentID != nil {
            moveGroupMenu(groupID: group.id)
        }
        Divider()
        if group.parentID == nil {
            Button("移除整个资源库…", role: .destructive) {
                _ = model.requestLibraryRemoval(ownerLease: ownerLease)
            }
        } else {
            Button("删除群组…", role: .destructive) {
                _ = model.requestGroupDeletion(id: group.id, ownerLease: ownerLease)
            }
        }
    }

    @ViewBuilder
    private func credentialMenu(
        title: String,
        scope: CredentialEditScope,
        hasBinding: Bool
    ) -> some View {
        if hasBinding {
            Menu(title) {
                Button("更改凭据…") {
                    model.editCredential(for: scope, host: credentialEditorHost)
                }
                Button("使用继承凭据") {
                    Task {
                        await model.performSettingsOperation(
                            host: credentialEditorHost,
                            failureMessage: "无法恢复凭据继承，请重试。"
                        ) {
                            try await model.restoreCredentialInheritance(scope: scope)
                        }
                    }
                }
            }
        } else {
            Button(title) {
                model.editCredential(for: scope, host: credentialEditorHost)
            }
        }
    }

    @ViewBuilder
    private func moveServerMenu(serverID: String) -> some View {
        let destinations = model.library.map {
            ResourceMoveDestinationPolicy.serverDestinations(in: $0, serverID: serverID)
        } ?? []
        ResourceMoveDestinationPicker(
            title: "移动到群组…", emptyTitle: "没有其他群组",
            destinations: destinations
        ) { destination in
            Task { try? await model.moveServer(
                id: serverID, destinationGroupID: destination.id
            ) }
        }
    }

    @ViewBuilder
    private func moveGroupMenu(groupID: String) -> some View {
        let destinations = model.library.map {
            ResourceMoveDestinationPolicy.groupDestinations(in: $0, groupID: groupID)
        } ?? []
        ResourceMoveDestinationPicker(
            title: "移动群组…", emptyTitle: "没有可用位置",
            destinations: destinations
        ) { destination in
            Task { try? await model.moveGroup(
                id: groupID, destinationGroupID: destination.id
            ) }
        }
    }

    private func isConnected(_ serverID: String) -> Bool {
        model.activeSessionServerID == serverID && model.session.descriptor != nil
    }

    private func isConnecting(_ serverID: String) -> Bool {
        model.selectedServerID == serverID && model.session.isConnecting
    }
}

struct NewChildGroupSheet: View {
    let request: NewChildGroupRequest
    @ObservedObject var model: RdcAppModel
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建子群组")
                .font(.system(size: 20, weight: .semibold))
            Text("将在“\(request.parentName)”中创建群组。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("群组名称", text: $name)
                .textFieldStyle(.roundedBorder)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("创建") {
                    isSaving = true
                    Task {
                        do {
                            try await model.createChildGroup(
                                parentID: request.parentID, name: name
                            )
                            dismiss()
                        } catch {
                            errorMessage = model.resourceOperationMessage
                                ?? "无法创建子群组，请重试。"
                            isSaving = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .padding(24)
        .frame(width: 390)
    }
}
