# Session dump: fuzz sweep wedge investigation

- **Session id:** 01a0c6c5-5e2a-70f1-955c-e8d9a8af8bf7
- **Started:** 2026-09-22T01:40:18.603Z
- **Source:** `/home/nfd/.pi/agent/sessions/--mnt-e-lindana--/2026-09-22T01-40-18-603Z_01a0c6c5-5e2a-70f1-955c-e8d9a8af8bf7.jsonl`
- **Machine-readable copy:** `2026-09-22T01-40-18-603Z_01a0c6c5-5e2a-70f1-955c-e8d9a8af8bf7.jsonl` (in ../machine-readable/)

---

## 🧑 User

Let's try the (recently-added) chaos knob on the fuzzer versus the Brainfuck interpreter in `examples/`.

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `read`
> 🔧 `bash`
> 🔧 `read`
> 🔧 `read`
> 🔧 `bash`

## 🤖 Assistant

The chaos sweep (`propSweep` in `Lindana.Fuzz.Chaos`) already picks from the whole `examples/` corpus, so `brainfuck.lind` is in scope — but the default run touches it rarely. Let me build, then hammer it directly: a soak of the sweep at high iters, plus raw `--chaos` CLI runs of the BF example.

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Baseline is clean (`Hello World!`, exit 0). Now the hammering — fuzzer soak and a CLI chaos seed sweep in parallel:

> 🔧 `bash`

## 🤖 Assistant

CLI sweep: 25/25 clean. Wrong fuzz target name — let me check the cabal file:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

The 1500-iter soak blew the 30-minute budget. Let me measure what one chaos run of the BF interpreter actually costs, then size the soak sensibly:

> 🔧 `bash`

## 🤖 Assistant

CLI runs are ~1.5s, so the timeout was probably mostly compile time (I'd only built the library, not the test suites). Let me prebuild, then run the soak in the background and poll:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

The test binary isn't on `stack exec`'s path — it lives under `stack test`. The earlier timeout was likely compile time; now that the prebuild is done, retry in the background:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Running. While it soaks, let me check what knob settings the CLI `--chaos` flag actually produces (to know what those 25 clean runs exercised):

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

So the CLI knob is `fullChaos` (micro on, shuffle 0.5, 1 runner) — my 25 clean runs exercised the harshest micro-yield setting. The fuzzer sweep additionally randomizes runners 1–3 and shuffle up to 0.9. Still soaking; keep polling:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

23 minutes with no visible progress — `stack test` buffers suite output, so I can't see per-property status. Let me kill it and run the fuzz binary directly for streaming output:

> 🔧 `bash`
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

Running directly now (the `/mnt/e` exec failure was a WSL drvfs quirk; copy to `/tmp` works). Output is block-buffered so the log fills only at flush points — but it's chewing along at ~40% CPU. Polling:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

CPU dropped sharply and there are 2 matching processes — possibly a wedged leaked RTS (the documented hazard). Inspecting:

> 🔧 `bash`

## 🤖 Assistant

The process has been fully asleep since ~1:30 in (CPU stuck at ~38s total, single thread). This looks like a genuine wedge, not slowness. Let me grab a backtrace:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

No ptrace under WSL. Bisect by iteration count instead — the wedge should reproduce deterministically at the same seed:

> 🔧 `bash`

## 🤖 Assistant

All clean through 100 iters. The wedge is past that — continuing the bisection:

> 🔧 `write`

## 🤖 Assistant

Wedge bracketed: between 200 and 400 iters, same seed. Now a standalone probe that runs the two chaos properties separately with per-iteration progress, to pinpoint property + iteration + chaos config:

> 🔧 `bash`

## 🤖 Assistant

Let me check the `PropertySpec` type and `Rand` helpers, then rewrite the probe cleanly:

> 🔧 `write`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `write`

## 🤖 Assistant

The wedge is in the **chaos sweep** (`propSweep`), somewhere in iterations 131–400. Extending the probe to print each sweep iteration's example + chaos config + seed before running:

> 🔧 `write`
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

**Wedge pinpointed:** iteration 196 — `examples/flaky.lind` with `chaosMicro=False, chaosShuffle=0.25, chaosRunners=2, seed=-7825849102273046152`. The run never returned and even the 10s in-harness watchdog didn't fire. Let me look at `runLoadedN` and reproduce in isolation:

> 🔧 `read`
> 🔧 `write`

## 🤖 Assistant

`runLoadedN`'s shutdown path (`wait runner`) is interruptible, so the 10s watchdog *should* always fire — yet it didn't. Let me reproduce the exact case in isolation:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

The exact case returns `OHang` promptly in isolation — the watchdog works there. So the hard wedge needs accumulated state: earlier timed-out runs leak threads (the documented hazard), and that eventually wedges the whole process. Let me check what the sweep saw before the wedge, then test the accumulation hypothesis:

> 🔧 `bash`

## 🤖 Assistant

One-line discrepancy to resolve — the log says `chaosMicro = True` for iter 196, my probe used `False`. Re-checking and retesting with the true config:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `write`

## 🤖 Assistant

Standalone: `OHang` every time, promptly. So it's accumulation. First, what are the baselines? If flaky's baseline is itself `OHang`, every earlier flaky iteration leaked threads silently while still printing "ok":

> 🔧 `bash`
> 🔧 `write`

## 🤖 Assistant

**Smoking gun:** three examples have baseline `OHang` (`throttle`, `greeter`, `flaky` — programs with no exit path / blocked on stdin). Every sweep iteration that picks one *leaks* its full thread set (the documented hazard), and those leaks accumulate. Let me verify causality — same OHang-producing run, repeated, with a short watchdog to make it fast:

> 🔧 `write`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

500 pure leaks, no wedge — accumulation of flaky runs alone doesn't explain it. Let me see which examples the sweep actually hit before the wedge:

> 🔧 `bash`

## 🤖 Assistant

27 of the 195 pre-wedge iterations were `OHang`-baseline examples (`flaky` 12, `greeter` 8, `throttle` 7) — each leaked a run. Let me look at what greeter/throttle leak, since pure-flaky leaks didn't reproduce it:

> 🔧 `bash`

## 🤖 Assistant

`greeter` is just another blocked-forever machine; `throttle` is an infinite self-throttling loop — neither is exotic. Since thread scheduling is *not* deterministic, let me check whether the wedge point is even stable — re-running the probe twice:

> 🔧 `bash`

## 🤖 Assistant

Both re-runs wedge at **exactly iteration 272** (`throttle.lind`, micro off, shuffle 0.5, runners 2). Deterministic! Let me test that exact case standalone:

> 🔧 `write`

## 🤖 Assistant

Standalone it's clean again — accumulation-dependent, but the wedge point drifted (196 vs 272), so it's a race near a threshold, not a fixed trigger. Time to see *which stage* wedges — a sweep-loop replica with stage-by-stage stderr tracing:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `write`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Wedge stage found: **inside `runLoadedN` itself** — "running, 2 runners" printed, then not even the outer 10s `timeout` can cancel it. A thread that never yields would starve the RTS timer and block async-exception delivery. Let me check the build flags and hunt for polling/spin loops in the engine:

> 🔧 `read`
> 🔧 `read`
> 🔧 `bash`

## 🤖 Assistant

All blocking sites look interruptible. One suspect remains: this package is built **without `-threaded`** (only `-Wall` appears) — single-capability RTS, where a wedged scheduler can block async-exception delivery entirely. Testing that hypothesis: same probe, compiled `-threaded`:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

`-threaded` wedges too (later: iter 385, throttle, 3 runners) — so it's not an RTS artifact; something in `runLoadedN` genuinely stops processing async exceptions. Let me count leak composition up to each wedge and test whether throttle's leaks alone reproduce it:

> 🔧 `bash`

## 🧑 User

Checking in. Whatcha up to, when you have a moment?


## 🤖 Assistant

Status: I've been stress-testing the new chaos knob against `examples/brainfuck.lind`, and it turned into a real bug hunt. Summary so far:

**The BF interpreter itself is fine.** 25/25 raw `--chaos random` CLI runs (`fullChaos`: micro-yields + 50% shuffle) produced `Hello World!`, exit 0. And in the fuzzer's chaos sweep, brainfuck was picked 5 times across 195 iterations — all matched baseline.

**But the soak found a hard wedge in the fuzz harness.** At `LINDANA_FUZZ_ITERS=1500` (seed 424242), the whole `lindana-fuzz` process hangs. Bisected it to the Tier-1 chaos sweep property, then built standalone probe binaries to dissect it:

- **Wedge point:** inside `runLoadedN` — the stage trace prints "running, N runners" and then nothing. Notably, *not even the outer 10s watchdog fires*, so the run can't be cancelled at all.
- **It's accumulation-dependent:** the exact wedging case (e.g. `throttle.lind`, micro off, shuffle 0.5, runners 2/3) returns `OHang` promptly when run standalone in a fresh process. It only wedges after ~200–400 prior iterations.
- **The leak source:** three examples (`flaky`, `greeter`, `throttle`) have `OHang` baselines — no exit path / infinite demo loops. Every sweep iteration that picks one abandons a full run's thread set (the hazard documented in `Chaos.hs`' header), and those leaks compound. ~39 leaked runs before wedge at iter 272, ~56 before wedge at iter 385.
- Ruled out so far: not deterministic to a single case, not the non-threaded RTS (compiled `-threaded` — wedges later but still wedges), and not pure leak count (500 leaked flaky runs, 400 leaked throttle runs in isolation — no wedge, though note the isolated probes' leaked runs differ in shape: the probes' inner timeout aborts the run mid-flight, while real `OHang` leaks run to their own halt).

**Current hypothesis:** leaked runs' threads eventually interact with a fresh run's `runLoadedN` such that the calling thread stops processing async exceptions (e.g. stuck in an STM conflict loop holding exceptions off, or something in the shutdown `wait runner` path) — that's why the watchdog can't fire. Next step is instrumenting `runLoadedN`'s blocking points individually, or reproducing with a mix of leaked-run shapes rather than one repeated example.

Everything is in `/tmp/probe/` (probe2–probe8, logs preserved) — nothing in the repo touched. The finding is reproducible: `LINDANA_FUZZ_SEED=424242 LINDANA_FUZZ_ITERS≥400` wedges the suite. Want me to keep digging, or write this up as a handover note / issue first?


## 🧑 User

Sure, you can keep going. If you reach a conclusion, well, you've read AGENTS.md already.

> 🔧 `bash`

## 🤖 Assistant

Continuing the dig. First, a quick check for hidden cross-run global state (which would change the "each run is an island" assumption), then fine-grained phase tracing inside `runLoadedN`:

> 🔧 `bash`

## 🤖 Assistant

No hidden globals — each run really is an island. Time for fine-grained phase tracing: I'll copy the repo to `/tmp` (fast, native FS) and instrument `runLoadedN` there:

> 🔧 `bash`
> 🔧 `edit`

## 🤖 Assistant

Now instrument `runLoadedN`'s phases (env-gated trace, scratch copy only):

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

No wedge in 400 iters — tracing (or the rebuild) perturbed timing enough to dodge it. Run the instrumented build *without* tracing, longer, to see if the wedge reappears and where:

> 🔧 `bash`

## 🤖 Assistant

No wedge from `/tmp` cwd — but the earlier wedges all ran with the corpus on the slow `/mnt/e` drvfs. File-I/O latency may be the timing ingredient. Same binary, `/mnt/e` cwd:

> 🔧 `bash`

## 🤖 Assistant

Not reproduced yet with the instrumented build. Sanity check: does the *uninstrumented* probe still wedge on `/mnt/e`? Running both sequentially:

> 🔧 `bash`

## 🤖 Assistant

Now even the previously-consistent wedger completes cleanly — the race is sensitive to environment (earlier runs overlapped with the wedged victim process still alive, and drvfs caches were cold then; everything's hot now). I'll make reproduction robust: randomized pre-run delays to emulate cold-cache jitter, more iterations, run in background:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

While that soaks, let me study `newRTSWith` and the effect paths for anything exception-hostile:

> 🔧 `bash`

## 🤖 Assistant

`newRTSWith` is clean (fresh TVars per run, no cross-run state). Polling the jitter soak:


## 🧑 User

Whoops. Accidentally unplugged the whole PC you were running on. Care to retry that?

> 🔧 `bash`

## 🤖 Assistant

Ouch. Let me check what survived and rebuild the investigation from a known state:

> 🔧 `bash`

## 🤖 Assistant

Repo's intact (one stray fuzz-residue file I'll clean), but `/tmp` — all probes, the instrumented copy, binaries — is gone, and the wedged processes with it. Silver lining: this is a *cold-boot* environment, which per my earlier analysis is exactly the state the wedge reproduced in. Rebuilding the key probes and re-running:

> 🔧 `write`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Binary's fine — the backgrounded launch must have died with the tool shell. Relaunching detached properly:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Running. Polling for the wedge:

> 🔧 `bash`

## 🤖 Assistant

CPU pinned at ~0% since iter 212 (`flaky.lind`, micro on, shuffle 0.5, 2 runners) — wedged again, and on a cold boot this time. Grabbing forensics before killing it:

> 🔧 `bash`

## 🤖 Assistant

False alarm — it was just a cluster of slow leaky iterations (219→253 results since; ~1.3s/iter). Not wedged. Continuing to poll:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

870 iterations, no wedge this boot — but I notice a pattern: every pre-crash wedge happened while *other* fuzz processes were alive (the first soak ran parallel to the CLI chaos loop; probe2 ran alongside the wedged victim; `-threaded` variant also had the instrumented build running?). Contention may be the missing timing ingredient. Launching a second probe instance alongside the running one — same seed, so they iterate in lockstep and contend:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

First instance finished all 1500 clean; second still going. While it runs, let me check a mundane suspect I haven't ruled out — `/tmp` filling up with leaked temp files and handles across the session:

> 🔧 `bash`

## 🤖 Assistant

Disk's fine — resource exhaustion ruled out too. Time to consolidate: I have a reproducible-at-the-time, watchdog-defeating wedge with solid stage-level evidence, and a clean environment that won't reproduce it (rare race). The responsible deliverable is documenting the hazard properly plus minimal hardening. Let me check the handover's current state and the README's fuzz section:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Now the write-up. Checking the README's fuzz section and the second probe's status:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

probe7p2 is a seventh+ soak sample and still counting. Branch is ready. Cleaning the stray residue and making the edits:

> 🔧 `edit`
> 🔧 `edit`
> 🔧 `edit`
> 🔧 `bash`

## 🤖 Assistant

Now the handover §13.28:

> 🔧 `edit`
> 🔧 `edit`

## 🤖 Assistant

Now §11 item 13 and the README:

> 🔧 `edit`
> 🔧 `bash`

## 🤖 Assistant

Now verify: build, warnings, quick fuzz run, full suite:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

The warnings look pre-existing (the duplicate `System.Exit` import I spotted). Verifying they exist on main too:

> 🔧 `bash`

## 🤖 Assistant

4 warnings pre-existing on main. Since the merge bar says zero `-Wall` warnings, they're cheap to fix in this slice — let me look:

> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Zero warnings (verified via forced rebuild). Full suite now:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Both suites green; stderr progress lines working. Checking the long-running parallel soak, then committing:

> 🔧 `bash`

## 🤖 Assistant

All 1500 there too — ~4900 post-reboot sweep iterations, zero wedges; the pre-reboot rarity stands as recorded. Committing:

> 🔧 `bash`

## 🤖 Assistant

`promote.out` is test-suite residue (a sweep iteration ran `promote.lind`, which fwrites a file into cwd) — shouldn't be committed. Checking gitignore handling:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `read`

## 🤖 Assistant

Committed. Now the session dump per AGENTS.md — loading the skill:

> 🔧 `bash`
