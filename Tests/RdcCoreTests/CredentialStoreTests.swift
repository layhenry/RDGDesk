import XCTest
@testable import RdcCore

final class CredentialStoreTests: XCTestCase {
    func testDpapiPasswordsAreMarkedNotMigratableAndNeverDecrypted() {
        let decision = CredentialImportDecision(rdcPassword: .windowsDPAPIEncrypted("AQAAANCMnd8BFdERjHoAwE"))

        XCTAssertEqual(decision.status, .requiresUserEntry)
        XCTAssertEqual(decision.reason, .windowsDPAPINotMigratableToMacOSKeychain)
        XCTAssertFalse(decision.attemptedDecryption)
    }

    func testImportDecisionDoesNotCarryPasswordBearingCredentialState() {
        let decision = CredentialImportDecision(rdcPassword: .none)

        XCTAssertFalse(Mirror(reflecting: decision).children.contains { $0.label == "credential" })
    }
}
