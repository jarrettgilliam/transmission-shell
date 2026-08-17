import Foundation
import Testing
@testable import TransmissionKit

/// The save-rule table: what the settings form's two boxes mean either side of an existing
/// credential. Test Connection and Save share this, so these cover both.
@Suite("Credential resolution")
struct CredentialResolutionTests {
    private func store(username: String? = nil, password: String = "") -> InMemoryCredentialStore {
        InMemoryCredentialStore(username: username, password: password)
    }

    @Test("Nothing stored, nothing typed, nothing to do")
    func emptyForm() throws {
        #expect(try resolveCredential(username: "  ", password: nil, in: store()) == nil)
    }

    @Test("A password with no username is refused", arguments: [nil, "hunter2"])
    func passwordNeedsUsername(stored: String?) throws {
        let store = stored.map { self.store(username: "jarrett", password: $0) } ?? self.store()

        #expect(throws: CredentialFormError.usernameRequired) {
            try resolveCredential(username: "", password: "typed", in: store)
        }
    }

    /// Erasing the prefilled username while a login is stored is an edit, not a request to
    /// look the name back up.
    @Test("Erasing the username over a stored login is refused")
    func erasedUsernameIsRefused() throws {
        #expect(throws: CredentialFormError.usernameRequired) {
            try resolveCredential(username: "", password: nil, in: store(username: "jarrett", password: "hunter2"))
        }
    }

    @Test("Nothing stored: a blank password box means an empty password")
    func emptyPasswordIsValid() throws {
        let resolved = try resolveCredential(username: " jarrett ", password: nil, in: store())

        #expect(resolved == CredentialResolution(username: "jarrett", password: "", needsWrite: true))
    }

    @Test("Nothing stored: a typed pair is written")
    func newPair() throws {
        let resolved = try resolveCredential(username: "jarrett", password: "hunter2", in: store())

        #expect(resolved == CredentialResolution(username: "jarrett", password: "hunter2", needsWrite: true))
    }

    /// The common Save, since the username box is prefilled. Writing here would wipe the
    /// stored password.
    @Test("An untouched form writes nothing and keeps the stored password")
    func untouchedFormIsANoOp() throws {
        let resolved = try resolveCredential(
            username: "jarrett",
            password: nil,
            in: store(username: "jarrett", password: "hunter2")
        )

        #expect(resolved == CredentialResolution(username: "jarrett", password: "hunter2", needsWrite: false))
    }

    @Test("A changed username with a blank password keeps the stored password")
    func renameKeepsPassword() throws {
        let resolved = try resolveCredential(
            username: "alice",
            password: nil,
            in: store(username: "jarrett", password: "hunter2")
        )

        #expect(resolved == CredentialResolution(username: "alice", password: "hunter2", needsWrite: true))
    }

    @Test("A typed password replaces the stored one")
    func typedPasswordWins() throws {
        let resolved = try resolveCredential(
            username: "jarrett",
            password: "new",
            in: store(username: "jarrett", password: "hunter2")
        )

        #expect(resolved == CredentialResolution(username: "jarrett", password: "new", needsWrite: true))
    }

    /// A login whose password is empty is still a login: Test Connection must send it rather
    /// than fall back to "no credential".
    @Test("A stored empty password survives an untouched form")
    func storedEmptyPassword() throws {
        let resolved = try resolveCredential(
            username: "jarrett",
            password: nil,
            in: store(username: "jarrett", password: "")
        )

        #expect(resolved == CredentialResolution(username: "jarrett", password: "", needsWrite: false))
    }
}
