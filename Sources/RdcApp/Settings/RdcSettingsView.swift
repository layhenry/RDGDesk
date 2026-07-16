import RdcCore
import SwiftUI

struct RdcSettingsView: View {
    @ObservedObject var model: RdcAppModel
    @ObservedObject private var resourcePropertyCoordinator: ResourcePropertySheetCoordinator
    @State private var selection: RdcSettingsCategory? = .globalCredential
    @State private var credentialEditorLease: ResourcePropertySheetCoordinator.HostLease?

    init(model: RdcAppModel) {
        self.model = model
        _resourcePropertyCoordinator = ObservedObject(
            wrappedValue: model.resourcePropertyCoordinator
        )
    }

    var body: some View {
        NavigationSplitView {
            List(RdcSettingsCategory.allCases, selection: $selection) { category in
                Label(category.title, systemImage: category.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.vertical, 7)
                    .accessibilityLabel("设置类别：\(category.title)")
                    .tag(category)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 208, max: 230)
        } detail: {
            Group {
                switch selection ?? .globalCredential {
                case .general: GeneralSettingsView(model: model)
                case .globalCredential: GlobalCredentialSettingsView(model: model)
                case .credentialOverrides: CredentialOverridesView(model: model)
                case .certificates: CertificateSettingsView(model: model)
                case .about: AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsBackdrop())
        }
        .frame(minWidth: 860, idealWidth: 960, minHeight: 580, idealHeight: 660)
        .sheet(item: credentialEditorBinding(lease: credentialEditorLease)) { item in
            CredentialEditorSheet(model: model, scope: item.scope, host: item.host)
        }
        .alert("操作失败", isPresented: model.settingsOperationErrorBinding) {
            Button("好") { model.settingsOperationError = nil }
        } message: {
            Text(model.settingsOperationError ?? "")
        }
        .onAppear {
            credentialEditorLease = resourcePropertyCoordinator.register(
                host: .settingsWindow
            )
        }
        .onDisappear { [lease = credentialEditorLease] in
            guard let lease else { return }
            let presentation = model.credentialEditorPresentation
            let shouldDismiss = presentation.map {
                resourcePropertyCoordinator.canDismissCredentialPresentation(
                    $0, lease: lease
                )
            } ?? false
            resourcePropertyCoordinator.unregister(lease: lease)
            if presentation != nil, shouldDismiss {
                model.dismissCredentialEditor(host: .settingsWindow)
            }
        }
    }

    private func credentialEditorBinding(
        lease: ResourcePropertySheetCoordinator.HostLease?
    ) -> Binding<CredentialEditorItem?> {
        let capturedPresentation = lease.flatMap {
            resourcePropertyCoordinator.credentialBindingPresentation(
                model.credentialEditorPresentation,
                lease: $0
            )
        }
        return Binding<CredentialEditorItem?>(
            get: {
                guard let lease,
                      let presentation = resourcePropertyCoordinator
                    .credentialBindingPresentation(
                        model.credentialEditorPresentation,
                        lease: lease
                    ) else { return nil }
                return CredentialEditorItem(scope: presentation.scope, host: presentation.host)
            },
            set: { item in
                guard item == nil,
                      let lease,
                      let capturedPresentation,
                      model.credentialEditorPresentation == capturedPresentation,
                      resourcePropertyCoordinator.canDismissCredentialPresentation(
                        capturedPresentation,
                        lease: lease
                      ) else { return }
                model.dismissCredentialEditor(host: .settingsWindow)
            }
        )
    }
}

struct SettingsBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color(nsColor: .windowBackgroundColor), Color.blue.opacity(0.035)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 27, weight: .bold))
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                content
            }
            .padding(34)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.09), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.035), radius: 14, y: 4)
    }
}

struct CredentialEditorItem: Identifiable {
    let scope: CredentialEditScope
    let host: CredentialEditorHost
    var id: String {
        switch scope {
        case .global: "global"
        case let .group(id, _): "group:\(id)"
        case let .server(id, _): "server:\(id)"
        case let .oneTime(id): "once:\(id)"
        }
    }
}
