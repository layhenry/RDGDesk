import XCTest
@testable import RdcApp

final class ServerEndpointInputTests: XCTestCase {
    func testResolvesEmbeddedPortsForDNSIPv4AndBracketedIPv6() throws {
        let cases = [
            (" q6id.cn:6609 ", "q6id.cn", 6_609),
            ("192.168.1.10:6609", "192.168.1.10", 6_609),
            ("[2001:db8::10]:6609", "2001:db8::10", 6_609)
        ]

        for (address, expectedHost, expectedPort) in cases {
            let result = try ServerEndpointInputParser.resolve(
                address: address,
                portText: "3389"
            )
            XCTAssertEqual(result.host, expectedHost)
            XCTAssertEqual(result.port, expectedPort)
            XCTAssertTrue(result.usesEmbeddedPort)
        }
    }

    func testUsesSeparatePortForPlainHostsBareIPv6AndBracketedIPv6() throws {
        for address in ["q6id.cn", "192.168.1.10", "2001:db8::10", "[2001:db8::10]"] {
            let result = try ServerEndpointInputParser.resolve(
                address: address,
                portText: " 6609 "
            )
            XCTAssertEqual(result.port, 6_609)
            XCTAssertFalse(result.usesEmbeddedPort)
        }
        XCTAssertEqual(
            try ServerEndpointInputParser.resolve(
                address: "2001:db8::10", portText: "6609"
            ).host,
            "2001:db8::10"
        )
    }

    func testRejectsInvalidEmbeddedPortsAndMalformedAddresses() {
        for address in ["q6id.cn:", "q6id.cn:0", "q6id.cn:65536", "q6id.cn:abc"] {
            XCTAssertThrowsError(
                try ServerEndpointInputParser.resolve(address: address, portText: "3389")
            ) {
                XCTAssertEqual(
                    $0 as? ServerEndpointInputValidationError,
                    .invalidEmbeddedPort
                )
            }
        }

        for address in [
            "", "https://q6id.cn:6609", "[2001:db8::10", "[q6id.cn]:6609",
            "[2001:db8::10]extra", "999.1.1.1:6609"
        ] {
            XCTAssertThrowsError(
                try ServerEndpointInputParser.resolve(address: address, portText: "3389")
            ) {
                XCTAssertEqual($0 as? ServerEndpointInputValidationError, .invalidHost)
            }
        }
    }

    func testEmbeddedPortIgnoresSeparatePortButPlainHostValidatesIt() throws {
        for portText in ["", "3390", "not-a-port"] {
            let embedded = try ServerEndpointInputParser.resolve(
                address: "q6id.cn:6609",
                portText: portText
            )
            XCTAssertEqual(embedded.port, 6_609)
            XCTAssertTrue(embedded.usesEmbeddedPort)
        }

        for portText in ["", "0", "65536", "not-a-port"] {
            XCTAssertThrowsError(
                try ServerEndpointInputParser.resolve(
                    address: "q6id.cn", portText: portText
                )
            ) {
                XCTAssertEqual($0 as? ServerEndpointInputValidationError, .invalidPort)
            }
        }
    }

    func testAcceptsPortBoundaries() throws {
        XCTAssertEqual(
            try ServerEndpointInputParser.resolve(
                address: "q6id.cn:1", portText: "3389"
            ).port,
            1
        )
        XCTAssertEqual(
            try ServerEndpointInputParser.resolve(
                address: "q6id.cn:65535", portText: "3389"
            ).port,
            65_535
        )
    }
}
