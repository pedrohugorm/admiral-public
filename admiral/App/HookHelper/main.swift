import Foundation
import AdmiralCore

// A hook must never wedge the agent, so nothing here is allowed to die noisily.
signal(SIGPIPE, SIG_IGN)

// admiral-hook <cli-type> <event>
// Reads the hook JSON payload on stdin, dispatches, and prints whatever stdout the handler
// returns. Always exits 0 — even on bad input or an unknown (cli, event).
//
// Admiral registers this per session, via the `--settings` file `commission` writes — the same
// way it registers the bridge relay via `--mcp-config`. Nothing is installed globally.
//
// This helper does NOT govern. Governance rules live in a separate, globally registered hook
// daemon that covers every session, not in Admiral. Admiral registers exactly two events here, for two of its own features that
// have no other delivery path (see `HookDispatcher` for the full list, including the Chat
// view's ledger and AskUserQuestion routing) — e.g. `PostToolUse` (the touched-repos log) and `Stop` (the
// structured-output tripwire).
//
// ADMIRAL_SESSION is required by both — each reads or writes under `sessions/<token>/`.
let argv = CommandLine.arguments
guard argv.count >= 3 else { exit(0) }
let cliType = argv[1]
let event = argv[2]
let token = ProcessInfo.processInfo.environment["ADMIRAL_SESSION"]

let payload = FileHandle.standardInput.readDataToEndOfFile()
if let out = await HookDispatcher.handle(
    cliType: cliType, event: event, payload: payload,
    base: AdmiralPaths.defaultSupportDir, token: token,
    notifier: { HookNotifier.send($0, token: $1) }
) {
    FileHandle.standardOutput.write(Data(out.utf8))
}
exit(0)
