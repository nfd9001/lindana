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
- **Lists**: **no new primitive type.** **Provisionally resolved** (§13.7, branch `parser/list-cons-sugar`): cons-lists — nested 2-tuples terminated by the `Nil` atom — with parse-time sugar: `[a, b, c]` → `(a, (b, (c, Nil)))`, `[h | t]` conses onto an arbitrary tail expression/pattern, `[]` → `Nil`; multi-head forms (`[a, b | t]`) likewise. Purely syntactic — no AST nodes, so the pretty-printer renders the desugared tuple form (which round-trips). `Nil` is *not* a reserved word (a program may still use it as an ordinary atom; doing so makes list literals meaningless — documented hazard, flip-worthy).
- **Strings (casual)**: **no primitive type either.** Sugar over cons-lists of codepoint `Int`s, in the spirit of Haskell's `type String = [Char]` but with weaker guarantees (no static type system enforcing anything is really "chars"). Actions consuming a "string" (e.g. a print action) are responsible for checking it looks list-of-int-shaped and `error`-ing if not — same discipline as arithmetic (§3.3), no special-casing needed anywhere in the runtime. **Open**: is there a distinct `Char` type, or plain `Int`s all the way down with `"..."` purely as literal sugar and interpretation entirely up to whichever action consumes the value? Leaning toward the latter for consistency, but not confirmed.
- **Strings (real/UTF-8)**: since primitive strings were dropped, real string work goes through **opaque bytestring handles** rather than a first-class type. **Implemented** (§13.8, branch `runtime/bytestring-side-table`):
  - `bytesBind Handle codepoint-list` registers the UTF-8 encoding under the (compile-time-chosen) atom handle; the effect runner emits a **`(Bytes, H)` completion tuple into `Global`** when the side-table write lands — the deterministic gate consumers join on (binds are deferred effects, §7.2). This is also the return path a future dynamic `bytesNew` would need (fresh-name generation: still open).
  - The side-table is `rtsBytes :: TVar (Map Name ByteString)` on the RTS. To the matcher a handle is just an ordinary atom — no special case in matching logic.
  - **`==` stays pure atom identity, uniformly, everywhere** — now actually true: `Eq`/`Neq` on `VAtom` operands used to be a Haskell error; `arith` compares atom names (§3.3: comparing handles compares the handles, not the contents). `bytesEqual(a, b)` is the builtin that reaches into the side-table for real content comparison (missing handle = provisional Haskell error, §3.3 routing pending).
  - `say "%b"` formats a bytestring handle by decoding its bytes (unknown handle / invalid UTF-8 = provisional Haskell errors).
  - `bytesDestroy e` drops the entry (manual lifetime, "build your own GC"); lookup on a destroyed/unknown handle is the attempting action's problem — missing-key case, provisional Haskell error. The actual hazard is purely *logical liveness*, not memory unsafety.
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
4. **Char type vs. plain Ints** for string sugar — posed, not confirmed either way (§9).
5. **Exact list literal/pattern sugar syntax for cons-lists (§9)** — **provisionally resolved** (§13.7, branch `parser/list-cons-sugar`): `[a, b, c]` / `[h | t]` / `[]`, parse-time desugaring to nested 2-tuples with the `Nil` sentinel atom; no AST nodes; renderer emits the desugared form; `Nil` deliberately not reserved. Flip-worthy.
6. **Concrete effect-bundle syntax** for the reframed effect-runner model (§7) — the old bracket sketch was for the superseded STM-flavored idea and doesn't apply.
7. **Effect-runner scope**: one global runner, or multiple (e.g. per-bag)? (§7.3)
8. **Bytestring lifecycle vs. effect-runner**: do `create`/`destroy` route through the shared effect-runner, or use independent synchronization? (§7.3) — **provisionally resolved** (§13.8, branch `runtime/bytestring-side-table`): both route through the shared effect-runner as ordinary bundle effects (`EffBytesBind`/`EffBytesDestroy`); the side-table is a plain `TVar`, so bind/destroy are single STM writes from the runner, and a bind emits its `(Bytes, H)` completion tuple into `Global`. Flip-worthy if the global-runner serialization (§11.7) ever matters.
9. **`die` vs. `quit`** — used interchangeably in discussion; exact keyword not finalized.
10. **Top-level program grammar**: now that named bags exist, how do multiple `Name { ... }` blocks, `Global`'s implicit initial-tuple literal, and any other bag's initial state compose into one program's file-level syntax? Flagged early, never revisited. **Provisionally resolved** (§13.6, branch `runtime/named-bags-loader`): a `{ … }` initial block belongs to its nearest enclosing bag — top level is `Global`'s; at most one per bag; nothing else nests (a bag block may not contain another bag block, §6 — sharding is internal, §6.3).
11. **Bytestring reclamation** — explicitly punted for now (§9); revisit if it matters later.

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

