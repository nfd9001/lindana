SLEEP EXPERIMENT: what `sleep` actually does, a defer protocol, and
a shutdown hazard found on the way

Session: the post-audit sidebar of 2025-12 (examples audit; the
`bags.lind` error-message discussion). Prompt: a tagged error handler
`(Error, Demo, (s, n))` racing a catchall `(Error, rest!)`, where the
catchall — on grabbing a Demo-tagged tuple — puts it back and naps a
few millis so the specialist can win the re-grab. "Don't commit it,
but let's try it out." It turned into the sharpest probe of `sleep`'s
semantics we have. Directly relevant to the PR #29 comment asking for
a strategy about what should race and what should synchronize, and to
flip #8 of provisional-std-fd-semantics.txt (the global effect
runner). Status: experiment record, nothing here is committed behavior;
all files in this directory are self-contained and runnable with
`stack exec lindana -- <file>`.

--------------------------------------------------------------------
FINDING 1 (the big one): `sleep` cannot delay a machine.

`sleep e` compiles to an `EffSleep` in the machine's deferred bundle;
the SINGLE global effect runner executes it as `threadDelay`
(Machine.hs `runBundle`). The machine thread itself re-arms the
instant its transaction commits — the sleep happens in somebody
else's thread. Consequences:

  * A machine cannot throttle ITS OWN next grab. "Push the tuple
    back and sleep" livelocks: the machine re-grabs its own pushback
    at full speed. See `defer-livelock.lind` (a 100% CPU spin; 11k
    defer rounds in a minute; no output progress).
  * Sleepsort is impossible as written: see `sleepsort-not.lind`.
    The input is a list of length l; a worker unwinds it into l
    (N, n) tuples while counting, and the countdown gate (Counter, r)
    meters out exactly l grabs — each grab re-arms the countdown,
    then sleeps proportional to n and says. The countdown's LAST
    token is the exception: its holder emits the terminal
    (Bytes, Last) gate AFTER its own work (a plain write would hoist
    to grab time — see the corollary below), and (Bytes, Last) closes
    the program, so exit cannot precede the last claimer's say. The
    design asks the runtime for l CONCURRENT instances of N, each
    delaying in its own thread — under that, classic sleepsort
    semantics give 1 1 3 4 5. Today's runtime provides one re-arming
    thread per DECLARATION, and its bundles drain FIFO through the
    single global effect runner, one fully live at a time — so the
    sleeps are honored but contribute nothing to order, and the
    output is grab order (5 1 4 1 3, deterministically, exit 0).
  * ACCEPTANCE TEST for any §11.7 flip (per-machine or per-bag
    runners, per PR #29's comment): if the flip can't make a
    sleepsort of `3 1 4 1 5` print `1 1 3 4 5`, it didn't fix
    `sleep`. `sleepsort-not.lind` is the yardstick.

What a REAL delay looks like today (the gate-tuple idiom): block on a
completion tuple that the runner emits after its work. `sleep 5` +
`bytesBind H [1]` → the `(Bytes, H)` gate lands a true 5ms later,
because it is the runner's own post-sleep write. The tag
`tagged-error-defer.lind` uses exactly this as the nap mechanism.

Corollary — sequencing does NOT order writes against effects (as
shipped). The §5 sugar story (an implicit continuation chaining the
steps) is not what ships: `interpretActions` folds the whole action
list in ONE transaction — tuple writes (`out`/`lob`/`error`) execute
immediately, in-transaction, wherever they sit in the list, while
effects defer into the bundle. So `[sleep 100; (Done,)]` lands
`(Done,)` at match time; list position cannot express "emit after
the delay". What IS enforced: effects within one machine's bundle
are FIFO (machine-local ordering), and bundles are globally FIFO
(single runner). The only tuple that can land after a delay today is
a completion tuple emitted by an effect (the gate idiom) — which is
why sleepsort-not.lind's terminal token is a `bytesBind` gate, not a
plain write.

THE INTENDED MODEL (recorded as a design position, provisional,
flip-worthy): sequencing SHOULD enforce ordering — the implicit
continuation is real semantics, not sugar: an action list is a chain
of steps, each step its own transaction, and a machine's later steps
do not run until its earlier effects have completed. Motivated by
this experiment (sleepsort's terminal token should be writable as
`[sleep n * 10; say "%i" n; (Counter, 0)]` — list position meaning
what it says) and by the PR #29 comment's "what should race and what
should synchronize": a write and a later effect in the same list are
synchronized, not racing.

Implementation sketch, staying in the language's existing idioms:
split the action list at irrevocable effects into segments; segment 1
commits in the match transaction (writes + first effect run, atomic
as today); when the runner finishes a segment's effects it emits that
machine's continuation gate — the (Bytes, H) mechanism generalized
into the §5 AContN machinery the handover always said "falls out of
the loop re-arming" — and the next segment's transaction consumes it
with the environment carried along. Machine-local ordering then holds
by construction; whether effect ordering is BAG-local (all machines
in a bag serialize) or machine-local is exactly the §11.7 flip —
per-bag runners would make it bag-local, per-machine runners
machine-local, and sleepsort-not.lind (which wants l instances
delaying concurrently, not serialized) is the test for how much
serialization is too much.

--------------------------------------------------------------------
FINDING 2: rest capture is LOSSY on unspliced re-emit.

`r!` in a pattern ALWAYS binds a tuple — a one-element capture binds a
1-tuple. Re-emitting `r` plain (no `!`) therefore nests the payload in
a fresh 1-tuple layer PER ROUND-TRIP:

  (Error, Demo, ("late", 30))  -- cycle 1
  (Error, Demo, (("late", 30)))  -- cycle 2
  (Error, Demo, ((("late", 30))))  -- cycle 3  ...

The defer loop did this silently; after one round-trip the specialist
pattern `(Error, Demo, (s, n))` could never match again, and it LOOKED
like a scheduling race. Found by instrumenting the runtime and
watching the parens compound in the bag dumps. The rule:

  capture-then-splice is identity; capture-then-plain-emit adds a
  1-tuple wrap every time.

So the faithful way to bounce a tuple through a helper machine is
`lob Tgt (Tag, r!)` — splice it back out. Worth a REFERENCE.md sentence
wherever rest capture is documented (§11.1): "a rest capture binds a
tuple; to round-trip, splice (`!`) it back."

--------------------------------------------------------------------
FINDING 3: the working defer protocol (tagged-error-defer.lind).

Since pattern-side exclusion is impossible and sleep is useless for
self-throttling, the honest version of the original idea:

  * A specialist `(Error, Demo, (s, n))` and a catchall
    `(Error, rest!)` share the Error bag (§3.1 race).
  * The head-of-rest check cannot be an `if` in the catchall's body
    (no head builtin; `==` on lists is a type error). Instead the
    catchall hands `rest` to a `HeadCheck` one-shot whose nested
    pattern `(HeadCheck, (h, r!))` binds the head AS A VALUE; the
    body checks `typeOf(h) == Atom` (guarding the list-headed case)
    and then `h == Demo` — atom identity, in-block, as originally
    imagined, one delegation deep.
  * On Demo: splice the tuple back (`r!`, per finding 2) and nap for
    real: consume an `(CatchallArmed,)` token (the catchall takes it
    as a join clause on every grab), then re-arm the catchall from a
    `(Bytes, Nap)` completion relay ~5ms later. During the tokenless
    window the catchall cannot re-grab, and the specialist — gated
    until after first contact by a delayed `(Bytes, GoGate)` — wins
    the re-grab. Deterministic across runs.
  * The `sleep 5` in the defer branch is kept for looks; the token
    relay is what actually gates. If the catchall wins a contested
    re-grab anyway, it just defers again — the protocol is
    race-robust, which is the polite way to say it's a
    recreational-programming-language artifact.

--------------------------------------------------------------------
FINDING 4: hot machines own the bag; parked machines starve.

With a hot pushback ping-pong on one bag (`defer-livelock.lind`), a
parked machine NEVER won the tuple back — the already-running machine
re-grabs before the woken transaction can commit (hundreds of rounds,
zero specialist wins, both under GHC's scheduler and across
declaration orders). Fine for the defer protocol (deferring again is
progress), but it means: don't design anything that needs a parked
machine to win a contested re-grab. Ties into the §3.1 race having no
priority story and the PR #29 comment's "what should race and what
should synchronize".

--------------------------------------------------------------------
FINDING 5 (bug-class, promote me): the default Error machine makes
"all machines die" shutdown a false deadlock.

While autopsying sleepsort-not.lind, a control program
`{ (Tick,) }  (Tick,) : [say "hi"; die]` — no Error block, no exit —
printed `hi` then reported the §1 deadlock message and exited 1. Cause:
with no user Error block, the loader installs the §6.4 default
`(c!) : panic c` machine — an IMMORTAL looping thread. It parks on the
empty Error bag forever, `rtsLive` never reaches 0, main parks on the
live/exit check, and the RTS aborts the blocked threads with
BlockedIndefinitelyOnSTM, which Main.hs reports as the deadlock
message. Verified: appending `Error { }` (which suppresses the
default machine) makes the same program exit 0. Every existing example
dodges it by either declaring an Error block (bags, imports, reroute,
stdio, …) or ending via `exit` (hello, toy, lists, …); `throttle.lind`
and the two module files are "supposed to" deadlock. But the shape
"do some work, die out naturally" is the most natural beginner
program there is, and it reports a scary exit-1 deadlock by default.

Candidate fixes (not implemented; this note is the record):
  * the loader marks the default Error machine exempt from `rtsLive`
    (or spawns it lazily on the first error tuple — there's a §6.2
    precedent for lazy machine installation);
  * or the deadlock check ignores machines whose join is the default
    Error catch-all.
Filed as §11.12. Whoever picks it up: the sleepsort file doubles as
the reproduction.
