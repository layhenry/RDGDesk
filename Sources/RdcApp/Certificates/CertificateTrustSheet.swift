import RdcCore
import SwiftUI

struct CertificateTrustSheetItem: Identifiable {
    let presentation: CertificateTrustPresentation
    let attemptID: RdpConnectionAttemptID?
    let challengeID: UInt64
    var id: String { "\(attemptID?.rawValue.uuidString ?? "unknown"):\(challengeID)" }
    var sharedModalKind: ResourcePropertySheetCoordinator.SharedModalKind? {
        attemptID.map {
            .certificate(attemptID: $0.rawValue, challengeID: challengeID)
        }
    }

    init(
        _ presentation: CertificateTrustPresentation,
        token: RdcSessionModel.PendingCertificateToken? = nil
    ) {
        self.presentation = presentation
        attemptID = token?.attemptID
        switch presentation {
        case let .firstUse(challenge): challengeID = challenge.id
        case let .changed(_, challenge): challengeID = challenge.id
        }
    }
}

struct CertificateTrustSheet: View {
    @ObservedObject var model: RdcAppModel
    let presentation: CertificateTrustSheetItem
    @State private var isResolving = false

    private var state: CertificateTrustSheetState {
        CertificateTrustSheetState(presentation: presentation.presentation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: state.isChangedCertificate ? "exclamationmark.shield.fill" : "exclamationmark.triangle")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(state.isChangedCertificate ? .red : .orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.isChangedCertificate ? "服务器证书已更改" : "确认服务器证书")
                        .font(.title2.bold())
                    Text(endpoint).foregroundStyle(.secondary)
                    Text(reason).font(.caption).foregroundStyle(state.isChangedCertificate ? .red : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                certificateRow("证书名称", state.challenge.commonName ?? state.challenge.subject)
                certificateRow("签发者", state.challenge.issuer)
                certificateRow("有效期", validity)

                if let old = state.oldFingerprint {
                    Divider()
                    Text("指纹变化").font(.headline)
                    HStack(alignment: .top, spacing: 14) {
                        fingerprintCard("旧指纹", old, tint: .red)
                        fingerprintCard("新指纹", state.newFingerprint, tint: .blue)
                    }
                    if let date = state.lastConfirmedAt {
                        Text("上次确认：\(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    certificateRow("指纹（SHA-256）", state.newFingerprint, monospaced: true)
                        .accessibilityLabel("SHA-256 指纹：\(state.newFingerprint)")
                }
            }
            .padding(16)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09)) }

            HStack {
                Button("取消", role: .cancel) { resolve(.reject) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("取消证书信任")
                Spacer()
                Button("信任一次") { resolve(.trustOnce) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("仅本次连接信任证书")
                Button(state.persistentActionTitle) { resolve(.trustAlways) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(state.persistentActionTitle)
            }
            .disabled(isResolving)
        }
        .padding(26)
        .frame(width: state.isChangedCertificate ? 650 : 560)
        .interactiveDismissDisabled()
    }

    private var endpoint: String { "\(state.challenge.endpoint.host):\(state.challenge.endpoint.port)" }
    private var reason: String {
        if state.isChangedCertificate { return "已保存的指纹与服务器当前证书不一致。连接已暂停。" }
        if state.challenge.hostNameMismatch { return "证书名称与服务器地址不一致，请核对后再继续。" }
        return "这是此端点首次显示的证书，请核对详情。"
    }
    private var validity: String {
        let start = state.challenge.notBefore?.formatted(date: .abbreviated, time: .omitted) ?? "未知"
        let end = state.challenge.notAfter?.formatted(date: .abbreviated, time: .omitted) ?? "未知"
        return "\(start) – \(end)"
    }

    private func resolve(_ decision: RdpCertificateDecision) {
        guard !isResolving else { return }
        isResolving = true
        let token = presentation.attemptID.map {
            RdcSessionModel.PendingCertificateToken(
                attemptID: $0, challengeID: presentation.challengeID
            )
        }
        Task { await model.resolvePendingCertificate(decision: decision, expectedToken: token) }
    }

    private func certificateRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 118, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .system(.body))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fingerprintCard(_ title: String, _ fingerprint: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
            Text(fingerprint).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                .accessibilityLabel("\(title)：\(fingerprint)")
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}
