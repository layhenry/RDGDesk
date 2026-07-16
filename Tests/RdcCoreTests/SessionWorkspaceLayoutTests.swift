import XCTest
@testable import RdcCore

final class SessionWorkspaceLayoutTests: XCTestCase {
    func testDirection2WorkspaceOnlyContainsSidebarAndCanvasRegions() {
        let layout = SessionWorkspaceLayout.direction2

        XCTAssertEqual(layout.regions, [.resourceLibrary, .sessionCanvas])
        XCTAssertFalse(layout.showsTopModeSwitcher)
        XCTAssertFalse(layout.showsTopSessionActions)
        XCTAssertFalse(layout.showsRightInspector)
        XCTAssertFalse(layout.showsBottomStatusBar)
    }

    func testSessionCanvasUsesLargePolishedMacStyleSurface() {
        let canvas = SessionWorkspaceLayout.direction2.canvas

        XCTAssertGreaterThanOrEqual(canvas.minimumWidth, 760)
        XCTAssertGreaterThanOrEqual(canvas.minimumHeight, 500)
        XCTAssertEqual(canvas.borderWidth, 1)
        XCTAssertLessThanOrEqual(canvas.borderOpacity, 0.14)
        XCTAssertGreaterThan(canvas.shadowRadius, 20)
        XCTAssertEqual(canvas.chromeStyle, .macOSWindow)
    }
}
