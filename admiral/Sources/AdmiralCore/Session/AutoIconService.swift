import Foundation

/// Picks a symbol for a tab from the start of its first prompt, or nil when it can't (no
/// on-device model, or the model declined).
public protocol IconPicker: Sendable {
    func pickSymbol(for prompt: String, from symbols: [String]) async -> String?
}

/// Gives a tab an icon from its first prompt, once, and only while its icon is untouched.
///
/// A tab opens with the default icon. When its first prompt arrives, the picker chooses a
/// symbol from the start of that prompt and the tab takes it. An icon the user set is never
/// changed, including one set while the picker was still choosing, and only the first prompt
/// picks: not the tab's creation, not a later prompt, not the next prompt of a tab restored
/// with a history. The pick runs off the tick, so nothing waits on the model.
@MainActor
public final class AutoIconService {
    /// How much of the first prompt the picker sees.
    public static let promptPrefix = 200

    private let manager: SessionManager
    private let picker: IconPicker
    private let symbols: [String]
    /// Read position in each session's prompt log, by token.
    private var offsets: [String: UInt64] = [:]
    /// Sessions whose chance has come and gone: first prompt handled, or icon already set.
    private var decided: Set<UUID> = []
    /// Picks still running, by session. Tests await them.
    var picks: [UUID: Task<Void, Never>] = [:]

    public init(manager: SessionManager, picker: IconPicker, symbols: [String]) {
        self.manager = manager
        self.picker = picker
        self.symbols = symbols
    }

    public func tick() {
        for session in manager.sessions where !decided.contains(session.id) {
            guard Self.untouched(session) else { decided.insert(session.id); continue }
            // The prompt log is per launch, so a restored tab starts a fresh one: its first
            // entry is the first prompt of this run, not necessarily of the tab.
            let log = AdmiralPaths.promptsLog(base: manager.supportDir, token: session.token)
            let read = PromptLogReader.read(url: log, offset: offsets[session.token] ?? 0)
            offsets[session.token] = read.offset
            guard let first = read.events.first else { continue }
            decided.insert(session.id)
            pick(for: session.id, prompt: Self.pickerText(first.prompt), transcript: session.transcriptPath)
        }
    }

    /// What the picker sees of a prompt: its start, without the `<pasted_content>` tags claude
    /// wraps a paste in. The tags say nothing about the work and would use up the prefix.
    static func pickerText(_ prompt: String) -> String {
        let untagged = prompt.replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: "",
                                                   options: .regularExpression)
        return String(untagged.trimmingCharacters(in: .whitespacesAndNewlines).prefix(promptPrefix))
    }

    private func pick(for id: UUID, prompt: String, transcript: String?) {
        let picker = picker, symbols = symbols
        picks[id] = Task { [weak self] in
            // The transcript decides whether this is the tab's first prompt: it already holds
            // the prompt (claude writes it before the hook runs), so more than one means a
            // history. Read off the main actor, since a restored tab's transcript can be large.
            let prompts = await Task.detached(priority: .utility) {
                transcript.map { ChatHistory.transcriptEvents(path: $0, tail: nil) }?
                    .filter { $0.kind == .prompt }.count ?? 0
            }.value
            guard prompts <= 1,
                  let symbol = await picker.pickSymbol(for: prompt, from: symbols),
                  symbols.contains(symbol) else { return }
            self?.apply(symbol, to: id)
        }
    }

    /// Set the icon unless the user set one while the picker was choosing.
    private func apply(_ symbol: String, to id: UUID) {
        guard let session = manager.sessions.first(where: { $0.id == id }), Self.untouched(session) else { return }
        manager.setAppearance(id, colorHex: nil, symbol: symbol)
    }

    /// Any edit in the avatar editor stores both a color and a symbol, even the defaults, so an
    /// icon the user never touched has neither.
    static func untouched(_ session: AgentSession) -> Bool {
        session.avatarColorHex == nil && session.avatarSymbol == nil
    }
}
