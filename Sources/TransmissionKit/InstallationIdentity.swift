import Foundation

/// Namespaces this installation's stored state.
///
/// `swift run` produces a bare executable with no bundle, so it falls back to a distinct
/// identity: dev runs and the installed app never share a keychain item or a settings
/// domain.
public enum InstallationIdentity {
    public static let current = Bundle.main.bundleIdentifier
        ?? "com.jarrettgilliam.transmission-shell.dev"

    /// `UserDefaults(suiteName:)` rejects the app's own bundle identifier, hence the suffix.
    public static let settingsSuite = current + ".settings"
}
