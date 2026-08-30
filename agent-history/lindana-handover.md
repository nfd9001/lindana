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
- **Concrete syntax** for declaring an effect bundle hasn't been written — the earlier bracket sketches were for the superseded STM-flavored `tx`, not this model.
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
- **Lists**: **no new primitive type.** Preference is cons-lists — nested 2-tuples, presumably terminated by a sentinel atom (e.g. `Nil`) — with syntactic sugar for literals and pattern destructuring (something in the shape of `[1,2,3]` / `[H|T]`). **Exact desugaring/sugar syntax not yet written.**
- **Strings (casual)**: **no primitive type either.** Sugar over cons-lists of codepoint `Int`s, in the spirit of Haskell's `type String = [Char]` but with weaker guarantees (no static type system enforcing anything is really "chars"). Actions consuming a "string" (e.g. a print action) are responsible for checking it looks list-of-int-shaped and `error`-ing if not — same discipline as arithmetic (§3.3), no special-casing needed anywhere in the runtime. **Open**: is there a distinct `Char` type, or plain `Int`s all the way down with `"..."` purely as literal sugar and interpretation entirely up to whichever action consumes the value? Leaning toward the latter for consistency, but not confirmed.
- **Strings (real/UTF-8)**: since primitive strings were dropped, real string work goes through **opaque bytestring handles** rather than a first-class type:
  - An effect converts a byte/int list into a UTF-8 bytestring and returns/binds an **Atom** handle.
  - The runtime holds the actual bytes in an internal side-table keyed by that atom (conceptually a map from atom to bytestring). To the matcher, a handle is just an ordinary atom — no special case needed in matching logic.
  - **`==` stays pure atom identity, uniformly, everywhere** — comparing two handles with `==` compares the handles, not the contents. A separate verb (e.g. `bytesEqual`) is the action responsible for reaching into the side-table and doing real content comparison. This keeps the "actions check, matcher doesn't" rule (§3.3) applied consistently rather than special-casing equality for one type.
  - **Bytestrings can be destroyed by an explicit effect** — deliberate manual lifetime management ("build your own GC"), left in as an intentional hazard. This is **not** real memory unsafety: the side-table is an ordinary Haskell map, so a lookup on a destroyed handle is just a missing-key case, which the attempting action is responsible for handling (via `error`, same as any other bad-input case). The actual hazard is purely *logical liveness* — is this atom still meaningful — not undefined behavior.
  - **Not yet addressed**: no automatic reclamation; entries otherwise leak for the process lifetime. Treated as a deliberate non-goal for now, not an oversight, but worth flagging if revisited.
  - See §6.4/§8 pattern: one-use, no-tuple machines are the proposed mechanism for binding a "static" bytestring to a compile-time-chosen atom name at program start.

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

1. **Pattern-side `!` rest-capture** — wanted, exact syntax not written (§4).
2. **Repeated variables within one pattern** — does `(a, a)` require equality between the two positions (Prolog-style), or is it a rebind/shadow? Raised, never resolved.
3. **Mixed int/double arithmetic** — auto-promote, or a type error via `error`? (§9)
4. **Char type vs. plain Ints** for string sugar — posed, not confirmed either way (§9).
5. **Exact list literal/pattern sugar syntax** for cons-lists (§9).
6. **Concrete effect-bundle syntax** for the reframed effect-runner model (§7) — the old bracket sketch was for the superseded STM-flavored idea and doesn't apply.
7. **Effect-runner scope**: one global runner, or multiple (e.g. per-bag)? (§7.3)
8. **Bytestring lifecycle vs. effect-runner**: do `create`/`destroy` route through the shared effect-runner, or use independent synchronization? (§7.3)
9. **`die` vs. `quit`** — used interchangeably in discussion; exact keyword not finalized.
10. **Top-level program grammar**: now that named bags exist, how do multiple `Name { ... }` blocks, `Global`'s implicit initial-tuple literal, and any other bag's initial state compose into one program's file-level syntax? Flagged early, never revisited.
11. **Bytestring reclamation** — explicitly punted for now (§9); revisit if it matters later.

---

## 12. Design philosophy, for whoever picks this up

A few threads run through essentially every decision made so far, worth keeping in mind for anything not yet settled:

- **New features are sugar over old ones wherever possible** — named bags are sugar over sharding; `error` is sugar over `lob`; lists/strings are sugar over tuples; Terse sequencing is sugar over Restricted machines and `!`. Prefer this shape for any new primitive under consideration.
- **One capitalized-identifier lexical class does triple duty**: atoms, type-tags, and bag names are all just capitalized identifiers, disambiguated purely by syntactic position. Consistent with this rather than introducing new lexical categories.
- **The matcher checks structure; actions check semantics.** Never move a semantic/type check into the matcher.
- **Chaos is opt-*out*, not opt-in.** Racing matches, cross-invocation `ACont` collisions, and manual bytestring lifetime bugs are all deliberate, inspectable, and left un-guarded by default — mitigations (named bags, effect bundles, throttling) exist as things a programmer reaches for, not defaults the runtime imposes.
