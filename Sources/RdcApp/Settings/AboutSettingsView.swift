import RdcCore
import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        SettingsPage(title: "关于", subtitle: "Rdc for macOS") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 18) {
                        Image(systemName: "display.2").font(.system(size: 42)).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppBranding.productName).font(.title2.bold())
                            Text("版本 \(version)").foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Label("远程桌面引擎：FreeRDP 3", systemImage: "shippingbox")
                    Label("密码仅保存在 macOS 钥匙串；应用配置不包含密码。", systemImage: "hand.raised.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
