import SwiftUI
import AppKit
import SwiftTerm
import AdmiralCore

struct DetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let group = model.selectedGroup {
            // A group shows its own window; the tab selection underneath is kept for when it closes.
            GroupChatView(group: group)
                .id(group.id)
        } else if let session = model.sessions.selectedSession {
            // Only this region swaps between Chat and Terminal (⌘J); the status bar below is
            // shared by both. The terminal keeps running in Chat mode — the host retains its view.
            VStack(spacing: 0) {
                if model.viewMode(for: session) == .chat {
                    ChatView(session: session)
                        .id(session.id)   // fresh paging state per tab; switching frees the pages
                } else {
                    terminal(for: session)
                }
                Divider().opacity(0.5)
                StatusBar(
                    session: session,
                    conversation: conversation(for: session),
                    teammates: teammates(for: session),
                    prStatus: model.prStatus,
                    onMerge: { model.mergeSelectedPR() },
                    confirmingMerge: $model.confirmingMerge
                )
            }
            .paneBackground(Theme.contentBackground)
        } else {
            EmptyDetail()
        }
    }

    @ViewBuilder
    private func terminal(for session: AgentSession) -> some View {
        if let view = model.host.view(for: model.sessions.handle(for: session.id)) {
            // The terminal auto-focuses when it appears / when you switch to it (see
            // TerminalContainerView), so typing goes straight there — no click, no
            // focus indicator needed.
            TerminalPane(view: view)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "terminal").font(.system(size: 30)).foregroundStyle(Theme.secondaryText)
                Text("No live terminal for this session.").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .paneBackground(Theme.contentBackground)
        }
    }

    private func conversation(for session: AgentSession) -> Conversation {
        model.sessions.conversations[session.id] ?? .empty
    }

    /// Other sessions sharing this session's team (for the status-bar team popover).
    private func teammates(for session: AgentSession) -> [AgentSession] {
        guard let team = session.teamName, !team.isEmpty else { return [] }
        return model.sessions.sessions
            .filter { $0.id != session.id && $0.teamName == team }
            .sorted { $0.displayTitle < $1.displayTitle }
    }
}

/// Hosts a session's live SwiftTerm view and exposes the terminal's visible text as
/// its accessibility value, so UI tests can assert which session's content is shown
/// (SwiftTerm itself exposes nothing to the a11y tree).
final class TerminalContainerView: NSView {
    weak var terminalView: LocalProcessTerminalView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTerminal()
    }

    /// Make the embedded terminal the first responder so keystrokes go straight to it the
    /// moment this pane appears or the selected session changes — no click required.
    func focusTerminal() {
        guard let window, let terminalView else { return }
        DispatchQueue.main.async { window.makeFirstResponder(terminalView) }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    override func accessibilityValue() -> Any? {
        guard let terminal = terminalView?.getTerminal() else { return "" }
        var lines: [String] = []
        var row = 0
        while row < 500, let line = terminal.getLine(row: row) {
            lines.append(line.translateToString(trimRight: true))
            row += 1
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Embeds the live SwiftTerm view, swapping in the selected session's view (the host
/// retains each view, so content survives session switches).
struct TerminalPane: NSViewRepresentable {
    let view: LocalProcessTerminalView?

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.wantsLayer = true
        container.setAccessibilityIdentifier("terminal-content")
        host(in: container)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        host(in: container)
    }

    private func host(in container: TerminalContainerView) {
        guard container.terminalView !== view else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        container.terminalView = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Focus the freshly-shown terminal (first appearance or a session switch).
        container.focusTerminal()
    }
}
