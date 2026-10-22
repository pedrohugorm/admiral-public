import AppKit
import SwiftUI
import AdmiralCore

/// The `-probeGroupsUI` cases for a member's AskUserQuestion shown in the group window: one
/// question still open, one answered from the group (the answer logged "User (to @member): …",
/// waking nobody), drawn dark and light. The fixture is invented; the ledger lines are what the
/// bridge mirror and the prompt hook would write.
extension AppModel {
    func probeGroupAsks(check: (String, Bool, String) -> Void,
                        draw: (String, GroupChatView, NSSize, Bool) async -> Void) async {
        let tabs = Dictionary(sessions.sessions.map { ($0.callsign, $0) }, uniquingKeysWith: { a, _ in a })
        guard let web = tabs["web-ui"], let infra = tabs["infra"], let lead = tabs["lead"],
              let webSID = web.claudeSessionID, let infraSID = infra.claudeSessionID,
              case .success(let group) = createGroup(name: "Schema review",
                                                    members: [lead, web, infra].map(memberKey(for:)))
        else { return check("ask fixture", false, "tabs or group missing") }
        let base = sessions.supportDir
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        groupStore.append(to: group.id, author: .human, name: "User", colorHex: nil, symbol: nil,
                          text: "Before we add the orders table: @web-ui @infra anything you need from me?",
                          target: .members([memberKey(for: web), memberKey(for: infra)]), at: ago(25))
        let storage = AskQuestion(question: "Where should order history live?", header: "Storage", options: [
            AskOption(label: "Postgres", description: "Same instance as carts; one more table."),
            AskOption(label: "SQLite per tenant", description: "Simpler backups, harder reporting."),
        ])
        ChatLedger.append(ChatEvent(ts: GroupTimeline.iso(ago(20)), kind: .ask, questions: [storage]),
                          base: base, session: webSID)
        groupStore.append(to: group.id, author: .member(memberKey(for: infra)), name: infra.callsign,
                          colorHex: infra.avatarColorHex, symbol: infra.avatarSymbol,
                          text: "Staging Postgres has room for it. I'll have the migration ready once the checks are settled.",
                          target: .everyone, at: ago(15))
        let checks = AskQuestion(question: "Which checks gate the migration?", header: "CI", multiSelect: true, options: [
            AskOption(label: "Lint", description: "Schema naming rules."),
            AskOption(label: "Unit", description: "Serializer and repository tests."),
            AskOption(label: "Staging dry run", description: "Apply and roll back against a copy."),
        ])
        let window = AskQuestion(question: "When should it run?", header: "Window", options: [
            AskOption(label: "Tonight"), AskOption(label: "Next release"),
        ])
        ChatLedger.append(ChatEvent(ts: GroupTimeline.iso(ago(10)), kind: .ask, questions: [checks, window]),
                          base: base, session: infraSID)

        func asks() -> [GroupAsk] {
            groupTimeline(group).compactMap { if case .ask(let ask) = $0 { return ask } else { return nil } }
        }
        let before = asks()
        check("both questions in the group, open", before.map(\.open) == [true, true]
              && before.map(\.member) == [memberKey(for: web), memberKey(for: infra)], "\(before.map(\.open))")
        check("a question is not a group message", groupStore.messages(group.id).count == 2,
              "\(groupStore.messages(group.id).count) logged")

        // Answer web-ui's question from the group, then the prompt hook logs the typed answer
        // in web-ui's ledger (no claude here, so the probe writes that line itself).
        guard let open = before.first else { return }
        let logged = groupStore.messages(group.id).count
        answerGroupAsk(open, answers: ["Postgres"], in: group)
        let answer = AskAnswer.text(questions: open.questions, answers: ["Postgres"])
        let last = groupStore.messages(group.id).last
        check("the answer is logged to the asker",
              groupStore.messages(group.id).count == logged + 1
              && last.map { GroupPrompt.line($0, names: [memberKey(for: web): web.callsign]) }
                  == "User (to @web-ui): " + answer,
              last?.text ?? "nothing logged")
        check("the logged answer wakes nobody", !groupService.hasPending(memberKey(for: lead))
              && !groupService.hasPending(memberKey(for: infra)), "no pending wakes")
        ChatLedger.append(ChatEvent(ts: GroupTimeline.iso(Date()), kind: .prompt, text: answer),
                          base: base, session: webSID)
        let after = asks()
        check("answered in the tab's session closes the group card", after.map(\.open) == [false, true],
              "\(after.map(\.open))")

        for dark in [true, false] {
            await draw("group-ask", GroupChatView(group: groupStore.group(group.id) ?? group),
                       NSSize(width: 900, height: 1000), dark)
        }
    }
}
