import Foundation
import Synchronization
import Testing
@testable import TransmissionKit

/// Counts reads so tests can assert the keychain is touched once, since every real read is
/// a chance for macOS to prompt for the user's password.
private final class CountingCredentialStore: CredentialStore {
    private let storage = Mutex<(username: String, password: String)?>(nil)
    private let readDuration: TimeInterval
    let reads = Mutex(0)

    init(username: String?, password: String = "", readDuration: TimeInterval = 0) {
        self.readDuration = readDuration
        if let username {
            storage.withLock { $0 = (username: username, password: password) }
        }
    }

    func credential() throws -> (username: String, password: String)? {
        reads.withLock { $0 += 1 }
        Thread.sleep(forTimeInterval: readDuration)
        return storage.withLock { $0 }
    }

    func setCredential(username: String, password: String) throws {
        storage.withLock { $0 = (username: username, password: password) }
    }

    func hasCredential() throws -> Bool {
        reads.withLock { $0 += 1 }
        return storage.withLock { $0 } != nil
    }

    func username() throws -> String? {
        reads.withLock { $0 += 1 }
        return storage.withLock { $0?.username }
    }
}

@Suite("CachingCredentialStore")
struct CachingCredentialStoreTests {
    @Test("Repeated reads hit the wrapped store once")
    func readsThroughOnce() throws {
        let counting = CountingCredentialStore(username: "jarrett", password: "hunter2")
        let store = CachingCredentialStore(counting)

        for _ in 0..<5 {
            #expect(try store.credential()! == ("jarrett", "hunter2"))
            #expect(try store.hasCredential())
            #expect(try store.username() == "jarrett")
        }

        #expect(counting.reads.withLock { $0 } == 1)
    }

    /// The app reads on two threads at launch — the web UI's auth challenge on the main
    /// actor, the RPC client's on its actor — and each read that reaches the keychain is
    /// its own prompt.
    @Test("Concurrent reads hit the wrapped store once")
    func concurrentReadsCollapse() {
        let counting = CountingCredentialStore(username: "jarrett", password: "hunter2", readDuration: 0.2)
        let store = CachingCredentialStore(counting)

        let group = DispatchGroup()
        for _ in 0..<4 {
            DispatchQueue.global().async(group: group) {
                #expect((try? store.credential())??.password == "hunter2")
            }
        }
        group.wait()

        #expect(counting.reads.withLock { $0 } == 1)
    }

    @Test("An absent login is cached too")
    func cachesAbsence() throws {
        let counting = CountingCredentialStore(username: nil)
        let store = CachingCredentialStore(counting)

        #expect(try store.credential() == nil)
        #expect(try store.hasCredential() == false)
        #expect(try store.username() == nil)

        #expect(counting.reads.withLock { $0 } == 1)
    }

    @Test("Writing refreshes the cache rather than staling it")
    func writeRefreshes() throws {
        let counting = CountingCredentialStore(username: "jarrett", password: "old")
        let store = CachingCredentialStore(counting)
        #expect(try store.credential()! == ("jarrett", "old"))

        try store.setCredential(username: "alice", password: "new")

        #expect(try store.credential()! == ("alice", "new"))
        #expect(try store.username() == "alice")
        #expect(counting.reads.withLock { $0 } == 1)
    }

    @Test("Invalidating picks up a password changed elsewhere")
    func invalidationRereads() throws {
        let counting = CountingCredentialStore(username: "jarrett", password: "old")
        let store = CachingCredentialStore(counting)
        #expect(try store.credential()!.password == "old")

        try counting.setCredential(username: "jarrett", password: "changed in Safari")
        #expect(try store.credential()!.password == "old")

        store.invalidate()

        #expect(try store.credential()!.password == "changed in Safari")
        #expect(counting.reads.withLock { $0 } == 2)
    }
}

@Suite("InMemoryCredentialStore")
struct InMemoryCredentialStoreTests {
    @Test("hasCredential tracks the stored value")
    func reportsPresence() throws {
        #expect(try InMemoryCredentialStore().hasCredential() == false)

        let store = InMemoryCredentialStore(username: "jarrett")
        #expect(try store.hasCredential())
        #expect(try store.username() == "jarrett")
    }

    @Test("An empty password is a login, not an absence")
    func emptyPasswordIsStored() throws {
        let store = InMemoryCredentialStore(username: "jarrett", password: "")

        #expect(try store.credential()! == ("jarrett", ""))
        #expect(try store.hasCredential())
    }
}
