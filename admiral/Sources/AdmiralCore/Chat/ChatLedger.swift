import Foundation

/// The chat ledger on disk: `<base>/chat/<session_id>.jsonl`, one `ChatEvent` per line.
///
/// Keyed by claude's session id, like goals, not by `ADMIRAL_SESSION`: the token is a fresh
/// UUID every launch, so a token-keyed ledger would lose its history on every relaunch and
/// `--resume`. The hook helper learns the id from the payload; the app from the session.
public enum ChatLedger {
    /// A reply can be long; cap it so one `write(2)` still carries the whole line.
    public static let maxTextLength = 32_000
    /// How many trailing events the view loads.
    public static let tailCount = 400

    public static func url(base: URL, session: String) -> URL {
        chatDir(base: base).appendingPathComponent("\(AdmiralPaths.sanitized(session)).jsonl")
    }

    /// The per-session view mode the app publishes for the hook (`chat` / `terminal`).
    public static func modeURL(base: URL, session: String) -> URL {
        chatDir(base: base).appendingPathComponent("\(AdmiralPaths.sanitized(session)).mode")
    }

    /// Prompts Admiral itself typed into the session, awaiting their `UserPromptSubmit`.
    public static func injectedURL(base: URL, session: String) -> URL {
        chatDir(base: base).appendingPathComponent("\(AdmiralPaths.sanitized(session)).injected.jsonl")
    }

    static func chatDir(base: URL) -> URL {
        let dir = base.appendingPathComponent("chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: Int(PrivateFile.directoryMode)])
        return dir
    }

    public static func append(_ event: ChatEvent, base: URL, session: String) {
        var event = event
        if let text = event.text, text.count > maxTextLength {
            event.text = String(text.prefix(maxTextLength)) + "…"
        }
        guard let data = try? JSONEncoder().encode(event) else { return }
        AtomicAppend.line(data, to: url(base: base, session: session))
    }

    /// The last `tailCount` events (all of them with `tail: nil`), each `id`'d by its line
    /// number so an item keeps its identity as the ledger grows. Unparseable lines are
    /// skipped, never fatal.
    public static func read(base: URL, session: String, tail: Int? = tailCount) -> [ChatEvent] {
        guard let raw = try? String(contentsOf: url(base: base, session: session), encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let start = tail.map { max(0, lines.count - $0) } ?? 0
        return lines[start...].enumerated().compactMap { offset, line in
            guard !line.isEmpty, var event = try? decoder.decode(ChatEvent.self, from: Data(line.utf8))
            else { return nil }
            event.id = start + offset
            return event
        }
    }

    /// Timestamp of the ledger's first event — where transcript history hands over to it.
    public static func firstTimestamp(base: URL, session: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url(base: base, session: session)) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        guard let line = head.split(separator: 0x0A).first,
              let event = try? JSONDecoder().decode(ChatEvent.self, from: Data(line)) else { return nil }
        return event.ts
    }

    // MARK: - View mode

    public enum Mode: String, Sendable { case chat, terminal }

    /// Absent means terminal — the default view.
    public static func mode(base: URL, session: String) -> Mode {
        let raw = (try? String(contentsOf: modeURL(base: base, session: session), encoding: .utf8)) ?? ""
        return Mode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .terminal
    }

    public static func setMode(_ mode: Mode, base: URL, session: String) {
        try? PrivateFile.write(mode.rawValue, to: modeURL(base: base, session: session))
    }

    // MARK: - Injected-prompt markers

    struct Injected: Codable { var source: String; var text: String }

    /// Record that Admiral is about to type `text` into the session, so the prompt it
    /// produces is attributed to `source` rather than to the user.
    public static func markInjected(_ text: String, source: String, base: URL, session: String) {
        let marker = Injected(source: source, text: String(normalized(text).prefix(2000)))
        guard let data = try? JSONEncoder().encode(marker) else { return }
        AtomicAppend.line(data, to: injectedURL(base: base, session: session))
    }

    /// The source of `prompt` if Admiral typed it, consuming that marker. Nil means the user.
    static func consumeInjected(prompt: String, base: URL, session: String) -> String? {
        let url = injectedURL(base: base, session: session)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        var markers = raw.split(separator: "\n").compactMap {
            try? decoder.decode(Injected.self, from: Data($0.utf8))
        }
        let key = String(normalized(prompt).prefix(2000))
        guard let index = markers.firstIndex(where: { $0.text == key }) else { return nil }
        let source = markers.remove(at: index).source
        let encoder = JSONEncoder()
        let rest = markers.compactMap { (try? encoder.encode($0)).map { String(decoding: $0, as: UTF8.self) } }
        try? PrivateFile.write(rest.isEmpty ? "" : rest.joined(separator: "\n") + "\n", to: url)
        return source
    }

    /// Whitespace-insensitive key: the terminal may reflow what was typed, and a pasted part
    /// comes back wrapped in `<pasted_content>` tags (a long hail's body).
    static func normalized(_ text: String) -> String {
        ChatFolder.displayPrompt(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
