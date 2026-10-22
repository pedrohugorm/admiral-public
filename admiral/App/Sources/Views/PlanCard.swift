import SwiftUI
import AdmiralCore

/// The collapsible plan/todo card — the centerpiece of the Transcript View.
struct PlanCard: View {
    let plan: PlanModel
    let title: String?
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                    Text(headerTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Theme.planCardHeader)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(plan.items) { PlanRow(item: $0) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.planCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var headerTitle: String {
        guard let title, !title.isEmpty else { return "Plan" }
        return title.lowercased().contains("plan") ? title : "\(title) plan"
    }
}

struct PlanRow: View {
    let item: PlanItem

    var body: some View {
        HStack(spacing: 11) {
            marker
                .frame(width: 16, height: 16)
            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var marker: some View {
        switch item.state {
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.checkGreen)
        case .inProgress:
            Circle().fill(Theme.inProgressBlue).frame(width: 11, height: 11)
        case .pending:
            Circle().strokeBorder(Theme.pendingGray, lineWidth: 1.5).frame(width: 11, height: 11)
        }
    }
}
