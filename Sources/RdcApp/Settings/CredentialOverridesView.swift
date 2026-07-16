import SwiftUI

struct CredentialOverridesView: View {
    @ObservedObject var model: RdcAppModel
    @State private var searchText = ""

    private var rows: [CredentialOverrideRowState] {
        let all = CredentialOverrideRowState.makeRows(
            library: model.library,
            configuration: model.configuration
        )
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return all }
        return all.filter { $0.searchableText.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        SettingsPage(title: "凭据覆盖", subtitle: "为分组或单台服务器设置独立凭据") {
            TextField("搜索分组或服务器", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索凭据覆盖")

            SettingsCard {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "没有匹配项",
                        systemImage: "person.badge.key",
                        description: Text(model.library == nil ? "请先导入 .rdg 连接列表。" : "尝试其他搜索词。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            overrideRow(row)
                            if index < rows.count - 1 { Divider() }
                        }
                    }
                }
            }
        }
    }

    private func overrideRow(_ row: CredentialOverrideRowState) -> some View {
        HStack(spacing: 13) {
            Image(systemName: row.kind == .group ? "folder" : "display")
                .foregroundStyle(row.kind == .group ? .blue : .secondary)
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.system(size: 14, weight: .medium))
                Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(row.sourceBadge)
                .font(.caption.weight(.medium))
                .foregroundStyle(row.hasOverride ? Color.blue : Color.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background((row.hasOverride ? Color.blue : Color.secondary).opacity(0.09), in: Capsule())
                .accessibilityLabel("凭据来源：\(row.sourceBadge)")
            Button("编辑") { edit(row) }.buttonStyle(.borderless)
            if row.hasOverride {
                Button("恢复继承") { restore(row) }.buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 12)
        .contextMenu {
            Button(row.kind == .group ? "设置分组凭据" : "设置服务器凭据") { edit(row) }
            if row.hasOverride { Button("使用继承凭据") { restore(row) } }
        }
    }

    private func scope(for row: CredentialOverrideRowState) -> CredentialEditScope {
        row.kind == .group
            ? .group(id: row.id, displayName: row.title)
            : .server(id: row.id, displayName: row.title)
    }

    private func edit(_ row: CredentialOverrideRowState) {
        model.editCredential(for: scope(for: row), host: .settingsWindow)
    }
    private func restore(_ row: CredentialOverrideRowState) {
        Task {
            await model.performSettingsOperation(
                host: .settingsWindow,
                failureMessage: "无法恢复凭据继承，请检查配置存储后重试。"
            ) {
                try await model.restoreCredentialInheritance(scope: scope(for: row))
            }
        }
    }
}
