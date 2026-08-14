import Foundation
import TransmissionKit
import UserNotifications
import os

/// Reports the outcome of each add.
///
/// Authorization is requested on first use rather than at launch, so the system prompt
/// arrives when the app has visibly done something.
@MainActor
final class Notifier {
    private static let threadIdentifier = "torrent-adds"

    private let logger = Logger(subsystem: Bundle.transmissionShellIdentifier, category: "Notifier")

    /// `UNUserNotificationCenter.current()` traps outright when the executable isn't in a
    /// bundle, which is exactly what `swift run TransmissionShell` gives you.
    private let isBundled = Bundle.main.bundleIdentifier != nil
    private var hasRequestedAuthorization = false

    func report(_ result: AddResult) {
        switch result {
        case .added(let torrent):
            post(title: "Torrent added", body: torrent.name)
        case .duplicate(let torrent):
            post(title: "Already in Transmission", body: torrent.name)
        }
    }

    func reportFailure(_ error: any Error, describing source: String) {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        post(title: "Couldn’t add torrent", body: "\(source)\n\(reason)")
    }

    private func post(title: String, body: String) {
        guard isBundled else {
            logger.notice("\(title, privacy: .public): \(body, privacy: .public)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = Self.threadIdentifier

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        Task {
            await requestAuthorizationIfNeeded()
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                logger.error("Notification refused: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func requestAuthorizationIfNeeded() async {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
