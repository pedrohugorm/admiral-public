import AppKit
import SwiftTerm
import AdmiralCore

/// SwiftTerm's terminal view plus what it lacks and iTerm2 has: files dragged in from Finder.
/// SwiftTerm registers for no drag types, so a drop onto a session did nothing. A drop now
/// types the files' paths — escaped and joined as iTerm2 types them (`TerminalDrop`) — as a
/// paste, so claude reads (or attaches) them just as it does when they're dropped in iTerm2.
///
/// Only file drags are taken: a text drag, like a sidebar tab being reordered, would otherwise
/// type its payload into claude's prompt.
final class AdmiralTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("AdmiralTerminalView is built in code") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.typedText(for: sender) != nil else { return [] }
        // iTerm2's order: generic draws no green "+" badge; link is all some sources (Fork)
        // offer; copy is the last resort.
        let offered = sender.draggingSourceOperationMask
        return [NSDragOperation.generic, .link, .copy].first { offered.contains($0) } ?? []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = Self.typedText(for: sender) else { return false }
        paste(text)
        return true
    }

    /// What dropping `drag` types, or nil when it carries no files.
    private static func typedText(for drag: NSDraggingInfo) -> String? {
        let urls = drag.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return TerminalDrop.pasteText(paths: (urls ?? []).map(\.path))
    }

    /// Type `text` the way SwiftTerm's own ⌘V does (its bracketing is internal, so it's
    /// mirrored here): wrapped in bracketed-paste markers when the program turned that mode on —
    /// claude does — so it arrives as one paste rather than as keystrokes.
    private func paste(_ text: String) {
        let bytes = Array(text.utf8)
        send(getTerminal().bracketedPasteMode
             ? EscapeSequences.bracketedPasteStart + bytes + EscapeSequences.bracketedPasteEnd
             : bytes)
    }
}
