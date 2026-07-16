import XCTest
@testable import RdcCore

final class AppPolishTests: XCTestCase {
    func testPolishKeepsRdcBrandConsistentAcrossCoreSurfaces() {
        let polish = RdcPolishProfile.default

        XCTAssertEqual(polish.productName, "RDGDesk")
        XCTAssertEqual(polish.resourceLibraryTitle, "RDGDesk 资源库")
        XCTAssertEqual(polish.sessionCanvasTitle, "RDGDesk 远程桌面")
    }

    func testEmptyLoadingAndErrorStatesHaveActionablePresentations() {
        let empty = RdcInterfaceState.emptyResourceLibrary.presentation
        let loading = RdcInterfaceState.loadingResourceLibrary.presentation
        let error = RdcInterfaceState.error("无法读取 .rdg 文件").presentation

        XCTAssertEqual(empty.title, "导入 .rdg 文件")
        XCTAssertEqual(empty.accessibilityLabel, "RDGDesk 空资源库")
        XCTAssertEqual(loading.title, "正在读取资源库")
        XCTAssertEqual(loading.accessibilityLabel, "RDGDesk 正在加载")
        XCTAssertEqual(error.title, "读取失败")
        XCTAssertEqual(error.message, "无法读取 .rdg 文件")
        XCTAssertEqual(error.accessibilityLabel, "RDGDesk 错误状态")
    }

    func testAccessibilityLabelsCoverPrimaryDirection2Regions() {
        let accessibility = RdcAccessibilityProfile.direction2

        XCTAssertEqual(accessibility.resourceLibraryLabel, "RDGDesk 资源库")
        XCTAssertEqual(accessibility.searchFieldLabel, "搜索服务器")
        XCTAssertEqual(accessibility.sessionCanvasLabel, "RDGDesk 远程桌面画布")
        XCTAssertEqual(accessibility.remoteScreenLabel, "远程桌面预览画面")
    }

    func testResourceAccessibilityDescriptorsExposeContextWithoutVisibleToolbarControls() {
        let accessibility = RdcAccessibilityProfile.direction2

        XCTAssertEqual(accessibility.serverPropertiesTitle, "服务器属性")
        XCTAssertEqual(accessibility.groupPropertiesTitle, "群组属性")
        XCTAssertEqual(
            accessibility.destructiveResourceActionLabel(
                resourceName: "测试组", groupCount: 3, serverCount: 12
            ),
            "删除测试组，将影响3个群组和12台服务器"
        )
        XCTAssertEqual(
            accessibility.moveDestinationLabel(path: ["根", "客服", "夜班"]),
            "移动到群组：根 / 客服 / 夜班"
        )
        XCTAssertEqual(
            accessibility.overflowCommandHelp(title: "发送 Ctrl+Alt+Del"),
            "更多连接操作：发送 Ctrl+Alt+Del"
        )
    }
}
