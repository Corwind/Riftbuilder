import Foundation

/// A process-local credential cache that fronts a persistent credential store.
///
/// The first load is forwarded to the backing store. A successful load, including a missing
/// credential, is cached until its absolute expiration time. Saves reach persistent storage first
/// and begin a new cache window. Deletes reach persistent storage first and invalidate the cache.
public final class SessionCredentialStore: CredentialStoring, @unchecked Sendable {
    public static let defaultCacheDuration: TimeInterval = 24 * 60 * 60

    private enum State {
        case unloaded
        case loaded(value: String?, expiresAt: Date)
    }

    private let backingStore: any CredentialStoring
    private let cacheDuration: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var state: State = .unloaded

    public init(
        backingStore: any CredentialStoring,
        cacheDuration: TimeInterval = SessionCredentialStore.defaultCacheDuration,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.backingStore = backingStore
        self.cacheDuration = max(0, cacheDuration)
        self.now = now
    }

    public func loadAPIKey() throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        let currentDate = now()
        if case let .loaded(value, expiresAt) = state, currentDate < expiresAt {
            return value
        }

        let value = try backingStore.loadAPIKey()
        state = .loaded(value: value, expiresAt: currentDate.addingTimeInterval(cacheDuration))
        return value
    }

    public func saveAPIKey(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }

        try backingStore.saveAPIKey(key)
        state = .loaded(value: key, expiresAt: now().addingTimeInterval(cacheDuration))
    }

    public func deleteAPIKey() throws {
        lock.lock()
        defer { lock.unlock() }

        try backingStore.deleteAPIKey()
        state = .unloaded
    }
}
