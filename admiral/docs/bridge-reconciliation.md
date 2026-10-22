# Admiral ↔ iTerm2-bridge TUI: data-layer reconciliation

The bridge Go TUI (`tui/internal/bridge`) and Python (`src/iterm2_bridge`) are the
proven source of truth for Claude transcript discovery. This records, per piece,
whether Admiral **reuses**, **ports (with the bridge's own tests brought over)**, or
**justifiably diverges** — and why.

## Empirical settlement (launch-vs-pid)

Measured against a fresh Admiral-spawned claude in a workspace dir (`-realProof`):

- `sessions/<claude-pid>.json` is **ABSENT** for a fresh spawn — claude does not write
  the pid→sessionId map promptly. So Admiral cannot depend on it (the bridge only can
  because it observes user-started sessions that have been alive a while).
- A hosted claude that inherits Claude Code's own env markers (`CLAUDECODE`,
  `CLAUDE_CODE_CHILD_SESSION`, …) runs as a **child session that persists no transcript
  at all**. This — not a read/pid bug — was why the view was blank/stale. Stripping the
  markers restores persistence.
- With persistence restored, `claude --session-id <uuid>` **is** honored in interactive
  mode: the transcript is written to `projects/<enc-cwd>/<uuid>.jsonl` (verified: a
  commissioned session resolved to its own id file and a sent message appeared).

## Reconciliation table

| Data-layer piece | Bridge source | Admiral | Status |
|---|---|---|---|
| `EncodeProjectDir` (`/ . _` → `-`) | `activity.go` | `TranscriptLocator.encodeProjectDir` | **Ported verbatim.** Go `TestEncodeProjectDir` cases brought over as Swift fixtures (`testEncodeProjectDir`). |
| `ResolvePath` (pid → `sessions/<pid>.json` → encoded path → glob → newest-in-cwd) | `transcript.go` / `session.go` | `TranscriptLocator.resolve(pid:fallbackCwd:claudeHome:)` | **Ported with tests** for adopted/legacy sessions. Go `TestResolvePathViaSessionFile` + `TestResolvePathFallbackNewest` brought over (`testResolveViaSessionFile`, `testResolvePathFallbackNewest`). |
| `find_claude_pid` (process-tree walk for "claude") | `iterm.py` | `ProcessTree.findClaudePid` | **Ported with a justified divergence: descendant-only.** The Python bridge walks self→ancestors→descendants; Admiral is claude's *parent*, so it walks self+descendants only. Runs on the 1s tick (legacy path). |
| Transcript parse (`decodeBlocks`, `unitsFromRows`, `LoadTail` tail-limit) | `transcript.go` | `TranscriptParser` + `TranscriptStore.loadTail` | **Reimplemented, structurally equivalent** (string-or-array content, tool_use/tool_result correlation, thinking/text/tool units, 600-line tail). Swift golden-fixture tests. |
| Inject = type, **0.15s pause**, then `\r` | `protocol.py` | `SwiftTermHost.submit` | **Ported verbatim** (the pause keeps claude's TUI from swallowing the Enter). |
| `ps` snapshot | `iterm.py` (Python `subprocess`) | `ProcessTree.snapshot` | **Ported with a fix:** Foundation `Process` deadlocks if you `waitUntilExit()` before draining a >64KB pipe. Drain-then-wait. Guarded by `ProcessTreeTests` running real `ps`. |
| **Which transcript a session shows** | newest `.jsonl` in the workspace dir | `TranscriptLocator.resolveOwn` (exact `--session-id` file, else newest created at/after spawn) | **Justified divergence.** The bridge *monitors* sessions it didn't spawn, so workspace-newest is correct for it. Admiral *owns* each session, so it pins each terminal to its **own** transcript and never leaks another session's data. |
| Deterministic transcript id | n/a (bridge reads, never spawns) | `commission` passes `--session-id <uuid>`; `AgentSession.claudeSessionID`/`spawnedAt` | **New (Admiral-only).** Admiral spawns, so it can choose the id up front and resolve deterministically. |
| Hosted-agent environment | n/a | `commission` strips `CLAUDECODE` / `CLAUDE_CODE_*` / `CLAUDE_EFFORT` / `AI_AGENT` (keeps `ANTHROPIC_*`) | **New (Admiral-only).** Required so a hosted claude is a top-level session that persists a transcript. |

## Net

The discovery primitives (`EncodeProjectDir`, `ResolvePath`, `find_claude_pid`, the
0.15s inject, the parse) are reused/ported from the bridge with its tests. The
divergences are all driven by one structural difference: **the bridge observes; Admiral
owns.** Owning the spawn lets Admiral be deterministic (`--session-id`), correctly
isolated (`resolveOwn`), and self-sufficient about persistence (env strip) — none of
which the read-only bridge needs.
