import Foundation
import XCTest
@testable import RdcCore

final class CertificateTrustIntegrationTests: XCTestCase {
    func testChangedPinBlocksAndRejectsUntilExplicitDecision() async throws {
        let fixture = try ChangedPinIntegrationFixture()

        await fixture.presentChangedCertificate()
        let blocked = await fixture.isBlockedBeforeDecision
        let fingerprintsShown = await fixture.presentationContainsOldAndNewFingerprints
        XCTAssertTrue(blocked)
        XCTAssertTrue(fingerprintsShown)

        await fixture.cancel()
        let resolutions = await fixture.resolutions
        let oldPinPersisted = await fixture.oldPinIsStillPersisted
        let connectionProceeded = await fixture.connectionProceeded
        XCTAssertEqual(resolutions, [.reject])
        XCTAssertTrue(oldPinPersisted)
        XCTAssertFalse(connectionProceeded)
    }

    func testChangedPinUpdateResolvesOnlyAfterSuccessfulSave() async throws {
        let fixture = try ChangedPinIntegrationFixture()

        await fixture.presentChangedCertificate()
        await fixture.updateAndTrustAlways()

        let resolutions = await fixture.resolutions
        let newPinPersisted = await fixture.newPinIsPersisted
        let connectionProceeded = await fixture.connectionProceeded
        XCTAssertEqual(resolutions, [.trustAlways])
        XCTAssertTrue(newPinPersisted)
        XCTAssertTrue(connectionProceeded)
    }

    func testChangedPinSaveFailureRejectsAndPreservesOldPin() async throws {
        let fixture = try ChangedPinIntegrationFixture(failSave: true)

        await fixture.presentChangedCertificate()
        await fixture.updateAndTrustAlways()

        let resolutions = await fixture.resolutions
        let oldPinPersisted = await fixture.oldPinIsStillPersisted
        let connectionProceeded = await fixture.connectionProceeded
        XCTAssertEqual(resolutions, [.reject])
        XCTAssertTrue(oldPinPersisted)
        XCTAssertFalse(connectionProceeded)
    }
}

private actor ChangedPinIntegrationFixture {
    private let endpoint = RdpEndpoint(host: "changed-pin.invalid", port: 3_389)
    private let oldPin: CertificatePin
    private let challenge: RdpCertificateChallenge
    private let store: ChangedPinConfigurationStore
    private let coordinator: CertificateTrustCoordinator
    private let bridge = ControllableCertificateBridge()
    private var presentation: CertificateTrustPresentation?

    init(failSave: Bool = false) throws {
        let certificateURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../RdcCoreTests/Fixtures/test-certificate.pem")
            .standardizedFileURL
        challenge = try RdpCertificateChallenge(
            id: 9001,
            endpoint: endpoint,
            pemData: Data(contentsOf: certificateURL),
            flags: 0x80
        )
        oldPin = CertificatePin(
            endpoint: endpoint,
            subject: "previous subject",
            issuer: "previous issuer",
            sha256Fingerprint: "00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF",
            notBefore: nil,
            notAfter: nil,
            firstTrustedAt: Date(timeIntervalSince1970: 1),
            lastConfirmedAt: Date(timeIntervalSince1970: 2)
        )
        let store = ChangedPinConfigurationStore(
            configuration: .init(certificatePins: [endpoint: oldPin]),
            failSave: failSave
        )
        self.store = store
        coordinator = CertificateTrustCoordinator(
            configurationRepository: RdcConfigurationRepository(store: store)
        )
    }

    func presentChangedCertificate() async {
        presentation = try? await coordinator.presentation(for: challenge)
    }

    var isBlockedBeforeDecision: Bool {
        bridge.resolutions.isEmpty && !bridge.connectionProceeded
    }

    var presentationContainsOldAndNewFingerprints: Bool {
        guard case let .changed(old, new) = presentation else { return false }
        return old.sha256Fingerprint == oldPin.sha256Fingerprint
            && new.sha256Fingerprint == challenge.sha256Fingerprint
    }

    func cancel() async {
        let decision = (try? await coordinator.prepareResolution(
            challenge: challenge, decision: .reject
        )) ?? .reject
        bridge.resolveCertificate(challengeID: challenge.id, decision: decision)
    }

    func updateAndTrustAlways() async {
        do {
            let decision = try await coordinator.prepareResolution(
                challenge: challenge, decision: .trustAlways
            )
            bridge.resolveCertificate(challengeID: challenge.id, decision: decision)
        } catch {
            bridge.resolveCertificate(challengeID: challenge.id, decision: .reject)
        }
    }

    var resolutions: [RdpCertificateDecision] { bridge.resolutions }
    var connectionProceeded: Bool { bridge.connectionProceeded }

    var oldPinIsStillPersisted: Bool {
        get async {
            guard let saved = try? await store.load().certificatePins[endpoint] else { return false }
            return saved == oldPin
        }
    }

    var newPinIsPersisted: Bool {
        get async {
            guard let saved = try? await store.load().certificatePins[endpoint] else { return false }
            return saved.sha256Fingerprint == challenge.sha256Fingerprint
        }
    }
}

private actor ChangedPinConfigurationStore: RdcConfigurationStore {
    private var configuration: RdcAppConfiguration
    private var failSave: Bool

    init(configuration: RdcAppConfiguration, failSave: Bool) {
        self.configuration = configuration
        self.failSave = failSave
    }

    func load() async throws -> RdcAppConfiguration { configuration }

    func save(_ configuration: RdcAppConfiguration) async throws {
        if failSave {
            failSave = false
            throw ChangedPinFailure.save
        }
        self.configuration = configuration
    }
}

private final class ControllableCertificateBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RdpCertificateDecision] = []
    private var didProceed = false

    var resolutions: [RdpCertificateDecision] { lock.withLock { recorded } }
    var connectionProceeded: Bool { lock.withLock { didProceed } }

    func resolveCertificate(challengeID: UInt64, decision: RdpCertificateDecision) {
        guard challengeID != 0 else { return }
        lock.withLock {
            recorded.append(decision)
            didProceed = decision != .reject
        }
    }
}

private enum ChangedPinFailure: Error { case save }
