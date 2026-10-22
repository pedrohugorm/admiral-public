import SwiftUI
import AdmiralCore

/// A titled checklist pinned to the bottom of the Footprint panel: a header with an
/// `n / m` count, then one row per item in three states.
///
/// Two callers — the session's Task List (folded from its `Task*`/`TodoWrite` calls) and its
/// Goals — because they differ only in title, where the items come from, and what a person can
/// do with them: the Task List only mirrors claude's tasks, while Goals give each row a
/// right-click menu and put a `…` menu beside the count. **Renders nothing at all when it has
/// no items**, so a session with no tasks shows no section rather than an empty header.
struct SessionChecklist<RowMenu: View, Accessory: View>: View {
    let title: String
    let items: [PlanItem]
    /// A row's right-click menu; empty content shows none.
    @ViewBuilder let rowMenu: (PlanItem) -> RowMenu
    /// Drawn after the count.
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Spacer()
                    Text(count)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        // On the count itself, not the container: a SwiftUI group's own
                        // value doesn't reach the a11y tree, but a Text's label always does.
                        .accessibilityIdentifier("checklist-\(slug)")
                    accessory()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(items.openFirst) { item in
                        ChecklistRow(item: item)
                            .contentShape(Rectangle())   // right-click anywhere on the row
                            .contextMenu { rowMenu(item) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var count: String {
        "\(items.filter { $0.state == .completed }.count) / \(items.count)"
    }

    private var slug: String {
        title.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}

extension SessionChecklist where RowMenu == EmptyView, Accessory == EmptyView {
    /// A list that is only read — the Task List mirrors claude's own tasks, so there is nothing
    /// to decide from it.
    init(title: String, items: [PlanItem]) {
        self.init(title: title, items: items, rowMenu: { _ in EmptyView() }, accessory: { EmptyView() })
    }
}

/// One checklist line: a small status dot and the text. The row in flight is the only one
/// at full strength — done recedes, pending sits between them — so the eye lands on the
/// current work without any row shouting.
private struct ChecklistRow: View {
    let item: PlanItem
    private static let dot: CGFloat = 6

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            marker
                .frame(width: Self.dot, height: Self.dot)
                .padding(.top, 4)   // optically centers the dot on the first line
            Text(item.title)
                .font(.system(size: 11))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var marker: some View {
        switch item.state {
        case .completed:
            Circle().fill(Theme.checkGreen)
        case .inProgress:
            Circle().fill(Theme.accent)
        case .pending:
            Circle().strokeBorder(Theme.pendingGray, lineWidth: 1)
        }
    }

    private var textColor: Color {
        switch item.state {
        case .completed: return Theme.secondaryText.opacity(0.65)
        case .inProgress: return Theme.primaryText
        case .pending: return Theme.secondaryText
        }
    }
}

extension SessionGoals {
    /// Goals as checklist items. Cancelled ones leave the panel entirely — they were decided
    /// and no longer describe the work. Of what remains, the row in flight is simply the
    /// first one still open, which is what the design shows and costs no stored state.
    var checklistItems: [PlanItem] {
        var seenOutstanding = false
        return visible.map { goal in
            let state: PlanItemState
            if goal.done {
                state = .completed
            } else if seenOutstanding {
                state = .pending
            } else {
                seenOutstanding = true
                state = .inProgress
            }
            return PlanItem(id: goal.id, title: goal.text, state: state)
        }
    }
}
