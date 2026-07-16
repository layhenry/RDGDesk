import Foundation
import XCTest
@testable import RdcCore

final class CertificateTrustCoordinatorTests: XCTestCase {
    func testTrustClassificationDistinguishesFirstUseMatchAndChange() throws {
        let challenge = try certificateChallenge()
        let matching = certificatePin(
            endpoint: challenge.endpoint,
            fingerprint: challenge.sha256Fingerprint
        )
        let changed = certificatePin(endpoint: challenge.endpoint, fingerprint: "CC:DD")

        XCTAssertEqual(
            CertificateTrustCoordinator.classify(challenge: challenge, pin: nil),
            .requiresFirstUseApproval(challenge)
        )
        XCTAssertEqual(
            CertificateTrustCoordinator.classify(challenge: challenge, pin: matching),
            .trustedStoredPin
        )
        XCTAssertEqual(
            CertificateTrustCoordinator.classify(challenge: challenge, pin: changed),
            .requiresChangedCertificateApproval(old: changed, new: challenge)
        )
    }

    func testStoredPinUsesNormalizedHostAndExactPortIdentity() async throws {
        let challenge = try certificateChallenge(host: "EXAMPLE.invalid", port: 3_389)
        let matching = certificatePin(
            endpoint: .init(host: " example.INVALID ", port: 3_389),
            fingerprint: challenge.sha256Fingerprint
        )
        let otherPort = certificatePin(
            endpoint: .init(host: "example.invalid", port: 3_390),
            fingerprint: challenge.sha256Fingerprint
        )
        let store = CertificateConfigurationStore(configuration: .init(certificatePins: [
            matching.endpoint: matching,
            otherPort.endpoint: otherPort,
        ]))
        let coordinator = CertificateTrustCoordinator(
            configurationRepository: RdcConfigurationRepository(store: store)
        )

        let matchingPresentation = try await coordinator.presentation(for: challenge)
        XCTAssertNil(matchingPresentation)

        let differentPort = try certificateChallenge(host: "example.invalid", port: 3_391)
        let differentPortPresentation = try await coordinator.presentation(for: differentPort)
        XCTAssertEqual(differentPortPresentation, .firstUse(differentPort))
    }

    func testTrustAlwaysPersistsNewPinBeforeReturningNativeDecision() async throws {
        let challenge = try certificateChallenge()
        let now = Date(timeIntervalSince1970: 1_234)
        let store = CertificateConfigurationStore()
        let coordinator = CertificateTrustCoordinator(
            configurationRepository: RdcConfigurationRepository(store: store),
            now: { now }
        )

        let decision = try await coordinator.prepareResolution(
            challenge: challenge,
            decision: .trustAlways
        )

        XCTAssertEqual(decision, .trustAlways)
        let savedConfiguration = try await store.load()
        let saved = try XCTUnwrap(savedConfiguration.certificatePins[challenge.endpoint])
        XCTAssertEqual(saved.sha256Fingerprint, challenge.sha256Fingerprint)
        XCTAssertEqual(saved.subject, challenge.subject)
        XCTAssertEqual(saved.issuer, challenge.issuer)
        XCTAssertEqual(saved.firstTrustedAt, now)
        XCTAssertEqual(saved.lastConfirmedAt, now)
    }

    func testChangedCertificatePreservesOldPinWhenSaveFails() async throws {
        let challenge = try certificateChallenge()
        let old = certificatePin(endpoint: challenge.endpoint, fingerprint: "OLD")
        let store = CertificateConfigurationStore(
            configuration: .init(certificatePins: [challenge.endpoint: old])
        )
        await store.failNextSave()
        let coordinator = CertificateTrustCoordinator(
            configurationRepository: RdcConfigurationRepository(store: store)
        )

        do {
            _ = try await coordinator.prepareResolution(
                challenge: challenge,
                decision: .trustAlways
            )
            XCTFail("expected persistence failure")
        } catch {
            XCTAssertEqual(error as? CertificateTrustCoordinatorError, .configurationPersistenceFailed)
        }

        let configurationAfterFailure = try await store.load()
        XCTAssertEqual(configurationAfterFailure.certificatePins[challenge.endpoint], old)
    }

    func testRejectAndTrustOnceDoNotPersistPins() async throws {
        let challenge = try certificateChallenge()
        let store = CertificateConfigurationStore()
        let coordinator = CertificateTrustCoordinator(
            configurationRepository: RdcConfigurationRepository(store: store)
        )

        let trustOnce = try await coordinator.prepareResolution(
            challenge: challenge, decision: .trustOnce
        )
        let reject = try await coordinator.prepareResolution(
            challenge: challenge, decision: .reject
        )
        XCTAssertEqual(trustOnce, .trustOnce)
        XCTAssertEqual(reject, .reject)
        let configuration = try await store.load()
        XCTAssertTrue(configuration.certificatePins.isEmpty)
    }

    func testRemovePinRevokesOnlyExactEndpoint() async throws {
        let firstEndpoint = RdpEndpoint(host: "one.invalid", port: 3_389)
        let secondEndpoint = RdpEndpoint(host: "one.invalid", port: 3_390)
        let first = certificatePin(endpoint: firstEndpoint, fingerprint: "AA")
        let second = certificatePin(endpoint: secondEndpoint, fingerprint: "BB")
        let store = CertificateConfigurationStore(configuration: .init(certificatePins: [
            firstEndpoint: first,
            secondEndpoint: second,
        ]))
        let coordinator = CertificateTrustCoordinator(
            configurationRepository: RdcConfigurationRepository(store: store)
        )

        try await coordinator.removePin(for: firstEndpoint)

        let pins = try await store.load().certificatePins
        XCTAssertNil(pins[firstEndpoint])
        XCTAssertEqual(pins[secondEndpoint], second)
    }

    private func certificateChallenge(
        host: String = "example.invalid",
        port: UInt16 = 3_389
    ) throws -> RdpCertificateChallenge {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "test-certificate",
            withExtension: "pem",
            subdirectory: "Fixtures"
        ))
        return try RdpCertificateChallenge(
            id: 42,
            endpoint: RdpEndpoint(host: host, port: port),
            pemData: Data(contentsOf: url),
            flags: 0
        )
    }

    private func certificatePin(
        endpoint: RdpEndpoint,
        fingerprint: String
    ) -> CertificatePin {
        CertificatePin(
            endpoint: endpoint,
            subject: "old subject",
            issuer: "old issuer",
            sha256Fingerprint: fingerprint,
            notBefore: nil,
            notAfter: nil,
            firstTrustedAt: Date(timeIntervalSince1970: 10),
            lastConfirmedAt: Date(timeIntervalSince1970: 20)
        )
    }
}

private actor CertificateConfigurationStore: RdcConfigurationStore {
    private var configuration: RdcAppConfiguration
    private var shouldFailNextSave = false

    init(configuration: RdcAppConfiguration = .default) {
        self.configuration = configuration
    }

    func load() async throws -> RdcAppConfiguration { configuration }

    func save(_ configuration: RdcAppConfiguration) async throws {
        if shouldFailNextSave {
            shouldFailNextSave = false
            throw CertificateStoreError.saveFailed
        }
        self.configuration = configuration
    }

    func failNextSave() {
        shouldFailNextSave = true
    }
}

private enum CertificateStoreError: Error {
    case saveFailed
}
