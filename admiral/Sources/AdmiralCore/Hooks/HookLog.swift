import Foundation

/// Appends one event line to a session's `touched.jsonl`.
///
/// Uses `AtomicAppend` because the many short-lived hook processes genuinely do write at the
/// same time — a `seekToEnd` + write here silently lost most of the log.
enum HookLog {
    static func append(_ event: TouchedRepoEvent, to url: URL) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        AtomicAppend.line(data, to: url)
    }
}
