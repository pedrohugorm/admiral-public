import SwiftUI

/// A sheet's Close, for its `.cancellationAction` toolbar slot. From macOS 26 it is the system's
/// own (`ButtonRole.close`), which the OS draws and places to its current standard; on the older
/// systems Admiral still runs on, a Close push button in the same slot. Esc presses it.
struct SheetCloseButton: View {
    let identifier: String
    let action: () -> Void

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                Button(role: .close, action: action)
            } else {
                Button("Close", action: action)
            }
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier(identifier)
    }
}

/// The list column's title row, shared by the Schedules and Settings sheets so the two can't drift.
struct SheetListHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
            Spacer()
            trailing
        }
        .frame(height: 22)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

extension SheetListHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// A multi-line field drawn like the text fields around it, with a placeholder while empty.
struct FieldEditor: View {
    @Binding var text: String
    let placeholder: String
    var monospaced = false
    let height: CGFloat
    let identifier: String

    var body: some View {
        let font = Font.system(size: monospaced ? 11 : 12, design: monospaced ? .monospaced : .default)
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(font)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .accessibilityIdentifier(identifier)
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(Theme.secondaryText.opacity(0.75))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.contentBackground))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.bubbleBorder))
    }
}

extension View {
    /// A sheet's card: the bubble fill plus a hairline, so it still reads in light mode, where
    /// that fill is nearly the sheet's own.
    func sheetCard() -> some View {
        background(Theme.bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.bubbleBorder))
    }
}
