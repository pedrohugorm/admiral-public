import Foundation

extension SessionManager: ScheduleBackend {
    /// A NEW tab for a run, named after its schedule. The schema is stored before the first
    /// prompt can arrive, keyed by the session id the tab launched with, so the prompt hook
    /// arms the output slot for that very turn.
    public func openRunTab(name: String, cwd: String, scratch: Bool, provider: String?, model: String?,
                           effort: String?, outputSchema: JSONValue?) -> Result<ScheduleTab, ScheduleLaunchError> {
        let resolved: CCSwitchProvider?
        switch CCSwitchCatalog.resolve(provider, from: providerCatalog) {
        case let .success(match): resolved = match
        case let .failure(error): return .failure(error)
        }
        let session = commission(callsign: name, cwd: cwd, scratch: scratch, provider: resolved,
                                  model: model, effort: effort)
        guard let sid = session.claudeSessionID else {
            delete(session.id)
            return .failure(ScheduleLaunchError(message: "the tab started no claude session"))
        }
        if let outputSchema, let problems = OutputSchemaStore.set(outputSchema, base: supportDir, session: sid) {
            delete(session.id)
            return .failure(ScheduleLaunchError(message: "output schema: " + problems.joined(separator: "; ")))
        }
        return .success(ScheduleTab(id: session.id, name: session.displayTitle, sessionID: sid,
                                    scratch: session.scratch, busy: false))
    }

    public func tabs(named name: String) -> [ScheduleTab] {
        sessions.filter { $0.displayTitle == name }.map {
            ScheduleTab(id: $0.id, name: $0.displayTitle, sessionID: $0.claudeSessionID,
                        scratch: $0.scratch, busy: $0.status == .busy)
        }
    }

    public func closeTab(_ id: UUID) { delete(id) }

    /// Where a session's transcript lives, whether its tab is still open or not.
    public func transcriptPath(sessionID: String, cwd: String) -> String {
        claudeHome.appendingPathComponent("projects")
            .appendingPathComponent(TranscriptLocator.encodeProjectDir(cwd))
            .appendingPathComponent("\(sessionID).jsonl").path
    }
}
