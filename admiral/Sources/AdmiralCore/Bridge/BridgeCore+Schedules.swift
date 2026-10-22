import Foundation

/// The `schedule_*` tools: plain-text answers over `SchedulerService`.
extension BridgeCore {
    private static let noScheduler = BridgeResult.failure("schedules are not available in this Admiral")

    public func scheduleList() -> BridgeResult {
        guard let scheduler else { return Self.noScheduler }
        let overviews = scheduler.overview()
        guard !overviews.isEmpty else { return .success("(no schedules)") }
        return .success(overviews.map { o in
            let s = o.schedule
            var head = "\(s.name) — \(o.summary) (\(s.cron))"
            head += s.enabled ? o.next.map { " — next \(scheduler.format($0))" } ?? " — never runs again" : " — paused"
            var facts = ["folder \(s.cwd)", s.scratch ? "scratch tab" : "regular tab",
                         "model \(s.model ?? ScheduleModel.default.rawValue)"]
            if let effort = s.effort { facts.append("effort \(effort)") }
            if let provider = s.provider { facts.append("custom model \(provider)") }
            if s.outputSchema != nil { facts.append("output schema") }
            var lines = [head, "  " + facts.joined(separator: " · ")]
            if let last = o.lastRun {
                lines.append("  last run: \(last.status.rawValue) \(scheduler.format(last.startedAt)) (\(last.trigger.rawValue))")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n"))
    }

    public func scheduleSet(_ spec: ScheduleSpec) -> BridgeResult {
        guard let scheduler else { return Self.noScheduler }
        let existed = scheduler.schedule(named: spec.name) != nil
        switch scheduler.set(spec) {
        case let .failure(problems):
            return .failure("schedule refused: " + problems.problems.joined(separator: "; "))
        case let .success(s):
            let summary = (try? CronExpression(s.cron))?.summary ?? s.cron
            let next = scheduler.nextFires(of: s, count: 3).map(scheduler.format).joined(separator: ", ")
            let runs = s.enabled ? "; next runs: \(next.isEmpty ? "none" : next)" : "; paused"
            return .success("\(existed ? "updated" : "created") schedule \(s.name) — \(summary)\(runs). "
                + "Each run opens a new \(s.scratch ? "scratch " : "")tab @\(s.name) in \(s.cwd)"
                + (s.provider.map { " on \($0)" } ?? "")
                + " on model \(s.model ?? ScheduleModel.default.rawValue)"
                + (s.effort.map { " at \($0) effort" } ?? "") + ".")
        }
    }

    public func scheduleDelete(name: String) -> BridgeResult {
        guard let scheduler else { return Self.noScheduler }
        return scheduler.delete(name: name)
            ? .success("deleted schedule \(StationName.sanitize(name)) and its run history")
            : .failure("no schedule named \(name)")
    }

    public func scheduleRun(name: String) -> BridgeResult {
        guard let scheduler else { return Self.noScheduler }
        switch scheduler.runNow(name: name) {
        case let .failure(problems):
            return .failure(problems.description)
        case let .success(run):
            switch run.status {
            case .running:
                return .success("started run \(run.id) of \(StationName.sanitize(name)) in tab @\(run.callsign ?? name)"
                    + (run.sessionID.map { " (session \($0))" } ?? "")
                    + " — follow it with schedule_history")
            default:
                return .failure("run \(run.id) \(run.status.rawValue): \(run.note ?? "")")
            }
        }
    }

    public func scheduleHistory(name: String?, runID: String?, limit: Int) -> BridgeResult {
        guard let scheduler else { return Self.noScheduler }
        if let runID, !runID.isEmpty {
            guard let detail = scheduler.detail(runID: runID) else { return .failure("no run \(runID)") }
            var lines = [line(for: detail.run, of: detail.schedule, scheduler)]
            if let path = detail.transcriptPath { lines.append("transcript: \(path)") }
            if let result = detail.result {
                lines.append("reply:\n" + (result.reply.isEmpty ? "(none yet)" : result.reply))
                if let output = result.output { lines.append("structured output:\n\(output)") }
            } else if detail.run.sessionID != nil {
                lines.append("(the transcript is not there yet)")
            }
            return .success(lines.joined(separator: "\n"))
        }
        switch scheduler.history(name: name, limit: limit) {
        case let .failure(problems):
            return .failure(problems.description)
        case let .success(runs):
            guard !runs.isEmpty else { return .success("(no runs)") }
            return .success(runs.map { line(for: $0.run, of: $0.schedule, scheduler) }.joined(separator: "\n"))
        }
    }

    private func line(for run: ScheduleRun, of schedule: Schedule, _ scheduler: SchedulerService) -> String {
        var parts = [run.id, schedule.name, run.status.rawValue, run.trigger.rawValue,
                     scheduler.format(run.startedAt) + (run.endedAt.map { " → " + scheduler.format($0) } ?? "")]
        if let callsign = run.callsign { parts.append("@\(callsign)") }
        if let sid = run.sessionID { parts.append("session \(sid)") }
        if let note = run.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}
