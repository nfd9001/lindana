# Lindana
A recreational programming language about race conditions.

The main idea is that everything is done by declaring *machines*,
which each stand by one Linda-style *bag*, from which they try to grab *tuples* to work on.
Upon grabbing a tuple, a machine may take one action, and it may place zero or more tuples back in its bag.

[CHAM](https://www.sciencedirect.com/science/article/pii/030439759290185I) is a similar formal model to what we're doing here.

## How do I use it?
The current state of the language is described in [`REFERENCE.md`](REFERENCE.md).
A *good* handwritten intro doc is a TODO. You can also check out `examples`.

Good uses are "for fun." This is a recreational art project: your ability to ship anything useful is an unfortunate accident. Ship something funny instead. No warranties.

## AI?
Yes. In the tradition of "if you're going to give me a pile of AI output to read, at least give me the prompts," see `/agent-history`. 
	

## Contributing?
Feel free!

```sh
stack build
stack test
stack exec lindana -- examples/hello.lind
```

`stack test` also runs `lindana-fuzz` — a property/fuzzing suite that
sweeps generated inputs and schedules against the runtime's contract
(issue #41). Pin the seed with `LINDANA_FUZZ_SEED=<n>` and scale it up
with `LINDANA_FUZZ_ITERS=<n>` for a longer soak. Tier 0 sweeps pure
properties over generated cases; Tier 1 turns the engine's own chaos
knob up (`--chaos`, §11.13) — a contested conservation property under
stirred schedules, and a seed-sweep of every example against its
no-chaos baseline.
