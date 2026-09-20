# Session dump: fuzz chaos knob tier-1 (issue 41)

- **Session id:** 01a0bf9d-2cde-738c-80e5-1aeab6c839ff
- **Started:** 2026-09-20T16:19:04.033Z
- **Source:** `/home/nfd/.pi/agent/sessions/--mnt-e-lindana--/2026-09-20T16-19-04-033Z_01a0bf9d-2cde-738c-80e5-1aeab6c839ff.jsonl`
- **Machine-readable copy:** `2026-09-20T16-19-04-033Z_01a0bf9d-2cde-738c-80e5-1aeab6c839ff.jsonl` (in ../machine-readable/)

---

## 🧑 User

Take a look at PR #43's next steps: let's go tackle T1 fuzzing.

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `read`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Now let me survey the engine internals I'll need to touch: the RTS, the machine loop, and the effect runner.

> 🔧 `read`
> 🔧 `read`
> 🔧 `read`
> 🔧 `read`
> 🔧 `read`
> 🔧 `read`
> 🔧 `bash`

## 🤖 Assistant

Now let me look at the fuzz suite conventions, the cabal file, and the CLI:

> 🔧 `read`
> 🔧 `read`
> 🔧 `read`
> 🔧 `bash`

## 🤖 Assistant

Let me look at how the main suite writes machine tests (idioms for capture, watchdog, etc.):

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Now let me check `Def.hs` and how tests construct `MachineDef`s directly:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Now I have the full picture. Let me start the branch and implement.

> 🔧 `edit`

## 🤖 Assistant

Now the core `Machine.hs` changes — the `Chaos` type, `Hooks`/`RTS` fields, micro-yields, shuffled runner, and `runLoadedN`:

> 🔧 `edit`

## 🤖 Assistant

Now the machine-thread micro-yields, the shuffled runner, and `runLoadedN`:

> 🔧 `edit`

## 🤖 Assistant

Now the CLI `--chaos` flag and the test-file `Hooks` record constructions:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Builds clean. Quick CLI verification of `--chaos`:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Let me check the `machine` helper idiom and time the slowest examples:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `write`

## 🤖 Assistant

Now write the fuzz Chaos module:

> 🔧 `write`

## 🤖 Assistant

Let me rewrite that file properly — it had leftover scaffolding:

> 🔧 `edit`
> 🔧 `edit`

## 🤖 Assistant

Now wire the chaos specs into `FuzzMain.hs`:

> 🔧 `edit`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Found it — `captureHooks` in MachineSpec wasn't matched by my python replace (different spacing), so its `Hooks` record is missing the new fields (the `-Wmissing-fields` warning at line 87) and every test using it dies with a missing-field error. Also `hookStdin` can't be an `error` since `newRTSWith` calls `hSetBinaryMode` on it:

> 🔧 `bash`
> 🔧 `edit`
> 🔧 `edit`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Linker hiccup (9p filesystem transient). Retrying:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

The zombie test process was holding the file. Rebuilding:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Found a real bug in my runner rewrite: with shuffle off, the drained `rest` was dropped, never requeued — bundles vanish (that's the hang and the failures). Fixing:

> 🔧 `edit`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Conservation holds; the sweep found a deviation. Reproducing:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

The sweep found a real finding: `files.lind` leans on emergent FIFO cross-bundle order (its `(Show,)` machine's `say %b Back` can run before the first `fread` lands → unknown-handle fatal). The example needs proper gating. Let me check the multi-clause join source syntax:

> 🔧 `write`

## 🤖 Assistant

The fix: gate every `say` on the completion tuple of the read that produced its content — exactly the §14 gate-tuple convention. Rewriting `files.lind`:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Now rerun the full fuzz suite:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Both suites pass (the lingering pgrep match was my own shell). Now verify zero warnings and run a soak:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

The soak finished (my pgrep was matching its own command line). Rerunning with output to a file:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

The process died silently mid-sweep. Reproducing with exit-code capture:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `write`

## 🤖 Assistant

Finding B is the same class again: `(Read,)` is an in-transaction `out`, not a gate — its `say %b Stdin` races the `fread`'s side-table landing. Fixing `stdio.lind` to gate on the completion tuples:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `edit`

## 🤖 Assistant

Seed 10 reproducibly loses the rerouted say. Root cause: the **commit→push gap** — the `(Fopen, Log)` machine commits `(Fin,)`, the `(Fin,)` machine's exit effect lands, shutdown cancels the machine *between its commit and its post-commit bundle push*, and the say bundle is never queued. The fix: queue the bundle *inside* the matching transaction, atomically with the commit:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Both suites green. Running a soak at a pinned seed plus fresh entropy:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Pre-existing behavior, fine. Now the docs — REFERENCE §1/§5/§14, README, and the handover:

> 🔧 `edit`
> 🔧 `edit`
> 🔧 `edit`
> 🔧 `bash`

## 🤖 Assistant

Now the handover — new §13.27 and the §11.13 update:

> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`

## 🤖 Assistant

Now commit the slice:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Now the session dump, per the working conventions:

> 🔧 `bash`
