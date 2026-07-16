import SwiftUI

struct GlobalCredentialSettingsView: View {
    @ObservedObject var model: RdcAppModel
    @State private var isConfirmingDeletion = false

    private var state: GlobalCredentialSettingsState { model.globalCredentialState }

    var body: some View {
        SettingsPage(
            title: "全局凭据",
            subtitle: "默认用于所有未单独设置凭据的服务器"
        ) {
            SettingsCard {
                VStack(spacing: 0) {
                    valueRow("用户名", value: state.username.isEmpty ? "未设置" : state.username)
                    Divider()
                    valueRow("域（可选）", value: state.domain.isEmpty ? "—" : state.domain)
                    Divider()
                    valueRow("密码", value: state.hasGlobalCredential ? "••••••••••••" : "未设置")
                    Divider()
                    HStack(spacing: 12) {
                        Image(systemName: state.hasGlobalCredential ? "key.fill" : "key")
                            .foregroundStyle(state.hasGlobalCredential ? .green : .secondary)
                        Text(state.keychainStatusText).font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                        Button(state.hasGlobalCredential ? "更新全局凭据" : "保存全局凭据") {
                            model.editCredential(for: .global, host: .settingsWindow)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 16)
                }
            }

            HStack(alignment: .top, spacing: 18) {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("凭据继承").font(.headline)
                        countRow("继承全局", count: state.globalInheritanceCount, color: .green)
                        Divider()
                        countRow("分组覆盖", count: state.groupOverrideCount, color: .blue)
                        Divider()
                        countRow("单台覆盖", count: state.serverOverrideCount, color: .purple)
                    }
                }

                if state.hasGlobalCredential {
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("删除凭据", systemImage: "trash")
                                .font(.headline).foregroundStyle(.red)
                            Text("删除后，\(model.globalCredentialDeletionImpact) 台继承全局凭据的服务器将需要重新输入凭据。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("删除全局凭据", role: .destructive) {
                                isConfirmingDeletion = true
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "删除全局凭据？",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("删除并影响 \(model.globalCredentialDeletionImpact) 台服务器", role: .destructive) {
                Task {
                    await model.performGlobalCredentialDeletion()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deletionConfirmationMessage)
        }
    }

    private var deletionConfirmationMessage: String {
        model.globalCredentialDeletionPresentation.confirmationMessage
    }

    private func valueRow(_ label: String, value: String) -> some View {
        HStack { Text(label).fontWeight(.medium); Spacer(); Text(value).foregroundStyle(.secondary) }
            .frame(height: 48)
    }

    private func countRow(_ label: String, count: Int, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
            Spacer()
            Text("\(count) 台").font(.caption.weight(.medium)).foregroundStyle(color)
                .padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.1), in: Capsule())
        }
    }
}
