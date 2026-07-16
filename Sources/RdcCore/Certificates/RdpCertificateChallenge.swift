import CryptoKit
import Foundation
import Security

public struct RdpCertificateChallenge: Equatable, Identifiable, Sendable {
    public let id: UInt64
    public let endpoint: RdpEndpoint
    public let commonName: String?
    public let subject: String
    public let issuer: String
    public let sha256Fingerprint: String
    public let notBefore: Date?
    public let notAfter: Date?
    public let hostNameMismatch: Bool
    public let pemData: Data

    public init(
        id: UInt64,
        endpoint: RdpEndpoint,
        pemData: Data,
        flags: UInt32
    ) throws {
        let derData = try Self.firstCertificateDER(from: pemData)
        guard let certificate = SecCertificateCreateWithData(nil, derData as CFData) else {
            throw RdpCertificateChallengeError.invalidCertificate
        }

        self.id = id
        self.endpoint = endpoint
        self.commonName = Self.commonName(of: certificate)
        self.subject = Self.propertyDescription(
            certificate: certificate, oid: kSecOIDX509V1SubjectName
        ) ?? self.commonName ?? ""
        self.issuer = Self.propertyDescription(
            certificate: certificate, oid: kSecOIDX509V1IssuerName
        ) ?? ""
        self.sha256Fingerprint = SHA256.hash(data: derData)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
        self.notBefore = Self.propertyDate(
            certificate: certificate, oid: kSecOIDX509V1ValidityNotBefore
        )
        self.notAfter = Self.propertyDate(
            certificate: certificate, oid: kSecOIDX509V1ValidityNotAfter
        )
        self.hostNameMismatch = (flags & 0x80) != 0
        self.pemData = pemData
    }

    private static func firstCertificateDER(from pemData: Data) throws -> Data {
        guard let pem = String(data: pemData, encoding: .utf8),
              let begin = pem.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = pem.range(
                of: "-----END CERTIFICATE-----",
                range: begin.upperBound..<pem.endIndex
              ) else {
            throw RdpCertificateChallengeError.invalidPEM
        }
        let base64 = String(pem[begin.upperBound..<end.lowerBound])
            .filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: base64), !der.isEmpty else {
            throw RdpCertificateChallengeError.invalidPEM
        }
        return der
    }

    private static func commonName(of certificate: SecCertificate) -> String? {
        var value: CFString?
        guard SecCertificateCopyCommonName(certificate, &value) == errSecSuccess else {
            return nil
        }
        return value as String?
    }

    private static func property(
        certificate: SecCertificate,
        oid: CFString
    ) -> Any? {
        guard let values = SecCertificateCopyValues(
            certificate, [oid] as CFArray, nil
        ) as? [CFString: Any],
        let entry = values[oid] as? [CFString: Any] else {
            return nil
        }
        return entry[kSecPropertyKeyValue]
    }

    private static func propertyDate(
        certificate: SecCertificate,
        oid: CFString
    ) -> Date? {
        let value = property(certificate: certificate, oid: oid)
        if let date = value as? Date {
            return date
        }
        if let absoluteTime = value as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: absoluteTime.doubleValue)
        }
        return nil
    }

    private static func propertyDescription(
        certificate: SecCertificate,
        oid: CFString
    ) -> String? {
        describe(property(certificate: certificate, oid: oid))
    }

    private static func describe(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let values = value as? [Any] {
            let parts = values.compactMap(describe)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        if let property = value as? [CFString: Any] {
            let label = property[kSecPropertyKeyLabel] as? String
            let describedValue = describe(property[kSecPropertyKeyValue])
            switch (label, describedValue) {
            case let (.some(label), .some(value)):
                return "\(label)=\(value)"
            case let (_, .some(value)):
                return value
            default:
                return nil
            }
        }
        return nil
    }
}

public enum RdpCertificateDecision: Int32, Equatable, Sendable {
    case reject = 0
    case trustAlways = 1
    case trustOnce = 2
}

public enum RdpCertificateChallengeError: Error, Equatable {
    case invalidPEM
    case invalidCertificate
}
