import SwiftUI
import AppKit
import AdmiralCore

/// A fixed-size, pure-SwiftUI composition of the full UI for offscreen rendering via
/// ImageRenderer (the UI validation gate). Avoids ScrollView and AppKit controls
/// (List/Picker/TextField), which ImageRenderer cannot rasterize, by drawing static
/// equivalents of the chrome — the content views are the real ones.
struct SnapshotRoot: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 272)
            Divider()
            if let session = model.sessions.selectedSession {
                SnapshotDetail(
                    session: session,
                    conversation: model.sessions.conversations[session.id] ?? .empty
                )
                Divider()
                footprintChecklists(for: session)
            }
        }
        .frame(width: 1280, height: 820)
        .environment(\.colorScheme, .light)
        .background(Theme.contentBackground)
    }

    /// The Footprint panel's bottom half — the real `SessionChecklist` views, so the gate
    /// catches a regression in how tasks and goals actually draw. The panel's repo list is
    /// a ScrollView, which ImageRenderer cannot rasterize, so only this part is composed.
    private func footprintChecklists(for session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Footprint").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider().opacity(0.5)
            Spacer()
            Divider().opacity(0.5)
            SessionChecklist(title: "Task List",
                             items: model.sessions.conversations[session.id]?.plan?.items ?? [])
            Divider().opacity(0.3).padding(.horizontal, 12)
            SessionChecklist(
                title: "Goals",
                items: session.claudeSessionID
                    .flatMap { model.goalsStore.goals(forSession: $0) }?.checklistItems ?? [])
        }
        .frame(width: 280)
        .background(Theme.contentBackground)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    Text("Search sessions…").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.chipBackground))
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            VStack(spacing: 2) {
                ForEach(model.sessions.sessions) { session in
                    SessionRow(
                        session: session, collapsed: false,
                        selected: session.id == model.sessions.selectedID
                    )
                    .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .background(Theme.sidebarBackground)
    }
}

/// Detail pane with static chrome (toggle/composer) for the snapshot.
private struct SnapshotDetail: View {
    let session: AgentSession
    let conversation: Conversation

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Avatar(session: session, size: 22)
                    Text(session.displayTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.primaryText)
                }
                HStack { Spacer(); toggle }.padding(.horizontal, 14)
            }
            .frame(height: 46)

            Divider()

            TranscriptContent(conversation: conversation)
                .padding(.vertical, 22).padding(.horizontal, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider().opacity(0.5)
            StatusBar(session: session, conversation: conversation, confirmingMerge: .constant(false))
        }
        .background(Theme.contentBackground)
    }

    private var toggle: some View {
        HStack(spacing: 0) {
            Text("Transcript")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 16).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.contentBackground).shadow(radius: 1))
            Text("Terminal")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 16).padding(.vertical, 4)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chipBackground))
    }
}

enum SnapshotRenderer {
    @MainActor
    static func render(model: AppModel, to path: String) {
        let content = SnapshotRoot().environmentObject(model)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
