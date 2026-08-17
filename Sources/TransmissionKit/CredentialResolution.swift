import Foundation

/// The login the settings form's two boxes amount to, and whether it has to be written.
public struct CredentialResolution: Equatable, Sendable {
    public let username: String
    public let password: String

    /// False when the form matches what is stored, so Save is a no-op rather than a rewrite.
    public let needsWrite: Bool
}

public enum CredentialFormError: Error, Equatable, LocalizedError {
    case usernameRequired

    public var errorDescription: String? {
        switch self {
        case .usernameRequired:
            "A password needs a username."
        }
    }
}

/// Turns the settings form's username and write-only password box into the login to use.
///
/// `password` is `nil` when the box is blank, which means "keep what is stored" when a
/// credential exists and "an empty password" when none does — a daemon with a username and
/// no password is a valid configuration. Returns `nil` when there is no login to use or
/// write at all. Throws ``CredentialFormError/usernameRequired`` when the username box is
/// blank and there is nonetheless a password: the box is prefilled, so blank means the user
/// erased it.
///
/// Both Save and Test Connection go through here, so Test Connection can't exercise a login
/// Save wouldn't write.
public func resolveCredential(
    username: String,
    password: String?,
    in store: any CredentialStore
) throws -> CredentialResolution? {
    let username = username.trimmingCharacters(in: .whitespaces)
    let stored = try store.credential()

    guard !username.isEmpty else {
        guard password == nil, stored == nil else { throw CredentialFormError.usernameRequired }
        return nil
    }

    if let password {
        return CredentialResolution(username: username, password: password, needsWrite: true)
    }

    guard let stored else {
        return CredentialResolution(username: username, password: "", needsWrite: true)
    }
    return CredentialResolution(
        username: username,
        password: stored.password,
        needsWrite: username != stored.username
    )
}
