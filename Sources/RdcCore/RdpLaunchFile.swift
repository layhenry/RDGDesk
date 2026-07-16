import Foundation

public struct RdpLaunchFile: Equatable, Sendable {
    public let request: RdpConnectionRequest
    public let credential: ServerCredential?

    public init(request: RdpConnectionRequest, credential: ServerCredential?) {
        self.request = request
        self.credential = credential
    }

    public var suggestedFilename: String {
        "\(sanitizedFilenameComponent(request.serverID)).rdp"
    }

    public var contents: String {
        var lines = [
            "full address:s:\(fullAddress)",
            "prompt for credentials:i:1",
            "authentication level:i:2",
            "screen mode id:i:2",
            "use multimon:i:0",
            "desktopwidth:i:1440",
            "desktopheight:i:900",
            "session bpp:i:32",
            "redirectclipboard:i:1",
            "redirectdrives:i:0"
        ]

        if let username = resolvedUsername {
            lines.append("username:s:\(username)")
        }

        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private var fullAddress: String {
        if let port = request.port {
            return "\(request.host):\(port)"
        }
        return request.host
    }

    private var resolvedUsername: String? {
        let username = credential?.username ?? request.username
        guard let username, !username.isEmpty else {
            return nil
        }

        let domain = credential?.domain ?? request.domain
        guard let domain, !domain.isEmpty else {
            return username
        }
        return "\(domain)\\\(username)"
    }

    private func sanitizedFilenameComponent(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let scalars = value.unicodeScalars.map { scalar -> Character in
            forbidden.contains(scalar) ? "-" : Character(scalar)
        }
        let sanitized = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return sanitized.isEmpty ? "rdc-session" : sanitized
    }
}
