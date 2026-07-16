public enum AppBranding {
    public static let productName = "Rdc"
    public static let remoteDesktopSubtitle = "Remote Desktop Client"
}

public enum WindowConfiguration {
    public static let primaryTitle = AppBranding.productName
    public static let minimumWidth = 1040
    public static let minimumHeight = 680
    public static let defaultWidth = 1280
    public static let defaultHeight = 800
}

public struct Direction2Shell: Equatable, Sendable {
    public let includesResourceLibrary: Bool
    public let includesSessionCanvas: Bool
    public let includesTopModeSwitcher: Bool
    public let includesTopSessionActions: Bool
    public let includesRightInspector: Bool
    public let includesBottomStatusBar: Bool

    public static let `default` = Direction2Shell(
        includesResourceLibrary: true,
        includesSessionCanvas: true,
        includesTopModeSwitcher: false,
        includesTopSessionActions: false,
        includesRightInspector: false,
        includesBottomStatusBar: false
    )
}
