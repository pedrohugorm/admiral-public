import SwiftUI
import AppKit
import AdmiralCore

/// Prompts sent to a NEW tab on a cron: every schedule on the left, each with its Enabled check;
/// the chosen one's editor and its runs on the right. A run opens its session — what it did
/// lives there, not here. Closed by the system's Close button (`ButtonRole.close`): nothing is
/// lost on the way out, since a schedule saves with Save and Enabled applies at once.
struct SchedulesWindow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var overviews: [SchedulerService.Overview] = []
    @State private var selection: UUID?
    @State private var creating = false
    /// Why the last Enabled click was refused (its folder went missing, say).
    @State private var toggleProblem: String?
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 250)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The system's button bar (Close) goes under this, so the content is that much shorter.
        .frame(width: 920, height: 600)
        .background(Theme.surface)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                SheetCloseButton(identifier: "schedules-close") { dismiss() }
            }
        }
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in reload() }
    }

    /// Schedules change from the tools and runs end on their own, so the list re-reads.
    private func reload() {
        overviews = model.scheduler.overview()
        if !creating, !overviews.contains(where: { $0.schedule.id == selection }) {
            selection = overviews.first?.schedule.id
        }
    }

    /// Pauses or resumes at once, no Save; resuming starts from now, never a catch-up.
    private func setEnabled(_ schedule: Schedule, _ on: Bool) {
        if case let .failure(refused) = model.scheduler.set(ScheduleSpec(name: schedule.name, enabled: on)) {
            toggleProblem = "\(schedule.name): \(refused.description)"
        } else {
            toggleProblem = nil
        }
        reload()
    }

    private func startCreating() {
        creating = true
        selection = nil
    }

    // MARK: - List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetListHeader("Schedules") {
                Button(action: startCreating) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.chipBackground))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.primaryText)
                .help("New schedule")
                .accessibilityIdentifier("schedules-new")
            }
            ScrollView {
                VStack(spacing: 2) {
                    if creating { newRow }
                    ForEach(overviews, id: \.schedule.id) { row($0) }
                    if overviews.isEmpty && !creating {
                        Text("No schedules yet.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.top, 4)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            status
        }
        .background(Theme.sidebarBackground)
    }

    private func row(_ overview: SchedulerService.Overview) -> some View {
        let schedule = overview.schedule
        let selected = !creating && selection == schedule.id
        return HStack(spacing: 8) {
            Toggle("Enabled", isOn: Binding(get: { schedule.enabled }, set: { setEnabled(schedule, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(schedule.enabled ? "Enabled — uncheck to pause" : "Paused — check to resume from now")
                .accessibilityIdentifier("schedule-enabled-\(schedule.name)")
            Button {
                creating = false
                selection = schedule.id
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(schedule.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(schedule.enabled ? Theme.primaryText : Theme.secondaryText)
                            .lineLimit(1)
                        subtitle(overview)
                    }
                    Spacer(minLength: 0)
                    if overview.lastRun != nil {
                        Circle()
                            .fill(ScheduleStyle.color(overview))
                            .frame(width: 7, height: 7)
                            .opacity(schedule.enabled ? 1 : 0.45)
                            .help(ScheduleStyle.lastRunHelp(overview))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("schedule-row-\(schedule.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? Theme.rowSelection : Color.clear))
    }

    /// What the cron means and how long until it fires; a paused schedule says so instead.
    private func subtitle(_ overview: SchedulerService.Overview) -> some View {
        HStack(spacing: 0) {
            if overview.schedule.enabled {
                Text(overview.summary).lineLimit(1).truncationMode(.tail)
                if let next = overview.next {
                    Text(" · in " + SchedulerService.countdown(to: next, from: Date())).fixedSize()
                }
            } else {
                Text("Paused")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondaryText)
    }

    private var newRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil").font(.system(size: 12)).frame(width: 14)
            Text("New schedule").font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.rowSelection))
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if creating {
            ScrollView {
                ScheduleEditor(schedule: nil, onSave: { saved in
                    creating = false
                    selection = saved.id
                    reload()
                }, onDelete: {})
                .padding(20)
            }
            .id("new")
        } else if let overview = overviews.first(where: { $0.schedule.id == selection }) {
            let schedule = overview.schedule
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScheduleEditor(schedule: schedule, nextRun: overview.next, onSave: { saved in
                        selection = saved.id
                        reload()
                    }, onDelete: {
                        selection = nil
                        reload()
                    }, onToggleEnabled: { setEnabled(schedule, $0) })
                    // Keyed by id, not value: a run moving `lastFire` must not reset half-typed edits.
                    .id(schedule.id)
                    ScheduleRunsView(schedule: schedule)
                }
                .padding(20)
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.secondaryText)
            Text(overviews.isEmpty ? "No schedules yet" : "Pick a schedule")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text("A schedule sends a prompt to a new tab, in a folder, on a cron.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            Button("New Schedule", action: startCreating)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Under the list: why the last Enabled click was refused, else the counts. Not a bar of its
    /// own — the sheet's only bottom bar is the system's, with Close.
    @ViewBuilder private var status: some View {
        if let toggleProblem {
            Label(toggleProblem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).lineLimit(3)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        } else if !overviews.isEmpty {
            let on = overviews.filter(\.schedule.enabled).count
            Text("\(overviews.count) schedule\(overviews.count == 1 ? "" : "s") · \(on) enabled")
                .foregroundStyle(Theme.secondaryText)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
    }
}

/// One schedule's fields. Saving goes through `SchedulerService.set`, which lists every problem.
/// Enabled is not one of them: on a saved schedule it applies at once, from the header switch.
struct ScheduleEditor: View {
    @EnvironmentObject private var model: AppModel
    let schedule: Schedule?
    var nextRun: Date? = nil
    let onSave: (Schedule) -> Void
    let onDelete: () -> Void
    /// Pauses or resumes the saved schedule; nil while a new one is being written.
    var onToggleEnabled: ((Bool) -> Void)? = nil

    @State private var name = ""
    @State private var cron = "0 9 * * 1-5"
    @State private var cwd = ""
    @State private var prompt = ""
    @State private var scratch = true
    @State private var useCustomModel = false
    @State private var providerID: String?
    @State private var claudeModel: String = ScheduleModel.default.rawValue
    @State private var effort = ""
    @State private var outputSchema = ""
    /// A new schedule's Enabled; a saved one's lives in the schedule itself.
    @State private var enabled = true
    @State private var problems: [String] = []
    @State private var message: String?
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            form
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sheetCard()
            if !problems.isEmpty { problemsBox }
            actions
        }
        .onAppear(perform: load)
        .confirmationDialog("Delete \(schedule?.name ?? "")?", isPresented: $confirmingDelete) {
            Button("Delete Schedule and History", role: .destructive) {
                if let schedule, model.scheduler.delete(name: schedule.name) { onDelete() }
            }
        } message: {
            Text("Tabs its runs opened stay open.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(schedule?.name ?? "New schedule")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(headerSubtitle).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Toggle("Enabled", isOn: enabledBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
                .help("Off pauses the schedule; on resumes it from now — missed fires are not caught up")
                .accessibilityIdentifier("schedule-enabled")
        }
    }

    private var enabledBinding: Binding<Bool> {
        guard let schedule, let onToggleEnabled else { return $enabled }
        return Binding(get: { schedule.enabled }, set: onToggleEnabled)
    }

    private var headerSubtitle: String {
        let tab = StationName.sanitize(name.isEmpty ? (schedule?.name ?? "") : name)
        let opens = tab.isEmpty ? "Each run opens a new tab named after the schedule"
                                : "Each run opens a new tab @\(tab)"
        guard let schedule else { return opens }
        if !schedule.enabled { return opens + " · paused" }
        return nextRun.map { opens + " · next run \(Self.format($0))" } ?? opens
    }

    // MARK: - Form

    private var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                label("Name")
                TextField("nightly-report", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("schedule-name")
            }
            GridRow {
                label("Folder")
                HStack(spacing: 8) {
                    TextField("~/code/project", text: $cwd)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("schedule-folder")
                    Button("Choose…", action: chooseFolder)
                }
            }
            GridRow {
                label("Cron")
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        TextField("0 9 * * 1-5", text: $cron)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 170)
                            .accessibilityIdentifier("schedule-cron")
                        presetsMenu
                    }
                    cronPreview
                }
            }
            GridRow(alignment: .top) {
                label("Prompt").padding(.top, 7)
                FieldEditor(text: $prompt,
                            placeholder: "What the new tab should do, e.g. “Triage last night's failures and tell me what needs me.”",
                            height: 110, identifier: "schedule-prompt")
            }
            GridRow {
                label("Runs")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Open each run as a scratch tab", isOn: $scratch)
                        .toggleStyle(.checkbox).font(.system(size: 12))
                    if !model.ccSwitchProviders.isEmpty || schedule?.provider != nil { customModelRow }
                }
            }
            GridRow {
                label("Model")
                HStack(spacing: 8) {
                    Picker("", selection: $claudeModel) {
                        ForEach(ScheduleModel.allCases, id: \.rawValue) {
                            Text($0.rawValue.capitalized).tag($0.rawValue)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityIdentifier("schedule-model")
                    Picker("", selection: $effort) {
                        Text("Effort: claude's own").tag("")
                        ForEach(ScheduleEffort.allCases, id: \.rawValue) {
                            Text("Effort: \($0.rawValue)").tag($0.rawValue)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityIdentifier("schedule-effort")
                }
                .help("The claude model every run launches with, by its CLI alias (opus by "
                      + "default), and its effort level (claude's own when nothing is picked)")
            }
            GridRow(alignment: .top) {
                label("Schema").padding(.top, 7)
                VStack(alignment: .leading, spacing: 5) {
                    FieldEditor(text: $outputSchema,
                                placeholder: "Optional. Leave empty for none, or paste a strict JSON Schema every run must answer with.",
                                monospaced: true, height: 74, identifier: "schedule-schema")
                    schemaStatus
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            .gridColumnAlignment(.trailing)
    }

    /// The schema is whatever the field holds: empty is none, anything else must parse.
    @ViewBuilder private var schemaStatus: some View {
        let text = outputSchema.trimmingCharacters(in: .whitespacesAndNewlines)
        Group {
            if text.isEmpty {
                Label("No schema — runs answer freely", systemImage: "circle.dashed")
                    .foregroundStyle(Theme.secondaryText)
            } else if let problem = SchedulerService.outputSchemaProblem(text) {
                Label(problem, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            } else {
                Label("Every run must answer with this schema", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.checkGreen)
            }
        }
        .font(.system(size: 11))
        .lineLimit(2)
    }

    private var presetsMenu: some View {
        Menu("Presets") {
            ForEach(Self.cronPresets, id: \.cron) { preset in
                Button("\(preset.label)   \(preset.cron)") { cron = preset.cron }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 12))
    }

    @ViewBuilder private var cronPreview: some View {
        if let expression = try? CronExpression(cron) {
            let next = Self.nextFires(expression, count: 2).map(Self.format)
            Text(expression.summary + (next.isEmpty ? " — never fires" : " · next \(next.joined(separator: ", then "))"))
                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                .lineLimit(1).truncationMode(.tail)
        } else if !cron.trimmingCharacters(in: .whitespaces).isEmpty {
            Label(Self.cronError(cron), systemImage: "xmark.octagon.fill")
                .font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
        }
    }

    /// A custom model (a CC Switch config) for every run's tab, as the New-session form offers.
    private var customModelRow: some View {
        HStack(spacing: 8) {
            Toggle("Use custom model", isOn: $useCustomModel)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .accessibilityIdentifier("schedule-custom-model")
            Picker("", selection: $providerID) {
                ForEach(model.ccSwitchProviders) { Text($0.name).tag(Optional($0.id)) }
                if let stored = schedule?.provider, !model.ccSwitchProviders.contains(where: { $0.id == stored }) {
                    Text(stored).tag(Optional(stored))
                }
            }
            .labelsHidden()
            .frame(width: 240)
            .disabled(!useCustomModel)
        }
    }

    // MARK: - Problems and actions

    private var problemsBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill") }
        }
        .font(.system(size: 11))
        .foregroundStyle(.red)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(schedule == nil ? "Create Schedule" : "Save Changes", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("schedule-save")
            if schedule != nil {
                Button("Run Now", action: runNow).accessibilityIdentifier("schedule-run-now")
            }
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(2)
            }
            Spacer()
            if schedule != nil {
                Button("Delete…", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Load / save

    private func load() {
        guard let schedule else {
            scratch = true
            return
        }
        name = schedule.name
        cron = schedule.cron
        cwd = (schedule.cwd as NSString).abbreviatingWithTildeInPath
        prompt = schedule.prompt
        scratch = schedule.scratch
        claudeModel = schedule.model ?? ScheduleModel.default.rawValue
        effort = schedule.effort ?? ""
        outputSchema = schedule.outputSchema ?? ""
        if let key = schedule.provider {
            useCustomModel = true
            // Stored by id from here, possibly by name from the tools: show the matching config.
            providerID = model.ccSwitchProviders.first {
                $0.id == key || $0.name.caseInsensitiveCompare(key) == .orderedSame
            }?.id ?? key
        }
    }

    private func save() {
        let renamed = schedule.map { StationName.sanitize(name) != $0.name } ?? false
        let spec = ScheduleSpec(
            name: schedule?.name ?? name, newName: renamed ? name : nil, cron: cron, cwd: cwd, prompt: prompt,
            scratch: scratch, outputSchema: outputSchema, provider: useCustomModel ? (providerID ?? "") : "",
            model: claudeModel, effort: effort,
            enabled: schedule == nil ? enabled : nil)
        switch model.scheduler.set(spec) {
        case let .failure(refused):
            problems = refused.problems
            message = nil
        case let .success(saved):
            problems = []
            message = "Saved."
            onSave(saved)
        }
    }

    private func runNow() {
        guard let schedule else { return }
        switch model.scheduler.runNow(name: schedule.name) {
        case let .failure(refused):
            message = refused.description
        case let .success(run):
            message = run.status == .running ? "Started — tab @\(run.callsign ?? schedule.name)." : (run.note ?? run.status.rawValue)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { cwd = (url.path as NSString).abbreviatingWithTildeInPath }
    }

    // MARK: - Cron helpers

    struct CronPreset: Hashable {
        let label: String
        let cron: String
    }

    static let cronPresets = [
        CronPreset(label: "Every hour", cron: "0 * * * *"),
        CronPreset(label: "Every 30 minutes, weekdays 9–18", cron: "*/30 9-18 * * 1-5"),
        CronPreset(label: "Every day at 9:00", cron: "0 9 * * *"),
        CronPreset(label: "Weekdays at 9:00", cron: "0 9 * * 1-5"),
        CronPreset(label: "Every night at 2:00", cron: "0 2 * * *"),
        CronPreset(label: "Mondays at 9:00", cron: "0 9 * * 1"),
    ]

    static func nextFires(_ expression: CronExpression, count: Int) -> [Date] {
        var fires: [Date] = []
        var after = Date()
        while fires.count < count, let next = expression.next(after: after) {
            fires.append(next)
            after = next
        }
        return fires
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d, HH:mm"
        return formatter.string(from: date)
    }

    static func cronError(_ cron: String) -> String {
        do { _ = try CronExpression(cron); return "" } catch { return String(describing: error) }
    }
}

/// A schedule's runs, newest first. A run that got a session opens it — its tab, or the
/// conversation resumed in a new one.
struct ScheduleRunsView: View {
    @EnvironmentObject private var model: AppModel
    let schedule: Schedule

    var body: some View {
        let runs = Array(model.scheduler.store.runs(for: schedule.id).prefix(50))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Runs").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Text(runs.isEmpty ? "none yet" : "newest first")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            if !runs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        if index > 0 { Divider().opacity(0.5) }
                        row(run)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheetCard()
    }

    private func row(_ run: ScheduleRun) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(ScheduleStyle.color(run.status)).frame(width: 7, height: 7)
                Text(ScheduleStyle.label(run.status))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.primaryText)
            }
            .frame(width: 92, alignment: .leading)
            Text(ScheduleEditor.format(run.startedAt))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.primaryText)
                .frame(width: 124, alignment: .leading)
            Text(ScheduleStyle.label(run.trigger))
                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                .frame(width: 52, alignment: .leading)
            Text(run.note ?? "")
                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                .lineLimit(1).truncationMode(.tail)
                .help(run.note ?? "")
            Spacer(minLength: 0)
            if run.sessionID != nil {
                Button("Open") { model.openRun(run, of: schedule) }
                    .controlSize(.small)
                    .help("Show what this run did: its session, in its tab or resumed in a new one")
                    .accessibilityIdentifier("schedule-run-open-\(run.id)")
            }
        }
        .padding(.vertical, 7)
    }
}

enum ScheduleStyle {
    static func color(_ status: ScheduleRun.Status?) -> Color {
        switch status {
        case .succeeded: return Theme.checkGreen
        case .failed, .timedOut: return .red
        case .running: return Theme.accent
        case .skipped, .missed: return .orange
        case nil: return Theme.secondaryText.opacity(0.4)
        }
    }

    /// A list row's dot: red while the latest fire went wrong, as the sidebar's dot, else how
    /// the last run ended.
    static func color(_ overview: SchedulerService.Overview) -> Color {
        overview.needsAttention ? color(.failed) : color(overview.lastRun?.status)
    }

    static func lastRunHelp(_ overview: SchedulerService.Overview) -> String {
        guard let run = overview.lastRun else { return "No runs yet" }
        let note = run.note.map { " — \($0)" } ?? ""
        let attention = overview.needsAttention && run.status != .failed && run.status != .timedOut
            ? " (earlier fires were missed)" : ""
        return "Last run: \(label(run.status))\(note)\(attention)"
    }

    static func label(_ status: ScheduleRun.Status) -> String {
        switch status {
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .timedOut: return "Timed out"
        case .skipped: return "Skipped"
        case .missed: return "Missed"
        }
    }

    static func label(_ trigger: ScheduleRun.Trigger) -> String {
        switch trigger {
        case .cron: return "on time"
        case .now: return "run now"
        case .late: return "late"
        }
    }
}
