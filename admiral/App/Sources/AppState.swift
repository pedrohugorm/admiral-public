import Foundation

/// Process-wide handle to the running app, used by App Intents (which run in the
/// app process) to reach the live `SessionManager` / `BridgeCore`.
@MainActor
final class AppState {
    static let shared = AppState()
    weak var model: AppModel?
    private init() {}
}
