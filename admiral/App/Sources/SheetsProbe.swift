import AppKit
import SwiftUI

/// `-probeSheets <dir>`: the Schedules and Settings sheets, closed for real and then drawn.
/// Presents each sheet on the real window the way the menu does and closes it twice — a click
/// on its Close button, then Esc — asserting each time that the sheet is gone; then draws the
/// Schedules sheet and every Settings section into `<dir>` (dark and light). Writes
/// `<dir>/proof.txt` (PASS/FAIL lines) and exits 1 on any FAIL. Run it isolated
/// (`ADMIRAL_SUPPORT_DIR` + a unique `ADMIRAL_PROFILE`): it seeds schedules there. Launch it with
/// `open -n`, so it starts frontmost — started from a shell, macOS may hold its activation while
/// another app is in front.
///
/// A Close that draws but does nothing is what this guards. The click goes to the trailing end
/// of the button bar the OS adds for it, so a Close that never rendered FAILs as "no button bar",
/// and a dead one leaves the sheet up. `live-*.png` is each sheet as presented, the OS's Close
/// included.
extension AppModel {
    func runSheetsProbe(dir: String) {
        Task { @MainActor in
            var lines: [String] = []
            func check(_ name: String, _ ok: Bool, _ detail: String) {
                lines.append("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
            }
            func finish() -> Never {
                let failed = lines.contains { $0.hasPrefix("FAIL") }
                lines.insert("sheets: \(failed ? "FAIL" : "PASS")", at: 0)
                try? (lines.joined(separator: "\n") + "\n")
                    .write(toFile: dir + "/proof.txt", atomically: true, encoding: .utf8)
                exit(failed ? 1 : 0)
            }

            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            seedSchedulesForUIProbe(cwd: dir)

            var found: NSWindow?
            for _ in 0..<40 {
                found = NSApp.windows.first { $0.toolbar != nil && $0.isVisible }
                if found != nil { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let window = found else {
                check("window", false, "no window with a toolbar appeared")
                finish()
            }
            // Clicks and keys only reach an active app's key window. Activation is only a request
            // while another app is in front, so wait for it, and say so if it never came.
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            var waited = 0
            while !(NSApp.isActive && window.isKeyWindow), waited < 100 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            check("window active and key", NSApp.isActive && window.isKeyWindow, "after \(waited * 100) ms")

            /// The sheet once it is up and key, else nil.
            func presented() async -> NSWindow? {
                for _ in 0..<50 {
                    if let sheet = window.attachedSheet, sheet.isVisible, sheet.isKeyWindow { return sheet }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return nil
            }
            func gone() async -> Bool {
                for _ in 0..<30 {
                    if window.attachedSheet == nil { return true }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return false
            }
            /// Where the OS drew Close: the trailing end of the button bar it adds under the sheet's
            /// `content`-tall view, 20 pt in from the edge as macOS sheet buttons sit. SwiftUI draws
            /// that button itself — no AppKit button to look up — so the bar is what proves it was
            /// drawn: no bar, no Close.
            func systemClose(in sheet: NSWindow, content: CGFloat) -> NSPoint? {
                let bar = sheet.frame.height - content
                guard bar > 20 else { return nil }
                return NSPoint(x: sheet.frame.width - 20 - 22, y: bar / 2)
            }
            /// A real click at `p`, in the sheet's coordinates.
            func click(_ p: NSPoint, in sheet: NSWindow) {
                func event(_ type: NSEvent.EventType) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: sheet.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)
                }
                if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
                if let down = event(.leftMouseDown) { NSApp.sendEvent(down) }
            }
            func pressEscape(_ sheet: NSWindow) {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let key = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: sheet.windowNumber, context: nil,
                                                  characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                  isARepeat: false, keyCode: 53) {
                        NSApp.sendEvent(key)
                    }
                }
            }

            /// The presented sheet as the OS drew it — the system's own Close included, which the
            /// offscreen renders below can't show.
            func capture(_ sheet: NSWindow, to file: String) {
                guard let view = sheet.contentView?.superview ?? sheet.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + file))
            }

            let sheets: [(name: String, open: () -> Void, isOpen: () -> Bool, shut: () -> Void)] = [
                ("Schedules", { self.openSchedules() }, { self.showSchedules }, { self.showSchedules = false }),
                ("Settings", { self.openSettings() }, { self.showSettings }, { self.showSettings = false }),
            ]
            for sheet in sheets {
                for way in ["Close", "Esc"] {
                    sheet.open()
                    guard let shown = await presented() else {
                        check("\(sheet.name) opens", false, "no sheet attached to the window")
                        continue
                    }
                    try? await Task.sleep(for: .milliseconds(500))   // let the slide-in finish
                    var how = "Esc"
                    if way == "Close" {
                        capture(shown, to: "live-\(sheet.name.lowercased()).png")
                        // Both sheets' own content is 600 pt tall; the bar is what the OS adds.
                        if let p = systemClose(in: shown, content: 600) {
                            click(p, in: shown)
                            how = "clicked Close at (\(Int(p.x)), \(Int(p.y))) of \(Int(shown.frame.width))×\(Int(shown.frame.height))"
                        } else {
                            how = "no button bar under the content (sheet \(Int(shown.frame.height)) tall)"
                        }
                    } else {
                        pressEscape(shown)
                    }
                    let closed = await gone()
                    check("\(sheet.name): \(way) closes it", closed && !sheet.isOpen(),
                          (closed ? "sheet gone, open flag \(sheet.isOpen())" : "still up") + " — \(how)")
                    if !closed {
                        // Put it away by its flag, so the next open presents it again.
                        sheet.shut()
                        _ = await gone()
                    }
                    try? await Task.sleep(for: .milliseconds(300))   // let the dismissal settle
                }
            }

            for dark in [true, false] {
                let suffix = dark ? "" : "-light"
                let drew = await renderOffscreen(SchedulesWindow(), size: NSSize(width: 920, height: 600),
                                                 dark: dark, to: dir + "/schedules\(suffix).png")
                check("Schedules drawn\(suffix)", drew, "schedules\(suffix).png")
                for section in SettingsWindow.sections(config.features) {
                    let file = "settings-" + section.face.icon + suffix + ".png"
                    let drew = await renderOffscreen(SettingsWindow(section: section),
                                                     size: NSSize(width: 860, height: 600), dark: dark,
                                                     to: dir + "/" + file)
                    check("Settings → \(section.rawValue) drawn\(suffix)", drew, file)
                }
            }
            finish()
        }
    }
}
