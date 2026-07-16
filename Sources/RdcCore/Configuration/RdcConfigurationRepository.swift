enum RdcConfigurationRepositoryOperationEvent: Equatable, Sendable {
    case queued
}

public struct RdcPreparedConfigurationUpdate<Result: Sendable>: Sendable {
    public let result: Result
    public let rollback: @Sendable () async throws -> Void

    public init(
        result: Result,
        rollback: @escaping @Sendable () async throws -> Void
    ) {
        self.result = result
        self.rollback = rollback
    }
}

public enum RdcConfigurationTransactionError: Error, Equatable, Sendable {
    case rollbackFailed
}

public actor RdcConfigurationRepository {
    private let store: any RdcConfigurationStore
    private let operationObserver: @Sendable (RdcConfigurationRepositoryOperationEvent) -> Void
    private var cached: RdcAppConfiguration?
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(store: any RdcConfigurationStore) {
        self.store = store
        operationObserver = { _ in }
    }

    init(
        store: any RdcConfigurationStore,
        operationObserver: @escaping @Sendable (
            RdcConfigurationRepositoryOperationEvent
        ) -> Void
    ) {
        self.store = store
        self.operationObserver = operationObserver
    }

    public func snapshot() async throws -> RdcAppConfiguration {
        await acquireOperationPermit()
        defer { releaseOperationPermit() }

        return try await cachedSnapshot()
    }

    public func reload() async throws -> RdcAppConfiguration {
        await acquireOperationPermit()
        defer { releaseOperationPermit() }

        let loaded = try await store.load()
        cached = loaded
        return loaded
    }

    private func cachedSnapshot() async throws -> RdcAppConfiguration {
        if let cached {
            return cached
        }
        let loaded = try await store.load()
        cached = loaded
        return loaded
    }

    @discardableResult
    public func update<Result: Sendable>(
        _ mutation: @Sendable (inout RdcAppConfiguration) throws -> Result
    ) async throws -> Result {
        await acquireOperationPermit()
        defer { releaseOperationPermit() }

        var candidate = try await cachedSnapshot()
        let result = try mutation(&candidate)
        try await store.save(candidate)
        cached = candidate
        return result
    }

    @discardableResult
    public func updateWithRollback<Result: Sendable>(
        _ prepare: @Sendable (
            inout RdcAppConfiguration
        ) async throws -> RdcPreparedConfigurationUpdate<Result>
    ) async throws -> Result {
        await acquireOperationPermit()
        defer { releaseOperationPermit() }

        var candidate = try await cachedSnapshot()
        let prepared = try await prepare(&candidate)
        do {
            try await store.save(candidate)
        } catch {
            do {
                try await prepared.rollback()
            } catch {
                throw RdcConfigurationTransactionError.rollbackFailed
            }
            throw error
        }
        cached = candidate
        return prepared.result
    }

    private func acquireOperationPermit() async {
        guard operationInProgress else {
            operationInProgress = true
            return
        }

        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
            operationObserver(.queued)
        }
    }

    private func releaseOperationPermit() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }

        operationWaiters.removeFirst().resume()
    }
}
