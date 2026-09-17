# Lindana: formal-model ancestry and design mining for "underhanded usability"

Session notes. Two halves: (1) where Lindana's semantics sit relative to known
abstract models of computation, (2) mechanics mined from those models' literature
for a Zachlike layer on top of the language.

Framing constraint for part 2: the concurrency model's inherent nastiness *is* the
puzzle. Don't abstract away races, blocking, hidden state, or starvation — make
them legible and make them the thing the player is actually reasoning about.

---

## Part 1 — Where the semantics land

### Colored Petri nets (closest structural match)

- bag = place
- tuple = colored token
- machine = transition
- match-and-fire = transition firing: enabled when matching tokens sit in input
  places; firing atomically consumes them and produces new ones
- join patterns (`rd`/`in` across a tuple in one STM transaction) = a multi-place
  transition consuming from several input positions atomically
- racing matches = the classical conflict-resolution problem (two enabled
  transitions sharing a token; firing one disables the other)

Lindana is effectively a colored Petri net where the "coloring" is structural
pattern matching rather than a type discipline.

### Chemical Abstract Machine (CHAM) — closest conceptual ancestor

Molecules float in a solution; reaction rules fire nondeterministically whenever
their pattern is present in the multiset, consuming reactants and producing new
molecules. That is nearly a direct description of the bag semantics: unordered
multiset, structural pattern-triggered rewriting, no imposed evaluation order.
Named bags with `lob` crossing between them echo the CHAM's membrane / airlock
concept for nested solutions.

### Join calculus

A join definition fires when messages are simultaneously present on several
channels, consumed atomically, spawning a continuation — same shape as Lindana's
join patterns. This is the formal model that actually produced real languages
(JoCaml; indirectly .NET's Joins library).

Where Lindana diverges: **join calculus is receive-only — no non-destructive
read.** So `rd` is a genuine Linda contribution grafted onto a join-calculus-shaped
atomic commit rule.

### Not like CCS / π-calculus

Those are channel/rendezvous-based: a send and a matching receive synchronize
directly, with no persistent shared space between them. Lindana's bag is
associative/content-addressed and *persists* tuples until something consumes them
— the defining Linda trait that CCS and π-calculus deliberately lack.

### One-line pedigree

> Linda's generative communication, formalized through a join-calculus-style
> atomic commit rule, running on something behaviorally identical to a
> CHAM / colored-Petri-net rewrite engine — with `lob` bolting on an
> Erlang-style addressed-actor escape hatch for crossing between bags.

### Turing-completeness note

The Brainfuck interpreter already settles completeness. The more interesting
Petri angle: bounded vs. unbounded token counts is exactly the line between plain
Petri nets (decidable reachability/liveness properties) and Turing-complete
extensions. Unbounded bags + matching machines put Lindana firmly on the
complete side, alongside CHAM and join calculus. **This is also why capacity
limits are a good game mechanic — see below.**

---

## Part 2 — What's actually novel here

Not a new formal model. The novelty is in the combination and in the runtime
engineering decisions the theory papers don't address.

**Genuinely distinctive:**

- **`rd` + join-calculus atomicity.** Join calculus has no non-consuming read;
  Linda has `rd`/`in` but no atomic multi-tuple joins. Mixing `rd` and `in`
  clauses inside one atomically-committed join is a real hybrid neither canonical
  model offers.
- **The `!` splice/rest-capture symmetry.** One operator for "splice a sub-tuple
  in" (construction) and "capture the rest as a sub-tuple" (destructuring). Small,
  clean unification; not something seen as a named first-class feature elsewhere.
- **Exposed CPS guts.** The auto-generated `ACont0`, `ACont1`, … continuation
  atoms from Terse-block desugaring are ordinary user-addressable atoms, left
  hackable rather than hidden. Most languages that desugar sequencing into CPS
  go out of their way to hide generated names. Thematically consistent with a
  language about poking at machinery.
- **Fairness as a user-visible, tunable runtime concern** (self-throttling backoff
  + heartbeat resetting fire-counts) rather than left unspecified the way Petri
  nets / CHAM / join calculus leave it. An engineering answer to a question the
  formal models shrug at.
- **`reroute` as live, rewritable indirection over error routing**, and runtime
  `import` that mid-run-spawns a whole namespaced sub-program. No real analogue in
  the classical models — these are systems ideas (dynamic linking, live fault-handler
  reconfiguration) grafted onto a normally-static substrate.

**Less novel than it feels:**

- Named bags + cross-bag `lob` is very close to **KLAIM** (De Nicola / Ferrari /
  Pugliese): multiple *located* tuple spaces with explicit addressed communication.
  Worth a skim to see how much of this design space was staked out in the mid-90s.
- Embracing racing matches is a *framing* choice, not a semantic one — Linda's
  nondeterminism was always there; leaning into it philosophically is the new part.
- Manual bytestring lifetimes / use-after-free-as-feature is a good esolang joke
  but not new computational ground; it's just declining to abstract something.

---

## Part 3 — Mechanics to mine

Ranked roughly by (cheap to prototype) × (in-genre payoff).

### 1. Bag capacity limits — from Petri net boundedness `[cheap, high payoff]`

Classical Petri analysis cares about *k-boundedness* (can a place ever hold more
than k tokens?) and *liveness* (can every transition always eventually fire
again?). Make bags finite-capacity; overflow is a visible, ugly failure.

This is the TIS-100 / Shenzhen I/O "your solution works but doesn't fit in the
box" constraint, arriving natively rather than bolted on — and it's the real
reason production systems implement back-pressure.

### 2. Opaque membranes — from the CHAM `[cheap, high payoff]`

Named bags are currently locality/scoping. The CHAM's membrane concept was
specifically about *forcing reactions to be local* and hiding internal state from
outside solutions.

Make a bag genuinely opaque from outside: no `rd`-probing in, only what leaks out
via `lob`. Debugging becomes an information-asymmetry puzzle — reason about a
black box from its outputs. Legitimately fun, legitimately underhanded.

### 3. Migrating machine definitions — from join-calculus mobility / KLAIM

The core join calculus insists receptors live at one fixed location (no smuggling
a matcher elsewhere), but the mobility extensions — and KLAIM's entire pitch —
let *code itself* migrate between locations at runtime.

Mechanic: relocating a whole machine definition into another bag mid-run as a
scarce, costly action. An "infiltration" move rather than a wiring move.

### 4. Ambient capabilities, especially `open` — from Mobile Ambients

**Best single fit for "underhanded" specifically.** Cardelli & Gordon model
nested locations with explicit capabilities to cross a boundary: `in n` (enter),
`out n` (exit), `open n` (dissolve the boundary, dumping everything inside into
the parent).

`open` is the interesting one: a one-shot demolition move a level designer can
leave lying around as *bait*. A "cheat" tool a clever player discovers lets them
bypass an intended routing puzzle by just popping the container. Sanctioned
exploits — very much the Zachtronics community-speedrun spirit.

### 5. Supervision strategies — from Erlang/OTP

Closest to home, given `error` / `panic` / `reroute` already exist. The real OTP
insight isn't "errors go somewhere," it's *supervision strategies*: restart the
crashed child, restart its whole sibling group, or escalate to the supervisor's
supervisor.

Difficulty axis: "your solution must survive N induced crashes without a full
restart." Smuggles a real distributed-systems lesson (blast-radius containment)
into a puzzle constraint.

### 6. Confluence-gated rewrite puzzles — from the Gamma model

Banâtre & Le Métayer's Gamma model (the direct ancestor CHAM itself cites) is
explicitly about programming as multiset rewrite rules reaching a target
configuration. Their running examples — sorting by local swap, duplicate
elimination — are chosen because they visualize as local, myopic rewrites.

Nearly a ready-made level pack. The underhanded part: a *locally correct* rule can
still deadlock or livelock globally, and only certain rule shapes are provably
confluent. Levels could literally gate on "does this ruleset admit the diamond
property" — i.e. gamify a real confluence proof.

### 7. Weak vs. strong fairness as a difficulty toggle

Real concurrency theory distinguishes schedulers guaranteeing "every enabled
transition eventually fires" (weak fairness) from ones with no such guarantee.

Ship most levels solvable under a friendly scheduler, then unlock an
**adversarial scheduler** mode where solutions must be starvation-proof. Teaches
a real bug class (livelock/starvation) as a genre-appropriate late-game spike
rather than a random gotcha.

---

## Further reading

### Linda / tuple spaces

- Gelernter, *Generative Communication in Linda* (1985) — the original. The
  "generative" framing (a tuple has independent existence once emitted, until
  someone withdraws it) is the direct ancestor of the bag.
  https://www.cs.unc.edu/~stotts/COMP590-059-f21/slides/lindaGenerative.pdf
- the morning paper summary — much shorter walkthrough.
  https://blog.acolyer.org/2015/02/17/generative-communication-in-linda/

### Chemical Abstract Machine

- Berry & Boudol, *The Chemical Abstract Machine* (1992, TCS) — floating
  molecules reacting by rule; membranes-as-scoping maps ~1:1 onto named bags.
  https://courses.grainger.illinois.edu/cs522/sp2016/TheChemicalAbstractMachine.pdf
- https://en.wikipedia.org/wiki/Chemical_abstract_machine

### Join calculus

- Fournet & Gonthier, *The Reflexive CHAM and the Join-Calculus* (1996, POPL) —
  the original; explicitly builds join calculus out of CHAM molecules. The one
  most worth reading given how close `rd`/`in` join matching is to it.
  https://www.classes.cs.uchicago.edu/archive/2007/spring/32102-1/papers/p372-fournet.pdf
- Fournet & Gonthier, *The Join Calculus: A Language for Distributed Mobile
  Programming* (2000) — gentler, tutorial-style, with the equational theory.
  https://code.garrettmills.dev/Archives/papers-we-love_papers-we-love/raw/branch/main/distributed_systems/join-calculus.pdf
- https://en.wikipedia.org/wiki/Join-calculus — lists real implementations
  (JoCaml etc.) if you want to see how others turned theory into a language.

### Petri net ↔ join calculus bridge

- *An Operational Petri Net Semantics for the Join-Calculus* — formally works out
  the Petri-net encoding of join patterns. Directly the mapping sketched in Part 1.
  https://arxiv.org/pdf/1208.2753

### Mentioned, not yet chased down

- **KLAIM** (De Nicola, Ferrari, Pugliese) — located tuple spaces + agent
  migration. Overlaps named bags / `lob` most directly.
- **Mobile Ambients** (Cardelli & Gordon) — `in` / `out` / `open` capabilities.
  Source for mechanic #4.
- **Gamma** (Banâtre & Le Métayer) — multiset rewriting as a programming model.
  Source for mechanic #6.

---

## Open threads

- Does bag capacity interact sanely with the existing backoff/heartbeat fairness
  machinery, or do they fight?
- Opaque membranes vs. current debugging affordances — what's lost, and is the
  loss the point?
- If machine migration lands, does `reroute` need to become location-aware?
- Confluence checking as a static analysis: feasible on real Lindana programs, or
  only on a restricted rewrite-rule sublanguage designed for levels?
