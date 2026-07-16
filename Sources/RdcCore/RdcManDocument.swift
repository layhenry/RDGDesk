import Foundation

public struct RdcManDocument: Equatable, Sendable {
    public let programVersion: String
    public let schemaVersion: String
    public let root: RdcGroup
}

public struct RdcGroup: Equatable, Sendable {
    public let name: String
    public let isExpanded: Bool?
    public let logonCredentials: RdcLogonCredentials?
    public let groups: [RdcGroup]
    public let servers: [RdcServer]
}

public struct RdcServer: Equatable, Sendable {
    public let displayName: String
    public let address: RdcServerAddress
    public let logonCredentials: RdcLogonCredentials?
}

public struct RdcServerAddress: Equatable, Sendable {
    public let rawValue: String
    public let host: String
    public let port: Int?

    public init(_ rawValue: String) {
        self.rawValue = rawValue
        if rawValue.hasPrefix("["),
           let closing = rawValue.firstIndex(of: "]") {
            host = String(rawValue[rawValue.index(after: rawValue.startIndex)..<closing])
            let suffix = rawValue[rawValue.index(after: closing)...]
            if suffix.hasPrefix(":"), let parsed = Int(suffix.dropFirst()) {
                port = parsed
            } else {
                port = nil
            }
            return
        }
        let colonCount = rawValue.filter { $0 == ":" }.count
        if colonCount == 1,
           let colon = rawValue.lastIndex(of: ":"),
           let parsed = Int(rawValue[rawValue.index(after: colon)...]) {
            host = String(rawValue[..<colon])
            port = parsed
        } else {
            host = rawValue
            port = nil
        }
    }
}

public struct RdcLogonCredentials: Equatable, Sendable {
    public let inheritance: RdcInheritance
    public let profileName: String?
    public let userName: String?
    public let domain: String?
    public let password: RdcPassword
}

public enum RdcInheritance: Equatable, Sendable {
    case none
    case inherited
    case custom(String)

    init(rawValue: String?) {
        switch rawValue?.lowercased() {
        case "none":
            self = .none
        case nil, "", "fromparent", "inherited":
            self = .inherited
        case let value?:
            self = .custom(value)
        }
    }
}

public enum RdcPassword: Equatable, Sendable {
    case none
    case windowsDPAPIEncrypted(String)

    public var isDecryptableOnMac: Bool {
        false
    }
}
