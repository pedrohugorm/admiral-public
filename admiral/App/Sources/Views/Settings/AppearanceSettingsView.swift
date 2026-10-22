import SwiftUI

/// Settings → Appearance. Binds the same `themeMode` the titlebar moon button and the
/// ⌘/ palette cycle, so all three stay in sync and the change applies immediately.
struct AppearanceSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard("Theme",
                             "Auto follows macOS. Applies immediately — the titlebar moon "
                                + "button and the ⌘/ palette cycle this same setting.") {
                    Picker("", selection: $model.themeMode) {
                        Text("Auto").tag(ThemeMode.auto)
                        Text("Light").tag(ThemeMode.light)
                        Text("Dark").tag(ThemeMode.dark)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(maxWidth: 320)
                    .accessibilityIdentifier("settings-theme-picker")
                }
            }
            .padding(20)
        }
    }
}
