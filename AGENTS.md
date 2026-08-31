# Lindana — working conventions for agents

Work follows the pattern of the existing merged PRs (`git log` shows it). In short:

- **One slice per PR.** Branch named `<area>/<topic>` (`parser/…`, `runtime/…`, `examples/…`).
- **Commit subject**: `Area: what was done (§N, §M)` — always cite the handover sections touched (`agent-history/lindana-handover.md` is the spec-of-record; §11 = open questions, §13 = implementation status).
- **Session dump commit**: before finishing, dump the session via the `session-dump` skill (`agent-history/harness-sessions/`) and commit it as `Session dump: <topic>`.
- **PR body**: summary of the slice + a **"Next"** section listing remaining threads it opened or left.
- **Docs travel with code**: update the handover (new §13.x subsection; mark any §11 items provisionally resolved with branch refs) and README in the same PR.
- **Provisional is fine**: decisions are "provisional / flip-worthy" and recorded, not litigated. Hazards are documented, not guarded.
- **Bar to merge**: full test suite green (randomized order), zero `-Wall` warnings; new examples verified via CLI and `--parse` round-trip.
