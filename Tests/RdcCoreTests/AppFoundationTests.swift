import XCTest
@testable import RdcCore

final class AppFoundationTests: XCTestCase {
    func testBrandingUsesRdcProductName() {
        XCTAssertEqual(AppBranding.productName, "Rdc")
        XCTAssertEqual(AppBranding.remoteDesktopSubtitle, "Remote Desktop Client")
    }

    func testPrimaryWindowTitleUsesRdc() {
        XCTAssertEqual(WindowConfiguration.primaryTitle, "Rdc")
        XCTAssertEqual(WindowConfiguration.minimumWidth, 1040)
        XCTAssertEqual(WindowConfiguration.minimumHeight, 680)
        XCTAssertEqual(WindowConfiguration.defaultWidth, 1280)
        XCTAssertEqual(WindowConfiguration.defaultHeight, 800)
        XCTAssertGreaterThanOrEqual(WindowConfiguration.defaultWidth, WindowConfiguration.minimumWidth)
        XCTAssertGreaterThanOrEqual(WindowConfiguration.defaultHeight, WindowConfiguration.minimumHeight)
    }

    func testDirection2ShellKeepsOnlyResourceLibraryAndSessionCanvas() {
        let shell = Direction2Shell.default

        XCTAssertTrue(shell.includesResourceLibrary)
        XCTAssertTrue(shell.includesSessionCanvas)
        XCTAssertFalse(shell.includesTopModeSwitcher)
        XCTAssertFalse(shell.includesTopSessionActions)
        XCTAssertFalse(shell.includesRightInspector)
        XCTAssertFalse(shell.includesBottomStatusBar)
    }
}
