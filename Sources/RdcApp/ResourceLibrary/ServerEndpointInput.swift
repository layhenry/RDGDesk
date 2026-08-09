import Foundation
import RdcCore

struct ServerEndpointInputResolution: Equatable {
    let host: String
    let port: Int
    let usesEmbeddedPort: Bool
}

enum ServerEndpointInputValidationError: Error, Equatable {
    case invalidHost
    case invalidEmbeddedPort
    case invalidPort

    var message: String {
        switch self {
        case .invalidHost:
            "请输入有效的 IP 地址或主机名。"
        case .invalidEmbeddedPort:
            "地址中的端口必须是 1–65535 之间的整数。"
        case .invalidPort:
            "端口必须是 1–65535 之间的整数。"
        }
    }
}

enum ServerEndpointInputParser {
    static func resolve(
        address: String,
        portText: String
    ) throws -> ServerEndpointInputResolution {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains("://"),
              !value.contains("/"),
              !value.contains("?"),
              !value.contains("@") else {
            throw ServerEndpointInputValidationError.invalidHost
        }

        if value.hasPrefix("[") {
            return try resolveBracketed(address: value, portText: portText)
        }

        if let host = validatedHost(value) {
            return try resolveSeparatePort(host: host, portText: portText)
        }

        guard value.filter({ $0 == ":" }).count == 1,
              let separator = value.firstIndex(of: ":") else {
            throw ServerEndpointInputValidationError.invalidHost
        }
        let hostText = String(value[..<separator])
        let embeddedPortText = String(value[value.index(after: separator)...])
        guard let host = validatedHost(hostText) else {
            throw ServerEndpointInputValidationError.invalidHost
        }
        guard let port = parsedPort(embeddedPortText) else {
            throw ServerEndpointInputValidationError.invalidEmbeddedPort
        }
        return ServerEndpointInputResolution(
            host: host, port: port, usesEmbeddedPort: true
        )
    }

    private static func resolveBracketed(
        address: String,
        portText: String
    ) throws -> ServerEndpointInputResolution {
        guard let closing = address.firstIndex(of: "]") else {
            throw ServerEndpointInputValidationError.invalidHost
        }
        let hostText = String(address[address.index(after: address.startIndex)..<closing])
        guard hostText.contains(":"), let host = validatedHost(hostText) else {
            throw ServerEndpointInputValidationError.invalidHost
        }
        let suffix = String(address[address.index(after: closing)...])
        if suffix.isEmpty {
            return try resolveSeparatePort(host: host, portText: portText)
        }
        guard suffix.hasPrefix(":"), suffix.filter({ $0 == ":" }).count == 1,
              let port = parsedPort(String(suffix.dropFirst())) else {
            if suffix.hasPrefix(":") {
                throw ServerEndpointInputValidationError.invalidEmbeddedPort
            }
            throw ServerEndpointInputValidationError.invalidHost
        }
        return ServerEndpointInputResolution(
            host: host, port: port, usesEmbeddedPort: true
        )
    }

    private static func resolveSeparatePort(
        host: String,
        portText: String
    ) throws -> ServerEndpointInputResolution {
        guard let port = parsedPort(portText) else {
            throw ServerEndpointInputValidationError.invalidPort
        }
        return ServerEndpointInputResolution(
            host: host, port: port, usesEmbeddedPort: false
        )
    }

    private static func parsedPort(_ value: String) -> Int? {
        guard let port = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port) else { return nil }
        return port
    }

    private static func validatedHost(_ value: String) -> String? {
        try? ServerPropertiesDraft(
            displayName: "Server", host: value, port: 3_389
        ).validated().host
    }
}
