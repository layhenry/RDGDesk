import XCTest
@testable import RdcCore

final class RdcManParserTests: XCTestCase {
    func testParsesRdcmanMetadataAndRootGroup() throws {
        let document = try RdcManParser().parse(fileAt: fixtureURL())

        XCTAssertEqual(document.programVersion, "2.92")
        XCTAssertEqual(document.schemaVersion, "3")
        XCTAssertEqual(document.root.name, "示例资源库")
        XCTAssertEqual(document.root.groups.map(\.name), ["生产环境"])
    }

    func testParsesNestedGroupsAndServersWithHostPort() throws {
        let document = try RdcManParser().parse(fileAt: fixtureURL())
        let group = try XCTUnwrap(document.root.groups.first?.groups.first)

        XCTAssertEqual(group.name, "业务服务器")
        XCTAssertEqual(group.servers.count, 2)
        XCTAssertEqual(group.servers[0].displayName, "Windows Server A")
        XCTAssertEqual(group.servers[0].address.rawValue, "rdp.example.test:6166")
        XCTAssertEqual(group.servers[0].address.host, "rdp.example.test")
        XCTAssertEqual(group.servers[0].address.port, 6166)
        XCTAssertEqual(group.servers[1].displayName, "Windows Server B")
        XCTAssertEqual(group.servers[1].address.host, "198.51.100.57")
        XCTAssertNil(group.servers[1].address.port)
    }

    func testParsesCredentialInheritanceAndMarksDpapiPasswordAsNotMacDecryptable() throws {
        let document = try RdcManParser().parse(fileAt: fixtureURL())
        let credentials = try XCTUnwrap(document.root.logonCredentials)

        XCTAssertEqual(credentials.inheritance, .none)
        XCTAssertEqual(credentials.userName, "administrator")
        XCTAssertEqual(credentials.domain, "EXAMPLE")
        XCTAssertEqual(credentials.password, .windowsDPAPIEncrypted("AQAAANCMnd8BFdERjHoAwEExampleDpapiCipherText"))
        XCTAssertFalse(credentials.password.isDecryptableOnMac)
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/minimal-rdcman.rdg")
    }
}
