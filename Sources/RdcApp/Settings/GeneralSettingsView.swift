import RdcCore
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var model: RdcAppModel

    var body: some View {
        SettingsPage(title: "通用", subtitle: "控制启动、连接与远程画面行为") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 18) {
                    preferenceToggle(
                        "启动时恢复上次连接列表",
                        keyPath: \.restoresLastLibrary
                    )
                    Divider()
                    preferenceToggle(
                        "双击服务器直接连接",
                        keyPath: \.doubleClickConnects
                    )
                    Divider()
                    preferenceToggle(
                        "远程画面跟随窗口尺寸",
                        keyPath: \.resizesRemoteDesktopWithWindow
                    )
                }
            }
        }
    }

    private func preferenceToggle(
        _ title: String,
        keyPath: WritableKeyPath<RdcGeneralPreferences, Bool>
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { model.configuration.preferences[keyPath: keyPath] },
                set: { value in
                    var preferences = model.configuration.preferences
                    preferences[keyPath: keyPath] = value
                    Task {
                        await model.performSettingsOperation(
                            host: .settingsWindow,
                            failureMessage: "无法保存通用设置，请检查磁盘权限后重试。"
                        ) {
                            try await model.updatePreferences(preferences)
                        }
                    }
                }
            )
        )
        .toggleStyle(.switch)
        .accessibilityLabel(title)
    }
}
