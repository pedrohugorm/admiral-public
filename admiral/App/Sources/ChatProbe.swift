import AppKit
import AdmiralCore

/// `-probeChat <cwd> -probeChatProof <file>`: the Chat view's end-to-end proof against a REAL
/// claude — the part unit tests can't reach (claude's own hook payloads, its TUI, the model
/// actually choosing the bridge mirror). Writes PASS/FAIL lines, then quits.
///
/// Run it isolated (`ADMIRAL_SUPPORT_DIR` + a unique `ADMIRAL_PROFILE`), from the build
/// products — never against the installed app, which hosts live sessions.
extension AppModel {
    func runChatProbe(cwd: String, proof: String) {
        newSession(cwd: cwd)
        Task { @MainActor [weak self] in
            guard let self else { return }
            var lines: [String] = []
            func check(_ name: String, _ ok: Bool, _ detail: String) {
                lines.append("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
            }
            @MainActor func screen(_ label: String) {
                guard let session = self.sessions.selectedSession,
                      let handle = self.sessions.handle(for: session.id),
                      let text = self.host.captureVisibleText(handle) else { return }
                let visible = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(25)
                lines.append("----- screen: \(label) -----\n" + visible.joined(separator: "\n"))
            }
            @MainActor func finish() {
                screen("at finish")
                let failed = lines.contains { $0.hasPrefix("FAIL") }
                lines.insert(failed ? "RESULT: FAIL" : "RESULT: PASS", at: 0)
                try? (lines.joined(separator: "\n") + "\n").write(toFile: proof, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            func poll<T>(_ seconds: Double, _ probe: () -> T?) async -> T? {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    if let value = probe() { return value }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                return nil
            }

            guard let session = sessions.selectedSession, let sid = session.claudeSessionID else {
                check("commission", false, "no managed session was created")
                return finish()
            }
            let base = sessions.supportDir
            func ledger() -> [ChatEvent] { ChatLedger.read(base: base, session: sid) }

            check("Terminal is the default view for a new claude tab", viewMode(for: session) == .terminal,
                  "mode=\(viewMode(for: session).rawValue)")

            // claude's prompt is drawn once the TUI is up.
            let ready = await poll(90) { () -> Bool? in
                guard let handle = self.sessions.handle(for: session.id),
                      let screen = self.host.captureVisibleText(handle),
                      screen.contains("❯") else { return nil }
                return true
            }
            check("claude TUI came up", ready == true, ready == true ? "prompt visible" : "no prompt after 90s")
            guard ready == true else { return finish() }
            try? await Task.sleep(for: .seconds(2))

            // 1. Composer send: typed, multi-line, never a paste.
            let message = "Line one of a chat message.\nLine two: call AskUserQuestion exactly once, "
                + "one question, header Color, question \"Pick a color?\", single select, options "
                + "Red, Green, Blue. Then wait for my answer."
            screen("before send")
            sendChat(message, attachments: [], to: session)
            try? await Task.sleep(for: .seconds(3))
            screen("3s after send")
            let prompt = await poll(60) { self.firstEvent(ledger(), .prompt) }
            let promptText = prompt?.text ?? "(none)"
            check("composer send reaches claude as a typed prompt with real newlines",
                  promptText == message && !promptText.contains("pasted_content"),
                  String(reflecting: promptText))

            // 2. Chat mode: the built-in is denied and the model calls the bridge mirror.
            let ask = await poll(180) { self.firstEvent(ledger(), .ask) }
            check("agent asked through the bridge mirror", ask != nil,
                  ask.map { "questions=\($0.questions?.map(\.question) ?? [])" } ?? "no ask event after 180s")
            let transcript = sessions.sessions.first { $0.id == session.id }?.transcriptPath
                .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
            check("claude's built-in dialog was denied (never answered)",
                  !transcript.contains("User has answered your questions"),
                  "built-in calls=\(transcript.components(separatedBy: "\"name\":\"AskUserQuestion\"").count - 1), "
                  + "mirror calls=\(transcript.components(separatedBy: "\"name\":\"mcp__bridge__AskUserQuestion\"").count - 1)")
            guard let questions = ask?.questions, !questions.isEmpty else { return finish() }

            // The mirror returns at once; the turn ends waiting for the answer.
            _ = await poll(90) { () -> Bool? in
                let events = self.eventsAfter(ledger(), .ask)
                return events.contains { $0.kind == .reply } ? true : nil
            }

            // 3. Answering the card types the answers in as the next prompt.
            answerAsk(questions, answers: ["Green"], for: session)
            let answered = await poll(60) { () -> ChatEvent? in
                self.eventsAfter(ledger(), .ask).first { $0.kind == .prompt }
            }
            check("card answers arrive as the next prompt",
                  answered?.text == AskAnswer.text(questions: questions, answers: ["Green"]),
                  String(reflecting: answered?.text ?? "(none)"))
            let chat = ChatFolder.fold(ledger())
            check("the question card closed", chat.openAsk == nil, "openAsk=\(chat.openAsk != nil)")
            let reply = await poll(120) { () -> ChatEvent? in
                let after = self.eventsAfter(ledger(), .ask)
                guard let promptIndex = after.firstIndex(where: { $0.kind == .prompt }) else { return nil }
                return after[(promptIndex + 1)...].first { $0.kind == .reply }
            }
            check("agent replied after the answers (Stop → chat)", reply != nil,
                  String(reflecting: reply?.text ?? "(none)"))

            // 4. Terminal mode: the hook leaves the built-in alone.
            setViewMode(.terminal, for: session)
            let payload = try? JSONSerialization.data(withJSONObject: [
                "session_id": sid, "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
            ])
            let terminalDecision = payload.flatMap { ChatHookHandler.preToolUse(payload: $0, base: base) }
            check("Terminal mode keeps claude's own AskUserQuestion", terminalDecision == nil,
                  terminalDecision ?? "allowed")
            finish()
        }
    }

    private func firstEvent(_ events: [ChatEvent], _ kind: ChatEvent.Kind) -> ChatEvent? {
        events.first { $0.kind == kind }
    }

    /// Events after the first `kind` event.
    private func eventsAfter(_ events: [ChatEvent], _ kind: ChatEvent.Kind) -> [ChatEvent] {
        guard let index = events.firstIndex(where: { $0.kind == kind }) else { return [] }
        return Array(events[(index + 1)...])
    }
}
