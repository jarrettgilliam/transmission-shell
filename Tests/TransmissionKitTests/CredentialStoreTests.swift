import Foundation
import Synchronization
import Testing
@testable import TransmissionKit

/// Counts reads so tests can assert the keychain is touched once, since every real read is
/// a chance for macOS to prompt for the user's password.
private final class CountingCredentialStore: CredentialStore {
    private let storage = Mutex<String?>(nil)
    let reads = Mutex(0)

    init(password: String?) {
        storage.withLock { $0 = password }
    }

    func password() throws -> String? {
        reads.withLock { $0 += 1 }
        return storage.withLock { $0 }
    }

    func setPassword(_ password: String?) throws {
        let value = normalized(password)
        storage.withLock { $0 = value }
    }

    func hasPassword() throws -> Bool {
        reads.withLock { $0 += 1 }
        return storage.withLock { $0 } != nil
    }
}

@Suite("CachingCredentialStore")
struct CachingCredentialStoreTests {
    @Test("Repeated reads hit the wrapped store once")
    func readsThroughOnce() throws {
        let counting = CountingCredentialStore(password: "hunter2")
        let store = CachingCredentialStore(counting)

        for _ in 0..<5 {
            #expect(try store.password() == "hunter2")
            #expect(try store.hasPassword())
        }

        #expect(counting.reads.withLock { $0 } == 1)
    }

    @Test("An absent password is cached too")
    func cachesAbsence() throws {
        let counting = CountingCredentialStore(password: nil)
        let store = CachingCredentialStore(counting)

        #expect(try store.password() == nil)
        #expect(try store.hasPassword() == false)
        #expect(try store.password() == nil)

        #expect(counting.reads.withLock { $0 } == 1)
    }

    @Test("Writing refreshes the cache rather than staling it")
    func writeRefreshes() throws {
        let counting = CountingCredentialStore(password: "old")
        let store = CachingCredentialStore(counting)
        #expect(try store.password() == "old")

        try store.setPassword("new")

        #expect(try store.password() == "new")
        #expect(try store.hasPassword())
        #expect(counting.reads.withLock { $0 } == 1)
    }

    @Test("Removal is visible without a re-read", arguments: [nil, ""])
    func removalRefreshes(erasure: String?) throws {
        let counting = CountingCredentialStore(password: "old")
        let store = CachingCredentialStore(counting)
        #expect(try store.password() == "old")

        try store.setPassword(erasure)

        #expect(try store.password() == nil)
        #expect(try store.hasPassword() == false)
        #expect(counting.reads.withLock { $0 } == 1)
    }
}

@Suite("InMemoryCredentialStore")
struct InMemoryCredentialStoreTests {
    @Test("hasPassword tracks the stored value")
    func reportsPresence() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.hasPassword() == false)

        try store.setPassword("hunter2")
        #expect(try store.hasPassword())

        try store.setPassword(nil)
        #expect(try store.hasPassword() == false)
    }

    @Test("An empty password is a removal")
    func emptyIsRemoval() throws {
        let store = InMemoryCredentialStore(password: "hunter2")
        try store.setPassword("")

        #expect(try store.password() == nil)
        #expect(try store.hasPassword() == false)
    }
}
