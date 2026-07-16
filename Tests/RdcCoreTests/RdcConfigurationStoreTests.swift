import Foundation
import XCTest
@testable import RdcCore

final class RdcConfigurationStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testConfigurationRoundTripContainsMetadataButNoPassword() async throws {
        let url = temporaryDirectory.appendingPathComponent("settings.json")
        let store = FileRdcConfigurationStore(fileURL: url)
        let configuration = RdcAppConfiguration(
            globalCredentialID: "global-1",
            credentialMetadata: [
                "global-1": CredentialMetadata(
                    id: "global-1", username: "Administrator", domain: "WORKGROUP"
                )
            ]
        )

        try await store.save(configuration)

        let loaded = try await store.load()
        XCTAssertEqual(loaded, configuration)
        let bytes = try Data(contentsOf: url)
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(text.contains("local-secret"))
    }

    func testUnparseableConfigurationBackupContainsOnlyFixedMetadata() async throws {
        let url = temporaryDirectory.appendingPathComponent("settings.json")
        let secret = "malformed-secret"
        let dpapiMarker = "AQAAANCM-private-ciphertext"
        let payload = Data("{\"password\":\"\(secret)\",\"blob\":\"\(dpapiMarker)\"".utf8)
        try payload.write(to: url)
        let store = FileRdcConfigurationStore(fileURL: url)

        let loaded = try await store.load()

        XCTAssertEqual(loaded, .default)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let backupData = try Data(contentsOf: URL(fileURLWithPath: url.path + ".corrupt"))
        let backupText = try XCTUnwrap(String(data: backupData, encoding: .utf8))
        XCTAssertFalse(backupText.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(backupText.contains(secret))
        XCTAssertFalse(backupText.contains(dpapiMarker))
        let backup = try XCTUnwrap(
            JSONSerialization.jsonObject(with: backupData) as? [String: Any]
        )
        XCTAssertEqual(
            Set(backup.keys),
            ["backupFormat", "byteCount", "parseable", "sha256"]
        )
        XCTAssertEqual(backup["backupFormat"] as? String, "rdc-sanitized-corrupt-v1")
        XCTAssertEqual(backup["byteCount"] as? Int, payload.count)
        XCTAssertEqual(backup["parseable"] as? Bool, false)
        XCTAssertEqual((backup["sha256"] as? String)?.count, 64)
    }

    func testFutureSchemaBackupContainsOnlyAllowlistedMetadata() async throws {
        let url = temporaryDirectory.appendingPathComponent("settings.json")
        let secret = "future-secret"
        let dpapiMarker = "AQAAANCM-future-ciphertext"
        let payload: [String: Any] = [
            "schemaVersion": 2,
            "token": "token-\(secret)",
            "apiKey": "api-key-\(secret)",
            "note": "neutral-looking-\(secret)",
            "username": "Administrator",
            "hostname": "server.example.com",
            "nested": [
                "arbitrary": secret,
                "anotherUnknownKey": dpapiMarker
            ],
            "array": ["unknown-value", secret, dpapiMarker]
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        try payloadData.write(to: url)
        let store = FileRdcConfigurationStore(fileURL: url)

        let loaded = try await store.load()

        XCTAssertEqual(loaded, .default)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let backupData = try Data(contentsOf: URL(fileURLWithPath: url.path + ".corrupt"))
        let backupText = try XCTUnwrap(String(data: backupData, encoding: .utf8))
        XCTAssertFalse(backupText.contains(secret))
        XCTAssertFalse(backupText.contains(dpapiMarker))
        XCTAssertFalse(backupText.contains("token-"))
        XCTAssertFalse(backupText.contains("api-key-"))
        XCTAssertFalse(backupText.contains("neutral-looking-"))
        XCTAssertFalse(backupText.contains("Administrator"))
        XCTAssertFalse(backupText.contains("server.example.com"))
        XCTAssertFalse(backupText.contains("unknown-value"))
        let backup = try XCTUnwrap(
            JSONSerialization.jsonObject(with: backupData) as? [String: Any]
        )
        XCTAssertEqual(
            Set(backup.keys),
            ["backupFormat", "byteCount", "parseable", "schemaVersion", "sha256"]
        )
        XCTAssertEqual(backup["backupFormat"] as? String, "rdc-sanitized-corrupt-v1")
        XCTAssertEqual(backup["byteCount"] as? Int, payloadData.count)
        XCTAssertEqual(backup["parseable"] as? Bool, true)
        XCTAssertEqual(backup["schemaVersion"] as? Int, 2)
        XCTAssertEqual((backup["sha256"] as? String)?.count, 64)
    }

    func testPreReleaseEmptyConfigurationMigratesToSchemaOneDefaults() async throws {
        let url = temporaryDirectory.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: url)
        let store = FileRdcConfigurationStore(fileURL: url)

        let loaded = try await store.load()

        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertEqual(loaded.preferences, .default)
    }

    func testCertificatePinDictionaryRoundTripsTwoEndpoints() async throws {
        let url = temporaryDirectory.appendingPathComponent("settings.json")
        let store = FileRdcConfigurationStore(fileURL: url)
        let first = RdpEndpoint(host: " HOST.Example.com ", port: 3389)
        let second = RdpEndpoint(host: "other.example.com", port: 3390)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let configuration = RdcAppConfiguration(certificatePins: [
            first: makePin(endpoint: first, fingerprint: "AA", timestamp: timestamp),
            second: makePin(endpoint: second, fingerprint: "BB", timestamp: timestamp)
        ])

        try await store.save(configuration)

        XCTAssertEqual(first.host, "host.example.com")
        let loaded = try await store.load()
        XCTAssertEqual(loaded, configuration)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let dictionary = try XCTUnwrap(object as? [String: Any])
        let pins = try XCTUnwrap(dictionary["certificatePins"] as? [Any])
        XCTAssertEqual(pins.count, 4)
    }

    func testDefaultFileURLUsesRdcApplicationSupportDirectory() {
        let url = FileRdcConfigurationStore.defaultFileURL()

        XCTAssertEqual(url.lastPathComponent, "settings.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Rdc")
        XCTAssertTrue(url.path.contains("Application Support/Rdc/settings.json"))
    }

    func testFileOperationsRunOnInjectedSerialIOQueue() async throws {
        let url = temporaryDirectory.appendingPathComponent("settings.json")
        let queue = DispatchQueue(label: "test.rdc.configuration-io")
        let key = DispatchSpecificKey<String>()
        queue.setSpecific(key: key, value: "configuration-io")
        let recorder = IOQueueRecorder()
        let store = FileRdcConfigurationStore(
            fileURL: url,
            ioQueue: queue,
            ioOperationObserver: {
                recorder.record(DispatchQueue.getSpecific(key: key))
            }
        )

        try await store.save(.default)
        _ = try await store.load()

        XCTAssertEqual(recorder.values, ["configuration-io", "configuration-io"])
    }

    func testConcurrentRepositoryUpdatesPreserveBothChanges() async throws {
        let store = InMemoryConfigurationStore()
        let repository = RdcConfigurationRepository(store: store)
        let endpoint = RdpEndpoint(host: "server.example.com", port: 3389)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let pin = makePin(endpoint: endpoint, fingerprint: "AA", timestamp: timestamp)

        async let metadataUpdate: Void = repository.update { configuration in
            configuration.credentialMetadata["global-1"] = CredentialMetadata(
                id: "global-1", username: "Administrator", domain: nil
            )
        }
        async let pinUpdate: Void = repository.update { configuration in
            configuration.certificatePins[endpoint] = pin
        }
        _ = try await (metadataUpdate, pinUpdate)

        let snapshot = try await repository.snapshot()
        XCTAssertEqual(snapshot.credentialMetadata["global-1"]?.username, "Administrator")
        XCTAssertEqual(snapshot.certificatePins[endpoint], pin)
    }

    func testSaveFailureLeavesRepositoryCacheAtLastPersistedValue() async throws {
        let store = InMemoryConfigurationStore()
        let repository = RdcConfigurationRepository(store: store)
        try await repository.update { configuration in
            configuration.globalCredentialID = "persisted"
        }
        await store.failNextSave()

        do {
            try await repository.update { configuration in
                configuration.globalCredentialID = "not-persisted"
            }
            XCTFail("Expected save failure")
        } catch is TestStoreError {
            // Expected.
        }

        let cached = try await repository.snapshot()
        let persisted = try await store.load()
        XCTAssertEqual(cached.globalCredentialID, "persisted")
        XCTAssertEqual(persisted.globalCredentialID, "persisted")
    }

    func testBlockedColdSnapshotQueuesUpdateAndLoadsOnlyOnce() async throws {
        let stale = RdcAppConfiguration(globalCredentialID: "stale")
        let storeEvents = AsyncEventProbe<StoreTestEvent>()
        let permitEvents = AsyncEventProbe<RdcConfigurationRepositoryOperationEvent>()
        let store = ControlledFirstLoadConfigurationStore(
            configuration: stale,
            eventObserver: { event in
                Task { await storeEvents.record(event) }
            }
        )
        let repository = RdcConfigurationRepository(
            store: store,
            operationObserver: { event in
                Task { await permitEvents.record(event) }
            }
        )

        let coldSnapshot = Task {
            try await repository.snapshot()
        }
        let firstLoadStarted = await storeEvents.wait(
            for: .firstLoadStarted,
            timeout: Duration.seconds(1)
        )
        XCTAssertTrue(firstLoadStarted)
        let update = Task {
            try await repository.update { configuration in
                configuration.globalCredentialID = "fresh"
            }
        }
        let updateQueued = await permitEvents.wait(
            for: .queued,
            timeout: Duration.seconds(1)
        )
        XCTAssertTrue(updateQueued)
        await store.releaseFirstLoad()

        let initial = try await coldSnapshot.value
        _ = try await update.value

        let cached = try await repository.snapshot()
        let persisted = await store.persistedConfiguration()
        let loadCount = await store.loadInvocationCount()
        XCTAssertEqual(initial.globalCredentialID, "stale")
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(cached.globalCredentialID, "fresh")
        XCTAssertEqual(persisted.globalCredentialID, "fresh")
    }

    private func makePin(
        endpoint: RdpEndpoint,
        fingerprint: String,
        timestamp: Date
    ) -> CertificatePin {
        CertificatePin(
            endpoint: endpoint,
            subject: "CN=server.example.com",
            issuer: "CN=Test CA",
            sha256Fingerprint: fingerprint,
            notBefore: nil,
            notAfter: nil,
            firstTrustedAt: timestamp,
            lastConfirmedAt: timestamp
        )
    }
}

private enum TestStoreError: Error {
    case saveFailed
}

private final class IOQueueRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [String?] = []

    var values: [String?] {
        lock.withLock { recordedValues }
    }

    func record(_ value: String?) {
        lock.withLock { recordedValues.append(value) }
    }
}

private actor InMemoryConfigurationStore: RdcConfigurationStore {
    private var configuration: RdcAppConfiguration = .default
    private var shouldFailNextSave = false

    func load() async throws -> RdcAppConfiguration {
        configuration
    }

    func save(_ configuration: RdcAppConfiguration) async throws {
        if shouldFailNextSave {
            shouldFailNextSave = false
            throw TestStoreError.saveFailed
        }
        self.configuration = configuration
    }

    func failNextSave() {
        shouldFailNextSave = true
    }
}

private enum StoreTestEvent: Sendable {
    case firstLoadStarted
}

private actor AsyncEventProbe<Event: Equatable & Sendable> {
    private var events: [Event] = []
    private var waiters: [UUID: (Event, CheckedContinuation<Bool, Never>)] = [:]

    func record(_ event: Event) {
        events.append(event)
        let matching = waiters.filter { $0.value.0 == event }
        for (id, waiter) in matching {
            waiters.removeValue(forKey: id)
            waiter.1.resume(returning: true)
        }
    }

    func wait(for event: Event, timeout: Duration) async -> Bool {
        if events.contains(event) {
            return true
        }

        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = (event, continuation)
            Task {
                try? await Task.sleep(for: timeout)
                self.timeoutWaiter(id: id)
            }
        }
    }

    private func timeoutWaiter(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else {
            return
        }
        waiter.1.resume(returning: false)
    }
}

private actor ControlledFirstLoadConfigurationStore: RdcConfigurationStore {
    private var configuration: RdcAppConfiguration
    private var loadCount = 0
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?
    private let eventObserver: @Sendable (StoreTestEvent) -> Void

    init(
        configuration: RdcAppConfiguration,
        eventObserver: @escaping @Sendable (StoreTestEvent) -> Void
    ) {
        self.configuration = configuration
        self.eventObserver = eventObserver
    }

    func load() async throws -> RdcAppConfiguration {
        loadCount += 1
        let captured = configuration
        if loadCount == 1 {
            eventObserver(.firstLoadStarted)
            await withCheckedContinuation { continuation in
                firstLoadContinuation = continuation
            }
        }
        return captured
    }

    func save(_ configuration: RdcAppConfiguration) async throws {
        self.configuration = configuration
    }

    func releaseFirstLoad() {
        firstLoadContinuation?.resume()
        firstLoadContinuation = nil
    }

    func persistedConfiguration() -> RdcAppConfiguration {
        configuration
    }

    func loadInvocationCount() -> Int {
        loadCount
    }
}
