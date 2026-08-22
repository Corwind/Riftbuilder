import Foundation
import XCTest
@testable import RiftBuilderCore

final class SessionCredentialStoreTTLTests: XCTestCase {
    func testDefaultCacheDurationIsOneDay() {
        XCTAssertEqual(SessionCredentialStore.defaultCacheDuration, 86_400)
    }

    func testAbsoluteTTLDoesNotSlideAndReloadsAtExpiration() throws {
        let clock = CredentialTestClock(Date(timeIntervalSince1970: 1_000))
        let backing = TTLCredentialBackingStore(key: "first")
        let store = SessionCredentialStore(
            backingStore: backing,
            cacheDuration: 100,
            now: { clock.now }
        )

        XCTAssertEqual(try store.loadAPIKey(), "first")
        backing.key = "second"
        clock.advance(by: 99)
        XCTAssertEqual(try store.loadAPIKey(), "first")
        XCTAssertEqual(backing.loadCount, 1)

        // Prior cache hits do not slide the original expiration at t=1100.
        clock.advance(by: 1)
        XCTAssertEqual(try store.loadAPIKey(), "second")
        XCTAssertEqual(backing.loadCount, 2)
    }

    func testSaveStartsANewAbsoluteTTLWindow() throws {
        let clock = CredentialTestClock(Date(timeIntervalSince1970: 1_000))
        let backing = TTLCredentialBackingStore(key: "original")
        let store = SessionCredentialStore(
            backingStore: backing,
            cacheDuration: 100,
            now: { clock.now }
        )
        XCTAssertEqual(try store.loadAPIKey(), "original")

        clock.advance(by: 80)
        try store.saveAPIKey("saved")
        backing.key = "external"
        clock.advance(by: 99)
        XCTAssertEqual(try store.loadAPIKey(), "saved")
        XCTAssertEqual(backing.loadCount, 1)

        clock.advance(by: 1)
        XCTAssertEqual(try store.loadAPIKey(), "external")
        XCTAssertEqual(backing.loadCount, 2)
    }

    func testDeleteInvalidatesImmediately() throws {
        let clock = CredentialTestClock(Date(timeIntervalSince1970: 1_000))
        let backing = TTLCredentialBackingStore(key: "secret")
        let store = SessionCredentialStore(
            backingStore: backing,
            cacheDuration: 100,
            now: { clock.now }
        )
        XCTAssertEqual(try store.loadAPIKey(), "secret")

        try store.deleteAPIKey()
        backing.key = "recreated"

        XCTAssertEqual(try store.loadAPIKey(), "recreated")
        XCTAssertEqual(backing.loadCount, 2)
    }
}

private final class CredentialTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class TTLCredentialBackingStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: String?
    private var storedLoadCount = 0

    init(key: String?) {
        storedKey = key
    }

    var key: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedKey
        }
        set {
            lock.lock()
            storedKey = newValue
            lock.unlock()
        }
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedLoadCount
    }

    func loadAPIKey() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        storedLoadCount += 1
        return storedKey
    }

    func saveAPIKey(_ key: String) throws {
        lock.lock()
        storedKey = key
        lock.unlock()
    }

    func deleteAPIKey() throws {
        lock.lock()
        storedKey = nil
        lock.unlock()
    }
}
