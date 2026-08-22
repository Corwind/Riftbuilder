import Foundation
import XCTest
@testable import RiftBuilderCore

final class SessionCredentialStoreTests: XCTestCase {
    func testMultipleLoadsReadBackingStoreOnlyOnce() throws {
        let backing = CredentialBackingStoreFake(key: "secret")
        let store = SessionCredentialStore(backingStore: backing)

        XCTAssertEqual(try store.loadAPIKey(), "secret")
        XCTAssertEqual(try store.loadAPIKey(), "secret")
        XCTAssertEqual(try store.loadAPIKey(), "secret")
        XCTAssertEqual(backing.loadCount, 1)
    }

    func testMissingCredentialIsCachedForTheSession() throws {
        let backing = CredentialBackingStoreFake(key: nil)
        let store = SessionCredentialStore(backingStore: backing)

        XCTAssertNil(try store.loadAPIKey())
        backing.externallySetKey("added-elsewhere")
        XCTAssertNil(try store.loadAPIKey())
        XCTAssertEqual(backing.loadCount, 1)
    }

    func testSaveUpdatesBackingStoreAndSessionCacheWithoutReloading() throws {
        let backing = CredentialBackingStoreFake(key: "old")
        let store = SessionCredentialStore(backingStore: backing)
        XCTAssertEqual(try store.loadAPIKey(), "old")

        try store.saveAPIKey("new")

        XCTAssertEqual(try store.loadAPIKey(), "new")
        XCTAssertEqual(backing.storedKey, "new")
        XCTAssertEqual(backing.loadCount, 1)
        XCTAssertEqual(backing.saveCount, 1)
    }

    func testDeleteClearsBackingStoreAndCachesMissingState() throws {
        let backing = CredentialBackingStoreFake(key: "secret")
        let store = SessionCredentialStore(backingStore: backing)
        XCTAssertEqual(try store.loadAPIKey(), "secret")

        try store.deleteAPIKey()

        XCTAssertNil(try store.loadAPIKey())
        XCTAssertNil(backing.storedKey)
        XCTAssertEqual(backing.loadCount, 2)
        XCTAssertEqual(backing.deleteCount, 1)
    }

    func testFailedLoadIsRetriedInsteadOfCachingFailure() throws {
        let backing = CredentialBackingStoreFake(key: "secret", loadFailuresRemaining: 1)
        let store = SessionCredentialStore(backingStore: backing)
        XCTAssertThrowsError(try store.loadAPIKey())

        XCTAssertEqual(try store.loadAPIKey(), "secret")
        XCTAssertEqual(backing.loadCount, 2)
    }

    func testFailedSaveAndDeleteDoNotChangeCachedCredential() throws {
        let backing = CredentialBackingStoreFake(key: "old")
        let store = SessionCredentialStore(backingStore: backing)
        XCTAssertEqual(try store.loadAPIKey(), "old")

        backing.failSave = true
        XCTAssertThrowsError(try store.saveAPIKey("new"))
        XCTAssertEqual(try store.loadAPIKey(), "old")

        backing.failDelete = true
        XCTAssertThrowsError(try store.deleteAPIKey())
        XCTAssertEqual(try store.loadAPIKey(), "old")
    }

    func testConcurrentLoadsAreSerializedIntoOneBackingRead() throws {
        let backing = CredentialBackingStoreFake(key: "secret")
        let store = SessionCredentialStore(backingStore: backing)
        let queue = DispatchQueue(label: "SessionCredentialStoreTests", attributes: .concurrent)
        let group = DispatchGroup()
        let failures = LockedFailures()

        for _ in 0..<20 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    if try store.loadAPIKey() != "secret" { failures.record() }
                } catch {
                    failures.record()
                }
            }
        }
        group.wait()

        XCTAssertEqual(failures.count, 0)
        XCTAssertEqual(backing.loadCount, 1)
    }
}

private final class CredentialBackingStoreFake: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private var storedLoadCount = 0
    private var storedSaveCount = 0
    private var storedDeleteCount = 0
    private var loadFailuresRemaining: Int
    var failSave = false
    var failDelete = false

    init(key: String?, loadFailuresRemaining: Int = 0) {
        self.key = key
        self.loadFailuresRemaining = loadFailuresRemaining
    }

    func loadAPIKey() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        storedLoadCount += 1
        if loadFailuresRemaining > 0 {
            loadFailuresRemaining -= 1
            throw FakeError.requested
        }
        return key
    }

    func saveAPIKey(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storedSaveCount += 1
        if failSave { throw FakeError.requested }
        self.key = key
    }

    func deleteAPIKey() throws {
        lock.lock()
        defer { lock.unlock() }
        storedDeleteCount += 1
        if failDelete { throw FakeError.requested }
        key = nil
    }

    func externallySetKey(_ key: String?) {
        lock.lock()
        self.key = key
        lock.unlock()
    }

    var storedKey: String? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedLoadCount
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSaveCount
    }

    var deleteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDeleteCount
    }
}

private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    func record() {
        lock.lock()
        storedCount += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }
}

private enum FakeError: Error {
    case requested
}
