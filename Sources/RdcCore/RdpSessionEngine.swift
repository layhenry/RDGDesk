import Foundation

public protocol RdpSessionEngine: AnyObject, Sendable {
    func currentState() async -> RdpSessionState

    func connect(
        _ request: RdpConnectionRequest,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport,
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor
    func disconnect() async
    func disconnectVerified() async throws
    func reconnect(attemptID: RdpConnectionAttemptID) async throws -> RdpSessionDescriptor
    func resolveCertificate(
        attemptID: RdpConnectionAttemptID,
        sessionID: String,
        challengeID: UInt64,
        decision: RdpCertificateDecision
    ) async
    func resize(sessionID: String, width: Int, height: Int) async
    func sendPointer(sessionID: String, flags: UInt16, x: UInt16, y: UInt16) async
    func sendKey(sessionID: String, flags: UInt16, code: UInt16) async
    func sendUnicode(sessionID: String, event: RemoteUnicodeKeyEvent) async
    func sendSecureAttention(sessionID: String) async
    func setClipboardText(sessionID: String, text: String) async
}

public extension RdpSessionEngine {
    func disconnectVerified() async throws {
        await disconnect()
        switch await currentState() {
        case .idle, .disconnected:
            return
        case .connecting, .connected, .disconnecting, .failed:
            throw RdpSessionDisconnectError.notDisconnected
        }
    }
    func connect(
        _ request: RdpConnectionRequest,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport
    ) async throws -> RdpSessionDescriptor {
        try await connect(
            request,
            credential: credential,
            viewport: viewport,
            attemptID: RdpConnectionAttemptID()
        )
    }

    func reconnect() async throws -> RdpSessionDescriptor {
        try await reconnect(attemptID: RdpConnectionAttemptID())
    }

    func resolveCertificate(
        attemptID: RdpConnectionAttemptID,
        sessionID: String,
        challengeID: UInt64,
        decision: RdpCertificateDecision
    ) async {}

    func resize(sessionID: String, width: Int, height: Int) async {}
    func sendPointer(sessionID: String, flags: UInt16, x: UInt16, y: UInt16) async {}
    func sendKey(sessionID: String, flags: UInt16, code: UInt16) async {}
    func sendUnicode(sessionID: String, event: RemoteUnicodeKeyEvent) async {}
    func sendSecureAttention(sessionID: String) async {}
    func setClipboardText(sessionID: String, text: String) async {}
}

public enum RdpSessionDisconnectError: Error, Equatable, Sendable {
    case notDisconnected
}

public struct RdpConnectionAttemptID: Equatable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct RdpConnectionCredential: Equatable, Sendable {
    public let username: String?
    public let domain: String?
    public let password: String

    public init(username: String?, domain: String?, password: String) {
        self.username = username
        self.domain = domain
        self.password = password
    }
}

public struct RdpViewport: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
    }
}

public struct RdpConnectionRequest: Equatable, Sendable {
    public let serverID: String
    public let host: String
    public let port: Int?
    public let username: String?
    public let domain: String?

    public init(
        serverID: String,
        host: String,
        port: Int?,
        username: String?,
        domain: String?
    ) {
        self.serverID = serverID
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
    }
}

public struct RdpSessionDescriptor: Equatable, Identifiable, Sendable {
    public let id: String
    public let request: RdpConnectionRequest
    public let transport: RdpSessionTransport
}

public enum RdpSessionTransport: Equatable, Sendable {
    case mock
    case freeRDP
}

public enum RdpSessionState: Equatable, Sendable {
    case idle
    case connecting(RdpConnectionRequest)
    case connected(RdpSessionDescriptor)
    case disconnecting(RdpSessionDescriptor)
    case disconnected
    case failed(RdpSessionError)
}

public struct RdpSessionLifecycleUpdate: Equatable, Sendable {
    public let attemptID: RdpConnectionAttemptID
    public let sessionID: String
    public let state: RdpSessionState

    public init(
        attemptID: RdpConnectionAttemptID,
        sessionID: String,
        state: RdpSessionState
    ) {
        self.attemptID = attemptID
        self.sessionID = sessionID
        self.state = state
    }
}

public struct RdpSessionFrameUpdate: Equatable, Sendable {
    public let attemptID: RdpConnectionAttemptID
    public let sessionID: String
    public let frame: RemoteFrame

    public init(
        attemptID: RdpConnectionAttemptID,
        sessionID: String,
        frame: RemoteFrame
    ) {
        self.attemptID = attemptID
        self.sessionID = sessionID
        self.frame = frame
    }
}

public struct RdpClipboardUpdate: Equatable, Sendable {
    public let attemptID: RdpConnectionAttemptID
    public let sessionID: String
    public let text: String

    public init(attemptID: RdpConnectionAttemptID, sessionID: String, text: String) {
        self.attemptID = attemptID
        self.sessionID = sessionID
        self.text = text
    }
}

public struct RdpCertificateChallengeUpdate: Equatable, Sendable {
    public let attemptID: RdpConnectionAttemptID
    public let sessionID: String
    public let challenge: RdpCertificateChallenge

    public init(
        attemptID: RdpConnectionAttemptID,
        sessionID: String,
        challenge: RdpCertificateChallenge
    ) {
        self.attemptID = attemptID
        self.sessionID = sessionID
        self.challenge = challenge
    }
}

public enum RdpAuthenticationFailureReason: Equatable, Sendable {
    case wrongPassword
    case invalidCredentials
    case accountDisabled
    case accountLocked
    case passwordExpired
    case passwordMustChange
    case accountRestriction
    case accountExpired
    case unknown
}

public enum RdpSessionError: Error, Equatable, Sendable {
    case missingEndpoint
    case invalidPort(Int)
    case invalidViewport(width: Int, height: Int)
    case authenticationFailed(reason: RdpAuthenticationFailureReason, code: Int32?)
    case certificateRejected
    case network(code: Int32, message: String)
    case protocolFailure(code: Int32, message: String)
    case notConnected
    case simulatedFailure(String)
}

public final class MockRdpSessionEngine: RdpSessionEngine, @unchecked Sendable {
    public private(set) var state: RdpSessionState = .idle
    public private(set) var stateHistory: [RdpSessionState] = [.idle]

    private var lastRequest: RdpConnectionRequest?
    private var lastViewport: RdpViewport?
    private var sequence = 0

    public init() {}

    public func currentState() async -> RdpSessionState {
        state
    }

    public func connect(
        _ request: RdpConnectionRequest,
        credential: RdpConnectionCredential?,
        viewport: RdpViewport,
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        guard !request.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            record(.failed(.missingEndpoint))
            throw RdpSessionError.missingEndpoint
        }

        lastRequest = request
        lastViewport = viewport
        record(.connecting(request))
        sequence += 1

        let session = RdpSessionDescriptor(
            id: "mock-rdp-session-\(sequence)",
            request: request,
            transport: .mock
        )
        record(.connected(session))
        return session
    }

    public func disconnect() async {
        if case let .connected(session) = state {
            record(.disconnecting(session))
        }
        record(.disconnected)
    }

    public func reconnect(
        attemptID: RdpConnectionAttemptID
    ) async throws -> RdpSessionDescriptor {
        guard let lastRequest, let lastViewport else {
            record(.failed(.notConnected))
            throw RdpSessionError.notConnected
        }

        return try await connect(
            lastRequest,
            credential: nil,
            viewport: lastViewport,
            attemptID: attemptID
        )
    }

    private func record(_ newState: RdpSessionState) {
        state = newState
        stateHistory.append(newState)
    }
}
