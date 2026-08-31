# Session dump: lindana-skeleton-and-parser

- **Session id:** 01a053f8-0023-7ad9-8067-d58b2ab6aa48
- **Started:** 2026-08-30T18:39:17.027Z
- **Source:** `/mnt/e/lindana/agent-history/harness-sessions/machine-readable/2026-08-30T18-39-17-027Z_01a053f8-0023-7ad9-8067-d58b2ab6aa48.jsonl`
- **Machine-readable copy:** `2026-08-30T18-39-17-027Z_01a053f8-0023-7ad9-8067-d58b2ab6aa48.jsonl` (in ../machine-readable/)

---

## 🧑 User

cd lindana;

> 🔧 `bash`

## 🤖 Assistant

Now in `/mnt/e/lindana` — it contains `lindana-handover.md` (~25KB). Note that each shell command runs in a fresh shell, so I'll prefix commands with `cd /mnt/e/lindana` as needed.

Want me to read the handover doc?


## 🧑 User

Go for it.

> 🔧 `read`

## 🤖 Assistant

Read it. Here's the gist:

## Lindana — handover summary

**What it is:** A recreational "platonic Erlang" — Linda-style tuple spaces + Haskell-style pattern matching, where race conditions are a deliberate feature. Host language: Haskell (parsec/megaparsec for the grammar, STM for matching).

**Core model:**
- Programs are **machines** that block on a pattern, match against a shared **bag** of tuples, then take actions and loop (unless they `die`).
- `in` (consume) vs `rd` (broadcast read) semantics; racing matches are intentional — at most one winner, no fairness guarantee, thundering herd mitigated by **named bags**.
- Matching is structural only and is commitment — no guards/rollback. Semantics checks are the action's job (`error` verb).
- Join patterns match atomically across multiple tuples via one STM transaction.

**Key mechanisms:**
- **`!` splice** — continuation-passing by shaping tuples; pattern-side rest-capture still unsyntaxed.
- **Terse sequencing** (`if/then/[a; b]`) is sugar desugaring into chained Restricted machines via generated `ACont0, ACont1...` continuation atoms — with cross-invocation collisions explicitly embraced.
- **Named bags** — Linda within a bag, Erlang-style one-way `lob` across bags; machineless bags are free accumulation sinks (e.g. logging).
- **Effect-runner** — bundles of side effects drained FIFO by a dedicated thread, one live bundle at a time; no rollback on partial failure.
- **Self-throttling** — CSMA-style exponential backoff with jitter, fire-counts kept *in-bag* as inspectable tuples, heartbeat/reset via `rd`-only epochs. Emergent load-balancing falls out for free.
- **No primitive strings/lists** — cons-lists of Ints as sugar; real string work via opaque bytestring handles with manual `destroy` (logical-liveness hazard, not memory unsafety).

**The philosophy:** everything new is sugar over tuples; one capitalized-identifier class does triple duty (atoms/type-tags/bag names); matcher checks structure, actions check semantics; **chaos is opt-out, not opt-in**.

**Open questions (§11):** ~11 items, the most foundational being pattern-side rest-capture syntax, repeated-variable semantics (`(a, a)` — equality or rebind?), and the top-level program grammar for composing multiple bag blocks.

What would you like to do with it — start implementing, resolve open questions, or something else?


## 🧑 User

Can you start by sketching out a shell of a Haskell app to get us started? I believe I have Stack installed. I think building a parser with `megaparsec` or `attoparsec` that we can test via `ghci` could be a good start.

> 🔧 `bash`
> 🔧 `write`
> 🔧 `write`
> 🔧 `write`

## 🤖 Assistant

Good call — parsec-family + ghci is exactly the right loop for this. I checked: Stack 3.7.1 with GHC 9.0.2 is available, so I'll pin `lts-19.33` (that GHC, no download needed) and use `megaparsec`.

Design choices for the shell, straight from the handover:
- **Scannerless megaparsec** with a depth-aware whitespace consumer: inside any bracket newlines are insignificant; at depth 0 a newline terminates a machine (the "one line by convention" rule).
- AST + a **round-trip pretty-printer**, so `renderProgram . parseProgram` is testable in ghci.
- Grammar covers: machines (`pats : actions`), join patterns with `rd`, tuples with `!` splice, Terse bracketed sequences `[a; b]`, `if/then/else`, verbs (`say`, `exit`, `die`, `sleep`, `lob`, `error`, `panic`), builtin calls (`rand`, `typeOf`, `atomize`, `atos`), initial-bag blocks `{ ... }`, and named bags `Name { ... }`. Explicitly *not* yet: pattern rest-capture, list sugar, cons desugaring.

Let me scaffold:

> 🔧 `write`

## 🤖 Assistant

Now the AST + pretty-printer:

> 🔧 `edit`

## 🤖 Assistant

One fix — a 1-tuple must render with a trailing comma or it reparses as grouping:

> 🔧 `write`

## 🤖 Assistant

Now the parser — the interesting part is the depth-aware whitespace consumer that implements "one line by convention, newlines allowed inside brackets":

> 🔧 `write`
> 🔧 `write`
> 🔧 `write`
> 🔧 `write`

## 🤖 Assistant

Now the executable, tests, and example files:

> 🔧 `write`
> 🔧 `bash`
> 🔧 `edit`

## 🤖 Assistant

Missing two boot-package deps:

> 🔧 `bash`
> 🔧 `edit`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `edit`

## 🤖 Assistant

Missing the `Text.Megaparsec.Char` import:

> 🔧 `bash`
> 🔧 `edit`

## 🤖 Assistant

megaparsec 9.2 dropped `chainl1` re-export and doesn't re-export `void` — add a local `chainl1` and import `void`:

> 🔧 `bash`
> 🔧 `edit`

## 🤖 Assistant

A few type fixes — `Name` is `String` not `Text`, `maybe` misuse, and a missing `ETuple` wrapper:

> 🔧 `bash`
> 🔧 `edit`

## 🤖 Assistant

Library compiles. The test suite needs megaparsec listed too:

> 🔧 `bash`
> 🔧 `write`

## 🤖 Assistant

My test helper was awkward — simplify the spec:

> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `edit`

## 🤖 Assistant

Test module needs `OverloadedStrings`:

> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

It compiles; now debugging the parse failures. Let me see the actual error:

> 🔧 `bash`

## 🤖 Assistant

Let me bisect with small inputs:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

The `if` machine reverts entirely. Let me debug in ghci:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

All fragments revert wholesale — inconclusive. Adding temporary traces:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Traces show `machineP` and `sepKw ":"` fire, but `ifP` never does. Let me inspect the current file state:

> 🔧 `bash`

## 🤖 Assistant

Let me use megaparsec's built-in `dbg` combinator instead:

> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

Let me export internals temporarily and test pieces interactively:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

`ifP` fails exactly at the condition — `exprP` rejects a bare variable. Testing `exprP` directly:

> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

**Found it.** `rword` consumed trailing whitespace *before* checking `notFollowedBy identChar` — so `if c` parsed as keyword `if`, ate the space, then saw `c` and decided `if` must be a prefix of a longer identifier. Every keyword followed by a space + identifier char (`if c`, `exit c`, …) failed. The fix: check the boundary before consuming trailing whitespace. Let me restore the clean file with the fix:

> 🔧 `bash`
> 🔧 `edit`
> 🔧 `bash`
> 🔧 `bash`

## 🤖 Assistant

All green. Verifying the CLI on both examples and a quick ghci round:

> 🔧 `bash`

## 🤖 Assistant

Done — the shell builds, tests pass, and both handover examples parse and round-trip. Summary:

## What's in place

```
/mnt/e/lindana/
├── lindana-handover.md      (your spec)
├── lindana.cabal, stack.yaml  (lts-19.33 → GHC 9.0.2, megaparsec 9.2)
├── src/Lindana/Syntax.hs    AST + round-trip pretty-printer
├── src/Lindana/Parser.hs    megaparsec parser
├── app/Main.hs              `stack exec lindana -- file.lind`
├── test/Spec.hs             hspec: §8.2 + §10 examples, render/reparse equality
└── examples/{toy,throttle}.lind
```

**Grammar covered:** machines, join patterns with `rd`/`in`, tuples with `!` splice, Terse `[a; b]` sequences, `if/then/else`, verbs (`say`, `exit`, `die`/`quit`, `sleep`, `lob`, `error`, `panic`), builtin calls (`rand`, `typeOf`, `atomize`, `atos`), initial-bag `{ ... }` blocks, named bag blocks. The §8.2 multi-line throttling machine parses, including newlines after `:`/`then`/`else`.

**Layout rule** (§1 "one line by convention"): the parser threads a bracket-depth `Int` in megaparsec user state — newlines are insignificant inside `() [] {}`, and at depth 0 a newline terminates a machine.

## The bug worth remembering

`rword` was originally `lexeme (string w) <* notFollowedBy identChar` — the lexeme's whitespace consume ran *before* the boundary check, so in `if c` the parser ate the space, saw `c`, and rejected `if` as a prefix of a longer identifier. Every keyword followed by space + identifier (`if c`, `exit c`, `then`…) silently failed and `try` reverted the whole machine. Fix: `try (string w <* notFollowedBy identChar) <* ws` — boundary check first, whitespace after. That's a gotcha to keep in mind when we add new keywords.

## Try it

```
stack build --test
stack exec lindana -- examples/throttle.lind
stack ghci    # then:
  :set -XOverloadedStrings
  import Lindana.Parser; import Lindana.Syntax
  fmap renderProgram (parseProgram "(Tick,) : (ResetEpoch, 0)")
```

Natural next steps: the STM tuple-bag + matcher (§3), machine threads with loop/die semantics, or knocking out open questions like repeated-variable binding (`(a, a)`) which affects pattern matching directly. Which way do you want to go?

