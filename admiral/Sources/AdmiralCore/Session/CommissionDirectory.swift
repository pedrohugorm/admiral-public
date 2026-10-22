import Foundation

/// The working directory a Siri/Shortcuts "Commission Session" asked for. A new claude session
/// runs with `bypassPermissions` in that folder, so only a folder that already exists is taken.
public enum CommissionDirectory {
    /// `requested` (default `home`, a leading `~` expanded) as a standardized absolute path,
    /// or nil when it is not an existing directory (missing, a file, or relative).
    public static func resolve(_ requested: String?, home: String,
                               fileManager: FileManager = .default) -> String? {
        let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var path = trimmed.isEmpty ? home : trimmed
        if path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst() }
        guard path.hasPrefix("/") else { return nil }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized, isDirectory: &isDir), isDir.boolValue else { return nil }
        return standardized
    }
}
