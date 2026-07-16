public struct RdcPolishProfile: Equatable, Sendable {
    public let productName: String
    public let resourceLibraryTitle: String
    public let sessionCanvasTitle: String

    public static let `default` = RdcPolishProfile(
        productName: AppBranding.productName,
        resourceLibraryTitle: "\(AppBranding.productName) 资源库",
        sessionCanvasTitle: "\(AppBranding.productName) 远程桌面"
    )
}

public enum RdcInterfaceState: Equatable, Sendable {
    case emptyResourceLibrary
    case loadingResourceLibrary
    case error(String)

    public var presentation: RdcStatePresentation {
        switch self {
        case .emptyResourceLibrary:
            return RdcStatePresentation(
                title: "导入 .rdg 文件",
                message: "资源库为空",
                accessibilityLabel: "\(AppBranding.productName) 空资源库"
            )
        case .loadingResourceLibrary:
            return RdcStatePresentation(
                title: "正在读取资源库",
                message: "请稍候",
                accessibilityLabel: "\(AppBranding.productName) 正在加载"
            )
        case let .error(message):
            return RdcStatePresentation(
                title: "读取失败",
                message: message,
                accessibilityLabel: "\(AppBranding.productName) 错误状态"
            )
        }
    }
}

public struct RdcStatePresentation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let accessibilityLabel: String
}

public struct RdcAccessibilityProfile: Equatable, Sendable {
    public let resourceLibraryLabel: String
    public let searchFieldLabel: String
    public let sessionCanvasLabel: String
    public let remoteScreenLabel: String

    public static let direction2 = RdcAccessibilityProfile(
        resourceLibraryLabel: "\(AppBranding.productName) 资源库",
        searchFieldLabel: "搜索服务器",
        sessionCanvasLabel: "\(AppBranding.productName) 远程桌面画布",
        remoteScreenLabel: "远程桌面预览画面"
    )

    public var serverPropertiesTitle: String { "服务器属性" }
    public var groupPropertiesTitle: String { "群组属性" }

    public func destructiveResourceActionLabel(
        resourceName: String,
        groupCount: Int,
        serverCount: Int
    ) -> String {
        "删除\(resourceName)，将影响\(groupCount)个群组和\(serverCount)台服务器"
    }

    public func moveDestinationLabel(path: [String]) -> String {
        "移动到群组：\(path.joined(separator: " / "))"
    }

    public func overflowCommandHelp(title: String) -> String {
        "更多连接操作：\(title)"
    }
}
