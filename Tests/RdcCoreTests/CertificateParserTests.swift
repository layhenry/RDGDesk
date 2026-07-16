import Foundation
import XCTest
@testable import RdcCore

final class CertificateParserTests: XCTestCase {
    func testParsesExpiredLocalhostCertificateDetailsAndFingerprint() throws {
        let pem = try fixturePEM()

        let challenge = try RdpCertificateChallenge(
            id: 7,
            endpoint: RdpEndpoint(host: "localhost", port: 3389),
            pemData: Data(pem.utf8),
            flags: 0
        )

        XCTAssertEqual(challenge.commonName, "localhost")
        XCTAssertTrue(challenge.subject.contains("localhost"))
        XCTAssertTrue(challenge.issuer.contains("localhost"))
        XCTAssertEqual(challenge.notBefore, iso8601("2020-01-01T00:00:00Z"))
        XCTAssertEqual(challenge.notAfter, iso8601("2021-01-01T00:00:00Z"))
        XCTAssertEqual(
            challenge.sha256Fingerprint,
            "27:E4:63:81:5E:BA:F2:60:FF:B3:EE:63:97:32:69:F4:" +
                "2E:96:49:AF:D5:9A:83:49:26:55:75:6B:61:61:8D:2C"
        )
        XCTAssertFalse(challenge.hostNameMismatch)
        XCTAssertEqual(challenge.pemData, Data(pem.utf8))
    }

    func testMismatchFlagIsCopiedFromFreeRDP() throws {
        let challenge = try RdpCertificateChallenge(
            id: 8,
            endpoint: RdpEndpoint(host: "example.invalid", port: 3390),
            pemData: Data(try fixturePEM().utf8),
            flags: 0x80
        )

        XCTAssertTrue(challenge.hostNameMismatch)
    }

    func testRejectsMalformedPEM() {
        XCTAssertThrowsError(
            try RdpCertificateChallenge(
                id: 9,
                endpoint: RdpEndpoint(host: "localhost", port: 3389),
                pemData: Data("not a certificate".utf8),
                flags: 0
            )
        )
    }

    private func fixturePEM() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "test-certificate",
                withExtension: "pem",
                subdirectory: "Fixtures"
            )
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func iso8601(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
