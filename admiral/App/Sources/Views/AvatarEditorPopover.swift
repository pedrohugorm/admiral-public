import SwiftUI
import AdmiralCore

/// Reminders/Calendar-style editor for a session's name, avatar color, and icon —
/// shown in a popover anchored to the avatar. Live preview on top, name field, a row
/// of color swatches + the system ColorPicker, and a grid of SF Symbols.
struct AvatarEditorPopover: View {
    let initialName: String
    let initialColorHex: String?
    let initialSymbol: String
    let onCommitName: (String) -> Void
    let onCommitAppearance: (_ colorHex: String, _ symbol: String) -> Void
    /// Optional: when set, a TEAM field is shown (sessions only — chats have no team).
    var initialTeam: String? = nil
    var onCommitTeam: ((String) -> Void)? = nil

    @State private var name = ""
    @State private var color = Theme.accent
    @State private var symbol = "sparkles"
    @State private var team = ""

    private static let swatches: [String] = [
        "#6C5CE7", // purple (accent)
        "#2F6BFF", // blue
        "#12B5C9", // teal
        "#2BA84A", // green
        "#F4C20D", // yellow
        "#E8912D", // orange
        "#E5484D", // red
        "#EC4899", // pink (distinct magenta, not a second red)
        "#8E8E93", // gray
    ]
    static let symbols: [String] = [
        "bubble.left.and.bubble.right", "terminal", "sparkles", "hammer", "anchor",
        "cube", "antenna.radiowaves.left.and.right", "gearshape", "bolt",
        "server.rack", "shippingbox", "lifepreserver", "sailboat",
        "wrench.and.screwdriver", "cloud", "square.grid.2x2", "flask",
        "ladybug", "compass.drawing", "star", "flag", "bell", "brain", "magnifyingglass",
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Spacer(); preview; Spacer() }

            VStack(alignment: .leading, spacing: 7) {
                caption("NAME")
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .onSubmit(commitName)
            }

            if onCommitTeam != nil {
                VStack(alignment: .leading, spacing: 7) {
                    caption("TEAM")
                    TextField("none", text: $team)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .onSubmit(commitTeam)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                caption("COLOR")
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(Self.swatches, id: \.self) { swatch($0) }
                    ColorPicker("", selection: colorBinding)
                        .labelsHidden()
                        .frame(width: 26, height: 26)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                caption("ICON")
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Self.symbols, id: \.self) { symbolCell($0) }
                }
            }
        }
        .padding(20)
        .frame(width: 344)
        .onAppear(perform: load)
        .onDisappear { commitName(); commitTeam() }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.secondaryText)
    }

    private var preview: some View {
        Avatar(tint: color, symbol: symbol, size: 62)
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { color }, set: { color = $0; commitAppearance() })
    }

    private func swatch(_ hex: String) -> some View {
        let c = Color(hexString: hex) ?? Theme.accent
        return Circle()
            .fill(c)
            .frame(width: 26, height: 26)
            .overlay(Circle().strokeBorder(Theme.bubbleBorder, lineWidth: 0.5))
            // Selection ring sits just outside the swatch, in a neutral color so it
            // reads on every hue (incl. white/gray).
            .overlay(Circle().strokeBorder(Theme.primaryText.opacity(isSelected(hex) ? 0.65 : 0), lineWidth: 2).padding(-3))
            .contentShape(Circle())
            .onTapGesture { color = c; commitAppearance() }
    }

    private func symbolCell(_ sym: String) -> some View {
        Image(systemName: sym)
            .font(.system(size: 16))
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(symbol == sym ? color.opacity(0.22) : Theme.chipBackground))
            .foregroundStyle(symbol == sym ? color : Theme.primaryText)
            .contentShape(Rectangle())
            .onTapGesture { symbol = sym; commitAppearance() }
    }

    private func isSelected(_ hex: String) -> Bool { color.hexString.caseInsensitiveCompare(hex) == .orderedSame }

    private func load() {
        name = initialName
        color = initialColorHex.flatMap(Color.init(hexString:)) ?? Theme.accent
        symbol = initialSymbol
        team = initialTeam ?? ""
    }

    private func commitName() { onCommitName(name) }

    private func commitTeam() { onCommitTeam?(team) }

    private func commitAppearance() { onCommitAppearance(color.hexString, symbol) }
}
