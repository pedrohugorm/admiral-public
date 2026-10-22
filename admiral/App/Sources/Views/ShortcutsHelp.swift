import SwiftUI

/// The single source of truth for keyboard-shortcut key strings — used by the menu, the
/// command palette, and the button tooltips so they never drift.
enum Shortcuts {
    static let newClaudeCode = "⌘T"
    static let newBash = "⌃⌘T"
    static let forkSession = "⇧⌘F"
    static let search = "⌘F"
    static let toggleSidebar = "⌘B"
    static let cycleAppearance = "⌃⌘A"
    static let nextItem = "⌘↓"
    static let prevItem = "⌘↑"
    static let moveItemUp = "⇧⌘↑"
    static let moveItemDown = "⇧⌘↓"
    static let selectItem = "⌘1–9"
    static let deleteSelected = "⌘⌫"
    static let commandPalette = "⌘/"
    static let mergePR = "⇧⌘M"
    static let openPR = "⇧⌘P"
    static let toggleRepos = "⇧⌘R"
    static let toggleChat = "⌘J"
    static let settings = "⌘,"
    static let schedules = "⇧⌘S"
    static let promoteTab = "⌘S"
}
