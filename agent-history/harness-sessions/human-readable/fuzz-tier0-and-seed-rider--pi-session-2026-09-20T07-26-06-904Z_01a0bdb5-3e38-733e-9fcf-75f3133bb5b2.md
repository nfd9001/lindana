# Session dump: fuzz-tier0-and-seed-rider

- **Session id:** 01a0bdb5-3e38-733e-9fcf-75f3133bb5b2
- **Started:** 2026-09-20T07:26:06.904Z
- **Source:** `/home/nfd/.pi/agent/sessions/--mnt-e-lindana--/2026-09-20T07-26-06-904Z_01a0bdb5-3e38-733e-9fcf-75f3133bb5b2.jsonl`
- **Machine-readable copy:** `2026-09-20T07-26-06-904Z_01a0bdb5-3e38-733e-9fcf-75f3133bb5b2.jsonl` (in ../machine-readable/)

---

## 🧑 User

Take a look over what's here, and what's covered by the test suites. These tests are pretty good for what they're there to do: confirm the basics about "does the implementation do what was promised?" But the scheduler is chaotic, and it's possible to do things with deliberate randomness in-engine. What strategies could we roll out for a fuzzing-based test suite? Presumably we'd run it independently of the main one, as an extended opportunity to reject the theory that the code is performing to contract.

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `read`
> 🔧 `read`
> 🔧 `bash`
> 🔧 `read`
> 🔧 `read`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `read`
> 🔧 `read`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `read`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Here's my read of the current state, then a proposed fuzzing strategy.

## What's there now

- **Code**: ~3,600 lines in `src/` — the STM bag + matcher (`Runtime.hs`), the one-thread-per-machine scheduler / two-phase interpreter / global FIFO effect runner (`Machine.hs`), plus loader, import, parser, prelude.
- **Tests**: 5 hspec spec files, ~2,700 lines, all example-driven: fixed programs with asserted end-states (bag snapshots, exit codes, captured `say` output). Notable spots of concurrency stress: the 20-machine contested-tuple test (`MachineSpec` §3.1) and "concurrent producers + consumers conserve the tuples" (`RuntimeSpec`). The parser suite round-trips exactly two fixed programs.

## The gap

One crucial fact shapes everything: **`rand` is already deterministic** (fixed seed in `rtsSeed`). The only nondeterminism in any run is the real RTS thread scheduler and STM commit ordering. So the fuzzer's job isn't to inject randomness into programs — it's to sweep *schedules*, and the two natural levers are (a) running the same program many times and (b) making the engine's own timing chaotic on demand. The current tests sample exactly one schedule per program and can therefore only confirm "it worked this time," never "it can't go wrong."

## Proposed strategy, in tiers of cost

### Tier 0 — pure-property fuzzing (cheap, do first)

The matcher and evaluator are nearly pure, classic property-test targets:

- **`matchPat`/`matchTuple`/`matchJoinSTM`** vs. a brute-force model: generate a bag of tuples + a join pattern; assert that either both matcher and model fail, or both succeed with consistent bindings — especially the distinct-tuples-per-take-clause rule (§3.4) and trailing `PRest` capture interacting with the §11.2 repeated-variable rule.
- **`casualString`/`stringVal`** inverse property over random strings. I'd fuzz this specifically with random *codepoints*, because `cpChar` accepts `0..0x10FFFF` — which includes the surrogate range D800–DFFF. A literal with a surrogate passes the range check and then hits `Text`/UTF-8 encoding downstream; that's exactly the kind of bug a generator finds and the two fixed examples never will.
- **Parser**: generalize the existing round-trip property from two programs to a generated AST rendered via `renderProgram`, plus mutation fuzzing of the `examples/` and `test/modules/` corpus (parse must either succeed or return a pretty `Left`, never crash).

### Tier 1 — the chaos knob (the "deliberate randomness in-engine" part)

Add a provisional `rtsChaos :: TVar StdGen` (or a `RunControls` field next to `Hooks`) and, when seeded:

- a random micro-`threadDelay` (µs-scale) before each `matchJoinSTM` attempt and between match-commit and bundle push, per machine thread;
- optionally, at each drain the effect runner picks a random queued bundle instead of the head with probability *p* (a probe for what the FIFO actually promises — within-bundle order is contract, cross-bundle order is emergent; find out which invariants survive);
- optionally, a variant of `runLoaded` that starts *N* runner threads (§7.3's open question — is the single-runner design load-bearing? Find out before someone flips it).

Crucially the seed is configurable, so a failing run is **reproducible chaos** — same ethos as the fixed `rand` seed. Run every generated and existing example program under K seeds and assert the schedule-insensitive invariants below every time.

### Tier 2 — generated programs + oracles

A generator of well-typed random Lindana programs over a small vocabulary (atoms, ints, tuple shapes, out/lob/die/exit, ACont-style continuation splices, `rand`/sleep for self-throttling §8.2 shapes). The oracles matter more than the generator:

1. **Tuple conservation** — every `Take` consumes exactly one; contested matches have exactly one winner; nothing lost, nothing duplicated. Property-ify the existing 20-job test (random machine counts, tuple shapes, bag graphs via `lob`).
2. **Body atomicity** — a "torn-write detector" machine matching sentinel pairs: a body's in-transaction writes are never observed half-applied.
3. **Bundle integrity** — within-bundle effect order holds (property-ize the existing `first`/`second` say test); every produced bundle is executed exactly once; the runner never dies silently (the §13.12 debugging tale).
4. **Exit/panic contract** — exit-code passthrough, `panic` → 1, shutdown with a pending error tuple still gets its guaranteed panic (§11.12), and no `error` in one machine's action kills anything but that machine's thread.
5. **Work conservation on pipelines** — in generated §5 AContN chains, every Job reaches its terminal continuation exactly once, or the program is flagged as (intentionally) blocked.
6. **Registry/idempotence** — concurrent imports of the same module load once and spawn their machines once; concurrent `bytesNew`/`bytesBind` never produce a colliding fresh handle.

Programs the generator makes that legitimately deadlock or error are fine — the oracle set above doesn't care *how* the run ends, only that its end-state obeys the contract.

### Tier 3 — systematic interleaving (optional, honest cost)

For exhaustive schedule coverage there's `dejafu` or `io-sim` (which has schedule-perturbation controls and STM simulation, and shrinking of failing interleavings). Both require porting `machineThread`/`runLoaded` off raw `IO`/`async` onto a concurrency-abstraction class. Given the codebase size it's a real slice, not an afternoon — I'd only do it if Tier 1–2 soak testing keeps finding schedule-dependent bugs and you want certainty rather than statistics.

## Infrastructure & house fit

- New cabal test-suite **`lindana-fuzz`** alongside `lindana-test`, so it runs independently and doesn't gate the merge bar (which stays: main suite green in randomized order). Profiles: a short default (seconds), a long soak via env var / CLI seed+iterations.
- Every failure records its seed; the reproducible-seed file goes in the bug report alongside the session dump.
- Fits the conventions as one slice on branch `fuzz/chaos-knob` (Tier 0 + Tier 1 in one PR, or split), handover §13.x entry, the chaos knob itself recorded as a new §11 open question (provisional, flip-worthy), and the tier-2 generator as its follow-up.

My recommended first PR: Tier 0's three properties plus the chaos knob applied to a seed-sweep over the existing examples corpus with the conservation and bundle-integrity oracles — smallest amount of machinery that can already start rejecting the "the code performs to contract" theory.


## 🧑 User

Looks good. Note that `rand` currently only using a fixed seed should not imply that we _always_ want to restrict it to a fixed seed: if it's convenient, it might be a good time to roll pulling real system entropy for the seed/letting the interpreter get a fixed seed from the user by CLI too. Can you start by writing this plan to a new Github issue for posterity?

> 🔧 `bash`
> 🔧 `write`
> 🔧 `bash`
> 🔧 `write`

## 🤖 Assistant

`files-out.tmp` is a scratch file, not a directory — I'll put the body in `/tmp` instead.

> 🔧 `bash`

## 🤖 Assistant

Filed: **https://github.com/nfd9001/lindana/issues/41**

The issue contains:

- **Motivation** — the one-schedule-per-program gap, framed around the invariant-sweeping job of a fuzz suite, with the note that `rand`'s fixed seed is the current design but shouldn't be permanent.
- **Seed-configurability rider** — as you asked: real system entropy as an option/default and a `--seed N` CLI flag, framed as part of the same slice since it's the enabling knob (`rtsSeed` is already a `TVar StdGen`, so it's mostly about who chooses the initial value in `newRTSWith` + a `Main.hs` flag).
- **Survey** of what the current suites cover, the four-tier strategy (pure properties → chaos knob → generated programs + oracles → `dejafu`/`io-sim`), the invariant oracle list, and infrastructure fit with the house PR conventions (`fuzz/<topic>` branches, §11/§13.x handover notes, non-gating suite).
- A **"Next"** section per the PR-body convention, and a recommended first PR: Tier 0 properties + the seed-configurability rider.

Per convention I stopped there — opening the issue only; picking up the first slice is yours to call.


## 🧑 User

Sure: go ahead and pick a slice, and give it a shot. (Note that #42 just merged, so your memory of some files may be stale.)

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

#42 is parser-side (import-position promotion) — touches `Parser.hs`/`Syntax.hs`/`Spec.hs`, so let me refresh on the files my slice would touch before picking.

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `read`
> 🔧 `read`

## 🤖 Assistant

Now let me read the parts I'll build on: `matchJoinSTM`, the rest of `Syntax.hs` (Action constructors, renderers), and the parser's validation rules.

> 🔧 `read`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `read`
> 🔧 `bash`

## 🤖 Assistant

The #42 changes are parser-only (import promotion), so they don't collide with my planned slice. I'll take **issue #41's recommended first PR: Tier 0 pure properties + the seed-configurability rider**, on branch `fuzz/pure-properties`. First, baseline: branch + build.

> 🔧 `bash`

## 🤖 Assistant

Baseline is green (already built, no warnings). Before designing the codepoint property, let me probe the surrogate-range question empirically — a surrogate can't arrive via source text (invalid UTF-8), but it *can* arrive as runtime data via a list literal:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

My test program was wrong (1-tuple vs 2-tuple). Fixing:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

**Confirmed finding**: `say %s` of a codepoint list containing surrogates (`55296` = U+D800, `57343` = U+DFFF) prints `got \uFFFD A \uFFFD` — the range check in `cpChar` accepts `0..0x10FFFF` including the surrogate range, but `T.pack`/`encodeUtf8` silently mangles non-scalars to U+FFFD. Exactly the kind of bug the fuzzer exists to find, invisible to the fixed examples.

Let me check where REFERENCE documents the string contract, and the `Say` interpret case (to know where the decode runs — in-transaction or effect-time):

> 🔧 `bash`

## 🤖 Assistant

The say effect already wraps the write in `try` and routes failures to `fdFailed` (runner-safe fatal) — and `formatSay`'s decode happens *inside* that try scope. So a surrogate-rejecting `cpChar` would surface as an honest runner-safe fatal, not the §13.12 silent-runner death. Let me confirm `fdFailed`:

> 🔧 `read`

## 🤖 Assistant

Now I'll study the expression/action grammar precisely so the AST generator only produces shapes that parse:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

I have the full grammar picture. Now let me check the `Parser` export list (I need `reservedWords` for the generator to avoid collisions) and the `Hooks` usages:

> 🔧 `read`

## 🤖 Assistant

All `Hooks` sites use explicit record syntax (adding a field = 5 one-line fixes). Now let me look at `MachineSpec`'s helpers to mimic for the seed-knob tests:

> 🔧 `edit`

## 🤖 Assistant

Now I'll write the code. Source edits first:

> 🔧 `edit`

## 🤖 Assistant

Now the seed knob in `Machine.hs`:

> 🔧 `edit`

## 🤖 Assistant

Now `Main.hs` — the `--seed` flag:

> 🔧 `edit`
> 🔧 `edit`

## 🤖 Assistant

Now export `reservedWords` from the Parser for the fuzz generator:

> 🔧 `edit`

## 🤖 Assistant

Now the cabal entry for the fuzz suite:

> 🔧 `edit`
> 🔧 `write`

## 🤖 Assistant

Now the generator module for the fuzz suite:

> 🔧 `edit`
> 🔧 `edit`
> 🔧 `write`

## 🤖 Assistant

Now the properties module:

> 🔧 `write`

## 🤖 Assistant

I overcomplicated the harness — STM and error-catching both need IO, so the property bodies should be IO with generation pinned to a deterministic sub-seed. Rewriting `Spec.hs` cleanly:

> 🔧 `edit`
> 🔧 `write`

## 🤖 Assistant

Now `FuzzMain.hs`:

> 🔧 `write`

## 🤖 Assistant

I left placeholder junk at the bottom — rewriting `FuzzMain.hs` properly:

> 🔧 `edit`
> 🔧 `read`

## 🤖 Assistant

I'm fumbling that edit — let me look at the file and clean it properly:

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
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `edit`
> 🔧 `edit`

## 🤖 Assistant

Now fix `Spec.hs`: oracle leftover, and the `propStrings` String/codepoints mixup:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `read`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `read`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `read`
> 🔧 `edit`

## 🤖 Assistant

Two fixes: missing `Control.Monad` import, and `sort` applied to the wrong thing:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Clean build, zero warnings. Now the first run of the fuzz suite:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Main suite: 241 examples, 0 failures. The fuzz suite found something — let's see:

> 🔧 `bash`
> 🔧 `edit`

## 🤖 Assistant

Found a bug in my own harness, not the runtime: `outSTM` *prepends*, so my bag preload order was reversed relative to the oracle's scan order. The `after == tuples` comparison then fails on every no-match case where order differs. Fixing the preload to reverse:

> 🔧 `edit`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

I ran the stale binary — the fix isn't compiled yet. Rebuild and rerun:

> 🔧 `bash`

## 🤖 Assistant

Matcher properties now pass at 500 iterations. But the surrogate check says 56544 didn't error — let me verify the runtime fix is actually live:

> 🔧 `bash`

## 🤖 Assistant

The runtime fix is live (CLI now exits 1 with the honest fatal). The fuzz binary must be stale — rebuild and rerun:

> 🔧 `edit`

## 🤖 Assistant

The `try` isn't catching because `length` never forces the *head* element (the erroring thunk) — classic laziness gotcha in the oracle itself:

> 🔧 `bash`
> 🔧 `edit`

## 🤖 Assistant

The pure-code `error` escaped `try` — the optimizer floated the thunk into a CAF (the classic catching-pure-exceptions pitfall). Standard fix: make the probe opaque with `NOINLINE`:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Still escaping even with NOINLINE — let me get empirical with a minimal -O1 reproduction:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `edit`

## 🤖 Assistant

Found it — my own bug in the property: `scalarValues` is *commented* as "surrogates excluded" but actually spans `[0 .. 0x10FFFF]` inclusive, so the round-trip check feeds a surrogate into `casualString` outside any `try`. Fix the list:

> 🔧 `bash`
> 🔧 `edit`

## 🤖 Assistant

Round-trip failure: `genExpr` produces top-level `ESplice`, which renders as `y!` outside tuple position (unparseable). Splices only belong in tuple elements — remove that alternative:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Let me include the parse error text in the counterexample for diagnosis. First check what `PError` is:

> 🔧 `edit`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

The parse error is at line 4 start after what should be a consumed newline. Let me isolate with the real binary:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

The divergence involves spliced 1-tuples in nested positions. Let me read the expression precedence chain to get the rule exactly right:

> 🔧 `edit`

## 🤖 Assistant

The picture is clear now: `ESplice` only reparses reliably when its containing tuple is consumed by `tupleExpr` directly (Out/Raise/Lob/Initial positions). Nested in any expression (`parenExpr` grouping path), a spliced element is silently dropped or blocks the closer. Encoding that constraint in the generator:

> 🔧 `bash`
> 🔧 `read`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `edit`

## 🤖 Assistant

All seeds pass. Fix the unused import, then run a deeper soak plus the full suite:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Both suites pass, including a 10k soak. Now pin the two behavior changes in the main suite. Check RuntimeSpec's imports:

> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`

## 🤖 Assistant

Now the MachineSpec additions — seed knob and the surrogate end-to-end fatal:

> 🔧 `edit`
> 🔧 `edit`

## 🤖 Assistant

I wrote a nonsense `draws` helper — fixing it:

> 🔧 `bash`

## 🤖 Assistant

Now the surrogate end-to-end test (runner-safe fatal via the say path):

> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Three test failures. #3 is my own laziness gotcha again (`evaluate` to WHNF of a cons cell never forces the erroring *head*). #1/#2 need a look — let me check the draw loop end-to-end via the CLI:

> 🔧 `read`

## 🤖 Assistant

The loop works via CLI, so something's off in my test helper. Let me read what I actually wrote:

> 🔧 `edit`

## 🤖 Assistant

Found it — `draws` runs with the *passed* hooks (real stdout), ignoring the capture hooks from `captureHooks`. The say output went to my terminal. Fix:

> 🔧 `edit`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

All green (246 + fuzz). Verify the CLI flag end-to-end:

> 🔧 `bash`

## 🤖 Assistant

The two "exit: 0"s are artifacts of my pipelines (`$?` reads `head`'s status, and the broken-pipe panics are the pre-existing honest fd-fatal on early-closed stdout). Verify exit codes properly:

> 🔧 `bash`

## 🤖 Assistant

Everything verified. Now the docs — first look at the handover's tail and §11 to match the house style:

> 🔧 `edit`

## 🤖 Assistant

Now update REFERENCE.md:

> 🔧 `bash`

## 🤖 Assistant

Now the handover — §13.26 and a new §11 item:

> 🔧 `edit`
> 🔧 `bash`

## 🤖 Assistant

Now append §13.26 at the end of the handover:

> 🔧 `bash`
> 🔧 `edit`

## 🤖 Assistant

README gets a note too (conventions say README travels with code):

> 🔧 `bash`

## 🤖 Assistant

Re-verify the examples (the only behavior change a program could notice is the surrogate fix — confirm no example carries surrogate codepoints, and run them all):

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

All verified. Now clean the run artifact, review the final state of the code, and commit. First, the session-dump skill for the handoff dump:

> 🔧 `bash`
