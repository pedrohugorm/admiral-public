import AppKit
import SwiftUI
import AdmiralCore

/// `-probeGroupsUI <dir>`: the group chat UI drawn into PNGs from an invented fixture, dark and
/// light, with no claude — tabs are registered without a process, so their status is whatever
/// the fixture says. Draws (a) the sidebar with tabs and two groups, expanded and collapsed,
/// (b) a group window mid-conversation with the working capsule, (c) the same group paused,
/// (d) the `@` picker open, (e) the members popover after a refused removal, (f) the New Group
/// sheet, (g) the group's merged Footprint beside one member tab's, and the sidebar and
/// Footprint with the flag off. Writes `<dir>/proof.txt` and exits 1 on any FAIL.
///
/// It turns the groups flag on in the config, so it refuses to run without an isolated
/// `ADMIRAL_SUPPORT_DIR` (and use a unique `ADMIRAL_PROFILE`, as for every probe).
extension AppModel {
    func runGroupsUIProbe(dir: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var lines: [String] = []
            func check(_ name: String, _ ok: Bool, _ detail: String) {
                lines.append("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
            }
            func finish() -> Never {
                let failed = lines.contains { $0.hasPrefix("FAIL") }
                lines.insert("groups-ui: \(failed ? "FAIL" : "PASS")", at: 0)
                try? (lines.joined(separator: "\n") + "\n")
                    .write(toFile: dir + "/proof.txt", atomically: true, encoding: .utf8)
                exit(failed ? 1 : 0)
            }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard ProcessInfo.processInfo.environment["ADMIRAL_SUPPORT_DIR"].map({ !$0.isEmpty }) == true else {
                check("isolated", false, "ADMIRAL_SUPPORT_DIR is not set; refusing to touch the real config")
                finish()
            }

            var features = self.config.features
            features.groups = true
            self.updateFeatures(features)
            let fixture = self.seedGroupsForUIProbe()
            let checkout = fixture.checkout, release = fixture.release
            self.selectedGroupID = checkout.id

            let footprintSize = NSSize(width: 280, height: 720)
            func draw<V: View>(_ name: String, _ view: V, _ size: NSSize, dark: Bool) async {
                let file = name + (dark ? "" : "-light") + ".png"
                let ok = await self.renderOffscreen(view, size: size, dark: dark, to: dir + "/" + file)
                check("\(name) drawn\(dark ? "" : " (light)")", ok, file)
            }

            // The refusal is the store's own, from a real attempt on a 2-member group.
            var refusal = ""
            if case .failure(let error) = self.removeGroupMember(release.members[0], from: release.id) {
                refusal = error.description
            }
            check("removing below 2 members is refused", refusal == GroupError.tooFewMembers.description, refusal)

            let collapsed = self.sidebarCollapsed
            for dark in [true, false] {
                self.sidebarCollapsed = false
                await draw("sidebar", SidebarView(), NSSize(width: 272, height: 620), dark: dark)
                self.sidebarCollapsed = true
                await draw("sidebar-collapsed", SidebarView(), NSSize(width: 64, height: 620), dark: dark)
                self.sidebarCollapsed = collapsed

                await draw("group", GroupChatView(group: checkout), NSSize(width: 900, height: 760), dark: dark)
                for _ in 0..<ChatGroup.defaultBudget { self.groupStore.spendBudget(checkout.id) }
                let paused = self.groupStore.group(checkout.id) ?? checkout
                check("checkout is paused", paused.isPaused, "spent \(paused.spent)/\(paused.budgetLimit)")
                await draw("group-paused", GroupChatView(group: paused), NSSize(width: 900, height: 760), dark: dark)
                self.groupStore.resetBudget(checkout.id)

                await draw("group-picker", GroupChatView(group: checkout, initialText: "Looks good, thanks. @"),
                           NSSize(width: 900, height: 760), dark: dark)
                await draw("members-popover",
                           GroupMembersPopover(groupID: release.id, initialError: refusal)
                               .background(Theme.bubbleBackground),
                           NSSize(width: 280, height: 230), dark: dark)
                await draw("new-group-sheet",
                           NewGroupSheet(request: NewGroupRequest(preselected: fixture.preselected)),
                           NSSize(width: 420, height: 470), dark: dark)

                // Footprint: the group's merged one, then one member tab's for comparison.
                self.selectedGroupID = checkout.id
                await draw("footprint-group", TouchedReposPanel(), footprintSize, dark: dark)
                self.selectTerminal(fixture.footprintTab)
                await draw("footprint-tab", TouchedReposPanel(), footprintSize, dark: dark)
                self.selectedGroupID = checkout.id
            }

            // Reactions: chips on the messages they are on, and no row of their own.
            let log = self.groupStore.messages(checkout.id)
            let chips = GroupReaction.chips(log)
            check("reactions: chips on #3, #4, #6", Set(chips.keys) == [3, 4, 6],
                  "\(chips.keys.sorted()) \(chips[4]?.map { "\($0.emoji)\($0.names.count)" } ?? [])")
            let timelineRows = GroupAsks.timeline(group: checkout, messages: log, ledgers: [:])
            check("reactions: no timeline row of their own", timelineRows.count == log.filter { !$0.isReaction }.count,
                  "\(timelineRows.count) rows for \(log.count) log lines")

            // The group's merged rows, from the same model the panel reads.
            let merged = GroupFootprint.merge(self.memberSessions(checkout).map {
                GroupFootprint.Member(key: self.memberKey(for: $0), repos: $0.touchedRepos, tickets: $0.tickets)
            })
            let rows = merged.repos.map { "\(($0.repo.root as NSString).lastPathComponent)×\($0.members.count)" }
            check("footprint: shared repo once, two members first", rows == ["shop×2", "payments-api×1"],
                  rows.joined(separator: ", "))
            check("footprint: the panel walks the group's members", self.footprintSessions.count == 4,
                  "\(self.footprintSessions.map(\.callsign))")
            let groupPNG = FileManager.default.contents(atPath: dir + "/footprint-group.png")
            let tabPNG = FileManager.default.contents(atPath: dir + "/footprint-tab.png")
            check("footprint: group panel differs from the tab's", groupPNG != nil && groupPNG != tabPNG,
                  "footprint-group.png vs footprint-tab.png")
            self.selectTerminal(fixture.footprintTab)
            await draw("footprint-tab-again", TouchedReposPanel(), footprintSize, dark: true)
            check("footprint: tab panel is deterministic",
                  FileManager.default.contents(atPath: dir + "/footprint-tab-again.png") == tabPNG,
                  "two renders of the same tab")
            self.selectedGroupID = checkout.id
            await self.probeGroupAsks(check: check, draw: draw)

            // Flag off: no group row, no New Group, nothing selected as a group.
            features.groups = false
            self.updateFeatures(features)
            let groupRows = self.sidebarItems.filter { if case .group = $0 { return true } else { return false } }
            check("flag off: no group in the list", groupRows.isEmpty, "\(groupRows.count) group rows")
            check("flag off: no New Group", !GroupUIGate.footer(groupsEnabled: self.groupsEnabled, apiServer: true)
                .contains(.newGroup), "footer \(GroupUIGate.footer(groupsEnabled: self.groupsEnabled, apiServer: true))")
            check("flag off: group view closed", self.selectedGroup == nil, "selectedGroup nil")
            self.sidebarCollapsed = false
            await draw("sidebar-flag-off", SidebarView(), NSSize(width: 272, height: 620), dark: true)
            self.sidebarCollapsed = collapsed
            // Flag off, even with a group id left behind, the panel is the tab's, pixel for pixel.
            self.sessions.selectedID = fixture.footprintTab
            self.selectedGroupID = checkout.id
            await draw("footprint-flag-off", TouchedReposPanel(), footprintSize, dark: true)
            check("flag off: footprint is the tab's",
                  FileManager.default.contents(atPath: dir + "/footprint-flag-off.png")
                      == FileManager.default.contents(atPath: dir + "/footprint-tab.png"),
                  "footprint-flag-off.png == footprint-tab.png")
            finish()
        }
    }

    struct GroupsProbeFixture {
        let checkout: ChatGroup
        let release: ChatGroup
        let preselected: [UUID]
        /// The tab whose single-tab Footprint is drawn beside the group's.
        let footprintTab: UUID
    }

    /// Six invented tabs, two groups placed between them, and a short invented conversation
    /// spanning yesterday and today.
    func seedGroupsForUIProbe() -> GroupsProbeFixture {
        let cwd = NSHomeDirectory() + "/workspace/shop"
        let specs: [(String, String?, String?, SessionStatus)] = [
            // Symbols come from the icon picker's own list (`AvatarEditorPopover.symbols`), so the
            // fixture never shows an icon a user could not choose.
            ("lead", "#8B7CF6", "sailboat", .idle),
            ("api-fix", "#3B82F6", "server.rack", .busy),
            ("web-ui", "#1FA971", "square.grid.2x2", .idle),
            ("qa", "#E8912D", "ladybug", .busy),
            ("infra", "#D6527A", "shippingbox", .idle),
            ("notes", nil, nil, .idle),
        ]
        // Footprint: api-fix and web-ui both wrote to `shop` (on different branches); api-fix
        // also wrote to `payments-api`. Ticket SHOP-142 came up in both, PAY-7 only in api-fix.
        func pr(_ number: Int, _ title: String, canMerge: Bool, approvals: Int, passed: Int, running: Int) -> PRStatus {
            PRStatus(number: number, title: title, url: "https://example.invalid/pr/\(number)", isMerged: false,
                     canMerge: canMerge, approvals: approvals, checksPassed: passed, checksRunning: running,
                     checksFailed: 0)
        }
        let shop = NSHomeDirectory() + "/workspace/shop", payments = NSHomeDirectory() + "/workspace/payments-api"
        let footprint: [String: ([TouchedRepo], [TicketRef])] = [
            "api-fix": ([TouchedRepo(root: shop, branches: ["fix/empty-cart-total"], filesWritten: 3, insideSessionRoot: true),
                         TouchedRepo(root: payments, branches: ["fix/null-total"], filesWritten: 2, insideSessionRoot: false,
                                     prs: [pr(77, "Serialize an empty cart's total as 0", canMerge: true, approvals: 1,
                                              passed: 6, running: 0)])],
                        [TicketRef(key: "SHOP-142", statusName: "In Progress", statusCategory: .inProgress),
                         TicketRef(key: "PAY-7", statusName: "To Do", statusCategory: .todo)]),
            "web-ui": ([TouchedRepo(root: shop, branches: ["fix/totals-row"], filesWritten: 4, insideSessionRoot: true,
                                    prs: [pr(418, "Guard the totals row against a null total", canMerge: false,
                                             approvals: 0, passed: 3, running: 2)])],
                       [TicketRef(key: "SHOP-142", statusName: "In Progress", statusCategory: .inProgress)]),
        ]
        var tabs: [String: AgentSession] = [:]
        for (name, color, symbol, status) in specs {
            var tab = AgentSession(callsign: name, cwd: cwd, claudeSessionID: UUID().uuidString.lowercased(),
                                   status: status, avatarColorHex: color, avatarSymbol: symbol)
            if let (repos, tickets) = footprint[name] { tab.touchedRepos = repos; tab.tickets = tickets }
            sessions.register(tab, handle: nil)
            tabs[name] = tab
        }
        // Goals per member: api-fix has open ones (expanded), web-ui only a met one and lead
        // none (both collapsed), qa one open.
        func goals(_ name: String, _ items: [(String, GoalStatus)]) {
            guard let sid = tabs[name]?.claudeSessionID else { return }
            goalsStore.set(SessionGoals(goals: items.enumerated().map {
                SessionGoal(id: "g\($0.offset + 1)", text: $0.element.0, status: $0.element.1)
            }, setAt: Date()), forSession: sid)
        }
        goals("api-fix", [("An empty cart's total serializes as 0, not null", .open),
                          ("The serializer test covers the empty cart", .open),
                          ("PR #77 is up", .met)])
        goals("web-ui", [("The totals row shows $0.00 for an empty cart", .met)])
        goals("qa", [("The empty-cart case passes against PR #77", .open)])
        func key(_ name: String) -> UUID { memberKey(for: tabs[name]!) }

        guard case .success(let checkout) = createGroup(name: "Checkout fix",
                                                        members: ["lead", "api-fix", "web-ui", "qa"].map(key)),
              case .success(let release) = createGroup(name: "Release prep", members: ["qa", "infra"].map(key))
        else { fatalError("fixture groups") }
        // A mixed list: lead, Checkout fix, api-fix, web-ui, Release prep, qa, infra, notes.
        moveItem(checkout.id, before: tabs["api-fix"]!.id)
        moveItem(release.id, before: tabs["qa"]!.id)

        let today = Calendar.current.startOfDay(for: Date())
        func at(_ dayOffset: Int, _ h: Int, _ m: Int) -> Date {
            today.addingTimeInterval(Double(dayOffset * 86_400 + h * 3600 + m * 60))
        }
        func say(_ group: ChatGroup, _ who: String?, _ text: String, _ ts: Date) {
            if let who, let tab = tabs[who] {
                groupStore.append(to: group.id, author: .member(key(who)), name: tab.callsign,
                                  colorHex: tab.avatarColorHex, symbol: tab.avatarSymbol, text: text,
                                  target: .everyone, at: ts)
            } else {
                groupStore.append(to: group.id, author: .human, name: "You", colorHex: nil, symbol: nil,
                                  text: text, target: .everyone, at: ts)
            }
        }
        say(checkout, nil, "Kicking this off: the cart page shows a blank total for an empty cart. @lead can you split the work?", at(-1, 17, 5))
        say(checkout, "lead", "On it. @api-fix owns the serializer, @web-ui the totals row, @qa verifies once both land.", at(-1, 17, 7))
        say(checkout, nil, "@web-ui the totals row shows $NaN when the cart is empty. @api-fix is the API returning null there?", at(0, 10, 41))
        say(checkout, "api-fix", "An empty cart returns `total: null`, not 0. I'm patching the serializer now.", at(0, 10, 41))
        say(checkout, "web-ui", "Added a null guard in `CartTotals` as a stopgap. I'll remove it once @api-fix lands.", at(0, 10, 42))
        say(checkout, "api-fix", "Serializer fix is up. @qa can you run the empty-cart case against it?", at(0, 10, 44))
        // Acknowledgements as reactions on the messages they answer (#3 the user's, #4 and #6 api-fix's).
        func react(_ who: String, _ emoji: GroupReaction, to seq: Int) {
            guard let target = groupStore.messages(checkout.id).first(where: { $0.seq == seq }),
                  let tab = tabs[who] else { return }
            groupStore.append(to: checkout.id, author: .member(key(who)), name: tab.callsign,
                              colorHex: tab.avatarColorHex, symbol: tab.avatarSymbol,
                              text: "reacted \(emoji.rawValue) to #\(seq) (\(target.name))", target: .everyone,
                              reaction: emoji.rawValue, reactionTo: seq, at: at(0, 10, 45))
        }
        react("api-fix", .eyes, to: 3)
        react("web-ui", .up, to: 4)
        react("lead", .up, to: 4)
        react("qa", .eyes, to: 6)
        react("web-ui", .done, to: 6)
        markGroupSeen(checkout.id)

        say(release, nil, "@all what's left before we cut the release branch?", at(0, 9, 30))
        say(release, "infra", "Staging is green. Waiting on the changelog from @qa.", at(0, 9, 34))
        // Release prep: unread (never opened) and paused.
        for _ in 0..<ChatGroup.defaultBudget { groupStore.spendBudget(release.id) }

        return GroupsProbeFixture(checkout: groupStore.group(checkout.id) ?? checkout,
                                  release: groupStore.group(release.id) ?? release,
                                  preselected: [key("web-ui"), key("infra")],
                                  footprintTab: tabs["api-fix"]!.id)
    }
}
