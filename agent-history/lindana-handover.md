# Lindana

**A recreational programming language about race conditions.**

## 0. Naming & pitch

- **Lindana** riffs on *Linda*, the classic tuple-space coordination language (itself named after Linda Lovelace), crossed with **Lindana** the Phineas and Ferb character known for the one-hit-wonder "I'm Lindana and I Wanna Have Fun" — apropos for a recreational language.
- Working description: a tiny "platonic Erlang" built on Linda-style tuple spaces plus Haskell-style pattern matching, where concurrency races are a deliberate, load-bearing feature rather than a bug to be engineered away.

This document is a handover/spec-in-progress. It records what's been decided, what's tentative, and what's still genuinely open. Nothing here is final syntax unless explicitly marked as such — treat bracket/keyword choices as illustrative pending a real grammar pass.

---

## 1. Core concept

A Lindana program is a set of **machines**. Each machine:

1. Declares a pattern (its left-hand side).
2. Blocks until a tuple in the shared **bag** matches that pattern.
3. Once matched, **immediately takes zero or more actions**: performing side effects, and/or pushing new tuples into the bag.

Each machine is declared in one line by convention (the grammar should tolerate embedded newlines, e.g. inside brackets).

**Machines loop by default** — after acting, a machine re-arms and waits to match again. An explicit `die` (or `quit`) side effect terminates a machine instead of looping.

**A machine with an empty pattern (no tuple to match) runs once, unconditionally, at program start**, then terminates (implicitly one-shot). Proposed use: binding "static" resources — e.g. a bytestring — to a compile-time-chosen atom name. There is no enforced guarantee these finish before ordinary matching begins ("static" by convention, not by contract). If ordering is required, use the same broadcast-readiness idiom as the heartbeat system (§7): the init machine's last action is `out (Ready,)`, and consumers `rd (Ready,)` before touching the resource.

---

## 2. Implementation approach

**Host language: Haskell.** Two independent reasons:

- The `parsec`/`megaparsec` family is a comfortable fit for specifying a formal grammar, including the "normally one line, but allow embedded newlines inside brackets" requirement (via a standard whitespace-consumer pattern).
- **STM (Software Transactional Memory)** is a near-perfect match for the *matching* semantics (see §3) — but **not** for the *effect* semantics, which were deliberately pulled out of STM later in the design (see §8).

An alternative substrate considered and set aside: **Prolog**, since tuple-space matching is structurally similar to unification against a fact database. Rejected mainly because Prolog doesn't natively give you the concurrency/blocking semantics that are core to this language — Haskell + STM was judged the better fit for owning both the matcher and the scheduler.

---

## 3. Matching semantics — the tuple bag

The bag is modeled as one or more `TVar`s (see §6 for how named bags shard this). A machine's matching loop is, conceptually:

```haskell
atomically $ do
  bag <- readTVar bagVar
  case findMatch pattern bag of
    Nothing        -> retry
    Just (t, bag') -> writeTVar bagVar bag' >> return t
```

**Two read modes**, both classic Linda:
- `in` — take (consumes the tuple). **Default** verb for a bare pattern clause.
- `rd` — read (leaves the tuple in the bag; lets multiple machines react to the same fact — this is your broadcast/fan-out mechanism).

Non-blocking probe variants (`inp`, `rdp`) exist for polling without blocking — see §7 for why they matter.

### 3.1 Racing matches are an intentional feature

If multiple machines could match the same tuple, **at most one gets it, and which one is explicitly allowed to be a race.** This isn't bolted on — it falls directly out of STM commit semantics: two matcher threads both see the tuple, both build "bag minus tuple," one commits, the other's transaction is invalidated on validation and its *entire body re-runs*, finds the tuple gone, and looks elsewhere. **This is a deliberate design choice** ("hand grenades, pins pre-pulled") — the language leans into this chaos rather than hiding it.

Real consequences to keep in mind:
- **No fairness guarantee.** GHC's STM does not promise a losing transaction won't keep losing. A machine could in principle starve.
- **Thundering herd.** With one big bag `TVar`, every `out`/`in` commit invalidates every transaction that read it, waking every blocked matcher even for unrelated tags. Named bags (§6) are the primary mitigation — they double as a performance fix and a first-class language feature.

### 3.2 Matching is commitment — no guard/rollback concept

**Decided:** once a machine's pattern structurally matches and binds, the machine has committed to handling it, even if that just means re-emitting the tuple unchanged. There is **no** separate guard-evaluation phase that can cause a match to be rejected and the tuple released back to the bag. Think "the LHS of a Haskell guard" — match success and commitment are the same event.

Practical idiom that falls out of this: a machine that wants to conditionally decline to *really* process a tuple does so by re-emitting it unchanged as one of its actions (see the throttling example in §7).

### 3.3 Type/arity checking is the action's job, not the matcher's

**Decided:** the matcher only ever does structural matching. It never validates that, say, an arithmetic operand is numeric. That's the responsibility of whichever action operates on the value (e.g. `+`) — and if the action's precondition fails, it raises via the `error` verb (§6.4).

### 3.4 Join patterns

A machine's LHS can be a comma-separated list of patterns, matched and committed together as one atomic transaction (STM composability handles this "for free" — it's just reading a few more `TVar`s in the same `atomically` block). Per-clause read mode can differ:

```
("add", a, b, c), (Stats, Add, count, epoch), rd(ResetEpoch, e) : ...
```

Here the request and the machine's own stats are consumed (`in`, default), while the epoch is only read (`rd`) so every throttled machine can observe the same heartbeat.

---

## 4. Syntax reference (current state)

- **Tuples**: `(...)`, comma-separated, e.g. `("add", a, b, c)`.
- **Grouping / sequences**: `[...]` — a distinct bracket from tuple literals, used for multi-action sequences (see §5 for how these desugar).
- **Atoms vs. variables**: pure case-sensitivity. Capitalized (`Atom`, `A`) = atom. Lowercase (`var`, `v`) = variable. (Note: this is the *inverse* of Prolog's convention — considered a feature, not a bug, given the tone of the language.)
- **`!` splice (construction side)**: expands an entire tuple's contents into the surrounding tuple at that position — e.g. `(c!, a + b)` splices whatever's bound to `c` into the result tuple. This is the core continuation-passing mechanism: a caller controls "what happens next" purely by shaping the continuation tuple it hands to a callee.
- **`!` rest-capture (pattern side)**: **wanted, syntax not yet settled.** Intended as the symmetric counterpart — something like Erlang's `[H|T]` for capturing "everything after position N" as a sub-tuple.
- **Type names as atoms**: `Int`, `Bool`, `Atom`, `Str`/`Tuple`, etc. are themselves ordinary atoms. `typeOf(x) == Int` uses the same equality operator as everything else — no separate `is_int`/`is_atom` primitive family needed. Deliberately allows collision: nothing stops a user from also using the atom `Int` for their own purposes; that ambiguity is an accepted hazard, consistent with the language's general stance.
- **Runtime atom conversion**: `atomize "Foo"` (string → atom) fatally errors (`panic`) if the input isn't capitalized — this isn't arbitrary, it protects round-tripping: since case is the only lexical signal distinguishing atoms from variables, an atom that couldn't be re-spelled as valid source would break anything that prints/re-parses values. `atos Foo` is the inverse (atom → string).

---

## 5. "Terse" sequencing, desugared to "Restricted" machines

Original open question: can an `if`/`else` branch contain a `;`-separated sequence of actions (**Terse**), or must every branch be exactly one action, pushing multi-step logic out into the tuple space as separate machines (**Restricted**)?

**Resolved ("Funny" option):** allow **Terse** syntax, but treat it as pure sugar that desugars at compile time into a chain of **Restricted** machines, linked by fresh compiler-generated continuation atoms `ACont0`, `ACont1`, ... This keeps the actual runtime semantics minimal (only ever one action per reaction, no primitive block construct) while giving programmers the convenient bracketed syntax.

```
if c then [say "Error, closing"; exit c] else [exit c]
```

roughly desugars to a chain like:

```
(ACont0, c)
ACont0(x) : say "Error, closing"; (ACont1, x)
ACont1(x) : exit x
```

Key decisions about this mechanism:

- **Nothing prevents a user from manually interacting with the generated `AContN` atoms.** This is explicit and intentional.
- **Continuation-tuple arity is a closure-capture problem**: each generated tuple must carry forward every free variable the remaining suffix of the sequence still needs — real closure conversion, done by the compiler, and naturally implemented *using* the `!` splice mechanism rather than as a bespoke pass.
- **Full chaos was explicitly chosen for cross-invocation collisions.** Because machines loop by default and `AContN` names are not scoped per-invocation, two concurrent firings of the *same* looping machine can race over the *same* `AContN` tuple — invocation A's first half could get followed by invocation B's second half. This was confirmed as desired behavior, not a bug to fix.

---

## 6. Named bags

**Declaration**: `Name { <machine declarations> }`. Unqualified/bare top-level machines implicitly belong to a bag called `Global` (explicit `Global { ... }` is also legal — pick one style, don't mix). **A given bag's machines can only be declared in one place in the program** (single declaration site per bag name).

**Convention**: route all external input into `Global` by default; internal machines re-route (via `lob`, below) into other named bags as needed. `Global` effectively acts as the program's front door/dispatcher.

### 6.1 `lob` — cross-bag send

`lob` is the only way to push a tuple into a bag from outside it. Receiving from a bag always requires a machine to be declared *inside* that bag's block — there's no cross-bag read primitive. This produces a clean split in the language's identity:

- **Within a bag**: Linda semantics — shared space, any matching machine can take it, racing allowed.
- **Across bags**: Erlang semantics — asynchronous, addressed, one-way message passing via `lob`.

Cross-bag atomicity is free: if bags are separate trees of `TVar`s, one `atomically` block can still span `TVar`s in different bags (STM doesn't know about the "bag" boundary), so a machine's action list mixing a same-bag `out` and a cross-bag `lob` still commits as one atomic unit without extra engineering.

### 6.2 Machineless bags — cheap accumulation

A bag declared with no machines at all just accumulates `lob`'d tuples in a cheap structure (conceptually a list) — cheap specifically because nothing is retrying/matching against it, so there's no contention. **Any ordering that results is accidental**, an artifact of whichever `lob` happened to commit first when several race — never a promise. E.g. `lob Log ("bar")` is a free logging sink.

A machine can be declared for a previously-machineless bag later. The transition — draining the accumulator into the live matching structure — must itself be one atomic STM transaction, so no tuple can be lost or double-delivered during the handoff. Once wound in, accumulation order is irrelevant: the tuples become ordinary members of the live bag, subject to normal racing-match chaos from that point on.

### 6.3 Sharding / performance note

Named bags double as the user-facing version of an internal performance fix: sharding the single global `TVar` into per-tag (or per-bag) `TVar`s avoids the thundering-herd problem from §3.1, since matchers only need to watch the shard(s) relevant to them.

### 6.4 Error handling

- `error` is a verb that fires context into a named `Error` bag (conceptually similar to `lob Error (...)`).
- `fatal` was renamed to **`panic`** for clarity.
- `Error` has a default machine: `(c!) : panic c` — **active only if the program declares no machine(s) of its own for `Error`.** A user-declared `Error { ... }` block, even if empty, fully replaces (not merely races against) the default. Consistent with the single-declaration-site rule: the default is only ever installed when zero user declarations exist for `Error`, never coexisting with a user block.
- **A deliberately empty `Error { }` block means "silently swallow all errors."**
- The **Prelude** is imported by default in the top-level file (§13.15, provisional) — prefixless, one-shot preregistration machines only, with a deliberate `Error { }` so it never adds a second §6.4 default machine to the plain `Error` bag. `{-# no-prelude #-}` opts out; an explicit `import Prelude Nil […]` after the pragma brings it back with a hide list.
- Error calls are also *reroutable at runtime* (§13.14, provisional): `reroute Src Tgt` repoints the `error` verb — per bag, or module-wide via the module's mangled Error bag name — last update wins. The reroute changes only where the tuple is delivered; its leading atom stays the original mangled Error bag (stable provenance). `panic` is never rerouted (it is fatal, not a message).

---

## 7. Effects & the effect-runner (formerly "tx")

### 7.1 History note

Earlier in the design, "transactions" were imagined as an STM-flavored construct (`tx [...]`) bundling tuple-space operations atomically, with candidate designs ranging from "restrict to tuple-space verbs only" to "allow anything, defer irrevocable effects until after commit." **This was superseded** by a cleaner reframing — recorded below as the current model. If you see references implying `tx` wraps STM retries, that's the old idea; disregard it in favor of §7.2.

### 7.2 Current model

Reframed: not STM atomicity over the bag, but **bundling a sequence of side effects together with clear ordering**, deferred until ready, and run as one synchronized unit. Because matching is already commitment (§3.2), by the time an action list is being bundled the relevant match has already committed for good — there's no STM retry to protect against, so the effect layer doesn't need STM at all. It's built from ordinary concurrent-Haskell primitives instead:

- A `Chan`/`TQueue` (or `MVar` for a single-slot/backpressure variant) that finished bundles are pushed into.
- A dedicated **effect-runner** thread drains bundles in order, running each bundle's effects sequentially, one bundle fully finishing before the next starts. This gives both **sequencing** (FIFO drain) and **synchronization** (exactly one bundle "live" at a time) with no bespoke machinery.
- **No automatic rollback on partial failure within a bundle.** If effects leak observable state before a later effect in the same bundle fails, that's the programmer's responsibility to guard against — checking success is on them, same "action's responsibility, not the runtime's" philosophy as arithmetic errors (§3.3).

### 7.3 Open questions on this subsystem

- **Global effect-runner vs. one-per-bag (or otherwise multiple)?** Single global runner is the simplest reading of "enforce synchronization" but means unrelated I/O in different bags serializes against each other. Not yet decided.
- **Concrete syntax** for declaring an effect bundle hasn't been written — the earlier bracket sketches were for the superseded STM-flavored `tx`, not this model. **Resolved (§11.6, §13.9): none will be written** — the bundle is the machine body's post-commit action list; bundles live in the runtime, not the grammar.
- **Do bytestring `create`/`destroy` effects (§9) route through this same effect-runner**, or are they synchronized independently via their own lock on the runtime side-table? Not yet decided — leaning toward "route through it," for consistency, but unconfirmed.

---

## 8. Workload management (self-throttling)

Motivation: mitigate the cross-invocation `AContN` collision hazard from §5 by letting hot machines back off under load, without adding correctness machinery — this is a *load* fix, not a *correctness* fix (the `tx`/effect-bundle mechanism above is the correctness angle, if wanted).

### 8.1 Mechanism

- Standard **exponential backoff with jitter** (same shape as Ethernet CSMA/CD or TCP congestion control). Jitter matters: without it, a burst of throttled machines can resume probing in lockstep and reproduce the same contention spike, just time-shifted.
- Throttled machines must switch from blocking `retry` to the **non-blocking probe primitive** (`inp`): check the bag, if no match, `sleep` for the rolled delay, then probe again. Tradeoff: a throttled machine loses "wakes instantly the moment its data lands" — accepted cost for machines that opt into throttling.
- **Fire-count storage — decided: in-bag, not thread-local.** An ordinary tuple, e.g. `(Stats, MachineId, Count)`, that the machine itself `in`s and re-`out`s on each fire. Chosen deliberately over cheaper private thread-local state specifically *because* it stays inspectable and hijackable by other machines, consistent with the language's general philosophy — even though it does add some of its own tuple-space traffic.
- **Heartbeat/reset**, itself expressed entirely as ordinary machines (no privileged runtime hook needed — a good sign the primitive set is sufficient):
  - A timer service does `out (Tick,)` on an interval.
  - A workload-manager machine matches `(Tick,)` and bumps a persistent, broadcast fact: `(ResetEpoch, n) → (ResetEpoch, n+1)`.
  - **Must use `rd`, not `in`**, for any throttled machine reading the epoch — `in` would let exactly one waiting machine consume the reset and starve everyone else of it.

### 8.2 Worked example

```
{
  (ResetEpoch, 0),
  (Stats, Add, 0, 0)
}

(Tick,), (ResetEpoch, n) : (ResetEpoch, n + 1)

("add", a, b, c), (Stats, Add, count, epoch), rd(ResetEpoch, e) :
  if epoch != e then
    [(Stats, Add, 0, e); ("add", a, b, c)]
  else if rand(count) == 0 then
    [(Stats, Add, 0, epoch); (c!, a + b)]
  else
    [(Stats, Add, count + 1, epoch); sleep(rand(count) * 5); ("add", a, b, c)]
```

Reading: a stale epoch means the heartbeat ticked since this worker last checked, so reset the count and retry immediately. Otherwise roll the dice with odds `1/count` of proceeding (swap `rand(count)` for `rand(2^count)` for true exponential rather than harmonic backoff). Losing the roll bumps the count, sleeps proportionally, and **re-emits the original request tuple** rather than holding it privately.

**Note `sleep` (like `say`, `exit`) cannot be part of an atomic commit** — same reasoning as bundled effects in §7: you can't hold an STM transaction open across a real-time delay. The atomic part is "read the join patterns, decide, write replacement tuples"; `sleep` and other irrevocable actions are a post-commit action list.

### 8.3 Emergent property

Because a backed-off request is **re-emitted into the open bag** rather than retried privately, and because racing-match chaos is a first-class feature, a second, less-loaded handler machine for the same tag could pick up the re-emitted request instead. Self-throttling plus racing yields something that looks like load balancing across redundant workers, without either mechanism being designed with the other in mind.

---

## 9. Numbers, Booleans, Lists, Strings & Bytestrings

- **Numbers**: no distinct declared numeric types — literal form infers system-width `long` or `double` (integer literal → long, decimal literal → double). **Open**: does mixed int/double arithmetic auto-promote, or is that a type error routed through `error`? Not decided.
- **Booleans**: C-style truthiness is permitted (an `if` condition can be a raw int; `0` is falsy). A distinct `Bool` type is also being added, with `True`/`False` presumably just ordinary capitalized atoms (consistent with the atoms-as-type-tags idea). Exact unifying truthiness rule (which values besides `0`/`False` count as falsy — e.g. does the empty tuple `()` count?) not finalized.
- **Lists**: **no new primitive type.** **Provisionally resolved** (§13.7, branch `parser/list-cons-sugar`): cons-lists — nested 2-tuples terminated by the `Nil` atom — with parse-time sugar: `[a, b, c]` → `(a, (b, (c, Nil)))`, `[h | t]` conses onto an arbitrary tail expression/pattern, `[]` → `Nil`; multi-head forms (`[a, b | t]`) likewise. Purely syntactic — no AST nodes, so the pretty-printer renders the desugared tuple form (which round-trips). `Nil` is *not* a reserved word (a program may still use it as an ordinary atom; doing so makes list literals meaningless — documented hazard, flip-worthy).
- **Strings (casual)**: **no primitive type either.** **Implemented** (§13.9, branch `parser/string-sugar`): a @"..."@ literal desugars at parse time to a cons-list of codepoint `Int`s — the exact shape the §11.5 list literal builds (`"hi"` IS `[104, 105]`). **Plain `Int`s all the way down — no `Char` type — provisionally resolving §11.4** on the side the design was already leaning (consistency: no new lexical class, no new runtime type; interpretation entirely up to whichever action consumes the value, §3.3). No AST nodes (`EStr`/`PStr` removed; `VStr` gone from `Val`), so the pretty-printer renders the desugared form, which round-trips. The shipped consumers share one decoder (`casualString`/`stringVal` in Runtime): `say %s` decodes a codepoint list; `atomize` decodes then checks capitalization (§4 fatal on lowercase — still a provisional Haskell-level error); `atos` hands back a casual string; `bytesBind`'s codepoint-list check uses the same decoder. Documented hazards rather than guards: `typeOf` of a casual string reports `Tuple` (its shape — there is no `Str` tag), and `==` on two casual strings is a §3.3 type error (only atom identity and numerics compare; structural matching is the way to compare list-shaped values).
- **Characters**: **no primitive type** (consistent with §11.4). **Implemented** (§13.10, branch `parser/char-sugar`, issue #12): @'x'@ literal sugar desugars at parse time to the single codepoint as a plain `Int` — @'a'@ IS @97@, exactly the element shape the string/list literals build from — @''@ is a synonym for the `Nil` atom, and wrapping multiple codepoints in @'…'@ is a parse error (use a string). Escapes resolved before the codepoint is taken (@\n@, @\t@, @\'@, @\\@). Purely syntactic — no AST nodes, so the pretty-printer renders the desugared form (`'+'` renders as `43`, `''` as `Nil`), which round-trips. Consequence (intended, per issue #12's bullet 3): chars cons into casual strings and feed `bytesBind` like any other codepoints, so "promoting" a string to a bytestring is already just `bytesBind H "…"` or a char list.
- **Strings (real/UTF-8)**: since primitive strings were dropped, real string work goes through **opaque bytestring handles** rather than a first-class type. **Implemented** (§13.8, branch `runtime/bytestring-side-table`):
  - `bytesBind Handle codepoint-list` registers the UTF-8 encoding under the (compile-time-chosen) atom handle; the effect runner emits a **`(Bytes, H)` completion tuple into `Global`** when the side-table write lands — the deterministic gate consumers join on (binds are deferred effects, §7.2). This is also the return path a future dynamic `bytesNew` would need (fresh-name generation: still open).
  - The side-table is `rtsBytes :: TVar (Map Name ByteString)` on the RTS. To the matcher a handle is just an ordinary atom — no special case in matching logic.
  - **`==` stays pure atom identity, uniformly, everywhere** — now actually true: `Eq`/`Neq` on `VAtom` operands used to be a Haskell error; `arith` compares atom names (§3.3: comparing handles compares the handles, not the contents). `bytesEqual(a, b)` is the builtin that reaches into the side-table for real content comparison (missing handle = provisional Haskell error, §3.3 routing pending).
  - `say "%b"` formats a bytestring handle by decoding its bytes (unknown handle / invalid UTF-8 = provisional Haskell errors).
  - `bytesDestroy e` drops the entry (manual lifetime, "build your own GC"); lookup on a destroyed/unknown handle is the attempting action's problem — missing-key case, provisional Haskell error. The actual hazard is purely *logical liveness*, not memory unsafety.
  - **`bytesRead(H)`** (§13.11, branch `runtime/bytes-read`, issue #12): the decode-back path — the handle's bytes decoded as UTF-8 and returned as the codepoint cons-list the bind consumed ('stringVal'), so `bytesBind H l … bytesRead(H)` is the identity and the result structurally matches string/char/list literal patterns. Missing handle / invalid UTF-8 = provisional Haskell errors, same routing as `bytesEqual`/`%b` (invalid UTF-8 is unreachable through `bytesBind` — the check is symmetry with `%b` and any future byte source).
  - **Not yet addressed**: no automatic reclamation; entries otherwise leak for the process lifetime. Treated as a deliberate non-goal for now, not an oversight, but worth flagging if revisited.
  - See §6.4/§8 pattern: one-use, no-tuple machines are the mechanism for binding a "static" bytestring to a compile-time-chosen atom name at program start (this is exactly `examples/bytes.lind`'s opening one-shot).

---

## 10. Worked example (original toy program, illustrative — not finalized syntax)

```
("add", a, b, c) : (c!, a + b)
(print, s) : say "Sum is %i" s; (stop, 0)
(stop, c) : if c then (say "Error, closing"; exit c) else (exit c)
```

Initial bag:

```
{
  (add, 1, 2, ("print"))
}
```

Note: this predates several later decisions (e.g. atom quoting was inconsistent here and later fixed to "capitalized = atom, no quoting"; the inline `if`/`;` sequencing shown here is what later became the Terse/`ACont` desugaring of §5; `stop` here is just a user-chosen tag, distinct from the built-in `die`/`quit` termination verb). Kept for continuity, not as a syntax reference.

---

## 11. Open design questions (consolidated)

Roughly in order of how foundational they are:

1. **Pattern-side `!` rest-capture** — **provisionally resolved** (§13.4, branch `runtime/machine-loop-actions`): trailing-only, var-only (`var!` as the last element of a tuple pattern; parser enforces), zero-or-more elements so `(c!)` matches any tuple — the shape the §6.4 default `Error` machine needs. Mid and trailing capture resolved as **mutually exclusive without language extensions**: under the natural "find an assignment" reading, a mid capture leaves the alignment of intervening fixed elements indeterminate (where does `c` sit in `(a, b!, c, d!)?`). A deterministic greedy-left/backtracking multi-slice strategy was considered and deliberately deferred — "a funny option with good footguns" — recorded in `agent-history/messageboard/multi-slice-rest-capture-future.txt`. Implementation: `PRest Name` in Syntax, `matchTuple` in Runtime, tests in RuntimeSpec/Spec/MachineSpec.
2. **Repeated variables within one pattern** — does `(a, a)` require equality between the two positions (Prolog-style), or is it a rebind/shadow? Raised, never resolved.
3. **Mixed int/double arithmetic** — auto-promote, or a type error via `error`? (§9)
4. **Char type vs. plain Ints** for string sugar — **provisionally resolved** (§13.9, branch `parser/string-sugar`): plain `Int`s all the way down — `"..."` is pure literal sugar (parse-time desugar to the §11.5 cons-list shape) and interpretation is up to whichever action consumes the value. Flip-worthy. **Reinforced** (§13.10, branch `parser/char-sugar`, issue #12): character sugar lands on the same side — `'x'` is the codepoint as a plain `Int`, no `Char` lexical class or runtime type.
5. **Exact list literal/pattern sugar syntax for cons-lists (§9)** — **provisionally resolved** (§13.7, branch `parser/list-cons-sugar`): `[a, b, c]` / `[h | t]` / `[]`, parse-time desugaring to nested 2-tuples with the `Nil` sentinel atom; no AST nodes; renderer emits the desugared form; `Nil` deliberately not reserved. Flip-worthy.
6. **Concrete effect-bundle syntax** for the reframed effect-runner model (§7) — the old bracket sketch was for the superseded STM-flavored idea and doesn't apply. **Provisionally resolved** (§13.9, branch `parser/string-sugar`): none needed — the bundle /is/ a machine reaction's post-commit action list, a runtime concept (`Effect`/`Bundle` in "Lindana.Machine"), not a user construct; the user already writes the action list. Decision note recorded in the module header. Flip-worthy.
7. **Effect-runner scope**: one global runner, or multiple (e.g. per-bag)? (§7.3) — **sharpened** (§13.21, `agent-history/messageboard/sleep-experiment/`): the global runner makes `sleep` unable to delay a machine's own re-arm (it throttles the runner thread, not the machine), which kills sleepsort and any self-throttling-by-sleep design; sleepsort is the acceptance test for any flip here. Interacts with the PR #29 comment on per-machine/per-bag fd modelling and "what should race and what should synchronize" (flip #8 of `provisional-std-fd-semantics.txt`). **Design position recorded** (sleep-experiment README): the intended working model is that action-list sequencing enforces ordering — the §5 implicit continuation as real semantics, a machine's later steps waiting on its earlier effects (the runner emits continuation gates at effect boundaries, generalizing the completion-gate idiom); whether ordering is bag-local or machine-local is the same §11.7 flip.
8. **Bytestring lifecycle vs. effect-runner**: do `create`/`destroy` route through the shared effect-runner, or use independent synchronization? (§7.3) — **provisionally resolved** (§13.8, branch `runtime/bytestring-side-table`): both route through the shared effect-runner as ordinary bundle effects (`EffBytesBind`/`EffBytesDestroy`); the side-table is a plain `TVar`, so bind/destroy are single STM writes from the runner, and a bind emits its `(Bytes, H)` completion tuple into `Global`. Flip-worthy if the global-runner serialization (§11.7) ever matters.
9. **`die` vs. `quit`** — used interchangeably in discussion; exact keyword not finalized.
10. **Top-level program grammar**: now that named bags exist, how do multiple `Name { ... }` blocks, `Global`'s implicit initial-tuple literal, and any other bag's initial state compose into one program's file-level syntax? Flagged early, never revisited. **Provisionally resolved** (§13.6, branch `runtime/named-bags-loader`): a `{ … }` initial block belongs to its nearest enclosing bag — top level is `Global`'s; at most one per bag; nothing else nests (a bag block may not contain another bag block, §6 — sharding is internal, §6.3).
11. **Bytestring reclamation** — explicitly punted for now (§9); revisit if it matters later.
12. **Default-Error-machine shutdown hazard**: a program that declares no `Error` block (so the §6.4 default `(c!) : panic c` machine is installed), has no `exit` path, and whose machines all terminate via `die` can never shut down cleanly — the default machine is an immortal parked thread, `rtsLive` never reaches 0, and the RTS aborts with `BlockedIndefinitelyOnSTM`, which Main.hs reports as the §1 deadlock message (exit 1) for what should be a clean exit 0. Repro and candidate fixes in `agent-history/messageboard/sleep-experiment/README.txt` (finding 5), discovered during the §13.21 sleep experiment. — **provisionally resolved** (§13.22, branch `runtime/idle-shutdown`): idle-exempt machines (`machIdle`) are not counted in the live total, and the shutdown check drains idle bags before cancelling so the guaranteed panic survives. Flip-worthy if any future machine class needs "parks forever but still gates shutdown".

---

## 12. Design philosophy, for whoever picks this up

A few threads run through essentially every decision made so far, worth keeping in mind for anything not yet settled:

- **New features are sugar over old ones wherever possible** — named bags are sugar over sharding; `error` is sugar over `lob`; lists/strings are sugar over tuples; Terse sequencing is sugar over Restricted machines and `!`. Prefer this shape for any new primitive under consideration.
- **One capitalized-identifier lexical class does triple duty**: atoms, type-tags, and bag names are all just capitalized identifiers, disambiguated purely by syntactic position. Consistent with this rather than introducing new lexical categories.
- **The matcher checks structure; actions check semantics.** Never move a semantic/type check into the matcher.
- **Chaos is opt-*out*, not opt-in.** Racing matches, cross-invocation `ACont` collisions, and manual bytestring lifetime bugs are all deliberate, inspectable, and left un-guarded by default — mitigations (named bags, effect bundles, throttling) exist as things a programmer reaches for, not defaults the runtime imposes.

---

## 13. Implementation status (session notes)

### 13.1 Done — STM tuple bag + matcher (§3), branch `runtime/stm-bag-matcher`

`src/Lindana/Runtime.hs` implements the §3 sketch:

- **`Val`** — runtime values (`VAtom`/`VInt`/`VDouble`/`VStr`/`VTuple`), mirroring the pattern/expr literal kinds. No list/string primitives (§9 sugar, not built); bytestring handles will be plain `VAtom`s + a side-table (§9, not built).
- **`RBag`** — the runtime bag: one `TVar [Val]` per bag, i.e. the pre-sharding model of §3's opening. Named bags/sharding (§6) will hold several of these and pick the right `TVar`s inside one `atomically` — the R (vs Syntax's `Bag` Decl constructor) prefix avoids the name clash. Thundering herd (§3.1) is unmitigated until then, as expected.
- **`matchJoinSTM`** — join patterns (§3.4) in one transaction; per-clause `Take`/`Read`; Take clauses consume *distinct* tuples (left-to-right against a working copy; a Read clause cannot match a tuple a Take clause consumed earlier in the same join — matches the §8.2 request+stats+epoch idiom). All-or-nothing is free from STM.
- **Blocking verbs** `inBag`/`rdBag` (STM `retry`) and **probes** `inpBag`/`rdpBag` (the §8.1 primitive throttled machines must use).
- **`evalExpr`/`evalElem`** — construction-side expression evaluation, including tuple splice `!` flattening (§4). Deliberately partial: builtins (`rand`, `atomize`, …) and arithmetic type errors belong to the action layer (§3.3, §7) and `error` there; not implemented yet.
- Racing (§3.1) needed **zero extra code** — it's STM commit contention, as the design predicted. Tests confirm: exactly one winner among 16 contenders; 200 tuples conserved across 100 concurrent draining consumers.

Tested in `test/Lindana/RuntimeSpec.hs` (23 cases, all green alongside the parser suite).

### 13.2 Provisional decision made here (was open §11.2)

**Repeated variables within one pattern require structural equality** (Prolog-style): `(a, a)` fails to match `(3, 4)`. Implemented entirely in `matchPat`; trivially flippable. Treated as provisional until a real grammar/semantics pass.

Also provisionally: int and double literals **do not cross-match** (`PInt 1` vs `VDouble 1.0` fails) — the matcher is structural, and mixed-arithmetic promotion (§11.3) is still open and belongs to the action layer anyway.

### 13.3 Natural next steps for the runtime

Roughly in dependency order:

1. **Machine loop / scheduler** (§1, §2): spawn a thread per machine; loop = `inBag` join → evaluate actions → re-arm; empty-pattern machines run once at start; `die`/`quit` terminates the thread. Note the §5 `AContN` chaos falls out of machines looping by default — nothing to build, just don't prevent it.
2. **Action layer** (§3.3, §7): the verbs (`out`, `lob`, `say`, `exit`, `sleep`, `panic`, `error`, `if`) as post-commit action lists; effect-runner thread with a `TQueue` of bundles (§7.2). Builtins like `rand` land here too.
3. **Named bags + `lob`** (§6): mostly wiring multiple `RBag`s; cross-bag atomicity is free (one `atomically` spans `TVar`s). Machineless-bag accumulation (§6.2) and the atomic drain-on-first-machine handoff are the interesting bits.
4. **Program loader**: `Program`/`Decl` AST → runtime wiring; resolve the §11.10 top-level grammar question on the way.

### 13.4 Done — machine loop/scheduler + action layer + effect-runner (§1, §2, §7.2), branch `runtime/machine-loop-actions`

New module `src/Lindana/Machine.hs` (off `main`, on top of a fast-forward of `runtime/stm-bag-matcher`):

- **Machine loop/scheduler** (§13.3 step 1): one thread per machine; loop = blocking join (`matchJoinSTM` + `retry`) → interpret body → re-arm. `die` ends the thread; empty-pattern machines fire once at start with empty env (§1) and terminate. Nothing done to *prevent* §5's `AContN` cross-invocation chaos — it falls out of the loop, as predicted.
- **Action layer** (§13.3 step 2), two-phase per the §8.2 note: the interpreter runs /inside/ the matching transaction. Tuple-space verbs (`out`, `lob`, and `error`'s Error-tuple write) execute there — so a machine's tuple writes commit atomically with its match. Every irrevocable verb comes back as a deferred `Effect` bundle, pushed to a `TQueue` after commit; a **single global effect-runner** thread (§7.3 provisionally global) drains FIFO, one bundle live at a time (§7.2). No rollback on partial failure, per §7.2.
- **Builtins evaluate in STM** (via a generalized `evalExprG` in Runtime, carrier `f ~ STM` in the action layer, `f ~ Identity` in the pure core): `rand` uses the `random` package's splitmix-backed `StdGen` — pure `uniformR` step with the generator in a `TVar`, so `rand` inside a machine's decision keeps the whole "match → decide → re-emit" step atomic (§8.2's requirement), with unbiased bounded ranges and deterministic runs (fixed `mkStdGen 12345` seed). An earlier hand-rolled MMIX-constant LCG sampled low bits and made `rand(2)` a strict 0,1,0,1 alternator — replaced by the library call (there's a regression test). `typeOf`, `atomize`, `atos` in. `atomize`'s §4 `panic`-on-lowercase is provisionally a Haskell-level `error` (kills the machine thread) pending the effect-bundle grammar (§11.6).
- **`exit` = program termination** with evaluated code (provisional; §10's two uses read that way); `die` = machine-only. `panic` = message to a hook + `ExitFailure 1`. `error` verb = degenerate pre-§6 form: emits an `(Error, …)` tuple into the main bag (tuple argument spliced). **No default `Error` machine installed** — its pattern needs rest-capture (§11.1); unmatched Error tuples just sit.
- **`lob` preview** (§6.2): lobbing to a not-yet-known bag creates a machineless accumulator (`Map Name RBag` in the RTS) — the free logging sink works today; matching *into* named bags waits for §6 proper.
- **Provisional truthiness** (§9/§11): falsy = `0`, `0.0`, `False`; everything else (including `()`) truthy.
- **Effect-runner shutdown** (found by test, now a firm contract): cancelling the runner dropped bundles mid-`sleep`. Instead: machines are cancelled, then a `rtsStop` flag makes the runner finish its current bundle and drain the queue — **every queued bundle fully executes before `runProgram` returns**. Residual provisional hazard: a machine cancelled between committing a match and queueing its bundle loses it (tiny window; a real shutdown contract is an open question worth adding to §11).
- **Fixed LCG seed** (12345): deterministic runs — reproducible chaos. Provisional.
- **Truthiness**: falsy = `VInt 0`, `VDouble 0.0`, `VAtom "False"`; everything else truthy, including `()`. Provisional (§11 open).
- **Effect-bundle syntax** (§11.6): still unwritten — the RTS speaks in `MachineDef`s/`Action`s directly; the loader will map AST → these.

Tests: 16 new cases in `test/Lindana/MachineSpec.hs` (loop/one-shot/loop-until-die, continuation pipelines, effect ordering, die-drops-rest, two-phase split, exit/panic/error routing, builtins, lob accumulation); 43 total green, randomized order, 5× repeat stable.

### 13.5 Next steps (revised §13.3)

3. **Named bags + `lob`** (§6): `rtsBags` already accumulates machineless bags; remaining: machines declared inside a bag match *that* bag (machine declarations need bag scoping), plus the atomic drain-on-first-machine handoff (§6.2) and the `Error` default machine.
4. **Program loader**: `Program`/`Decl` AST → `MachineDef`s + initial tuples via `runProgram`; resolve §11.10 (top-level grammar) on the way.

### 13.6 Done — named bags + program loader (§6, §13.5 steps 3–4, §11.10), branch `runtime/named-bags-loader`

New module `src/Lindana/Loader.hs`; `src/Lindana/Machine.hs` reworked for bag scoping; `app/Main.hs` now runs programs.

- **Bag scoping (§6)**: `MachineDef` gained `machBag`; machines match the bag whose block declared them (`"Global"` for bare top-level machines). `out` emits into the machine's *own* bag — within a bag it is Linda semantics, and the continuation idiom (`(c!, a + b)`) only works if continuations land where the matching machines are. Cross-bag traffic goes through `lob` exclusively (§6.1): Erlang-style, addressed, one-way.
- **§6.2 handoff is free here**: a machineless accumulator and a live bag are the /same/ structure (one `TVar [Val]`), so the "atomic drain-on-first-machine handoff" needs no code — tuples accumulated before the bag has machines are already in place when its machines start matching, and nothing can be lost or double-delivered. `bagForSTM` resolves `Global` to the main bag, finds other names in `rtsBags`, or creates them on demand (which is how `lob` makes accumulators). `lob Global` routes to the main bag.
- **Cross-bag atomicity (§6.1)**: unchanged and free — one `atomically` spans bags; a body mixing same-bag `out` and cross-bag `lob` commits as one unit.
- **§6.4 default `Error` machine**: the loader appends `(c!) : panic c` (rest capture, §11.1) /iff the program declares no `Error` bag at all/. A user-declared `Error { … }` block — even empty ("silently swallow all errors") — fully replaces it; the default never coexists with a user block. The `error` verb is now `lob Error (…)` proper: the `(Error, …)` tuple lands in the named bag, not `Global`.
- **Loader (§13.5 step 4)**: `loadProgram :: Program -> Either String Loaded` lowers the AST to bag-tagged `MachineDef`s + per-bag initial tuples, and enforces: single declaration site per bag name; no mixing bare top-level machines with an explicit `Global` block (§6 "pick one style"); no nested bag blocks; at most one initial block per bag. `runLoaded` runs the lowered shape; `runProgram`/`runProgramWith` remain as `Global`-only conveniences.
- **§11.10 provisionally resolved** (see the list above and the loader's module header): a `{ … }` initial block belongs to its nearest enclosing bag; at most one per bag; bags are flat. Flip-worthy per the house style.
- **Parser**: a `}` at depth 0 now also terminates a machine — it can only be the closing brace of an enclosing bag block, so one-line `Name { pat : action }` blocks parse. (`endOfMachine` in Parser.hs.)
- **CLI**: `lindana <file.lind>` parses, loads, and runs, exiting with the program's `exit`/`panic` status; `--parse` keeps the old render-only mode. Load errors (bag rules) print as messages. When every machine is blocked on a match that never arrives (the §1 loop keeping the run alive) the RTS raises `BlockedIndefinitelyOnSTM`; the CLI reports it as the deadlock it is: "every machine is blocked on a match that never arrives; such programs need an exit/die path". (A real shutdown contract for this is still an open §11 question worth adding.)
- **Examples**: `examples/toy.lind` had a latent pre-runtime bug — `("Print",)` is a 1-tuple containing the /string/ `"Print"`, which the structural matcher rightly refuses to match against the atom pattern `(Print, s)`; fixed to `(Print,)`. New `examples/bags.lind` exercises the whole §6 story (front door, cross-bag lob, machineless `Log` accumulator, user `Error` handler with rest capture, `rd` join clause) and terminates. `throttle.lind` (§8.2) is deliberately non-terminating — the CLI now reports it as a deadlock when it goes fully idle.

Tests: 22 new cases (loader scoping/rules/§11.10, §6.4 default-Error behavior end-to-end via parse→load→run, bag isolation, same-bag `out`, cross-bag `lob` incl. the §6.2 drain, `lob Global`, parser one-line bag blocks) — 75 total green, randomized order, 3× repeat stable. Zero `-Wall` warnings.

### 13.7 Done — list/cons sugar (§11.5, §9 lists, §11 item 5), branch `parser/list-cons-sugar`

Parse-time desugaring in `Parser.hs`; the AST is untouched.

- **Syntax (provisional, flip-worthy)**: `[a, b, c]` → `(a, (b, (c, Nil)))`; `[]` → `Nil`; `[h | t]` conses onto an arbitrary tail (expression or pattern); multi-head `[a, b | t]` → `(a, (b, t))`. List literals nest freely (`[[1], []]` etc.). Elements in expression position are tuple elements, so `!` splice works there too; pattern elements are plain patterns (rest-capture `var!` is a tuple-level concept — the cons tail is the list-shaped way to bind the remainder).
- **No AST nodes, no `Nil` reservation**: the parser lowers to `ETuple`/`PAtom` directly, so `renderProgram` emits the desugared tuple form — which reparses to an equal AST (round-trip intact). `Nil` remains an ordinary atom; a program that uses `Nil` as data makes list literals meaningless — documented hazard rather than a reserved word, for now.
- **Bracket depth**: list brackets participate in the existing newline-depth machinery (`grouped`), so multi-line lists work inside machines and initial blocks.
- **Tests**: 10 new cases — parser: literal/empty/cons-tail desugaring in expression and pattern position, multi-head patterns, nesting, round-trip; loader: end-to-end list walk (`([h | t],)` iterating machine + `([],)` exit machine, says `1`–`3`, `ExitSuccess`). 87 total green, randomized order, 3× repeat stable. Zero `-Wall` warnings.
- **Examples**: `examples/lists.lind` — sums a list literal via a cons-pattern walker + `Total` accumulator, then exits via the `(Stop, c)` idiom.
- **Remaining threads**: §9 bytestring side-table and §11.6 effect-bundle grammar (see PR #8's "Next"). Note for §9: list sugar gives byte-list literals (`[72, 105]`) for free; casual-string sugar over codepoint lists (§9) would now desugar to lists — unaddressed, `VStr` untouched this slice.

### 13.8 Done — bytestring side-table (§9, §11.8), branch `runtime/bytestring-side-table`

- **RTS**: `rtsBytes :: TVar (Map Name ByteString)`; final state exposed as `RunResult`'s `rrBytes` (symmetric with `rrBag`/`rrBags`, and handy for tests/CLI introspection).
- **Verbs**: `bytesBind Handle list` (handle is a capitalized atom, compile-time-chosen per the §6.4/§8 static pattern; list is a cons-list of codepoint ints — §11.5 sugar builds exactly that shape; shape/range checked at the action layer, §3.3), `bytesDestroy e`, builtin `bytesEqual(a, b)` (content comparison via the side-table; `VInt 1/0` like `==`). `say` gained `%b` (decode a handle; the runner snapshots `rtsBytes` per `EffSay`).
- **Completion tuple**: a successful bind emits `(Bytes, H)` into `Global` — binds are deferred effects, so consumers join on this to be deterministic; also the future return path for dynamic handles (fresh-name generation remains open).
- **`==` on atoms**: `arith` now handles `Eq`/`Neq` on `VAtom` (name identity) — §9's "== stays pure atom identity" previously wasn't actually evaluable; atom arithmetic still errors.
- **§11.8 provisionally resolved**: create/destroy are ordinary effect-runner bundle effects; no separate synchronization.
- **Testing lesson (recorded in LoaderSpec)**: a program whose machines all `die` leaves the §6.4 default `Error` machine blocked, and termination then depends on `BlockedIndefinitelyOnSTM` — which is *flaky under the test harness* (the suite hung nondeterministically until the e2e program ended in `exit` instead). The MachineSpec header's "programs must terminate" rule is now sharpened: end e2e programs with an explicit `exit`, not just `die`.
- **Tests**: 13 new cases (parser grammar ×4 incl. round-trip; MachineSpec side-table ×7: bind+completion, destroy, bytesEqual-vs-== verdicts, identical bytes, `%b` decode incl. non-ASCII, unbound-handle transaction abort, atom identity without bytes; LoaderSpec e2e ×2: static bind with completion-gated `%b` say, opacity of handles). 100 total green, randomized order, repeated runs stable. Zero `-Wall` warnings.
- **Examples**: `examples/bytes.lind` — static bind via one-shot, completion-gated `%b` say, bytesEqual-vs-`==` verdicts; verified via CLI and `--parse` round-trip.
- **Remaining threads**: §11.6 effect-bundle grammar (likely a decision note — the machine body is already the bundle); casual-string sugar over codepoint lists (§9) still open, `VStr` untouched.

### 13.9 Done — casual-string sugar (§9, §11.4) + §11.6 decision note, branch `parser/string-sugar`

Both threads PR #10's "Next" left open, in one slice.

- **Casual strings implemented (§9)**: `"..."` literals desugar at parse time to cons-lists of codepoint `Int`s — exactly the §11.5 list-literal shape (`"hi"` IS `[104, 105]`; a parser test asserts the two parse to the same AST). **Plain `Int`s all the way down: §11.4 provisionally resolved** (no `Char` type — the leaning recorded in §9, on consistency grounds: no new lexical class, no new runtime type, interpretation up to the consuming action, §3.3).
- **No string anywhere in the AST or runtime**: `EStr`/`PStr` removed from Syntax (string literals are sugar, like lists), `VStr` removed from `Val`. The pretty-printer renders the desugared tuple form, which reparses to an equal AST. `typeOf` of a casual string now reports `Tuple` (its shape; no `Str` tag — documented hazard). `==` on casual strings is a §3.3 type error (atom identity + numerics only); structural pattern matching is how list-shaped values compare.
- **Consumers share one decoder** (`casualString`/`stringVal`, now in Runtime): `say %s` decodes any codepoint cons-list (shape/range checks §3.3; escapes and non-ASCII ☺ verified); `atomize` decodes then applies the §4 capitalization check (lowercase still a provisional Haskell-level error that aborts the machine's transaction); `atos` returns a casual string, so `atos(atomize("Foo"))` round-trips through the list shape; `bytesBind`'s codepoint check routes through the same decoder — one implementation of "what a string is".
- **`say`'s format literal is the one raw survivor**: it stays a `String` in the AST (`Say String [Expr]`) because the say-position is not an expression — the action consumes the literal itself as a format, never a bag value. Provisional, flip-worthy (a variable-format `say s` would walk the list the same way).
- **§11.6 provisionally resolved — decision note, not code**: the effect bundle /is/ a machine reaction's post-commit action list: the `Effect` list `interpretActions` returns, queued as one `Bundle`, drained FIFO by the runner. There is no concrete syntax and none is wanted — the user already writes the action list, and the transaction/deferred split (§7.2/§8.2) is the runtime's implementation detail. Recorded in the Machine module header. This also retires the §13.4 note "pending the effect-bundle grammar": `atomize`'s panic routing is pending *unified error routing* (§3.3/§7.3), which is a separate, still-open thread.
- **Tests**: 9 new cases — parser: literal/empty/pattern desugaring, escapes, the `[104, 105]` ≡ `"hi"` shape equivalence, round-trip; MachineSpec: `%s` decoding incl. `\n`/☺, `typeOf` → `Tuple` for strings, atomize/atos round-trip over lists, uncapitalized-`atomize` transaction abort; LoaderSpec e2e: literal tag matches literal value, `%s` says a bound string. 109 total green, randomized order, 3× repeat stable. Zero `-Wall` warnings.
- **Examples**: `examples/strings.lind` — literal tag/pattern match, `%s` decode of `atos` output and a non-ASCII literal; verified via CLI and `--parse` round-trip (the renderer shows the desugared codepoint tuples, which reparse to the same AST and still run).
- **Remaining threads**: nothing from PR #10's "Next". Still open in §11: mixed int/double arithmetic (§11.3), effect-runner scope (§11.7), `die` vs `quit` (§11.9), bytestring reclamation (§11.11), fresh-name generation for a dynamic `bytesNew` (§9), unified error routing (§3.3/§7.3).

### 13.10 Done — character literal sugar (§9, §11.4), branch `parser/char-sugar` (issue #12)

Takes the character-sugar bullets of issue #12 (the follow-up notes to the string-sugar PR):

- **Syntax (provisional, flip-worthy)**: `'x'` desugars at parse time to the single codepoint as a plain `Int` (`'+'` IS `43`) — the exact element shape the §11.5/§9 cons-list literals build from, so `'a'` IS `97`, chars cons into casual strings, and they feed `bytesBind` like any other codepoints (issue #12's "promote a casual string to a bytestring" is thereby already expressible: `bytesBind H ['O', 'k']` or `bytesBind H "Ok"`). `''` is a synonym for the `Nil` atom. Multiple codepoints wrapped in `'…'` are a **parse error** — that's what string sugar is for (the issue's own ruling). Escapes resolved before the codepoint is taken: `\n`, `\t`, `\'`, `\\`.
- **No AST nodes** (the §11.5/§9 precedent): no `Char` lexical class, no runtime type — §11.4's "plain Ints all the way down" now covers characters too (§11.4 note updated; the issue's UTF-8 caveat about one-character-≠-one-codepoint is dodged entirely by keying the literal to *one codepoint*). The pretty-printer renders the desugared form — `'+'` renders as `43`, `''` as `Nil` — which reparses to an equal AST (round-trip intact; `examples/chars.lind` verified to render to a fixed point).
- **Tests**: 8 new cases — parser: literal → codepoint Int, `''` → `Nil`, escapes (`\n`/`\'`/`\\`), pattern desugaring, `'a'` ≡ `97` shape equivalence, multi-codepoint rejection (expression and pattern positions), round-trip; LoaderSpec e2e: char pattern matches an initial tuple, chars cons into a `%s`-decoded casual string, chars build a `bytesBind` bytestring decoded via `%b` (explicit `exit` end per the §13.8 house rule). 117 total green, randomized order, 3× repeat stable. Zero `-Wall` warnings.
- **Examples**: `examples/chars.lind` — char pattern matching, chars-as-codepoints into `%s` and `bytesBind`/`%b`; verified via CLI and `--parse` round-trip.
- **Noted, not fixed here** (house-wide, pre-existing): megaparsec's error merging swallows custom `fail` messages in choices — e.g. multi-codepoint `'ab'` and the §11.1 rest-capture errors all render as the generic "unexpected … expecting end of input or newline" at 1:1. The rejections are enforced and tested, but surfacing the real messages (via `label`/`withLastError`-style plumbing) would be its own slice.
- **Remaining threads from issue #12**: its bullet 3's “identity invariant” — there is still no builtin to decode a bytestring handle *back* into a codepoint list (bytes go in via `bytesBind`, come out only via `%b`'s render); a `bytesRead`-style builtin returning the codepoint list would make “string in and out of ByteString” literally the identity. Left as the natural next runtime slice. Still open in §11 otherwise: mixed int/double arithmetic (§11.3), effect-runner scope (§11.7), `die` vs `quit` (§11.9), bytestring reclamation (§11.11), fresh-name generation for a dynamic `bytesNew` (§9), unified error routing (§3.3/§7.3).

### 13.11 Done — `bytesRead`, the decode-back path (§9), branch `runtime/bytes-read` (closes issue #12)

Takes the last open bullet of issue #12 (the “identity invariant”), as scoped in the issue comment left after §13.10:

- **`bytesRead(H)` builtin**: the handle's bytes are UTF-8-decoded and returned as the codepoint cons-list the bind consumed — Runtime's `stringVal`, the same encoder `atos` uses, so there is one implementation of “what a string is” on both sides of the side-table (§12 philosophy). `bytesBind H l … bytesRead(H)` round-trips `l` exactly: the result's Val shape is asserted equal to the original list, not merely its render, so structural matching against string/char/list literal patterns just works (the e2e test proves it by matching the read-back value against the literal pattern `"Ok"`).
- **Provisional error routing (documented, not guarded)**: missing/destroyed handle and invalid UTF-8 are provisional Haskell errors that abort the machine's transaction — same routing as `bytesEqual` and `%b`, pending unified error routing (§3.3/§7.3). Invalid UTF-8 is unreachable through `bytesBind` (it only registers `encodeUtf8` of checked codepoints); the check is for symmetry with `%b` and any future byte source. The issue's “bytestring-to-list helpers that mogrify the result” are explicitly *not* built — the slice is the identity builtin only.
- **Tests**: 5 new cases — MachineSpec: decode-back (gated on the `(Bytes, H)` completion tuple), exact-shape identity round-trip, unbound-handle transaction abort; Spec: grammar + round-trip for `bytesRead` in expression position; LoaderSpec e2e: `bytesBind "Ok"` → `bytesRead` → structural match against the `"Ok"` pattern. 122 total green, randomized order, 3× repeat stable. Zero `-Wall` warnings.
- **Examples**: `examples/bytes.lind` — a `(Read,)` → `(RoundTrip, bytesRead(Greeting))` → `(RoundTrip, "Hi")` chain demonstrating the identity end-to-end (gate note: the bind has certainly landed by `(Read,)` — the `%b` say above already decoded it); verified via CLI and `--parse` round-trip.
- **Issue #12 closed**: char sugar (§13.10) + this slice cover all three bullets. Still open in §11: mixed int/double arithmetic (§11.3), effect-runner scope (§11.7), `die` vs `quit` (§11.9), bytestring reclamation (§11.11), fresh-name generation for a dynamic `bytesNew` (§9), unified error routing (§3.3/§7.3) — plus the house-wide parser-error-message plumbing noted in §13.10.


### 13.12 Done — Brainfuck interpreter example (§9, §11.5, §3.1, §3.2, §12), branch `examples/brainfuck`

`examples/brainfuck.lind` — a bounded-nothing, bounded-nothing… a
Brainfuck interpreter written entirely as Lindana machines; no runtime
or parser changes were needed (the language as of §13.11 was already
sufficient — the example is the stress test). It runs the classic
input-free "Hello World!" and exits 0.

- **Architecture** (header-commented in the file): an init `Scan`
  machine walks the casual-string program literal once, building a
  bracket jump table (open/close position pairs — order-free, lookup
  walks it with `==`) and the program as a cons-list (accumulated
  reversed). A generic `Rev` machine straightens lists, CPS-style: its
  last slot is a continuation tuple spliced in with `!` at the bottom
  (§4) — the same Rev serves both the scanned program (→ `BfInit`) and
  the output (→ `Fin`). The stepper `Bf` holds
  `(ip, cur, before, after, left, right, out)`: the program and the
  tape are both zippers; dispatcher machines are keyed on the
  instruction character at the head of `After`, all watching the one
  evolving state tuple. Jumps: `FindF`/`FindB` walk the pair table,
  `MoveF`/`MoveB` shuffle the program zipper by counter.
- **The tape is lazy and unbounded in both directions** (suggested by
  the project owner, and the funny consequence of the zipper
  strategy): an empty side just conses a fresh 0 cell, so there is no
  tape allocation step and no edge — a runaway `[<]`/`[>]` scan now
  allocates forever instead of hitting an edge (documented hazard, not
  guarded, §12 style). No `,` (no stdin verb) and no comment
  characters: a program containing either deadlocks the matching
  machine, which the CLI reports; stripping comments race-free would
  need a non-racing catch-all pattern, which the matcher deliberately
  doesn't have.
- **Deterministic despite the substrate**: because the dispatcher
  rules are keyed on distinct instruction literals, no two machines'
  patterns overlap — exactly one machine can fire per state tuple.
  Chaos is opt-out (§12), and the interpreter opts out.
- **Pattern-vs-branch lesson (generalizable)**: counter walkers must
  put their base case in an `if` in the body, NOT in a
  base-case-rule + general-rule pair — at the boundary value both
  patterns match and the §3.1 race picks a winner (a missed base case
  walks the counter past zero and never terminates the walk). All of
  `MoveF`/`MoveB` (base `n != 1`) and any "walk until" logic do this.
- **PRest races zero (§11.1 consequence)**: a rest capture matches
  *zero-or-more* elements, so an `st!`-shaped error rule races the
  `[]`-shaped success rule on the very state it means to exclude
  (Scan's "unmatched [" end rule). Nonempty-stack as a *pattern* must
  be the cons shape `[p | st]`, not a rest capture. Worth remembering
  for any future "rest capture but at least one" want.
- **PRest double-wraps continuations**: capturing a CPS continuation
  with `k!` wraps it in a sub-tuple *every* hop including the final
  capture, so the bottom splice produces a wrapped value nobody
  matches. Pass the continuation as a plain variable (PVar binds the
  whole value) and splice only at the bottom — `Rev` does this.
- **Zipper-jump subtlety**: a backward jump consumes the `]` in the
  dispatcher, and the jump shuffle must therefore cons `']'` back onto
  `Before` and move `ip - p + 1` chars so the `]` lands back at its
  position — otherwise a second pass through the loop walks straight
  past where it was and the ip threading desyncs (deadlock). The
  forward skip already preserved its `[` (FindF's found branch conses
  it before MoveF runs).
- **Debugging tale, recorded as a hazard**: mid-session misbehavior
  was traced by adding `say`s to the dispatcher rules — which
  deadlocked everything, because `say "no specifier" arg` throws
  "say: too many arguments" *inside the effect-runner thread*, killing
  it silently; every later effect (including `exit`) never runs and
  the run ends as a CLI-reported deadlock. Same provisional
  Haskell-error routing as `%b`/handle misses (§3.3/§7.3 unified error
  routing thread — this is another data point for it).
- **Verification**: Hello World deterministically over repeated runs;
  micro-programs `+++.` / `+++++---.` / `++[>+++++<-]>.` (10) /
  `++[>++[>+++<-]<-]>>.` (12, nested) / `++++++[>++++++++++<-]>+++++.`
  ('A'); unbounded-tape probes 30 cells right and 32 cells *left* of
  cell 0; `,`-containing program deadlocks as documented. `--parse`
  round-trip is a fixed point; full suite green (122 cases,
  randomized); zero new warnings (no Haskell changes).
- **Remaining threads**: unchanged from §13.11 (§11.3, §11.7, §11.9,
  §11.11, fresh-name generation, unified error routing — now with an
  extra data point, the effect-runner's silent death on `say` format
  errors).

### 13.13 Done — module import (§9, §6, §4, §12), branch `runtime/modules` (issue #17, part 1)

Takes the core of issue #17 — the `import` effect, suffix mangling,
hide lists, the `Nil → ""` preregistration, and the "add machines
during runtime" machinery — and leaves the Prelude/stdlib paragraph
and the error-reroute effect open (see "Next"). New modules:
`src/Lindana/Def.hs` (the lowered `MachineDef` + reserved bag names,
moved out of Machine so Import can sit between Loader and Machine
without a cycle) and `src/Lindana/Import.hs` (find/hide/mangle/lower
a module). The RTS gains the import machinery.

- **Syntax (provisional, flip-worthy)**: `import H S Hide` — an
  action with three /expressions/: the module-name handle, the
  namespace-suffix handle (both must evaluate to atoms naming
  bytestring side-table entries — module names are runtime data,
  per the issue's "a bytestring name to search"), and the hide list
  (a cons-list of atoms, `[]` for none). `import` is reserved.
  Renders `import H S Nil` and round-trips.
- **Search (provisional)**: the effect reads the handles' contents
  at effect time (a rebind between commit and run is honored) and
  loads `<moddir>/<name>.lind`, where @<moddir>@ is the new
  `Hooks` `hookModDir` (default `"."`; the CLI sets it to the main
  file's directory — `takeDirectory path`). The search name is
  /never/ suffixed — suffixed files don't exist; the suffix is
  purely an atom namespace. This matches the issue's "empty allowed,
  though… a bad idea": the empty suffix is spelled via the
  preregistered `Nil → ""` handle, and it means no namespacing.
- **Suffix mangling (`Lindana.Import.mangleProgram`)**: the module's
  effective suffix — ambient (the enclosing module's `machSfx`) plus
  the written one, so nesting propagates per the issue's "applies
  recursively to every import the imported module uses" — is
  appended (raw concatenation; the caller writes the separator) to
  every atom mentioned in the module's source: bag block names, atom
  patterns/expressions, `lob` targets, `bytesBind` handles. Two
  exemptions, both recorded: **`Nil`** (the cons-list spine sentinel
  of §11.5/§9 — mangling it would corrupt every string/list literal
  in the module; hazard: a module using `Nil` as ordinary data keeps
  it unsuffixed) and the **hide-list expression of a nested import**
  (it names the /target/ module's pre-mangle API). String/say-format
  literals are data, not atoms, and are not mangled — an
  `atomize "Foo"` inside a module names plain `Foo` (documented
  hazard). No other exemptions: `Error` mangles (the error verb
  routes at runtime instead, below) and `Global` mangles — a module
  therefore /cannot name the real front door/; it replies into
  whatever bag its caller passes as data. That's §4's continuation
  philosophy and §12's no-special-cases, but it is the biggest
  flip-worthy call of the slice: the obvious alternative is
  exempting `Global`.
- **Hide lists (`hideBags`)**: machines declared in the named bags
  are dropped before mangling (pre-mangle names — or the same with
  the suffix appended, for module-imports-module). Only machines:
  initial tuples still load, and `lob` can still create the bag as a
  machineless accumulator (§6.2).
- **Lowering**: `loadProgramWith errBag` (new, Loader) — the §6.4
  default Error machine's bag becomes a parameter. A module's
  default lands on its /mangled/ Error bag (`Error ++ suffix`),
  matching where the runtime routes its `error` calls: `interpretActions`
  now writes `(Error ++ sfx, …)` with the tag atom suffixed the same
  way, so a module's own `Error { … }` handler block (mangled like
  everything else) catches its own errors, and a module without one
  gets the fatal default on its private bag. Top-level behavior is
  byte-identical (`sfx == ""`).
- **Dynamic machines (the "adding more machines during runtime"
  bit)**: `import` interprets as a deferred effect plus a
  **pending-import slot**: `rtsLive` is bumped in-transaction, and
  the effect settles it (`+k` machines −1 on load, −1 on skip or
  failure). Without the slot, the run-alive check (`live == 0`)
  can fire while an import bundle is still queued — all startup
  machines may have died since it was committed (regression-tested).
  The effect outs the module's initial tuples, emits the
  **`(Imported, H, suffix)` completion tuple into `Global`** (the
  `(Bytes, H)` gate idiom; `H` is the handle as written in the
  import action — two imports through one handle are
  indistinguishable, documented hazard), spawns the module's machine
  threads, and records them in `rtsExtra` for shutdown cancellation
  alongside the startup threads.
- **Singletons**: `rtsMods` registers `(name, effective suffix)`
  pairs; a repeat import skips the load but still emits the
  completion tuple (consumers gate on it regardless). This also
  makes self- and mutual-import cycles terminate. Hazard: first
  import wins — a later hide list on an already-loaded pair is
  silent no-op.
- **Runner-safe failure**: import failure (missing file, parse
  error, load error, unknown handle, invalid UTF-8) is contained in
  the import effect: panic hook + `ExitFailure 1`, pending slot
  settled — the effect-runner thread does NOT die silently the way
  it does on a `say` format error (§13.12's tale; another argument
  for unified error routing, §3.3/§7.3).
- **`lob` takes an expression (provisional AST change, flip-worthy)**:
  `Lob Name Expr` → `Lob Expr Expr`. The target is usually an atom,
  but a lowercase variable is now legal — the bag name travels as
  data, which is what makes the module reply pattern possible at
  all. Must evaluate to an atom (action-layer check, §3.3).
- **`Nil → ""` preregistration**: `rtsBytes` starts with the entry;
  it is not special — `bytesBind Nil …` clobbers it,
  `bytesDestroy Nil` drops it (regression test updated: the entry
  survives unrelated destroys).
- **Deferred from the issue**: the error-reroute effect ("reroutes
  `error` calls for all the machines tracking a specific bag", last
  update wins — and the Accursed source/target-bucket variant) and
  the whole Prelude/stdlib paragraph (default import, pragmas-out,
  machines that preregister statics). Both need more design than
  this slice could carry honestly; see the PR's "Next".
- **Tests**: 16 new — Spec: import grammar (three expressions, the
  `Nil`/`[]` spelling, reserved-word check, round-trip) + mangler
  unit tests (atoms mangle; variables/strings/hide lists/`Nil` don't);
  ModuleSpec: e2e over `test/modules/*.lind` fixtures — load + mangled
  atoms meeting on both sides, one-shot-at-spawn witness, hide list,
  singleton repeat import (two completions, one spawn), missing
  module = runner-safe panic/exit 1, `Nil` preregistration, the
  pending-import shutdown race, recursive suffix propagation via a
  two-level module chain, and both mangled-error routings (module
  handler / fatal default). 138 total green, randomized order, 8×
  repeat stable. Zero `-Wall` warnings.
- **Examples**: `examples/imports.lind` + `examples/greeter.lind` —
  runtime load with suffix `_v2`, `(Imported, …)` gating, the
  reply-bag-as-data pattern; verified via CLI and `--parse`
  round-trip (both files fixed points).
- **Remaining threads (issue #17 part 2 + carried)**: the
  error-reroute effect; Prelude/stdlib (default import, pragma-out,
  static-preregistering machines); the issues this opens for #18
  (file descriptors will want the same dynamic-spawn machinery and
  probably a sister effect rerouting `say`'s target). Still open in
  §11: mixed int/double arithmetic (§11.3), effect-runner scope
  (§11.7), `die` vs `quit` (§11.9), bytestring reclamation (§11.11),
  fresh-name generation (§9), unified error routing (§3.3/§7.3 —
  import failure is now the strongest data point: it /can't/ afford
  the runner's silent death).

### 13.14 Done — error reroute (§6.4, §7, §12), branch `runtime/error-reroute` (issue #17, part 2)

Takes PR #19's first "Next" item: the error-reroute effect from issue
#17 — "reroutes `error` calls for all the machines tracking a specific
bag or all bags in the module (last update wins)". One new action, one
RTS table, no new module.

- **Syntax (provisional, flip-worthy)**: `reroute Src Tgt` — both
  arguments are bag names: a capitalized atom, or a lowercase variable
  holding a bag name as data (the same §13.13 `lob`-target extension).
  `reroute` is reserved; renders and round-trips. Both arguments
  mangle in modules (`Lindana.Import.mangleAction`), so a module can
  only reroute its OWN bags — its written `Error` is its own mangled
  error bag, and it cannot name the real top-level `Error`: consistent
  with §13.13's no-`Global`-exemption story.
- **The table**: `rtsReroute :: TVar (Map Name Name)` in the RTS.
  `reroute` interprets /in-transaction/ (no deferred effect — a plain
  STM write, like `lob`'s bag writes): the install commits atomically
  with the rerouting machine's match, so no error can be routed by a
  half-installed reroute, and a one-shot can emit a witness tuple in
  the same transaction that installs the reroute (the tests lean on
  this for race-free gating). "Last update wins" is `Map.insert`;
  reroutes from the same machine are strictly ordered; concurrent
  reroutes from different machines race like any other STM commit —
  the last committer wins (§3.1 chaos, documented not guarded).
- **Routing** (`errorTargetSTM` in "Lindana.Machine"): the `error`
  verb consults the table, in precedence order — (1) bag-specific:
  keyed by the raising machine's own bag; (2) module-wide: keyed by
  the machine's module's mangled Error bag (`Error ++ machSfx`) —
  every module machine's errors land there before any reroute, so
  rerouting that one name is "all bags in the module" (issue #17's
  words); at top level (sfx `""`) this key IS the plain Error bag, so
  a plain `reroute Error Log` catches every top-level machine; (3) the
  default: the machine's mangled Error bag (§13.13's routing,
  unchanged). Targets are NOT checked to exist — an unknown target is
  a §6.2 machineless accumulator (or a future module's bag): the
  Accursed point of the issue's "all you need is the source and target
  bucket".
- **Tag = provenance**: the tuple's leading atom stays the ORIGINAL
  mangled Error bag (`Error`, `Error_v2`, …) no matter where a reroute
  delivers it — a collector pattern keys on the tag ("an error from
  this module"), never on its own bag's name, and the tuple's shape is
  stable across reroute changes. `panic` is never rerouted (fatal, not
  a message). A module's own `Error { … }` handler is simply bypassed
  while its error stream is rerouted elsewhere (reroute is a runtime
  override — last update wins includes overriding a declared handler).
- **Provisional decisions made here (flip-worthy)**: the module-wide
  key being the mangled Error bag name (the obvious alternative:
  keying on the ambient suffix — but a suffix like `_v2` is not even
  spellable as an atom, and the Error-bag name already identifies the
  module's error stream); in-transaction install (vs a deferred
  effect through the FIFO runner, which would give a global total
  order on "last"); tag-as-provenance (vs tag = target bag); the
  bag-name/module-key collision hazard — a top-level bag literally
  named `Error ++ suffix` is caught by that module's module-wide
  reroutes too (lookup is bag-key first; deterministic, documented,
  not guarded). Recorded on the messageboard along with PR #19's
  pile: `agent-history/messageboard/provisional-error-reroute-semantics.txt`.
- **Deliberately deferred (the issue's Accursed aside)**: generalizing
  the reroute to arbitrary message streams (intercepting `out`/`lob`
  between buckets, not just `error`). Same table shape, much bigger
  blast radius — recorded as a FUTURE OPTION:
  `agent-history/messageboard/general-message-reroute-future.txt`.
- **Tests**: 16 new — Spec: grammar (two bag-name args, variables
  legal, reserved word, round-trip) + both args mangle; MachineSpec:
  bag-key reroute (target created on demand as a §6.2 accumulator,
  default Error bag never created), module-wide via `Error_v2`,
  top-level-wide via plain `Error`, last-update-wins (two reroutes in
  one transaction), tag = provenance in every tuple; ModuleSpec e2e
  over `test/modules/*.lind` (+ new `selfroute.lind` fixture): top
  level collects a module's errors (the §6.4 default on the mangled
  bag never fires), last-update-wins across the import boundary, and
  a module rerouting its own error stream from within — its written
  `reroute Error Tmp` installs `Error_v2 → Tmp_v2` and its own mangled
  `Tmp` handler catches the tuples. 150 total green, randomized
  order, 7× repeat stable. Zero `-Wall` warnings.
- **Examples**: `examples/reroute.lind` + `examples/flaky.lind` —
  import a failing module, reroute its whole error stream twice
  (second wins), collector keys on the `Error_v2` tag; verified via
  CLI (exit 0, no panic) and `--parse` round-trip (fixed point).
- **Remaining threads (issue #17 part 3 + carried)**: Prelude/stdlib
  (default import, pragma-out, static-preregistering machines) — needs
  its own design pass; for #18, the file-descriptor slice reuses the
  §13.13 dynamic-spawn machinery, and its "sister effect" (rerouting
  `say`'s target FD) mirrors this slice's table design. Still open in
  §11: mixed int/double arithmetic (§11.3), effect-runner scope
  (§11.7), `die` vs `quit` (§11.9), bytestring reclamation (§11.11),
  fresh-name generation (§9), unified error routing (§3.3/§7.3 —
  untouched here; the reroute repoints the *error verb's* destination
  bag, not the Haskell-level error path).

### 13.15 Done — the Prelude (§1, §6.4, §12, §13.13), branch `runtime/prelude` (issue #17 part 3)

Takes PR #21's first "Next" item — the Prelude/stdlib paragraph of
issue #17: "a Prelude is imported by default in the top-level file,
prefixless, including machines that preregister statics. But you can
pragma that away, explicitly import it, and hide whatever you want."
The design pass concluded: the prelude is a /builtin module/ — source
embedded in the RTS, loaded through the ordinary §13.13 import
machinery (no new effects, no new tables) — and the default import is
loader-owned program shape, exactly the §6.4-default-Error precedent.
New module: `src/Lindana/Prelude.hs` (a leaf: name + source + the
builtin registry; the import machinery does all the work).

- **The default import (provisional)**: `loadProgram` (top level
  only — `loadProgramWith`, which modules drive, is untouched)
  prepends a synthetic no-LHS one-shot `: import Prelude Nil []`
  (`preludeImportMachine`, exported for tests). The name handle
  `Prelude → "Prelude"` is preregistered in `rtsBytes` next to
  `Nil → ""` — neither entry is special, both clobberable/destroyable
  (hazard: `bytesDestroy Prelude` racing the default import machine's
  effect would fatal the run — astronomically unlikely, documented).
  The synthetic bare-style machine does NOT trip the §6 "bare machines
  + explicit Global" style check (that check runs on user decls
  first) — regression-tested.
- **Pragma (provisional, flip-worthy)**: `{-# no-prelude #-}` — new
  `Pragma String` Decl, top level only (the parser enforces; the
  loader's bag walk rejects it defensively for hand-built ASTs). The
  body is matched against the known pragmas; an unknown pragma is a
  loud parse error, never silently ignored (a typo'd pragma must not
  do nothing). Renders and round-trips.
- **Prelude content — one-shot preregistration machines only** (the
  design call of the slice): a looping service machine in the default
  import would keep EVERY program alive forever (the §1 loop keeping
  the run alive is the spec), so the default prelude contains only
  §1 empty-pattern one-shots that bind statics and die. Looping
  stdlib services belong in opt-in modules — recorded as future
  work, not implemented here. Content (provisional, tiny):
  `Newline → "\n"`, `Version → "0.1.0.0"` (kept in sync with
  `lindana.cabal` by hand — documented hazard). **One bag per static**
  — that is the hide list's granularity (`hideBags` hides bag blocks'
  machines). A deliberate `Error { }` block: the prelude's own
  lowering then installs no §6.4 default Error machine, and the plain
  Error bag stays owned by the top-level program's default (or user
  block) — without this, every program would carry two racing
  `(c!) : panic c` machines on Error (§3.1).
- **Customization story**: pragma out, then `import Prelude Nil […]`
  with a hide list (e2e-tested: hide `[Version]`, keep `Newline`).
  Without the pragma an explicit import is a harmless singleton
  repeat — first import wins, so a hide list there is silently
  ignored (consistent with the messageboard note; you cannot detect
  the intent at load time because module names are runtime data).
- **Builtins shadow disk (provisional)**: `importOnce` consults
  `Lindana.Prelude.builtinModules` before `hookModDir` — a user file
  named `Prelude.lind` is shadowed; the name is effectively reserved.
  (Flip: consult disk first.) Builtins are a plain constant, not a
  `Hooks` field — not injectable (flip-worthy; the tests exercise the
  mechanism via the pragma and hide lists instead).
- **Modules do not get the default** (the issue says "in the
  top-level file"): a module that wants the prelude imports it
  explicitly — `bytesBind SomeHandle "Prelude"` (the string literal
  is data, unmangled) then `import SomeHandle Sfx […]`; with the
  module's ambient suffix the prelude loads suffix-mangled
  (`Newline_v2`, …), consistent with §13.13's mangling rules. No
  special cases.
- **`Nil → ""` deliberately stays in the RTS (§13.13 unchanged)**:
  the empty-suffix spelling must work for pragma'd-out programs. Only
  the prelude's own name handle was added. (Flip-worthy: migrate
  `Nil → ""` into the prelude per the issue's wording — rejected here
  because it would make the prelude load-bearing for all imports.)
- **Found by this slice — §13.13 bug fixed: the pending-import slot
  leaked on skip.** The documented contract is "−1 on skip or
  failure", but the repeat-import branch never settled the slot — a
  leaked `+1` makes the run-alive check (`live == 0`) never fire, so
  any program that both repeats an import and terminates by
  all-machines-done hung forever (invisible until now: the existing
  repeat-import tests all ended in `exit`). Fixed in `importOnce`'s
  skip branch; regression-tested with a program that relies on
  `live == 0` (no exit path).
- **Tests**: 10 new — Spec: pragma grammar (parse at top level,
  after other decls, unknown pragma = parse error, bag-block pragma =
  parse error, round-trip); LoaderSpec: the synthetic machine's shape
  and position, pragma suppression, and five e2e runs (statics bound
  by default, pragma + explicit import with hide list, singleton
  repeat, the pending-slot regression, `bytesDestroy`-survivors list
  updated for the second preregistered entry). 160 total green,
  randomized order, 3× repeat stable, sub-second suite. Zero `-Wall`
  warnings.
- **Examples**: `examples/prelude.lind` (default import: gate on both
  `(Bytes, …)` completion tuples, `%b` the statics) and
  `examples/no-prelude.lind` (pragma + explicit import with hide
  list); verified via CLI (exit 0) and `--parse` round-trip (fixed
  point). All pre-existing examples re-verified (the three exit-1
  demonstration programs exit 1 on main too — no regression).
- **Remaining threads (issue #17 + carried)**: the issue's basic-
  stdlib ambition continues as OPT-IN modules (looping services,
  collection machines — anything that would keep a default-on program
  alive must never be default); for #18, file descriptors reuse the
  §13.13 dynamic-spawn + pending-slot machinery. Flip-worthy pile
  from this slice is on the messageboard
  (`provisional-prelude-semantics.txt`): one-shots-only default, one-
  bag-per-static, the prelude's `Error { }`, builtin-shadows-disk,
  non-injectable builtins, the `Prelude` handle/name collision
  hazard, flat-name collision of prelude bags with user bags, and
  the `Error`-clobbering-semantics question from the issue (still
  open — the prelude deliberately does not touch §6.4's clobbering
  rules). Still open in §11: mixed int/double arithmetic (§11.3),
  effect-runner scope (§11.7), `die` vs `quit` (§11.9), bytestring
  reclamation (§11.11), fresh-name generation (§9), unified error
  routing (§3.3/§7.3) — untouched here.

### 13.16 Done — ordering comparisons (§4, §9, §11.3), branch `runtime/comparisons` (issue #24)

Takes issue #24 as a sidebar slice: `<`, `>`, `<=`, `>=` join
`==`/`!=`, plus the issue's bytestring "enriched versions" and its
atom rulings. One new builtin; no new tables or effects.

- **Operators (provisional, flip-worthy)**: `Lt | Gt | Le | Ge` in
  `Op`; `renderOp` emits the four symbols. **C-style precedence**:
  the parser gains a level — ordering binds tighter than equality,
  additive tighter than both, multiplicative tightest (all
  left-associative). The renderer parenthesises every `EBin`
  regardless, so renders round-trip (tested with mixed
  `a >= 1 == b`, `a > b < 3` chains).
- **Semantics (the issue's rulings, implemented)**: ordering is
  **numeric-only, same-kind** — `VInt` vs `VInt` and `VDouble` vs
  `VDouble` (returning `1`/`0`, VInt for ints / VDouble for doubles
  consistent with the existing `Eq`/`Neq` equations). Atoms order
  /nowhere/: the issue says atom equality (hence inequality) is
  well-defined, and an atom never orders against a number — the
  provisional extension is that atom-vs-atom `<` etc. is /also/ an
  error (the issue's wording grants atoms only `==`/`!=`; content
  ordering is what `bytesCompare` is for). All rejections are the
  usual provisional Haskell errors that abort the machine's
  transaction (§3.3 routing; now with a sharper message: "atoms
  support only ==/!=, issue #24").
- **Mixed int/double ordering**: strict, like mixed arithmetic —
  an error, not a promotion. §11.3 (mixed int/double arithmetic,
  still open) is adjacent but untouched: whatever it resolves to
  would naturally extend to comparisons. Flip-worthy alongside it.
- **`bytesCompare(A, B)`** (§9, the issue's "enriched versions for
  ByteStrings — lexicographic ordering where appropriate"): one
  builtin, not four predicates — lexicographic /bytewise/ ordering
  of the side-table CONTENTS, returning `VInt -1`/`0`/`1`, from
  which `< <= > >=` derive by comparing against 0 (the e2e test
  derives exactly that way). Bytewise on UTF-8 == codepoint order,
  so this is the natural string ordering. `==` on handles stays
  pure atom identity (§9 unchanged) — reaching into the side-table
  is a verb's job, same split as `bytesEqual`. Missing handle:
  provisional error, same routing as `bytesEqual`.
- **Found while writing `examples/sort.lind` — reserved words are
  legal-looking variable names and die with the generic megaparsec
  error**: `(B, [a, b | t], swaps, out) : …` fails with "unexpected
  '(' expecting end of input or newline" because `out` is the verb
  (rword). The rejection is correct; the diagnosis cost a bisect.
  Another data point for §13.10's house-wide parser-error-message
  thread (surfacing real messages via `label`/`withLastError`-
  style plumbing would be its own slice). The example now uses
  `built`.
- **Tests**: 12 new — Spec: the four ops parse, both precedence
  rules, round-trip, `bytesCompare` grammar; RuntimeSpec: numeric
  ordering eval (int + double), atom-vs-atom and atom-vs-number
  ordering throw; MachineSpec: comparisons drive branches e2e,
  mixed int/double / atom-vs-atom / atom-vs-number transaction
  aborts, `bytesCompare` lexicographic (less/equal/greater incl.
  same-bytes-distinct-handles), unbound-handle abort; LoaderSpec
  e2e: `bytesCompare(A, B) < 0` gating, `2 + 2 >= 4`, exit-code
  steering. 175 total green, randomized order, 3× repeat stable.
  Zero `-Wall` warnings.
- **Example**: `examples/sort.lind` — a bubble sort as pure
  machines: each pass bubbles once counting swaps (`<=` decides
  every swap), a generic `Rev` straightens the cons-built output,
  zero-swap passes (base case in an `if` body, per the §13.12
  race lesson — a competing pattern would race) recurse via
  `(Sort, acc)`; plus a `bytesCompare` lexicographic demo gating
  the sort's start (deterministic output; `apple < apricot`, then
  1–9, `sorted.`, exit 0). Verified via CLI (5× identical output)
  and `--parse` round-trip (fixed point; the rendered form still
  runs).
- **Remaining threads**: unchanged from §13.15 — §11.3 (mixed
  arithmetic; comparisons recorded as flip-worthy alongside),
  §11.7, §11.9, §11.11, fresh-name generation, unified error
  routing (the new ordering-abort messages are the same provisional
  Haskell-error family), and the parser-error-message plumbing
  (new data point above).

### 13.17 Done — file descriptors (§9, §7.2, §12), branch `runtime/file-fds` (issue #18, part 1)

Takes the shared "Next" item of PRs #23 and #25: issue #18's core —
the file-handle table, open/close/read/write effects, data pushed and
pulled through the §9 bytestring side-table. Part 1 of three: std
fds + `say` repurposed + the say-FD reroute sister effect are part 2;
`bytesNew` fresh-handle generation is part 3 (both recorded in
"Next").

- **New RTS table**: `rtsFds :: TVar (Map Name FdState)` — the
  bytestring side-table's design: opaque atom handle → open OS
  handle + mode. To the matcher a handle is just an atom; only the
  `f*` verbs reach in. Empty at start (the issue's
  `Stdin`/`Stdout`/`Stderr` preregistration is the next slice —
  nothing std is in the table yet).
- **Syntax (provisional, flip-worthy)**: `fopen H Path Mode` — @H@ is
  a compile-time-chosen atom handle (mangled, the `bytesBind`
  precedent), @Path@ an expression evaluating to a casual string
  (data, never mangled), @Mode@ an expression that must evaluate to
  the atom `R` or `W` (`W` truncates; the mode position is exempt
  from mangling — a runtime-checked keyword, the hide-list
  precedent). `fclose e` / `fread e` / `fwrite H S` take the handle
  as an /expression/: fds travel as data, so a module can write
  through a caller-passed fd (the §13.13 bag-name-as-data pattern).
  All four verbs reserved; render and round-trip.
- **Data via the side-table (the issue's "data via Lindana-bytestrings")**:
  `fread H` pulls the entire remaining content through a read-mode
  handle and registers it in `rtsBytes` under the /same/ handle
  (clobbering — `say %b H` reads it back), emitting `(Fread, H)` into
  `Global`. `fwrite H S` writes the bytes named by side-table handle
  @S@ through write-mode handle @H@ (flushed), emitting `(Fwrote, H)`.
  All completion tuples into `Global` — the `(Bytes, H)` gate idiom.
- **Spent read fds**: strict `BS.hGetContents` closes the OS handle as
  it reads, so a successful `fread` SPENDS the read fd (`FdState`'s
  `fdSpent`); further `fread`s honestly return the empty remainder
  (clobber `""` + re-emit the gate tuple). `fclose` on a spent handle
  is a harmless no-op; `fclose` of an unknown handle is a no-op
  (idempotent, the `bytesDestroy` precedent).
- **Re-fopen closes the old handle**: last `fopen` on a name wins, and
  the superseded OS handle is /closed/ first — found by the tests:
  GHC's per-Handle locking makes a leaked handle keep the file locked
  (ResourceBusy on reopen); the silent-leak alternative was
  un-reopenable files. Provisional; "second fopen fails loudly" is
  the recorded flip.
- **Runner-safe fatals** (§13.13 import precedent): missing file,
  wrong-mode read/write, unknown fd/source handles → panic hook +
  exit 1, never silent runner death. No pending-live-count slots
  (FDs spawn no machines; the graceful effect-runner drain runs every
  queued bundle before a run returns — a queued `fwrite` after the
  last machine dies still lands).
- **Mangling**: the `fopen` handle mangles; the path string literal
  and the mode position do not (mode is a runtime-checked keyword —
  the hide-list precedent); `fclose`/`fread`/`fwrite` argument atoms
  mangle like any mention. A module can open its own paths but can
  only operate on ITS handles — caller-passed fds arrive as data.
- **Deliberately deferred (issue #18's remaining parts)**: std fds +
  `say` no longer magic + the say-FD reroute sister effect (§13.14's
  table is the design sketch); fresh-handle generation for a dynamic
  `bytesNew` (the "anonymous strings during runtime" paragraph, which
  wants fresh-name generation — still open in §11). Recorded as FUTURE
  OPTION in `agent-history/messageboard/provisional-file-fd-semantics.txt`
  alongside eleven flip-worthy calls of this slice (R/W-only, mode
  exempt from mangling, declaration-vs-data handle split, close-on-
  refopen, spent-fd semantics, same-handle dual-table, runner-safe
  fatals vs error routing, CWD-relative paths, no pending slots, std
  fds deferred, same-file interleave hazard).
- **Tests**: 22 new — Spec: fd grammar (fopen three-part, expression
  handles, reserved words, round-trip, mangling incl. the mode
  exemption); MachineSpec: write/read round-trip incl. UTF-8 bytes,
  gate tuples, the spent-fd second fread, five runner-safe fatal
  cases, fclose idempotence, fd-as-data variables, last-fopen-wins;
  ModuleSpec e2e: a module fwrites through a caller-passed fd
  (fd-as-data across the import boundary; the module's fwrite
  mentions only variables). 193 total green, randomized order, 3×
  repeat stable. Zero `-Wall` warnings (a pre-existing
  `-Wmissing-fields` in MachineSpec's `captureHooks` — present on
  main — fixed in passing with `hookModDir = "."`; `directory` and
  `bytestring` added to the test-suite deps, both boot packages).
- **Examples**: `examples/files.lind` — fopen W, bytesBind, fwrite,
  fclose, reopen R, two freads (the second shows the spent-fd empty
  remainder); verified via CLI (exit 0, deterministic output) and
  `--parse` round-trip (fixed point; the rendered desugared form
  also runs). All pre-existing examples re-verified (the three
  deadlock-demonstration programs still exit 1).
- **Remaining threads (issue #18 parts 2–3 + carried)**: std fds
  (`Stdin`/`Stdout`/`Stderr` preregistered at start), `say` as
  `lob`-over-fds + its reroute sister effect; `bytesNew` fresh-name
  generation (§11.11 adjacency). Still open in §11: mixed
  int/double arithmetic (§11.3), effect-runner scope (§11.7),
  `die` vs `quit` (§11.9), bytestring reclamation (§11.11),
  fresh-name generation, unified error routing (FD failures are now
  the second strongest data point after import failure),
  parser-error-message plumbing.

### 13.18 Done — std fds + un-magicked `say` + `sayfd` (§7.2, §9, §12), branch `runtime/std-fds` (issue #18, part 2)

Takes issue #18's part 2 (the shared "Next" of PRs #25/#27): the
`Stdin`/`Stdout`/`Stderr` preregistration, `say` no longer magic —
it writes through the fd table like any `fwrite` — and the say-FD
reroute sister effect, §13.14's table design applied to `say`'s
output. One new table (`rtsSayFd`), one new action (`sayfd`), the
`Hooks` shape changed (the `say` callback is gone); no new modules.

- **Std fds preregistered**: `Stdin` (read mode, LINE mode),
  `Stdout`, `Stderr` (write mode) land in `rtsFds` at RTS start —
  ordinary fd-table entries, issue #18's words: nothing std is
  special. Last `fopen` on the name wins (closing the std OS handle
  first), `fclose Stdout` makes every later `say`/`fwrite Stdout` an
  honest runner-safe fatal, `bytesBind` can clobber a read line.
  Tested: say fatals after fclose Stdout; freads fatal after fclose
  Stdin.
- **`say` un-magicked**: `EffSay` now carries the fd it writes
  through, resolved IN-TRANSACTION by `sayTargetSTM` (the §13.14
  reroute semantics — a `sayfd` earlier in the same action list is
  honored, the routed fd travels with the deferred bundle, and a
  concurrent sayfd from another machine is §3.1 commit chaos). At
  effect time the formatted line (`formatSay` unchanged, plus its
  newline) is `BS.hPut` + `hFlush` through the fd table — the
  `fwrite` path. Unknown fd / wrong mode: runner-safe fatal (§13.17
  precedent). `fwrite Stdout S` is now the natural endgame the
  §13.17 messageboard pointed at; say and fwrite share one byte
  stream, in bundle order (tested).
- **Blocking reads available (the carried §13.17 open question,
  resolved toward blocking)**: `fread Stdin` BLOCKS FOR A LINE —
  `BS.hGetLine` on the line-mode fd (`FdState`'s new `fdLine`).
  EOF reads as the honest empty remainder (the spent-fd shape:
  clobber `""` + emit the `(Fread, Stdin)` gate); the fd is never
  spent by a line read and stays EOF after. Tested: three gated
  reads over `"alpha\nbeta"` (no trailing newline — the partial
  last line is delivered) deliver alpha, beta, "". The cost: a
  blocked read parks the GLOBAL effect runner (§11.7) — every other
  queued effect waits behind it; recorded on the messageboard as
  unifying with §11.7's open runner-scope question, not a new
  hazard class.
- **`sayfd Bag Fd`** — the say-FD reroute sister effect (issue #18's
  words), §13.14's design with a different table
  (`rtsSayFd :: TVar (Map Name Name)`): bag-specific key (the
  machine's own bag), then module-wide key = the module's mangled
  Error bag (`Error ++ sfx` — the only per-module name a module's
  source can spell; at top level this key IS plain `Error`, so
  `sayfd Error F` catches every top-level machine's says), then
  default `Stdout`. In-transaction install, last update wins
  (strictly ordered within one machine's action list — tested).
  Targets are NOT checked against the fd table (the reroute
  precedent): the §6.2 accumulator story — the say effect fatals
  honestly at run time if the fd never appears (tested). Reserved;
  renders and round-trips; both arguments mangle in modules (a
  module can only sayfd its OWN bags; it reaches real fds as data —
  e2e-tested with the `sayfdmod.lind` fixture, the fdwriter
  fd-as-data pattern with sayfd standing in for fwrite).
- **Hooks changed**: `hookSay` is GONE — with say un-magicked there
  is no say callback; tests inject the std HANDLES
  (`hookStdin`/`hookStdout`/`hookStderr`) the std fds are
  preregistered with (capture = a scratch temp file read back after
  the run). `hookPanic` stays a callback (panic is fatal, never
  routed, §13.14). The std fds are preregistered binary
  (`hSetBinaryMode` on the hooked handles): say/fwrite write UTF-8
  bytes regardless of locale. Test-visible consequence, recorded on
  the messageboard: a capture now sees the fd's BYTE stream, where
  a say's trailing newline is the only separator — two pre-existing
  expectations (a %s with an embedded newline, the prelude's "nl"
  test) updated for exactly this reason; `fwrite` stays byte-exact.
- **Messageboard**: `provisional-std-fd-semantics.txt` — eleven
  flip-worthy calls (the `sayfd` spelling, the mangled-Error-bag
  module-wide key, unrouted-fd targets not checked, in-transaction
  fd resolution, say's trailing newline, blocking-line reads vs
  read-available, same-handle dual-table clobber, the §11.7 runner
  parking cost, std fds being uncloseable-by-default-less (they
  ARE closeable), hooks-as-Handles, binary preregistration).
- **Tests**: 15 new — Spec: sayfd grammar (two bag-name args,
  variables legal, reserved word, round-trip, both args mangle).
  MachineSpec: say/fwrite share Stdout in bundle order, fwrite
  Stderr through its fd, the blocked-line Stdin reads + EOF, sayfd
  bag-specific tier (gate lobbed into the routed bag), sayfd
  module-wide tier via `Error_v2` (machSfx-carrying MachineDef),
  last-update-wins, the unroutable-fd fatal, fclose Stdout/Stdin
  honesty. ModuleSpec e2e: a module reroutes its own say stream to
  a caller-passed fd. 208 total green, randomized order, 3× repeat
  stable, zero `-Wall` warnings.
- **Examples**: `examples/stdio.lind` (+ `stdio-input.txt`,
  `stdio-out.tmp` gitignored) — writes through `Stdout`, blocks on
  a piped `fread Stdin` line, `sayfd`-reroutes `Global`'s stream
  into a file and back (last update wins); verified via CLI
  (`stack exec lindana -- examples/stdio.lind <
  examples/stdio-input.txt`, exit 0, deterministic output) and
  `--parse` round-trip (fixed point; the rendered desugared form
  also runs). All pre-existing examples re-verified (the three
  non-standalone demos still exit 1 when run directly).
- **Remaining threads (issue #18 part 3 + carried)**: `bytesNew`
  fresh-name generation (§11.11 adjacency; the issue's inline
  auto-promotion sugar is the stretch goal); append mode `A`
  (messageboard flip #1 of §13.17); unified error routing (§3.3/
  §7.3 — FD failures and now say-through-dead-fd are the strongest
  data points). Still open in §11: mixed int/double arithmetic
  (§11.3), effect-runner scope (§11.7 — sharpened by the blocked-
  read parking cost), `die` vs `quit` (§11.9), bytestring
  reclamation (§11.11), fresh-name generation, parser-error-message
  plumbing (sayfd joins the reserved-word pile).

### 13.19 Done — README cleanup (issue #30), branch `docs/readme-cleanup`

- The README had grown into a second source-of-truth: a module-by-module Layout section and a giant Grammar-status run-on duplicated the handover's job and needed updating every slice. Per the issue, the README is no longer a source-of-truth — the human wants to handwrite a fresh one on the blank slate.
- **What moved**: the Layout section (module map + examples inventory) and the Grammar status section (implemented/not-yet/provisional inventory) left `README.md` and landed in `agent-history/readme-status.md` as a **frozen snapshot as of §13.18** — deliberately not maintained going forward; the handover's §13 stays the live record. One copy-paste artifact fixed in passing (a duplicated prelude sentence in the §13.15 entry).
- **What stayed**: the pitch + pointer to the handover, the handwritten part ("AI?", "Contributing?", the baby-agent section) verbatim, and the two usage how-tos (Building, parser-in-ghci). Everything else is gone — deliberately small; expect the handwritten rewrite to replace all of it.
- No code changes; docs-only slice. Full test suite green, zero `-Wall` warnings, no new examples (nothing to verify via CLI beyond the suite).
- **Next**: nothing opened. When the handwritten README lands, `agent-history/readme-status.md` can be deleted or left to rot — it is a freeze, not a pointer.

### 13.20 Done — model-maintained language reference (issue #33), branch `docs/language-reference`

Takes issue #33: a reference that tracks the *actual* state of the language/runtime — not the handover's history-plus-hazards shape, and deliberately **not** a ledger of every flip option or loose end (the issue says so explicitly; §12/§13 stay the home for those).

- **The doc**: `REFERENCE.md` at the repo root. Fifteen short sections: CLI/running, program structure, values (atoms/ints/doubles/tuples + the list/string/char sugar table), patterns & matching (join patterns, rest capture, repeated-var equality, rd/take, commitment, racing), machines (loop-by-default, one-shots, two-phase execution), a full **verb table** (all 17 actions incl. `sayfd`/`reroute`/`f*`/`import`), expressions & precedence & builtins, bags, errors (`error`/`panic`/default-Error-machine/`reroute` + the provisional hard-failure routing stated plainly), modules & import (mangling exemptions as shipped), bytestrings, files & I/O (std fds, un-magicked `say`, `sayfd`), the Prelude, **the gate-tuple convention as a table** (`(Bytes, H)`, `(Fopen/Fread/Fwrote, H)`, `(Imported, H, S)`), the throttling idiom, and the reserved-word list (lifted verbatim from `reservedWords` in Parser.hs).
- **Ground-truthing method** (so future slices can repeat it): every claim was checked against the implementation, not just against §13 — the AST/action shapes against `Syntax.hs`, the verb/keyword/reserved-word list against `Parser.hs` (`reservedWords`, `callP`, the `rword` tables), builtin semantics against `rtsBuiltin`/`formatSay`/`truthy` in Machine.hs/Runtime.hs, precedence against the `exprP` chain, and the §13.13–§13.18 behavior (mangling exemptions, gate tuples, spent-fd/EOF shapes, singleton imports, prelude statics) against those sections. Notable accretions the prose sections had left implicit, now stated in one place: `say`'s full specifier set (`%i %s %a %b %%`) and its error cases; `rand` of non-positive = `0`; `exitCodeOf`'s mod-256 rule; `fopen` emitting `(Fopen, H)`; `rand`'s deterministic seed making runs reproducible.
- **Maintenance posture** (the issue's "continually track"): the doc header states the contract — it tracks actual current behavior; where it and the handover disagree about *current* behavior, the doc is the one checked against code. It is expected to be updated in the same PR as any slice that changes user-visible behavior (same rule as the handover/README updates, per AGENTS.md). Flip-worthy alternatives and open questions stay out by design; §11/§13 remain the record of those.
- No code changes; docs-only slice. Full test suite green (208 cases), zero `-Wall` warnings, no new examples (nothing to verify via CLI beyond re-reading the doc against the sources; the doc contains no syntax not already exercised by the examples).
- **Next**: nothing opened. The reference is the source for the human's handwritten intro doc (the issue's stated purpose). If a slice lands whose behavior the reference describes, update the reference in that slice's PR.

### 13.21 Side experiment — `sleep` semantics, a tagged-error defer protocol, and the shutdown hazard it exposed (`agent-history/messageboard/sleep-experiment/`)

A sidebar during the post-audit discussion of `examples/bags.lind`'s
error-handler message: a tagged error handler `(Error, Demo, (s, n))`
racing a catchall `(Error, rest!)`, where the catchall puts
Demo-tagged tuples back and naps so the specialist can win the
re-grab. Experiment record + three runnable artifacts live in
`agent-history/messageboard/sleep-experiment/` (`README.txt` is the
writeup; nothing here is committed language behavior). Directly
relevant to the PR #29 comment on fd modelling and race-vs-
synchronize strategy, and to flip #8 of
`provisional-std-fd-semantics.txt`. Four findings:

- **`sleep` cannot delay a machine** (finding 1): it compiles to an
  `EffSleep` executed by the single global effect runner
  (`threadDelay` in `runBundle`); the machine re-arms the instant its
  transaction commits. "Push back and sleep" is a busy livelock
  (`defer-livelock.lind`); sleepsort degenerates to queue order
  (`sleepsort-not.lind`). **Sleepsort is the acceptance test for any
  §11.7 flip**: if a per-machine/per-bag runner design can't make
  that file print `1 1 3 4 5`, it didn't fix `sleep`. The working
  primitive for a real delay is the gate-tuple idiom: the runner
  emits `(Bytes, H)` after its own post-`sleep` work, so blocking on
  that gate genuinely waits.
- **Rest capture is lossy on unspliced re-emit** (finding 2): `r!`
  always binds a tuple (a one-element capture is a 1-tuple), so
  re-emitting `r` plain nests the payload one 1-tuple layer per
  round-trip — the defer loop silently mutated the tuple until the
  specialist's pattern could never match again (it looked like a
  scheduling race; found by instrumenting the runtime and watching
  the parens compound in bag dumps). Capture-then-splice is identity;
  capture-then-plain-emit wraps. Candidate REFERENCE.md sentence
  wherever §11.1 rest capture is documented.
- **The working defer protocol** (finding 3, `tagged-error-defer.lind`):
  the head-of-rest check happens one delegation deep (a `HeadCheck`
  one-shot binds the head via a nested pattern, guards with
  `typeOf(h) == Atom` — `==` on lists is a type error — then compares
  the atom in-block); the nap is a token discipline — the catchall
  consumes an `(CatchallArmed,)` token per grab and is re-armed by a
  `(Bytes, Nap)` completion relay — because sleep can't do it.
  Deterministic across runs.
- **Hot machines own the bag** (finding 4): a parked machine never
  won a contested re-grab against an already-running loop (hundreds
  of rounds, zero wins, across declaration orders). Fine for this
  protocol (deferring again is progress), but nothing should be
  designed to need a parked machine to win a re-grab until §3.1 has
  a priority story.

- **Shutdown hazard found on the way** (finding 5): programs with no
  `Error` block, no `exit`, and all machines ending in `die`
  false-deadlock (exit 1) — the default §6.4 Error machine is an
  immortal parked thread keeping `rtsLive` above zero until the RTS
  aborts. Repro: the minimal all-die shape `{ (Tick,) } … [say "hi";
  die]` — `sleepsort-not.lind` sported it too in its first version
  (a control with an explicit `Error { }` exits cleanly); candidate
  fixes and the full autopsy in the README. Filed as §11.12.

- No code changes; experiment + docs only. All three artifacts
  verified by CLI (parse + run, behaviors as documented in their
  headers); full test suite green (208 cases) before and after —
  the temporary runtime instrumentation used to diagnose finding 2
  was reverted (working tree: `git checkout src/Lindana/Machine.hs`)
  and the suite re-run.
- **Next**: the §11.12 shutdown hazard is the most actionable thread
  (small runtime slice: exempt or lazily-spawn the default Error
  machine, plus a regression test of the `{ (Tick,) } … [die]` shape);
  the §11.7 flip (per-machine/per-bag runners) is the big one, with
  sleepsort as its acceptance test; the finding-2 sentence for
  REFERENCE.md rides along with whichever slice next touches rest
  capture or the reference.

### 13.22 Done — idle-exempt default Error machine (§11.12), branch `runtime/idle-shutdown`

Closes the shutdown hazard opened by §13.21/§11.12: a program with no
`Error` block, no `exit`, and all machines ending in `die` reported
the §1 deadlock message (exit 1) instead of ending cleanly — the
default §6.4 Error machine parked forever, `rtsLive` never reached 0,
and the RTS aborted with `BlockedIndefinitelyOnSTM`.

- **`machIdle` on `MachineDef`** (Lindana.Def): idle-exempt machines
  do not keep the run alive. Only the loader's synthetic default
  Error machine sets it (top level and via `lowerModule` for
  modules); every user machine and the §13.15 prelude-import one-shot
  are non-idle.
- **Live accounting** (Lindana.Machine): `runLoaded` initializes
  `rtsLive` to the non-idle count; `machineThread`'s `finally`
  decrements only for non-idle machines; `installModule` credits
  `+(k′ − 1)` where `k′` counts non-idle module machines (the −1
  still settles the §13.13 pending-import slot — the §13.15
  leaked-slot shape would resurface otherwise).
- **The drain guard**: exempting the default machine alone would let
  shutdown cancel it while an error tuple sits unclaimed — silently
  dropping the §6.4 guaranteed panic (the dying machine's `decLive`
  and the parked default's grab are disjoint STM transactions; a
  pure live-count fix is genuinely racy). The run-alive check now
  also reads the idle machines' bags and waits until they are empty
  before proceeding: the parked machine's grab is already woken by
  the tuple write, the grab empties the bag, the panic bundle sets
  `rtsExit`, and the check passes on either arm. Deterministic both
  ways: clean exit when nothing is pending, guaranteed panic when an
  error tuple arrived.
- **Tests**: MachineSpec gains a loader-driven "shutdown (§11.12)"
  block — the all-die/no-Error-block shape now ends `ExitSuccess`
  (it timed out before the fix), and the one-shot `error` shape still
  panics with `ExitFailure 1` (hook fired, exit preserved). A panic
  message renders its payload structurally (codepoint cons-list), so
  the test asserts on the hook firing, not a payload substring — the
  §13.12/§13.18 render story, learned the hard way. ModuleSpec gains
  the module path via the new `test/modules/quiet.lind` fixture
  (one-shot `die`, no Error block: its imported default machine must
  not keep the run alive — this timed out before the fix).
- Full test suite green (211 cases, randomized order), zero `-Wall`
  warnings. CLI verified: the C1 repro (`{ (Tick,) } … [say "hi"; die]`)
  exits 0; `sleepsort-not.lind` now exits 0 (its false-deadlock arm
  is gone — it still prints one number, which is the §11.7
  sleep-serialization story, untouched here); `examples/throttle.lind`
  still reports its genuine deadlock, exit 1.
- **Next**: the §11.7 runner-scope flip remains the big open thread
  (sleepsort acceptance test per §13.21); the REFERENCE.md
  rest-capture sentence from §13.21's finding 2 still rides along
  with a future reference touch; `Main.hs`'s deadlock message could
  now mention the all-die shutdown shape if a docs pass wants it.
