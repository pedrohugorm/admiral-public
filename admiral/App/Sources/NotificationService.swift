import UserNotifications
import AppKit
import AdmiralCore

/// Every native notification Admiral posts goes through `post(kind:…)`: claude's terminal
/// notifications (OSC 9 / 777), the hook-driven ones (AskUserQuestion, needs-input), the
/// bridge `notify` tool, and the watchdog / goals nudges. It is the ONE place the Settings →
/// Notifications toggles are checked (`NotificationPolicy`), so no producer can bypass them.
/// Clicking a notification brings Admiral forward and selects the originating session
/// (via `onActivate`).
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// Invoked (on the main actor) when a notification is clicked, with the session id.
    var onActivate: ((UUID) -> Void)?

    /// Is the user looking at this session right now (app active + its tab selected)?
    /// Set by the app; kinds that `suppressedWhileViewing` are dropped when it says yes.
    var isViewing: (UUID) -> Bool = { _ in false }
    private let defaults: UserDefaults
    /// A needs-input within this long of a question for the same session is the question's
    /// own permission prompt: one notification is enough.
    private static let questionDedupeWindow: TimeInterval = 5
    private var lastQuestion: [UUID: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts unless Settings or the viewing rule say no. Returns whether it was posted.
    @discardableResult
    func post(kind: NotificationKind, title: String, body: String, sessionID: UUID) -> Bool {
        guard NotificationPolicy.shouldPost(kind, viewing: isViewing(sessionID), defaults: defaults) else {
            return false
        }
        if kind == .question { lastQuestion[sessionID] = Date() }
        if kind == .needsInput, let at = lastQuestion[sessionID],
           Date().timeIntervalSince(at) < Self.questionDedupeWindow { return false }
        deliver(title: title, body: body, sessionID: sessionID)
        return true
    }

    private func deliver(title: String, body: String, sessionID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionID": sessionID.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show the banner even when Admiral is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Click → bring Admiral forward and select the session it came from.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let raw = response.notification.request.content.userInfo["sessionID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        let activate = onActivate
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            activate?(id)
        }
    }
}
