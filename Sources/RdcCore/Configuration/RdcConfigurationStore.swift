import CryptoKit
import CoreFoundation
import Dispatch
import Foundation

public protocol RdcConfigurationStore: Sendable {
    func load() async throws -> RdcAppConfiguration
    func save(_ configuration: RdcAppConfiguration) async throws
}

public actor FileRdcConfigurationStore: RdcConfigurationStore {
    private let fileURL: URL
    private let ioQueue: DispatchQueue
    private let ioOperationObserver: @Sendable () -> Void

    public init(fileURL: URL = FileRdcConfigurationStore.defaultFileURL()) {
        self.fileURL = fileURL
        ioQueue = DispatchQueue(label: "com.rdc.configuration-store.io")
        ioOperationObserver = {}
    }

    init(
        fileURL: URL,
        ioQueue: DispatchQueue,
        ioOperationObserver: @escaping @Sendable () -> Void
    ) {
        self.fileURL = fileURL
        self.ioQueue = ioQueue
        self.ioOperationObserver = ioOperationObserver
    }

    public func load() async throws -> RdcAppConfiguration {
        let fileURL = fileURL
        return try await performIO {
            try Self.loadFromDisk(fileURL: fileURL)
        }
    }

    public func save(_ configuration: RdcAppConfiguration) async throws {
        let fileURL = fileURL
        try await performIO {
            try Self.saveToDisk(configuration, fileURL: fileURL)
        }
    }

    public nonisolated static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return base.appendingPathComponent("Rdc", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    private func performIO<Result: Sendable>(
        _ operation: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        let ioOperationObserver = ioOperationObserver
        return try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    ioOperationObserver()
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func loadFromDisk(fileURL: URL) throws -> RdcAppConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .default
        }

        let data = try Data(contentsOf: fileURL)
        do {
            let decoded = try makeDecoder().decode(RdcAppConfiguration.self, from: data)
            guard decoded.schemaVersion == RdcAppConfiguration.currentSchemaVersion else {
                throw RdcConfigurationError.unsupportedSchema(decoded.schemaVersion)
            }
            return decoded
        } catch {
            try writeSanitizedBackup(for: data, sourceURL: fileURL)
            try FileManager.default.removeItem(at: fileURL)
            return .default
        }
    }

    private nonisolated static func saveToDisk(
        _ configuration: RdcAppConfiguration,
        fileURL: URL
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try makeEncoder().encode(configuration).write(to: fileURL, options: .atomic)
    }

    private nonisolated static func writeSanitizedBackup(
        for data: Data,
        sourceURL: URL
    ) throws {
        let backupURL = URL(fileURLWithPath: sourceURL.path + ".corrupt")
        let backupData = try JSONSerialization.data(
            withJSONObject: diagnosticMarker(for: data),
            options: [.prettyPrinted, .sortedKeys]
        )

        try? FileManager.default.removeItem(at: backupURL)
        try backupData.write(to: backupURL, options: .atomic)
    }

    private nonisolated static func diagnosticMarker(for data: Data) -> [String: Any] {
        let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var marker: [String: Any] = [
            "backupFormat": "rdc-sanitized-corrupt-v1",
            "byteCount": data.count,
            "parseable": parsed != nil,
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        ]

        if let dictionary = parsed as? [String: Any],
           let schemaVersion = validSchemaVersion(dictionary["schemaVersion"]) {
            marker["schemaVersion"] = schemaVersion
        }
        return marker
    }

    private nonisolated static func validSchemaVersion(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let candidate = number.doubleValue
        guard candidate.isFinite,
              candidate.rounded() == candidate,
              candidate >= Double(Int.min),
              candidate <= Double(Int.max) else {
            return nil
        }
        return Int(candidate)
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum RdcConfigurationError: Error, Equatable {
    case unsupportedSchema(Int)
}
