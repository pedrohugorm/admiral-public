import SwiftUI

/// The visual unit of every settings pane: a titled card with a caption (markdown, so
/// `backticks` render) and arbitrary content, drawn as the Schedules sheet's cards are. One
/// definition so the panes can't drift.
struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
            Text(.init(subtitle)).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .sheetCard()
    }
}

/// A labeled single-line editor that commits on Return. `identifier` is the accessibility
/// id (UI tests address fields by it, so give every field a stable one).
struct SettingsField: View {
    let label: String
    @Binding var text: String
    let identifier: String
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                .frame(width: 96, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(onCommit)
                .accessibilityIdentifier(identifier)
        }
    }
}
