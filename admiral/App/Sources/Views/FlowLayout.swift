import SwiftUI

/// Lays subviews left-to-right, wrapping to a new line when the current row runs out of
/// width. Used for chip rows (PR status, tags) that must wrap instead of squeezing onto a
/// single line in the narrow Footprint panel. On an unbounded width proposal it reports its
/// natural single-line size, so it's a drop-in for an `HStack` in wide contexts like the
/// status bar (where a trailing `Spacer` keeps it on one line).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty, projected > maxWidth {
                rows.append(current)
                current = Row(items: [(index, size)], width: size.width, height: size.height)
            } else {
                current.items.append((index, size))
                current.width = projected
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let laid = rows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let height = laid.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, laid.count - 1))
        let widest = laid.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for row in rows(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }
}
