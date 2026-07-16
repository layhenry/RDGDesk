public struct SessionWorkspaceLayout: Equatable, Sendable {
    public let regions: [SessionWorkspaceRegion]
    public let showsTopModeSwitcher: Bool
    public let showsTopSessionActions: Bool
    public let showsRightInspector: Bool
    public let showsBottomStatusBar: Bool
    public let canvas: SessionCanvasStyle

    public static let direction2 = SessionWorkspaceLayout(
        regions: [.resourceLibrary, .sessionCanvas],
        showsTopModeSwitcher: false,
        showsTopSessionActions: false,
        showsRightInspector: false,
        showsBottomStatusBar: false,
        canvas: SessionCanvasStyle(
            minimumWidth: 760,
            minimumHeight: 500,
            cornerRadius: 18,
            borderWidth: 1,
            borderOpacity: 0.12,
            shadowRadius: 28,
            chromeStyle: .macOSWindow
        )
    )
}

public enum SessionWorkspaceRegion: Equatable, Sendable {
    case resourceLibrary
    case sessionCanvas
}

public struct SessionCanvasStyle: Equatable, Sendable {
    public let minimumWidth: Int
    public let minimumHeight: Int
    public let cornerRadius: Int
    public let borderWidth: Int
    public let borderOpacity: Double
    public let shadowRadius: Int
    public let chromeStyle: SessionCanvasChromeStyle
}

public enum SessionCanvasChromeStyle: Equatable, Sendable {
    case macOSWindow
}
