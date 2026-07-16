import Foundation
import XCTest
@testable import RdcCore

final class EmbeddedConnectionTests: XCTestCase {
    func testConfigurationErrorsNeverExposeEnvironmentValues() {
        let values = [
            "RDC_TEST_HOST": "sentinel-host",
            "RDC_TEST_PORT": "3389",
            "RDC_TEST_USER": "sentinel-user",
            "RDC_TEST_DOMAIN": "sentinel-domain",
            "RDC_TEST_PASSWORD": "sentinel-password",
            "RDC_TEST_EXPECTED_SHA256": String(repeating: "AA:", count: 31) + "AA",
        ]
        for key in values.keys {
            var missingValue = values
            missingValue.removeValue(forKey: key)
            assertConfigurationFailureIsSanitized(environment: missingValue)
        }

        var invalidFingerprint = values
        invalidFingerprint["RDC_TEST_EXPECTED_SHA256"] = "sentinel-fingerprint"
        assertConfigurationFailureIsSanitized(environment: invalidFingerprint)

        var invalidPort = values
        invalidPort["RDC_TEST_PORT"] = "sentinel-port"
        assertConfigurationFailureIsSanitized(environment: invalidPort)
    }

    func testRealFirstUseTrustOnceAndStoredMatchingPin() async throws {
        let configuration = try RealServerIntegrationConfiguration.load()
        let repository = RdcConfigurationRepository(store: IntegrationConfigurationStore())
        let coordinator = CertificateTrustCoordinator(configurationRepository: repository)

        do {
            let first = try await connect(
                configuration: configuration,
                coordinator: coordinator,
                expectedPresentation: true
            )
            guard first.challenge.sha256Fingerprint == configuration.expectedFingerprint else {
                XCTFail("Real-server certificate fingerprint did not match the configured expectation")
                await first.engine.disconnect()
                return
            }
            try await assertConnectedWithFrameAndDisconnect(first)
            let afterTrustOnce = try await repository.snapshot()
            guard afterTrustOnce.certificatePins.isEmpty else {
                XCTFail("Trust once unexpectedly persisted a certificate pin")
                return
            }

            _ = try await coordinator.prepareResolution(
                challenge: first.challenge,
                decision: .trustAlways
            )
            let second = try await connect(
                configuration: configuration,
                coordinator: coordinator,
                expectedPresentation: false
            )
            try await assertConnectedWithFrameAndDisconnect(second)
        } catch is XCTSkip {
            throw XCTSkip("Real-server integration is disabled; all required RDC_TEST_* values are needed")
        } catch {
            XCTFail("Real-server credential/certificate workflow failed")
        }
    }

    private func assertConfigurationFailureIsSanitized(environment: [String: String]) {
        do {
            _ = try RealServerIntegrationConfiguration.load(environment: environment)
            XCTFail("Expected sanitized integration configuration failure")
        } catch {
            let description = String(describing: error)
            for value in environment.values {
                if description.contains(value) {
                    XCTFail("Integration configuration error exposed an environment value")
                }
            }
        }
    }

    private func connect(
        configuration: RealServerIntegrationConfiguration,
        coordinator: CertificateTrustCoordinator,
        expectedPresentation: Bool
    ) async throws -> RealConnectionResult {
        setenv("WLOG_LEVEL", "OFF", 1)
        let engine = FreeRDPSessionEngine()
        let attemptID = RdpConnectionAttemptID()
        let request = RdpConnectionRequest(
            serverID: "integration-server",
            host: configuration.host,
            port: Int(configuration.port),
            username: configuration.username,
            domain: configuration.domain
        )
        let credential = RdpConnectionCredential(
            username: configuration.username,
            domain: configuration.domain,
            password: configuration.password
        )

        do {
            return try await withTimeout(seconds: 20) {
                async let frame = Self.firstNonEmptyFrame(from: engine.frames)
                async let descriptor = engine.connect(
                    request,
                    credential: credential,
                    viewport: RdpViewport(width: 1_440, height: 900),
                    attemptID: attemptID
                )
                let update = try await Self.firstCertificateChallenge(
                    from: engine.certificateChallenges
                )
                guard Self.isUppercaseSHA256(update.challenge.sha256Fingerprint) else {
                    XCTFail("Certificate fingerprint was empty or not uppercase SHA-256")
                    throw IntegrationFailure.assertion
                }
                let presentation = try await coordinator.presentation(for: update.challenge)
                guard (presentation != nil) == expectedPresentation else {
                    XCTFail("Certificate presentation did not match the expected first-use or stored-pin path")
                    throw IntegrationFailure.assertion
                }
                await engine.resolveCertificate(
                    attemptID: update.attemptID,
                    sessionID: update.sessionID,
                    challengeID: update.challenge.id,
                    decision: .trustOnce
                )
                return try await RealConnectionResult(
                    engine: engine,
                    descriptor: descriptor,
                    challenge: update.challenge,
                    receivedFrame: frame
                )
            }
        } catch {
            await engine.disconnect()
            throw error
        }
    }

    private func assertConnectedWithFrameAndDisconnect(_ result: RealConnectionResult) async throws {
        guard await result.engine.currentState() == .connected(result.descriptor) else {
            XCTFail("Real-server connection did not reach connected state")
            await result.engine.disconnect()
            throw IntegrationFailure.assertion
        }
        guard result.receivedFrame else {
            XCTFail("Real-server connection did not receive a nonempty frame")
            await result.engine.disconnect()
            throw IntegrationFailure.assertion
        }
        await result.engine.disconnect()
        guard await result.engine.currentState() == .disconnected else {
            XCTFail("Real-server connection did not reach disconnected state")
            throw IntegrationFailure.assertion
        }
    }

    private static func firstCertificateChallenge(
        from challenges: AsyncStream<RdpCertificateChallengeUpdate>
    ) async throws -> RdpCertificateChallengeUpdate {
        for await challenge in challenges { return challenge }
        throw IntegrationFailure.streamEnded
    }

    private static func firstNonEmptyFrame(from frames: AsyncStream<RemoteFrame>) async -> Bool {
        for await frame in frames {
            if frame.width > 0, frame.height > 0, !frame.bgraBytes.isEmpty { return true }
        }
        return false
    }

    private static func isUppercaseSHA256(_ value: String) -> Bool {
        value.range(of: #"^[0-9A-F]{2}(:[0-9A-F]{2}){31}$"#, options: .regularExpression) != nil
    }

    private func withTimeout<T: Sendable>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw IntegrationFailure.timeout
            }
            guard let result = try await group.next() else { throw IntegrationFailure.timeout }
            group.cancelAll()
            return result
        }
    }
}

private struct RealServerIntegrationConfiguration: Sendable {
    let host: String
    let port: UInt16
    let username: String
    let domain: String
    let password: String
    let expectedFingerprint: String

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard let host = environment["RDC_TEST_HOST"]?.nilIfBlank,
              let portText = environment["RDC_TEST_PORT"]?.nilIfBlank,
              let port = UInt16(portText), port > 0,
              let username = environment["RDC_TEST_USER"]?.nilIfBlank,
              let domain = environment["RDC_TEST_DOMAIN"]?.nilIfBlank,
              let password = environment["RDC_TEST_PASSWORD"], !password.isEmpty,
              let expected = environment["RDC_TEST_EXPECTED_SHA256"]?.nilIfBlank else {
            throw XCTSkip("Real-server integration is disabled; all required RDC_TEST_* values are needed")
        }
        let fingerprint = expected.uppercased()
        guard fingerprint.range(
            of: #"^[0-9A-F]{2}(:[0-9A-F]{2}){31}$"#,
            options: .regularExpression
        ) != nil else {
            throw IntegrationFailure.invalidConfiguration
        }
        return Self(
            host: host,
            port: port,
            username: username,
            domain: domain,
            password: password,
            expectedFingerprint: fingerprint
        )
    }
}

private struct RealConnectionResult: Sendable {
    let engine: FreeRDPSessionEngine
    let descriptor: RdpSessionDescriptor
    let challenge: RdpCertificateChallenge
    let receivedFrame: Bool
}

private actor IntegrationConfigurationStore: RdcConfigurationStore {
    private var configuration = RdcAppConfiguration.default

    func load() async throws -> RdcAppConfiguration { configuration }
    func save(_ configuration: RdcAppConfiguration) async throws {
        self.configuration = configuration
    }
}

private enum IntegrationFailure: Error {
    case assertion
    case invalidConfiguration
    case streamEnded
    case timeout
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
