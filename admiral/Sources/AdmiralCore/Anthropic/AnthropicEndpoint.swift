import Foundation

/// The Anthropic-compatible endpoint: routes `POST /v1/messages` to the Admiral tab
/// named by the required `ADMIRAL_TAB_NAME` header. `model` is left to mean what it
/// means everywhere else — it is echoed back, never used to pick a tab.
/// Owns the whole request lifecycle — tab resolution, delta detection, busy gate,
/// injection, transcript capture, completion — and emits raw HTTP bytes so the
/// socket layer stays a dumb pipe. One request in flight per tab.
@MainActor
public final class AnthropicEndpoint {
    public struct Config: Sendable {
        /// How long a request waits for a busy tab before 529.
        public var busyWaitTimeout: TimeInterval = 30
        /// If busy is never observed after injecting, complete once output exists
        /// and the tab reads idle after this long (fast turns can slip the 1s poll).
        public var busySeenTimeout: TimeInterval = 10
        /// Hard cap on a turn; return whatever was captured.
        public var turnTimeout: TimeInterval = 600
        public var pollInterval: TimeInterval = 1.0
        /// SSE keep-alive ping cadence while no text is flowing.
        public var pingInterval: TimeInterval = 15
        /// SO requests: if the tab reads idle while the tripwire is still armed with no
        /// Stop block recorded, the Stop hook isn't firing — fail fast instead of
        /// waiting out turnTimeout.
        public var structuredOutputGrace: TimeInterval = 15
        /// How long to wait for a freshly commissioned claude to write its session file
        /// (proof the process booted) before the first inject. A wait, not a gate — on
        /// timeout the inject attempts proceed anyway.
        public var injectReadyTimeout: TimeInterval = 30
        /// Per-attempt window for the transcript to gain the injected user message —
        /// the ground truth that the submit reached claude's TUI.
        public var injectVerifyTimeout: TimeInterval = 10
        /// Inject attempts before giving up and letting the turn timeouts govern.
        public var injectMaxAttempts: Int = 3
        public init(busyWaitTimeout: TimeInterval = 30, busySeenTimeout: TimeInterval = 10,
                    turnTimeout: TimeInterval = 600, pollInterval: TimeInterval = 1.0,
                    pingInterval: TimeInterval = 15, structuredOutputGrace: TimeInterval = 15,
                    injectReadyTimeout: TimeInterval = 30, injectVerifyTimeout: TimeInterval = 10,
                    injectMaxAttempts: Int = 3) {
            self.busyWaitTimeout = busyWaitTimeout
            self.busySeenTimeout = busySeenTimeout
            self.turnTimeout = turnTimeout
            self.pollInterval = pollInterval
            self.pingInterval = pingInterval
            self.structuredOutputGrace = structuredOutputGrace
            self.injectReadyTimeout = injectReadyTimeout
            self.injectVerifyTimeout = injectVerifyTimeout
            self.injectMaxAttempts = injectMaxAttempts
        }
    }

    /// The tab a request targets. `HTTPWire.parse` lowercases header keys, so the
    /// lookup key and the name clients type differ only in case.
    static let tabNameHeader = "admiral_tab_name"
    static let tabNameHeaderWireName = "ADMIRAL_TAB_NAME"
    static let sessionIDHeader = "admiral_session_id"
    static let sessionIDHeaderWireName = "ADMIRAL_SESSION_ID"
    static let cwdHeader = "admiral_cwd"
    static let cwdHeaderWireName = "ADMIRAL_CWD"

    private let backend: AnthropicBackend
    private let config: Config
    private let run: TabRun
    private var inFlight: Set<UUID> = []

    public init(backend: AnthropicBackend, config: Config = Config()) {
        self.backend = backend
        self.config = config
        run = TabRun(backend: backend, config: TabRun.Config(
            busySeenTimeout: config.busySeenTimeout, turnTimeout: config.turnTimeout,
            pollInterval: config.pollInterval, pingInterval: config.pingInterval,
            structuredOutputGrace: config.structuredOutputGrace, injectReadyTimeout: config.injectReadyTimeout,
            injectVerifyTimeout: config.injectVerifyTimeout, injectMaxAttempts: config.injectMaxAttempts))
    }

    /// Handle one parsed HTTP request; `emit` receives raw response bytes (a single
    /// buffered response, or — for streaming, Task 6 — head + SSE frames).
    public func handle(_ request: HTTPRequest, emit: @escaping (Data) -> Void) async {
        guard !Self.looksBrowserOriginated(request) else {
            emit(errorResponse(403, "permission_error", "cross-origin or non-loopback request refused"))
            return
        }
        guard request.method == "POST", request.path == "/v1/messages" else {
            emit(errorResponse(404, "not_found_error", "not found: \(request.method) \(request.path)"))
            return
        }
        let rawTab = request.headers[Self.tabNameHeader]?.trimmingCharacters(in: .whitespaces) ?? ""
        let rawSID = request.headers[Self.sessionIDHeader]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard rawTab.isEmpty != rawSID.isEmpty else {
            emit(errorResponse(400, "invalid_request_error",
                               "exactly one of \(Self.sessionIDHeaderWireName) or \(Self.tabNameHeaderWireName) is required"))
            return
        }
        guard let req = AnthropicMessagesRequest.decode(request.body) else {
            emit(errorResponse(400, "invalid_request_error", "could not parse request body"))
            return
        }
        if let soError = req.structuredOutputError {
            emit(errorResponse(400, "invalid_request_error", soError))
            return
        }
        // Routing: a tab name must name an existing tab (fails as it always has); a
        // session id routes to whichever tab owns it — or creates a scratch tab for it.
        // NOTE: everything from here to `inFlight.insert` is synchronous on the main
        // actor, so a concurrent same-sid request resolves the freshly created tab and
        // hits the in-flight 529 — no separate creation lock is needed.
        let tab: AnthropicTab
        if !rawTab.isEmpty {
            guard let named = backend.tab(named: rawTab) else {
                emit(errorResponse(404, "not_found_error",
                                   "tab '\(rawTab)' not found — \(Self.tabNameHeaderWireName) must name an Admiral tab"))
                return
            }
            tab = named
        } else {
            guard UUID(uuidString: rawSID) != nil else {
                emit(errorResponse(400, "invalid_request_error",
                                   "\(Self.sessionIDHeaderWireName) must be a UUID"))
                return
            }
            let sid = rawSID.lowercased()
            let cwdRaw = request.headers[Self.cwdHeader]?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !cwdRaw.isEmpty else {
                emit(errorResponse(400, "invalid_request_error",
                                   "missing required header \(Self.cwdHeaderWireName) — required with \(Self.sessionIDHeaderWireName)"))
                return
            }
            if let existing = backend.tab(sessionID: sid) {
                tab = existing  // live sid wins; the cwd header is ignored (the tab has one)
            } else {
                let cwd = (cwdRaw as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
                    emit(errorResponse(400, "invalid_request_error",
                                       "\(Self.cwdHeaderWireName) must be an existing directory: \(cwd)"))
                    return
                }
                guard let created = backend.createScratchTab(sessionID: sid, cwd: cwd) else {
                    emit(errorResponse(500, "api_error", "failed to create a session for \(sid)"))
                    return
                }
                tab = created
            }
        }
        guard tab.isManaged else {
            emit(errorResponse(400, "invalid_request_error", "tab is not a managed claude session"))
            return
        }
        guard !inFlight.contains(tab.id) else {
            emit(errorResponse(529, "overloaded_error", "a request for this tab is already in flight"))
            return
        }
        inFlight.insert(tab.id)
        defer { inFlight.remove(tab.id) }

        // Arm the structured-output tripwire before waiting on the tab or injecting — it
        // owns this request for its whole lifecycle, and the defer clears it on every exit
        // path (busy-gate 529, no-delta 400, timeout, success). Per design §4.2 arming
        // happens "before injecting the prompt".
        if let spec = req.structuredOutput {
            backend.armStructuredOutput(tabID: tab.id, spec: spec)
        }
        defer { if req.structuredOutput != nil { backend.clearStructuredOutput(tabID: tab.id, type: .api) } }

        // Busy gate: only .busy blocks — a freshly spawned claude has no status file yet.
        let gateDeadline = Date().addingTimeInterval(config.busyWaitTimeout)
        while backend.liveStatus(tabID: tab.id) == .busy {
            guard Date() < gateDeadline else {
                emit(errorResponse(529, "overloaded_error", "tab is busy"))
                return
            }
            await sleepPoll()
        }

        // We need the transcript's location to diff history and capture the reply. For a
        // managed tab this is always known (deterministic from the session id), even for a
        // brand-new tab whose file doesn't exist yet — a missing file just means empty
        // history, and injecting the first message is what creates it.
        var path = backend.transcriptPath(tabID: tab.id)
        for _ in 0..<5 where path == nil {
            await sleepPoll()
            path = backend.transcriptPath(tabID: tab.id)
        }
        guard let path else {
            emit(errorResponse(500, "api_error", "transcript path for this tab is not available"))
            return
        }
        let snapshot = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()

        let delta = TurnCapture.unseen(requestTexts: req.userTexts,
                                       transcriptTexts: TurnCapture.userTexts(in: snapshot))
        guard !delta.isEmpty else {
            emit(errorResponse(400, "invalid_request_error", "no new user message for this tab"))
            return
        }

        // Wait for claude to boot, type the prompt, and confirm the transcript gained it
        // (`TabRun.deliver`). If it never lands, the turn timeouts below still govern.
        await run.deliver(delta.joined(separator: "\n\n"), tabID: tab.id, path: path,
                          baselineUserCount: TurnCapture.userTexts(in: snapshot).count)
        let messageID = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        let structured = req.structuredOutput != nil
        if req.stream {
            emit(HTTPWire.sseHead())
            emit(HTTPWire.sseFrame(event: "message_start",
                                   data: AnthropicWire.messageStart(id: messageID, model: req.model)))
            // For SO requests the visible turn text is scaffolding, not the answer — no
            // text block is opened and nothing streams until the result exists.
            if !structured {
                emit(HTTPWire.sseFrame(event: "content_block_start",
                                       data: AnthropicWire.contentBlockStart()))
            }
            let result = await run.awaitTurn(tabID: tab.id, path: path, fromOffset: snapshot.count,
                                             slot: structured ? .api : nil) { chunk in
                if !structured {
                    emit(HTTPWire.sseFrame(event: "content_block_delta",
                                           data: AnthropicWire.contentBlockDelta(text: chunk)))
                }
            } onPing: {
                emit(HTTPWire.sseFrame(event: "ping", data: AnthropicWire.ping()))
            }
            let usage = result.usage ?? AnthropicUsage(inputTokens: 0, outputTokens: 0)
            if let spec = req.structuredOutput {
                guard let value = resolvedStructuredResult(tabID: tab.id) else {
                    emit(HTTPWire.sseFrame(event: "error", data: AnthropicWire.error(
                        type: "api_error",
                        message: "structured output failed after \(StructuredOutputState.maxAttempts) attempts")))
                    return
                }
                emitStructuredBlocks(spec: spec, result: value, messageID: messageID, emit: emit)
                emit(HTTPWire.sseFrame(event: "message_delta", data: AnthropicWire.messageDelta(
                    usage: usage, stopReason: spec.delivery == .toolUse ? "tool_use" : "end_turn")))
                emit(HTTPWire.sseFrame(event: "message_stop", data: AnthropicWire.messageStop()))
            } else {
                emit(HTTPWire.sseFrame(event: "content_block_stop", data: AnthropicWire.contentBlockStop()))
                emit(HTTPWire.sseFrame(event: "message_delta",
                                       data: AnthropicWire.messageDelta(usage: usage)))
                emit(HTTPWire.sseFrame(event: "message_stop", data: AnthropicWire.messageStop()))
            }
        } else {
            let result = await run.awaitTurn(tabID: tab.id, path: path, fromOffset: snapshot.count,
                                             slot: structured ? .api : nil)
            let usage = result.usage ?? AnthropicUsage(inputTokens: 0, outputTokens: 0)
            if let spec = req.structuredOutput {
                guard let value = resolvedStructuredResult(tabID: tab.id) else {
                    emit(errorResponse(500, "api_error",
                        "structured output failed after \(StructuredOutputState.maxAttempts) attempts"))
                    return
                }
                emit(HTTPWire.response(status: 200, body: AnthropicWire.structuredMessage(
                    id: messageID, model: req.model, spec: spec, result: value, usage: usage)))
            } else {
                emit(HTTPWire.response(status: 200, body: AnthropicWire.message(
                    id: messageID, model: req.model, text: result.text, usage: usage)))
            }
        }
    }

    /// The fulfilled structured result for this tab, or nil when the tripwire never
    /// resolved (still armed / failed / no result). Both response paths ask this one
    /// question, then turn nil into their own channel's "structured output failed" error.
    private func resolvedStructuredResult(tabID: UUID) -> JSONValue? {
        guard let state = backend.structuredOutputState(tabID: tabID, type: .api),
              state.status == .fulfilled else { return nil }
        return state.result
    }

    /// SSE frames for a fulfilled structured result — one block, emitted whole once the
    /// turn resolved (there is nothing to stream incrementally; the result exists only
    /// after set_structured_output succeeds).
    private func emitStructuredBlocks(spec: StructuredOutputSpec, result: JSONValue,
                                      messageID: String, emit: (Data) -> Void) {
        switch spec.delivery {
        case .jsonText:
            emit(HTTPWire.sseFrame(event: "content_block_start", data: AnthropicWire.contentBlockStart()))
            emit(HTTPWire.sseFrame(event: "content_block_delta",
                                   data: AnthropicWire.contentBlockDelta(text: AnthropicWire.jsonText(result))))
            emit(HTTPWire.sseFrame(event: "content_block_stop", data: AnthropicWire.contentBlockStop()))
        case .toolUse:
            emit(HTTPWire.sseFrame(event: "content_block_start",
                data: AnthropicWire.contentBlockStartToolUse(
                    id: "toolu_" + String(messageID.dropFirst(4)),
                    name: spec.toolName ?? "structured_output")))
            emit(HTTPWire.sseFrame(event: "content_block_delta",
                data: AnthropicWire.inputJSONDelta(partial: AnthropicWire.jsonText(result))))
            emit(HTTPWire.sseFrame(event: "content_block_stop", data: AnthropicWire.contentBlockStop()))
        }
    }

    private func sleepPoll() async {
        try? await Task.sleep(nanoseconds: UInt64(config.pollInterval * 1_000_000_000))
    }

    private func errorResponse(_ status: Int, _ type: String, _ message: String) -> Data {
        HTTPWire.response(status: status, body: AnthropicWire.error(type: type, message: message))
    }

    /// Reject requests that look like they came from a browser rather than an
    /// Anthropic SDK client. Browsers always send `Origin` on cross-origin
    /// fetch/XHR; SDK clients (Python/TS/curl) never do. A DNS-rebinding
    /// attacker reaches the loopback server via a hostname that resolves to
    /// 127.0.0.1, so a non-loopback `Host` header is the other tell.
    private static let allowedLoopbackHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]"]

    private static func looksBrowserOriginated(_ request: HTTPRequest) -> Bool {
        if let origin = request.headers["origin"], !origin.isEmpty { return true }
        if let host = request.headers["host"], !host.isEmpty {
            if !allowedLoopbackHosts.contains(hostWithoutPort(host)) { return true }
        }
        return false
    }

    /// Strip a trailing `:port` from a `Host` header value, preserving the
    /// bracket form of an IPv6 literal (e.g. `[::1]:4141` -> `[::1]`).
    private static func hostWithoutPort(_ host: String) -> String {
        if host.hasPrefix("["), let bracketEnd = host.firstIndex(of: "]") {
            return String(host[...bracketEnd])
        }
        if let colon = host.lastIndex(of: ":") {
            return String(host[..<colon])
        }
        return host
    }
}
