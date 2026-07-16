import AppKit
import RdcCore
import SwiftUI

enum SessionToolbarWidthClass: Equatable {
    case wide
    case medium
    case narrow
}

enum SessionToolbarAction: Hashable {
    case fullscreen
    case secureAttention
    case clipboard
    case more
}

enum SessionToolbarMenuCommand: Hashable {
    case secureAttention
    case clipboard
    case copyServerAddress
}

enum SessionToolbarTitleTruncation: Equatable {
    case middle

    var swiftUIValue: Text.TruncationMode {
        switch self {
        case .middle: .middle
        }
    }
}

struct SessionToolbarTitlePresentation: Equatable {
    let text: String
    let width: CGFloat
    let truncation: SessionToolbarTitleTruncation
}

enum SessionToolbarMetrics {
    static let wideBreakpoint: CGFloat = 960
    static let mediumBreakpoint: CGFloat = 760

    static let headerHeight: CGFloat = 48
    static let controlHeight: CGFloat = 36
    static let leadingInset: CGFloat = 150
    static let trailingInset: CGFloat = 12
    static let primarySpacing: CGFloat = 8
    static let spacerMinimum: CGFloat = 8
    static let actionSpacing: CGFloat = 8

    static let wideTitleWidth: CGFloat = 200
    static let mediumTitleWidth: CGFloat = 160
    static let narrowTitleWidth: CGFloat = 112
    static let elapsedWidth: CGFloat = 72
    static let pillHorizontalPadding: CGFloat = 14
    static let pillSpacing: CGFloat = 10
    static let connectionIconWidth: CGFloat = 15
    static let signalIconWidth: CGFloat = 14

    static let fullscreenWidth: CGFloat = 82
    static let secureAttentionWidth: CGFloat = 126
    static let clipboardWidth: CGFloat = 108
    static let moreWidth: CGFloat = 68

    static func titleWidth(for widthClass: SessionToolbarWidthClass) -> CGFloat {
        switch widthClass {
        case .wide: wideTitleWidth
        case .medium: mediumTitleWidth
        case .narrow: narrowTitleWidth
        }
    }

    static func width(for action: SessionToolbarAction) -> CGFloat {
        switch action {
        case .fullscreen: fullscreenWidth
        case .secureAttention: secureAttentionWidth
        case .clipboard: clipboardWidth
        case .more: moreWidth
        }
    }
}

struct SessionToolbarLayoutDescriptor: Equatable {
    let widthClass: SessionToolbarWidthClass
    let titleWidth: CGFloat
    let elapsedWidth: CGFloat
    let actionWidths: [SessionToolbarAction: CGFloat]
    let visibleActions: [SessionToolbarAction]

    func titlePresentation(for title: String) -> SessionToolbarTitlePresentation {
        SessionToolbarTitlePresentation(text: title, width: titleWidth, truncation: .middle)
    }

    var connectionPillWidth: CGFloat {
        (SessionToolbarMetrics.pillHorizontalPadding * 2)
            + SessionToolbarMetrics.connectionIconWidth
            + titleWidth
            + elapsedWidth
            + SessionToolbarMetrics.signalIconWidth
            + (SessionToolbarMetrics.pillSpacing * 3)
    }

    var actionGroupWidth: CGFloat {
        let controls = visibleActions.reduce(CGFloat.zero) { result, action in
            result + (actionWidths[action] ?? 0)
        }
        let gaps = CGFloat(max(0, visibleActions.count - 1)) * SessionToolbarMetrics.actionSpacing
        return controls + gaps
    }

    var minimumRequiredWidth: CGFloat {
        SessionToolbarMetrics.leadingInset
            + connectionPillWidth
            + (SessionToolbarMetrics.primarySpacing * 2)
            + SessionToolbarMetrics.spacerMinimum
            + actionGroupWidth
            + SessionToolbarMetrics.trailingInset
    }
}

struct SessionToolbarPolicy: Equatable {
    let widthClass: SessionToolbarWidthClass
    let visibleActions: [SessionToolbarAction]
    let overflowActions: [SessionToolbarAction]
    let layout: SessionToolbarLayoutDescriptor

    var menuCommands: [SessionToolbarMenuCommand] {
        overflowActions.compactMap { action in
            switch action {
            case .secureAttention: .secureAttention
            case .clipboard: .clipboard
            case .fullscreen, .more: nil
            }
        } + [.copyServerAddress]
    }

    init(width: CGFloat) {
        let widthClass: SessionToolbarWidthClass
        let visibleActions: [SessionToolbarAction]
        let overflowActions: [SessionToolbarAction]
        switch width {
        case SessionToolbarMetrics.wideBreakpoint...:
            widthClass = .wide
            visibleActions = [.fullscreen, .secureAttention, .clipboard, .more]
            overflowActions = []
        case SessionToolbarMetrics.mediumBreakpoint..<SessionToolbarMetrics.wideBreakpoint:
            widthClass = .medium
            visibleActions = [.fullscreen, .more]
            overflowActions = [.secureAttention, .clipboard]
        default:
            widthClass = .narrow
            visibleActions = [.fullscreen, .more]
            overflowActions = [.secureAttention, .clipboard]
        }
        self.widthClass = widthClass
        self.visibleActions = visibleActions
        self.overflowActions = overflowActions
        layout = SessionToolbarLayoutDescriptor(
            widthClass: widthClass,
            titleWidth: SessionToolbarMetrics.titleWidth(for: widthClass),
            elapsedWidth: SessionToolbarMetrics.elapsedWidth,
            actionWidths: Dictionary(
                uniqueKeysWithValues: visibleActions.map { ($0, SessionToolbarMetrics.width(for: $0)) }
            ),
            visibleActions: visibleActions
        )
    }
}

enum SessionElapsedTimeFormatter {
    static func display(seconds: Int?) -> String {
        guard let seconds else { return "点击连接" }
        let safeSeconds = max(0, seconds)
        guard safeSeconds < 360_000 else { return "99h+" }
        return String(
            format: "%02d:%02d:%02d",
            safeSeconds / 3600,
            (safeSeconds / 60) % 60,
            safeSeconds % 60
        )
    }

    static func accessibility(seconds: Int?) -> String {
        guard let seconds else { return "尚未开始计时" }
        let safeSeconds = max(0, seconds)
        return "\(safeSeconds / 3600)小时\((safeSeconds / 60) % 60)分\(safeSeconds % 60)秒"
    }
}

struct SessionConnectionAccessibilityDescriptor: Equatable {
    let label: String
    let value: String

    init(serverName: String, isConnected: Bool, elapsedSeconds: Int?) {
        label = "\(isConnected ? "断开连接" : "连接")，\(serverName)"
        if isConnected {
            value = "已连接，已连接时间\(SessionElapsedTimeFormatter.accessibility(seconds: elapsedSeconds))，连接信号已显示"
        } else {
            value = "未连接，\(SessionElapsedTimeFormatter.accessibility(seconds: nil))，连接信号不可用"
        }
    }
}

struct AdaptiveSessionToolbar: View {
    @ObservedObject var model: RdcAppModel

    var body: some View {
        GeometryReader { geometry in
            SessionToolbarVariant(
                model: model,
                policy: SessionToolbarPolicy(width: geometry.size.width)
            )
        }
        .frame(height: SessionToolbarMetrics.headerHeight)
    }
}

private struct SessionToolbarVariant: View {
    @ObservedObject var model: RdcAppModel
    let policy: SessionToolbarPolicy

    var body: some View {
        HStack(spacing: SessionToolbarMetrics.primarySpacing) {
            connectionButton
            Spacer(minLength: SessionToolbarMetrics.spacerMinimum)
            HStack(spacing: SessionToolbarMetrics.actionSpacing) {
                ForEach(policy.visibleActions, id: \.self) { action in
                    control(for: action)
                }
            }
        }
        .padding(.leading, SessionToolbarMetrics.leadingInset)
        .padding(.trailing, SessionToolbarMetrics.trailingInset)
        .frame(height: SessionToolbarMetrics.headerHeight)
    }

    private var connectionButton: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let isConnected = model.session.descriptor != nil
            let elapsedSeconds = isConnected ? elapsedSeconds(at: context.date) : nil
            let serverName = model.activeSessionServer?.displayName
                ?? model.selectedServer?.displayName ?? "选择连接"
            let accessibility = SessionConnectionAccessibilityDescriptor(
                serverName: serverName,
                isConnected: isConnected,
                elapsedSeconds: elapsedSeconds
            )
            Button {
                if isConnected {
                    model.closeSession()
                } else {
                    Task { await model.connectSelectedServer() }
                }
            } label: {
                AdaptiveSessionPill(
                    title: serverName,
                    elapsedText: SessionElapsedTimeFormatter.display(seconds: elapsedSeconds),
                    isConnected: isConnected,
                    layout: policy.layout
                )
            }
            .buttonStyle(.plain)
            .disabled(model.selectedServer == nil || model.session.isConnecting)
            .help(connectionHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibility.label)
            .accessibilityValue(accessibility.value)
        }
    }

    private func elapsedSeconds(at date: Date) -> Int? {
        model.connectionStartedAt.map { max(0, Int(date.timeIntervalSince($0))) }
    }

    private var connectionHelp: String {
        guard model.selectedServer != nil else { return "请先导入并选择连接" }
        return model.session.descriptor == nil ? "连接" : "断开连接"
    }

    @ViewBuilder
    private func control(for action: SessionToolbarAction) -> some View {
        switch action {
        case .fullscreen:
            AdaptiveToolbarCapsule(
                toolbarAction: .fullscreen,
                symbol: "arrow.up.left.and.arrow.down.right",
                title: "全屏",
                action: { NSApp.keyWindow?.toggleFullScreen(nil) }
            )
        case .secureAttention:
            AdaptiveToolbarCapsule(
                toolbarAction: .secureAttention,
                symbol: "keyboard", title: "Ctrl+Alt+Del",
                isDisabled: model.session.descriptor == nil,
                action: model.sendSecureAttention
            )
        case .clipboard:
            AdaptiveToolbarCapsule(
                toolbarAction: .clipboard,
                symbol: "clipboard", title: "发送剪贴板",
                isDisabled: model.session.descriptor == nil,
                help: "点击后发送本机文本剪贴板（最多 1 MB）",
                action: { _ = model.sendLocalClipboardText() }
            )
        case .more:
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            ForEach(policy.menuCommands, id: \.self) { command in
                menuButton(for: command)
            }
#if DEBUG
            Divider()
            Button("使用外部客户端调试", systemImage: "ladybug") {
                model.launchSelectedSessionExternallyForDebug()
            }
#endif
        } label: {
            Label("更多", systemImage: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 0.15, green: 0.17, blue: 0.21))
                .frame(
                    width: SessionToolbarMetrics.width(for: .more),
                    height: SessionToolbarMetrics.controlHeight
                )
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { capsuleBorder }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多连接操作")
        .accessibilityLabel("更多连接操作")
    }

    @ViewBuilder
    private func menuButton(for command: SessionToolbarMenuCommand) -> some View {
        switch command {
        case .secureAttention:
            Button("发送 Ctrl+Alt+Del", systemImage: "keyboard", action: model.sendSecureAttention)
                .disabled(model.session.descriptor == nil)
                .help(overflowHelp("发送 Ctrl+Alt+Del"))
                .accessibilityLabel(overflowHelp("发送 Ctrl+Alt+Del"))
        case .clipboard:
            Button("发送剪贴板", systemImage: "clipboard") { _ = model.sendLocalClipboardText() }
                .disabled(model.session.descriptor == nil)
                .help(overflowHelp("发送剪贴板"))
                .accessibilityLabel(overflowHelp("发送剪贴板"))
        case .copyServerAddress:
            Button("复制服务器地址", systemImage: "doc.on.doc") {
                guard let address = (model.activeSessionServer ?? model.selectedServer)?.address.rawValue else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
            }
            .disabled(model.selectedServer == nil)
            .help(overflowHelp("复制服务器地址"))
            .accessibilityLabel(overflowHelp("复制服务器地址"))
        }
    }

    private func overflowHelp(_ title: String) -> String {
        RdcAccessibilityProfile.direction2.overflowCommandHelp(title: title)
    }

    private var capsuleBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.black.opacity(0.08), lineWidth: 1)
    }
}

private struct AdaptiveSessionPill: View {
    let title: String
    let elapsedText: String
    let isConnected: Bool
    let layout: SessionToolbarLayoutDescriptor

    var body: some View {
        let titlePresentation = layout.titlePresentation(for: title)
        HStack(spacing: SessionToolbarMetrics.pillSpacing) {
            Image(systemName: isConnected ? "shield.checkerboard" : "play.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isConnected ? Color(red: 0.18, green: 0.70, blue: 0.37) : Color.accentColor)
                .frame(width: SessionToolbarMetrics.connectionIconWidth)
            Text(titlePresentation.text)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .truncationMode(titlePresentation.truncation.swiftUIValue)
                .frame(width: titlePresentation.width, alignment: .leading)
            Text(elapsedText)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: layout.elapsedWidth, alignment: .center)
            Image(systemName: "cellularbars")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.30, green: 0.36, blue: 0.45))
                .frame(width: SessionToolbarMetrics.signalIconWidth)
        }
        .padding(.horizontal, SessionToolbarMetrics.pillHorizontalPadding)
        .frame(height: SessionToolbarMetrics.controlHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.05), radius: 14, y: 3)
    }
}

private struct AdaptiveToolbarCapsule: View {
    let toolbarAction: SessionToolbarAction
    let symbol: String
    let title: String
    var isDisabled = false
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 0.15, green: 0.17, blue: 0.21))
                .frame(
                    width: SessionToolbarMetrics.width(for: toolbarAction),
                    height: SessionToolbarMetrics.controlHeight
                )
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}
