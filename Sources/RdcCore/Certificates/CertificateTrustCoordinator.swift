import Foundation

public enum CertificateTrustClassification: Equatable, Sendable {
    case trustedStoredPin
    case requiresFirstUseApproval(RdpCertificateChallenge)
    case requiresChangedCertificateApproval(old: CertificatePin, new: RdpCertificateChallenge)
}

public enum CertificateTrustPresentation: Equatable, Sendable {
    case firstUse(RdpCertificateChallenge)
    case changed(old: CertificatePin, new: RdpCertificateChallenge)
}

public enum CertificateTrustCoordinatorError: Error, Equatable, Sendable {
    case configurationPersistenceFailed
}

public actor CertificateTrustCoordinator {
    private let configurationRepository: RdcConfigurationRepository
    private let now: @Sendable () -> Date

    public init(
        configurationRepository: RdcConfigurationRepository,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configurationRepository = configurationRepository
        self.now = now
    }

    public nonisolated static func classify(
        challenge: RdpCertificateChallenge,
        pin: CertificatePin?
    ) -> CertificateTrustClassification {
        guard let pin else {
            return .requiresFirstUseApproval(challenge)
        }
        guard pin.endpoint == challenge.endpoint,
              pin.sha256Fingerprint == challenge.sha256Fingerprint else {
            return .requiresChangedCertificateApproval(old: pin, new: challenge)
        }
        return .trustedStoredPin
    }

    public func presentation(
        for challenge: RdpCertificateChallenge
    ) async throws -> CertificateTrustPresentation? {
        let pin = try await configurationRepository.snapshot()
            .certificatePins[challenge.endpoint]
        switch Self.classify(challenge: challenge, pin: pin) {
        case .trustedStoredPin:
            return nil
        case let .requiresFirstUseApproval(challenge):
            return .firstUse(challenge)
        case let .requiresChangedCertificateApproval(old, new):
            return .changed(old: old, new: new)
        }
    }

    public func prepareResolution(
        challenge: RdpCertificateChallenge,
        decision: RdpCertificateDecision
    ) async throws -> RdpCertificateDecision {
        guard decision == .trustAlways else { return decision }
        let timestamp = now()
        do {
            try await configurationRepository.update { configuration in
                let old = configuration.certificatePins[challenge.endpoint]
                configuration.certificatePins[challenge.endpoint] = CertificatePin(
                    endpoint: challenge.endpoint,
                    subject: challenge.subject,
                    issuer: challenge.issuer,
                    sha256Fingerprint: challenge.sha256Fingerprint,
                    notBefore: challenge.notBefore,
                    notAfter: challenge.notAfter,
                    firstTrustedAt: old?.firstTrustedAt ?? timestamp,
                    lastConfirmedAt: timestamp
                )
            }
        } catch {
            throw CertificateTrustCoordinatorError.configurationPersistenceFailed
        }
        return .trustAlways
    }

    public func removePin(for endpoint: RdpEndpoint) async throws {
        do {
            try await configurationRepository.update { configuration in
                configuration.certificatePins.removeValue(forKey: endpoint)
            }
        } catch {
            throw CertificateTrustCoordinatorError.configurationPersistenceFailed
        }
    }
}
