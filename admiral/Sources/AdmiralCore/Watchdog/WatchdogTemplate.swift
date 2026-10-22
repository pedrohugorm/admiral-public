import Foundation

/// Renders a watchdog message template. Known placeholders substitute (nil → empty);
/// anything else is left verbatim so a typo'd template degrades visibly, not silently.
public enum WatchdogTemplate {
    public static func render(_ template: String, trigger: String?, prompt: String?,
                              status: String?, reason: String?, idleMinutes: Int?) -> String {
        template
            .replacingOccurrences(of: "{trigger}", with: trigger ?? "")
            .replacingOccurrences(of: "{prompt}", with: prompt ?? "")
            .replacingOccurrences(of: "{status}", with: status ?? "")
            .replacingOccurrences(of: "{reason}", with: reason ?? "")
            .replacingOccurrences(of: "{idle_minutes}", with: idleMinutes.map(String.init) ?? "")
    }
}
