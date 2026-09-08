import SwiftUI

struct LegacySecurityCompatibilityToggle: View {
    @Binding var isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("兼容旧服务器", isOn: $isEnabled)
                .accessibilityHint("仅对这台服务器降低 TLS 安全级别")
            Text("仅在旧版 SHA-1/TLS 服务器无法连接时开启；会降低此连接的安全性。")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
