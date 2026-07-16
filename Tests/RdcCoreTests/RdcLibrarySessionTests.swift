import XCTest
@testable import RdcCore

final class RdcLibrarySessionTests: XCTestCase {
    func testImportedLibrarySelectsFirstServerAndBuildsConnectionRequest() throws {
        let document = try RdcManParser().parse(fileAt: fixtureURL())
        let library = RdcImportedLibrary(document: document, sourceName: "temp2.rdg")

        XCTAssertEqual(library.sourceName, "temp2.rdg")
        XCTAssertEqual(library.servers.count, 2)
        XCTAssertEqual(library.selectedServer?.displayName, "Windows Server A")

        let request = try XCTUnwrap(library.selectedServer?.connectionRequest)
        XCTAssertEqual(
            request.serverID,
            StableLibraryID.server(
                sourceID: library.sourceID,
                path: ["示例资源库", "生产环境", "业务服务器", "Windows Server A"],
                host: "rdp.example.test",
                port: 6_166
            )
        )
        XCTAssertEqual(request.host, "rdp.example.test")
        XCTAssertEqual(request.port, 6166)
        XCTAssertEqual(request.username, "administrator")
        XCTAssertEqual(request.domain, "EXAMPLE")
    }

    func testImportedLibraryCanSelectServerByStableIdentity() throws {
        let document = try RdcManParser().parse(fileAt: fixtureURL())
        let firstLibrary = RdcImportedLibrary(document: document, sourceName: "temp2.rdg")
        let secondServer = try XCTUnwrap(firstLibrary.servers.last)

        let library = firstLibrary.selectingServer(id: secondServer.id)

        XCTAssertEqual(library.selectedServer?.displayName, "Windows Server B")
        XCTAssertEqual(library.selectedServer?.connectionRequest.host, "198.51.100.57")
        XCTAssertNil(library.selectedServer?.connectionRequest.port)
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/minimal-rdcman.rdg")
    }
}
