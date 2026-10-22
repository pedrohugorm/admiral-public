import Foundation

/// How a clicked terminal link should be opened. SwiftTerm's default handler does
/// `URL(string: link)` then `NSWorkspace.shared.open` — which fails with OSStatus -50
/// (`paramErr`) for the bare, workspace-relative file paths claude emits as OSC 8 hyperlinks
/// (e.g. `.output/specs/2026-…-design.md`): those parse to a schemeless, un-openable URL.
///
/// This resolves the link into an openable form so the app never hands Launch Services a bad
/// URL: http/https/mailto URLs pass through; anything file-ish is turned into a real file URL,
/// resolving a relative path against the session's working directory. Pure + injectable so it's
/// covered by fast `swift test`; the app performs the actual `NSWorkspace` open.
///
/// A link is text a session (or whatever it read) printed, so a click must never run anything:
/// any other scheme (`x-apple.systempreferences:`, a custom app's URL handler, `ssh:`, …)
/// resolves to `.none`, and a file Launch Services would *execute* rather than display — an app
/// bundle, a script, anything with the executable bit — resolves to `.reveal` (shown selected in
/// Finder) instead of `.file`.
public enum TerminalLink: Equatable, Sendable {
    /// An http/https/mailto URL — open as-is.
    case web(URL)
    /// A resolved, existing, inert file or folder — open in its default app.
    case file(URL)
    /// A resolved, existing file that opening would run (`isRunnable`) — reveal it in Finder.
    case reveal(URL)
    /// Nothing openable (empty, a path that doesn't exist, a disallowed scheme) — the app can beep.
    case none

    /// The only URL schemes a click hands to the system as-is.
    public static let webSchemes: Set<String> = ["http", "https", "mailto"]

    /// True when `url` is a web link a click may open (`webSchemes`).
    public static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return webSchemes.contains(scheme)
    }

    /// Extensions Launch Services runs, installs, mounts or follows rather than displays.
    static let runnableExtensions: Set<String> = [
        "app", "pkg", "mpkg", "dmg", "iso", "img", "sparseimage", "sparsebundle",
        "command", "terminal", "tool", "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish",
        "py", "pl", "rb", "jar", "workflow", "action", "scpt", "scptd",
        "applescript", "osax", "webloc", "inetloc", "fileloc", "url", "shortcut", "prefpane",
        "saver", "kext", "plugin", "bundle", "framework", "xpc", "appex", "qlgenerator",
        "mdimporter", "mobileconfig", "configprofile", "dylib", "so",
    ]

    /// True when opening `url` would run something: its target (symlinks followed) has a
    /// runnable extension, or is a regular file with an executable bit, or is a directory
    /// carrying an app bundle's `Contents/MacOS`. Ordinary files and folders are false.
    public static func isRunnable(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let target = url.resolvingSymlinksInPath()
        for candidate in [url, target]
        where runnableExtensions.contains(candidate.pathExtension.lowercased()) {
            return true
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue {
            return fileManager.fileExists(atPath: target.appendingPathComponent("Contents/MacOS").path)
        }
        return fileManager.isExecutableFile(atPath: target.path)
    }

    /// An existing file URL classified for a click: `.reveal` if it would run, else `.file`.
    public static func forFile(_ url: URL, fileManager: FileManager = .default) -> TerminalLink {
        isRunnable(url, fileManager: fileManager) ? .reveal(url) : .file(url)
    }

    /// The file URL of a `.file` or `.reveal` link.
    public var fileURL: URL? {
        switch self {
        case .file(let url), .reveal(let url): url
        case .web, .none: nil
        }
    }

    public static func resolve(
        _ raw: String,
        cwd: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> TerminalLink {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return .none }

        // A real URL with a non-file scheme opens as-is only when it is http/https/mailto;
        // every other scheme resolves to nothing. A `file` scheme falls through to filesystem
        // handling so relative/percent-encoded forms resolve.
        if let url = URL(string: link), let scheme = url.scheme, !scheme.isEmpty,
           scheme.lowercased() != "file" {
            return isWebURL(url) ? .web(url) : .none
        }

        // Filesystem path: strip a `file://` prefix (decoding percent-escapes via URL.path),
        // expand a leading `~`, and resolve a relative path against the session cwd.
        var path: String
        if link.lowercased().hasPrefix("file://"), let url = URL(string: link) {
            path = url.path
        } else {
            path = link
        }
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = (cwd as NSString).appendingPathComponent(path)
        }
        let resolved = URL(fileURLWithPath: path).standardizedFileURL
        return fileExists(resolved.path) ? forFile(resolved) : .none
    }

    /// Punctuation prose puts straight after a path: the sentence's full stop, a closing
    /// backtick/quote/bracket, a list comma. A terminal link picked out of claude's rendered
    /// text carries it (`…/review.md.`), and so does a chat token (`` `review.md`. ``).
    static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?`'\"“”‘’)]}>*_")

    /// `raw`, then `raw` with trailing punctuation dropped one character at a time — longest
    /// first, so a file whose name really ends in one of these still wins over a shorter one.
    public static func proseCandidates(_ raw: String) -> [String] {
        var out = [raw]
        var scalars = raw.unicodeScalars[...]
        while let last = scalars.last, trailingPunctuation.contains(last) {
            scalars = scalars.dropLast()
            if !scalars.isEmpty { out.append(String(scalars)) }
        }
        return out
    }

    /// `resolve`, forgiving the punctuation prose leaves on a path (`proseCandidates`).
    public static func resolveInProse(
        _ raw: String,
        cwd: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> TerminalLink {
        for candidate in proseCandidates(raw) {
            let link = resolve(candidate, cwd: cwd, fileExists: fileExists)
            if link != .none { return link }
        }
        return .none
    }
}
