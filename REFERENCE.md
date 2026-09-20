# Lindana — Language Reference

This is a **model-maintained reference**: it tracks the *actual* state of
the language and runtime as implemented. It deliberately does not record
every open question, flip-worthy alternative, or loose end — for those,
see `agent-history/lindana-handover.md` (the spec-of-record) and its
§13 implementation notes. Where this document and the handover disagree
about *current* behavior, this document is the one that was checked
against the code and test suite.

Status as of handover §13.23.

---

## 1. Running a program

```sh
stack build
stack exec lindana -- examples/bags.lind    # run
stack exec lindana -- --parse file.lind     # parse + render (round-trip check)
```

- The process exit code is the program's `exit` value (`exit 0` = success;
  other values are taken mod 256 as failure codes). `panic` exits 1.
- `--parse` prints the parsed AST rendered back to source. The renderer
  outputs desugared forms (see §3), which reparse to an equal AST.
- If every machine is blocked on a match that never arrives, the run is
  reported as a deadlock: "every machine is blocked on a match that never
  arrives (a machine that would end in die still has to fire first); such
  programs need an exit path". Programs that end with all machines dead
  or `exit`ed terminate normally (the default Error machine does not
  count — idle-exempt machines never keep a run alive).

---

## 2. Program structure

A program is a sequence of top-level declarations:

| Declaration | Syntax | Meaning |
|---|---|---|
| Machine | `pat, pat : actions` | A machine (see §4–5), belonging to the enclosing bag (or `Global` at top level). |
| Initial block | `{ (Tick,), ("add", 1, 2, ...) }` | Tuples present in the bag when the program starts. Belongs to the nearest enclosing bag; at most one per bag. |
| Bag block | `Name { machines... }` | A named bag of machines (see §8). A bag's machines may be declared in exactly one place. Bag blocks do not nest. |
| Pragma | `{-# no-prelude #-}` | Top level only. The only known pragma suppresses the default Prelude import (§12). An unknown pragma is a parse error, never silently ignored. |

Style rule: either use bare top-level machines (implicit `Global`) or an
explicit `Global { ... }` block — not both. The loader rejects mixing.

Line-oriented: a newline at bracket depth 0 ends a machine declaration;
inside `(...)`, `[...]`, `{...}` newlines are ordinary whitespace. `--`
starts a line comment.

---

## 3. Values

There is no type system — only shapes. The matcher (§4) checks structure;
whichever action consumes a value checks its semantics.

| Value | Literals | Notes |
|---|---|---|
| Atom | `Foo`, `Add`, `Nil` | Capitalized identifier. Atoms are the universal tag: bag names, type names, handles. |
| Int | `42`, `-7` | System-width signed integer. |
| Double | `3.14` | Decimal literal. Ints and doubles do not cross-match in patterns, and mixed int/double arithmetic is an error. |
| Tuple | `(a, b, c)`, `(Tick,)`, `()` | Comma-separated; a 1-tuple needs the trailing comma (`(x)` is grouping). `()` is the empty tuple. |
| List | `[1, 2, 3]`, `[h \| t]`, `[]` | Pure sugar for nested 2-tuples ending in the atom `Nil`: `[a, b]` IS `(a, (b, Nil))`. Not a primitive type; `Nil` is an ordinary atom. |
| Casual string | `"hi"`, `"a\nb"` | Pure sugar for the cons-list of codepoint ints: `"hi"` IS `[104, 105]`. No string type exists. |
| Character | `'x'`, `'\n'`, `''` | Pure sugar for the single codepoint as an Int: `'a'` IS `97`. `''` IS `Nil`. Multiple codepoints in `'…'` are a parse error (that's what `"...\"` is for). Escapes: `\n`, `\t`, `\'`, `\\`. |
| Bytestring handle | an atom | An ordinary atom that names an entry in the runtime's bytestring side-table (§11). Opaque to the matcher. |
| File handle | an atom | An ordinary atom naming an entry in the fd table (§13). |

`typeOf(x)` reports the shape as an atom: `Int`, `Double`, `Atom`, or
`Tuple` (lists and casual strings report `Tuple` — their shape).

---

## 4. Patterns and matching

A machine's left-hand side is a comma-separated list of **join patterns**.
All patterns in the list match in one atomic transaction (all-or-nothing).

**Pattern elements**: a lowercase identifier is a *variable* (binds
anything); a capitalized identifier is an *atom* (matches that atom
exactly); int/double literals match numerically (no int/double
cross-match); tuples nest; lists/strings/chars in pattern position
desugar to their tuple/Int shapes and match structurally.

- **Repeated variables require equality**: `(a, a)` does not match `(3, 4)`.
- **Rest capture**: `x!` as the *last* element of a tuple pattern binds
  the remaining zero-or-more elements as a sub-tuple. `(c!)` matches any
  tuple. Trailing-only, variable-only. Note the capture always binds a
  tuple: re-emitting `rest!` (spliced) is the identity, but re-emitting
  `rest` bare wraps the value in a fresh 1-tuple per round-trip.
- **Read modes**: a bare pattern *takes* its tuple (consumes it — `in`).
  Prefix `rd ` to *read* without consuming (broadcast/fan-out: every
  interested machine can observe the same fact). Take-clauses in one join
  consume distinct tuples; a read-clause cannot match a tuple a
  take-clause consumed in the same join.
- **Matching is commitment**: once a pattern matches, the machine has
  committed to reacting — there are no guards and no rollback. A machine
  that conditionally declines re-emits the tuple as an action.
- **Racing is a feature**: if multiple machines can match a tuple, at
  most one gets it and which one is an honest race. No fairness
  guarantee.

---

## 5. Machines

```
pattern, rd pattern : action
pattern : [action; action; action]
```

- **Machines loop by default**: after acting, a machine re-arms and waits
  to match again.
- `die` (synonym `quit`) terminates the machine instead of looping.
  Remaining actions after a `die` in the same list are dropped.
- A machine with an **empty pattern** `()` ... — an LHS that is just an
  action, e.g. `bytesBind H "..."` — runs **once, unconditionally, at
  program start**, then terminates. There is no ordering guarantee
  relative to other machines; gate on a completion tuple when order
  matters (§14).
- `exit e` terminates the whole program with the evaluated code.
- `if cond then actions else actions` branches on truthiness (§7).
  Branches are action lists — one action renders bare, several as
  `[a; b]`. Multi-action sequences are sugar: they are run as the
  machine's action list, in order.
- **Two-phase execution**: tuple-space writes (`out`, `lob`, `error`)
  commit *atomically with the match*. Side-effecting verbs (`say`, file
  I/O, binds, imports, `sleep`) are deferred to a single effect-runner
  that drains them FIFO, one bundle at a time, in order. No rollback on
  partial bundle failure.

---

## 6. Actions (verbs)

| Verb | Form | Effect |
|---|---|---|
| (emit) | `("add", a, b, c)` | Push a tuple into the machine's **own** bag. A bare tuple is the default action. |
| `lob` | `lob Bag ("msg", x)` | Push a tuple into the named bag — the only cross-bag send. Target is an atom or a variable holding a bag name. |
| `say` | `say "Sum is %i" s` | Formatted line to the machine's routed fd (default `Stdout`), newline appended. Specifiers: `%i` int, `%s` casual string (codepoint list), `%a` any value rendered, `%b` bytestring handle decoded, `%%` literal percent. |
| `exit` | `exit 0` | Terminate the program with the code. |
| `die` / `quit` | `die` | Terminate this machine. |
| `sleep` | `sleep 100` | Pause (throttling back-off, §8-style); deferred with the effects. |
| `panic` | `panic e` | Fatal: message hook + exit 1. Never rerouted. |
| `error` | `error ("bad thing", x)` | Fire a context tuple into the error bag (§9). Tuple argument. |
| `bytesBind` | `bytesBind H [72, 105]` | Register UTF-8 bytes of the codepoint list under atom handle `H`; emits gate tuple (§14). |
| `bytesDestroy` | `bytesDestroy H` | Drop the bytestring entry. Manual lifetime — no GC. |
| `bytesNew` | `bytesNew "hi"` | Register the casual string's UTF-8 bytes under a runtime-fresh handle (`Bytes0`, `Bytes1`, …, skipping taken names) and emit the ordinary `(Bytes, H)` gate — `H` the fresh handle, grabbed from the gate and used as data. |
| `import` | `import H S []` | Load a module at runtime (§10). A `"..."` literal in `H` or `S` auto-promotes (§11). |
| `reroute` | `reroute Src Tgt` | Repoint where `error` tuples from bag `Src` go (§9). Last update wins. |
| `fopen` | `fopen H "path.txt" W` | Open a file into fd handle `H` (§13). Mode is the atom `R` or `W` (`W` truncates). |
| `fclose` | `fclose H` | Close a file handle (idempotent; unknown handle is a no-op). |
| `fread` | `fread H` | Read the entire remaining content through read-mode `H` into the bytestring table under the same name; emits gate. For `Stdin`, reads one line (blocks); EOF reads as empty. |
| `fwrite` | `fwrite H S` | Write the bytestring named by side-table handle `S` through write-mode fd `H` (flushed); emits gate. A `"..."` literal in `S` auto-promotes (§11). |
| `sayfd` | `sayfd Global F` | Repoint which fd `say`s from bag `Src` go through (§13). Last update wins. |

Reserved words (cannot be identifiers/variables):
`in inp rd out if then else say exit die quit sleep lob error panic rand
typeOf atomize atos bytesBind bytesDestroy bytesEqual bytesRead
bytesCompare bytesNew import reroute sayfd fopen fclose fread fwrite`.

---

## 7. Expressions

Operators, loosest to tightest binding (all binary ops left-associative):

| Level | Operators | Semantics |
|---|---|---|
| equality | `==` `!=` | Numeric equality; on atoms, pure name identity. On casual strings/lists: a type error — compare structurally via patterns or `bytesEqual`. |
| ordering | `<` `>` `<=` `>=` | Numeric-only, same-kind (int-int, double-double). Atoms order nowhere — use `bytesCompare` for bytestring content. Returns `1`/`0`. |
| additive | `+` `-` | Numeric. |
| multiplicative | `*` `/` | Numeric. |
| unary | `-e` | Negation. |

Mixed int/double arithmetic and ordering are errors, not promotions.

**Splice**: `e!` in tuple-construction position splices the whole value
of `e` (which must be a tuple) element-wise into the surrounding tuple:
`(c!, a + b)`. This is the continuation-passing mechanism.

**Builtins** (function-call syntax, evaluate in-transaction):

| Builtin | Result |
|---|---|
| `rand(n)` | Int in `0..n-1` (deterministic seed — runs are reproducible). `rand` of non-positive is `0`. |
| `typeOf(x)` | Shape atom: `Int`, `Double`, `Atom`, `Tuple`. |
| `atomize(s)` | Casual string → atom. Fatal unless the string is capitalized (case is the only atom/variable signal; atoms must re-spell as source). |
| `atos(a)` | Atom → casual string (codepoint list). `atos(atomize("Foo"))` round-trips. |
| `bytesEqual(a, b)` | `1`/`0` comparing bytestring **contents**. |
| `bytesRead(h)` | The handle's bytes decoded back to the codepoint cons-list — `bytesBind H l … bytesRead(H)` yields `l` exactly. |
| `bytesCompare(a, b)` | `-1`/`0`/`1`, lexicographic bytewise content ordering (UTF-8 bytewise = codepoint order). |

**Truthiness**: falsy = `0`, `0.0`, the atom `False`. Everything else is
truthy, including `()` and `Nil`.

---

## 8. Bags

- Machines declared inside `Name { ... }` match tuples in that bag; `out`
  emits into the machine's own bag. Within a bag: Linda semantics —
  shared space, racing matches, `rd` broadcast.
- `lob` is the only cross-bag send: asynchronous, addressed, one-way
  (Erlang-style). There is no cross-bag read — a bag's tuples are only
  consumable by machines declared inside it.
- A bag with no machines just accumulates `lob`'d tuples — a cheap,
  ordered-by-accident sink (e.g. a free log). Declaring machines for it
  later is seamless; accumulated tuples are simply there.
- `lob Global ...` routes to the main bag.
- Cross-bag atomicity is free: a machine's action list mixing same-bag
  `out`s and cross-bag `lob`s commits as one unit.

---

## 9. Errors

- `error (...)` delivers a tuple to the machine's error bag. For
  top-level machines that is the plain `Error` bag; a module's machines
  route to the module's mangled `Error` bag (e.g. `Error_v2`) — see §10.
  The tuple's leading tag is the error bag's name, always.
- `reroute Src Tgt` (in-transaction, last update wins) repoints where
  `error` tuples go: `Src` may be a bag name or a module's mangled error
  bag (= "all bags in that module"); `Tgt` may name anything — an
  unknown target is just a machineless accumulator. `reroute Error Log`
  at top level catches every top-level machine's errors. `panic` is
  never rerouted.
- The `Error` bag has a **default machine** `(c!) : panic c` — active
  only if the program declares no `Error` bag at all. A user-declared
  `Error { ... }` block, even empty, fully replaces it; a deliberate
  `Error { }` means "silently swallow all errors".
- Hard failures — malformed `say` formats, unknown bytestring/file
  handles, unimportable modules, wrong-mode file access, `atomize` of an
  uncapitalized string, arithmetic on atoms — currently abort the machine
  (or, for deferred effects, are runner-safe fatals: panic hook + exit 1,
  never a silent hang). These are provisional routes, not a designed
  error story.

---

## 10. Modules and import

- `import H S Hide` loads `<main file's directory>/<module name>.lind` at
  runtime. `H` names a bytestring holding the module name; `S` a
  bytestring holding the namespace suffix (the empty suffix is spelled
  with the preregistered `Nil` handle); `Hide` is a list of atoms naming
  module bags whose machines are not imported (initial tuples still
  load; `lob` can still create hidden bags as accumulators).
- The **effective suffix** (ambient suffix + `S`) is appended to every
  atom the module mentions — bag names, patterns, `lob` targets, handles
  — recursively, including every import the module itself performs.
  Exemptions: `Nil` (the list spine), hide-list expressions, string and
  `say`-format literals, and `fopen`'s mode position. A module cannot
  name the real `Global` or the real top-level `Error` — it talks to
  whatever bags the caller passes as data.
- On success the loader emits the gate tuple `(Imported, H, S)` into
  `Global` — `H` the handle /as written in the import action/, `S` the
  effective suffix as a casual string. With a promoted import the gate
  carries the anonymous `Auto<n>` handle (a compiler-generated name
  the consumer does not spell) and the suffix it bound — so gate on a
  distinctive suffix; two promoted imports with suffix `""` are
  indistinguishable from each other and from the prelude's
  `(Imported, Prelude, "")`. Repeat imports of the same (name, suffix)
  pair are singletons: skipped, but the gate tuple is still emitted.
- Import failure (missing file, parse error, load error) is contained:
  panic + exit 1.

---

## 11. Bytestrings

Real string/byte work goes through **opaque bytestring handles** — atoms
backed by a runtime side-table, built and consumed by the `bytes*` verbs
and `%b`. `bytesBind` is a deferred effect: consumers gate on the
`(Bytes, H)` completion tuple. Handles are plain atoms to the matcher;
`==` on handles compares the handles, never the contents. There is no
automatic reclamation — `bytesDestroy` is the manual lifetime tool.

For an *anonymous* string — data built at runtime, no name chosen in the
source — `bytesNew e` registers its bytes under a runtime-generated
handle: a flat counter `Bytes0`, `Bytes1`, … (deterministic, like the
`ACont` continuation names), skipping any name already in the side-table
(so an explicit `bytesBind Bytes0 …` is honored, not clobbered). The gate
tuple is the ordinary `(Bytes, H)`; what generation cannot prevent is a
*later* user bind clobbering a fresh handle — manual-lifetime chaos, as
everywhere. The handle never mangles in modules (nothing in any source
names it); note the gate lands in `Global`, which a module's own machines
cannot reach — a module's caller consumes the gate and passes the handle
in as data (§10, the fd-as-data pattern).

Two bytestrings are preregistered at start: `Nil → ""` (the empty-suffix
spelling) and, via the Prelude, `Prelude → "Prelude"`. Neither is
special: both can be clobbered or destroyed like any entry.

**Inline auto-promotion**: a `"..."` literal in a bytestring position
— `fwrite`'s `S`, and `import`'s `H` and `S` (`import "greeter"
"_v2" []`) — promotes to an anonymous bytestring: the literal
desugars at parse time to `bytesBind Auto0 (…)` immediately followed
by the action (for `import`, one bind per promoted position, in
source order). The hide list is a list-of-atoms position and promotes
nothing. The promoted names are a flat parse-time counter (`Auto0`,
`Auto1`, …, the `ACont`-precedent scaffolding — a different counter
and namespace from `bytesNew`'s runtime `Bytes<n>`), ordinary source
atoms: they render, round-trip, and mangle, so a module's promoted
handles namespace like everything else. Promotion is literal-only — a
variable or computed codepoint list promotes nothing (`fwrite H [72,
105]` is still an unknown-handle error; `import Mod Sfx []` still
means "resolve these handles"). The promoted binds share one action
list, so the effect bundle lands bind-before-use and no consumer
needs the byte gates (they are still emitted, and sit in `Global`
like every un-gated bind). No name reservation: a user atom spelling
`Auto0` races it — ordinary opt-out chaos.

---

## 12. Files and I/O

- The **fd table** maps atom handles to open OS handles + mode.
  `Stdin` (read, line mode), `Stdout`, `Stderr` (write) are
  preregistered — ordinary entries: `fopen` on their names re-opens them
  (closing the old OS handle first), `fclose Stdout` makes every later
  `say`/`fwrite Stdout` an honest fatal, `fread Stdin` blocks for a line
  (a partial last line without trailing newline is delivered; EOF reads
  as the empty remainder and the fd stays EOF).
- `fread H` (file mode) consumes the whole remaining file and spends the
  read fd; further `fread`s return the empty remainder.
- Data flows through the bytestring side-table: `fwrite H S` writes the
  bytes `S` names; `fread H` registers what it read under `H`, so
  `say %b H` reads it back.
- `say` is un-magicked: it writes through the fd table like any
  `fwrite`, resolved at match-commit time. `sayfd Src F` repoints the
  destination for bag `Src`'s says (module-wide key = the module's
  mangled error bag; default `Stdout`). Say and `fwrite` share one byte
  stream, in effect-bundle order.
- Paths are relative to the process CWD; file failures (missing file,
  wrong mode, unknown handle) are runner-safe fatals.

---

## 13. The Prelude

A built-in module, imported by default in the top-level file. It contains
one-shot preregistration machines only (so it can never keep a program
alive): currently `Newline → "\n"` and `Version → "0.1.0.0"`, plus a
deliberate `Error { }` block so it never installs a competing default
Error machine. `{-# no-prelude #-}` opts out entirely; an explicit
`import Prelude Nil [...]` (after the pragma) brings it back with a hide
list. Modules do not get the default import — they import the Prelude
explicitly if wanted. A disk file named `Prelude.lind` is shadowed by
the builtin.

---

## 14. The gate-tuple convention

Deferred effects emit completion tuples into `Global` when they land;
consumers `rd`/take them to sequence deterministically:

| Effect | Gate tuple |
|---|---|
| `bytesBind`, `bytesNew` | `(Bytes, H)` |
| `fopen` | `(Fopen, H)` |
| `fopen` | `(Fopen, H)` |
| `fread` | `(Fread, H)` |
| `fwrite` | `(Fwrote, H)` |
| `import` | `(Imported, H, S)` — `H` as written; a promoted import's `H` is the anonymous `Auto<n>` atom (gate on the suffix) |

The startup one-shot (`bytesBind`, prelude statics) runs before other
machines in practice, but the guarantee is by convention: gate on the
completion tuple when ordering matters.

---

## 15. Workload management idiom

There are no scheduler primitives — throttling is written with machines
(see `examples/throttle.lind`): a counter tuple the worker `in`s and
re-`out`s, a heartbeat `(Tick,)` machine bumping `(ResetEpoch, n)`, and
exponential backoff with jitter via `rand`, `sleep`, and the re-emission
of the request tuple. Read the epoch with `rd`, never `in`. A backed-off
request re-emitted into the open bag can be picked up by a different
worker — throttling plus racing yields load balancing for free.
