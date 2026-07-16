import RdcCore
import SwiftUI

struct CertificateSettingsView: View {
    @ObservedObject var model: RdcAppModel
    @State private var selectedEndpoint: RdpEndpoint?
    @State private var endpointToDelete: RdpEndpoint?

    private var pins: [CertificatePin] {
        model.configuration.certificatePins.values.sorted {
            if $0.endpoint.host == $1.endpoint.host { return $0.endpoint.port < $1.endpoint.port }
            return $0.endpoint.host < $1.endpoint.host
        }
    }

    private var selectedPin: CertificatePin? {
        let endpoint = selectedEndpoint ?? pins.first?.endpoint
        return endpoint.flatMap { model.configuration.certificatePins[$0] }
    }

    var body: some View {
        SettingsPage(title: "证书", subtitle: "管理已明确始终信任的服务器证书") {
            HStack(alignment: .top, spacing: 18) {
                SettingsCard {
                    if pins.isEmpty {
                        ContentUnavailableView("没有已保存证书", systemImage: "shield")
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(pins, id: \.endpoint) { pin in
                                Button { selectedEndpoint = pin.endpoint } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(endpointText(pin.endpoint)).fontWeight(.medium)
                                            Text(pin.lastConfirmedAt, format: .dateTime.year().month().day().hour().minute())
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 10).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if pin.endpoint != pins.last?.endpoint { Divider() }
                            }
                        }
                    }
                }
                .frame(maxWidth: 310)

                if let pin = selectedPin {
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("证书详情", systemImage: "doc.text.magnifyingglass").font(.headline)
                            detail("端点", endpointText(pin.endpoint))
                            detail("主题", pin.subject)
                            detail("签发者", pin.issuer)
                            detail("SHA-256", pin.sha256Fingerprint.uppercased(), monospaced: true)
                                .accessibilityLabel("SHA-256 指纹：\(pin.sha256Fingerprint.uppercased())")
                            detail("最近确认", pin.lastConfirmedAt.formatted(date: .abbreviated, time: .shortened))
                            Divider()
                            Text("删除信任只影响未来连接；当前会话不会断开。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("删除信任", role: .destructive) { endpointToDelete = pin.endpoint }
                        }
                    }
                }
            }
        }
        .confirmationDialog("删除此证书信任？", isPresented: deleteBinding, titleVisibility: .visible) {
            Button("删除信任", role: .destructive) {
                guard let endpoint = endpointToDelete else { return }
                Task {
                    let deleted = await model.performSettingsOperation(
                        host: .settingsWindow,
                        failureMessage: "无法删除证书信任，请检查配置存储后重试。"
                    ) {
                        try await model.deleteCertificatePin(endpoint)
                    }
                    if deleted {
                        selectedEndpoint = nil
                        endpointToDelete = nil
                    }
                }
            }
            Button("取消", role: .cancel) { endpointToDelete = nil }
        } message: { Text("下次连接此端点时将重新显示证书确认。") }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { endpointToDelete != nil }, set: { if !$0 { endpointToDelete = nil } })
    }
    private func endpointText(_ endpoint: RdpEndpoint) -> String { "\(endpoint.host):\(endpoint.port)" }
    private func detail(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .system(.body))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
