import SwiftUI
import TransmissionKit

@MainActor
@Observable
final class SettingsFormState {
    enum TestStatus: Equatable {
        case idle
        case testing
        case succeeded
        case failed(String)
    }

    var urlString: String
    var username = ""
    var password = ""
    var allowsInvalidCertificates: Bool
    var testStatus: TestStatus = .idle
    var saveError: String?

    /// Whether a login is stored for the URL currently typed, which is what the password
    /// placeholder reports.
    var hasStoredCredential = false

    init(config: ServerConfig?) {
        urlString = config?.baseURL.absoluteString ?? ServerConfig.defaultURLString
        allowsInvalidCertificates = config?.allowsInvalidCertificates ?? false
    }

    /// The field is write-only: empty means "leave whatever is in the keychain alone".
    var passwordChange: PasswordChange {
        password.isEmpty ? .unchanged : .set(password)
    }
}

struct SettingsView: View {
    let model: AppModel
    @Bindable var form: SettingsFormState
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var hasPrefilled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Section {
                    TextField("Server URL", text: $form.urlString, prompt: Text(ServerConfig.defaultURLString))
                        .textContentType(.URL)
                    Text("The address of the Transmission web interface. Pasting it from your browser works.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Username", text: $form.username, prompt: Text("Optional"))
                    SecureField("Password", text: $form.password, prompt: Text(passwordPrompt))
                }

                Section {
                    Toggle("Allow invalid certificates", isOn: $form.allowsInvalidCertificates)
                    Text("Only for a daemon behind a proxy using an internal certificate authority.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 12) {
                Button("Test Connection", action: test)
                    .disabled(form.testStatus == .testing)
                testStatusLabel
                Spacer()
            }

            if let saveError = form.saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task(id: form.urlString) { await refreshStoredLogin() }
    }

    private var passwordPrompt: String {
        form.hasStoredCredential ? "Unchanged" : "Optional"
    }

    /// Both lookups are prompt-free, but they are synchronous Security calls, so they wait
    /// for typing to stop. The first pass runs immediately, since it is the prefill.
    private func refreshStoredLogin() async {
        if hasPrefilled {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        hasPrefilled = true

        guard let login = model.storedLogin(forURLString: form.urlString) else { return }
        form.username = login.username ?? ""
        form.hasStoredCredential = login.exists
    }

    @ViewBuilder
    private var testStatusLabel: some View {
        switch form.testStatus {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .succeeded:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .lineLimit(2)
        }
    }

    private func test() {
        form.testStatus = .testing
        Task {
            do {
                let client = try model.probeClient(
                    urlString: form.urlString,
                    username: form.username,
                    password: form.passwordChange,
                    allowsInvalidCertificates: form.allowsInvalidCertificates
                )
                try await client.testConnection()
                form.testStatus = .succeeded
            } catch {
                form.testStatus = .failed(message(for: error))
            }
        }
    }

    /// Saving is never gated on a passing test — a sleeping server shouldn't stop you
    /// fixing a typo.
    private func save() {
        do {
            try model.save(
                urlString: form.urlString,
                username: form.username,
                password: form.passwordChange,
                allowsInvalidCertificates: form.allowsInvalidCertificates
            )
            form.saveError = nil
            onSave()
        } catch {
            form.saveError = message(for: error)
        }
    }

    private func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
