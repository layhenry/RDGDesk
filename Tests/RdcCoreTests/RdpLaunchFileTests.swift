import XCTest
@testable import RdcCore

final class RdpLaunchFileTests: XCTestCase {
    func testLaunchFileBuildsRdpContentWithoutPassword() {
        let credential = ServerCredential(
            username: "administrator",
            domain: "EXAMPLE",
            secret: .password("do-not-write")
        )
        let request = RdpConnectionRequest(
            serverID: "group/server",
            host: "rdp.example.test",
            port: 6166,
            username: "administrator",
            domain: "EXAMPLE"
        )

        let file = RdpLaunchFile(request: request, credential: credential)

        XCTAssertEqual(file.suggestedFilename, "group-server.rdp")
        XCTAssertTrue(file.contents.contains("full address:s:rdp.example.test:6166"))
        XCTAssertTrue(file.contents.contains("username:s:EXAMPLE\\administrator"))
        XCTAssertTrue(file.contents.contains("prompt for credentials:i:1"))
        XCTAssertFalse(file.contents.contains("do-not-write"))
        XCTAssertFalse(file.contents.localizedCaseInsensitiveContains("password"))
    }

    func testLaunchFileDefaultsToPromptWhenCredentialMissing() {
        let request = RdpConnectionRequest(
            serverID: "Example Server B",
            host: "198.51.100.57",
            port: nil,
            username: nil,
            domain: nil
        )

        let file = RdpLaunchFile(request: request, credential: nil)

        XCTAssertEqual(file.suggestedFilename, "Example Server B.rdp")
        XCTAssertTrue(file.contents.contains("full address:s:198.51.100.57"))
        XCTAssertTrue(file.contents.contains("prompt for credentials:i:1"))
        XCTAssertFalse(file.contents.contains("username:s:"))
    }
}
