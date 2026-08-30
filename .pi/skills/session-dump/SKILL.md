---
name: session-dump
description: Dump the current pi session into the project's agent-history/harness-sessions/ directory as a pair of files — a raw JSONL (machine-readable) and a conversation markdown (human-readable), both named <session-name>-<timestamp>. Use whenever the user asks to dump, save, export, or hand off the session history to agent-history/, or at the end of a work session when asked to record a handover.
---

# Session dump

Write the current conversation to `agent-history/harness-sessions/` so the human can review or hand it off later. Do **not** read the dump files back into context — the script prints a one-line summary; that's all you need.

## Usage

```bash
node .pi/skills/session-dump/scripts/dump-session.mjs            # auto name (from /name, else "session")
node .pi/skills/session-dump/scripts/dump-session.mjs "fix tuple-space races"   # explicit name
node .pi/skills/session-dump/scripts/dump-session.mjs --quiet    # just print the two paths
```

Optional flags: `--name <name>` (session name), `--out <dir>` (default: `<cwd>/agent-history/harness-sessions`).

## What it produces (matches the project's existing dump convention)

- `agent-history/harness-sessions/machine-readable/<original-session-filename>.jsonl` — verbatim copy of the live session JSONL (full fidelity: tool calls, results, branches).
- `agent-history/harness-sessions/human-readable/<session-name>--pi-session-<original-stem>.md` — readable transcript: user + assistant text, tool calls as one-liners, tool results omitted.

If the session has no `/name`, pass one explicitly — the name is what makes the human-readable dump findable.

The script finds the current session automatically (`PI_SESSION_FILE` when run inside pi, newest-session fallback otherwise). Run it from the project root so the default output paths resolve.

## When to use it

- The user asks to "dump the session", "save this to agent-history", or similar.
- The user asks for a handover document — dump first, then (only if asked) write a curated handover doc separately; the dump is the raw record, not the handover.
- If the session has no name yet and the user wants a specific one, pass it as an argument rather than telling the user to run `/name`.
