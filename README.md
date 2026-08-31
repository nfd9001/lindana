# Lindana

A recreational programming language about race conditions. See
`agent-history/lindana-handover.md` for the design; the implementation
covers the parser, the STM tuple bag + matcher, the machine
loop/scheduler + action layer + effect-runner, named bags, and a
program loader — `lindana <file.lind>` runs programs.

# The Handwritten Part of the README

## AI?
Yes. In the tradition of "if you're going to give me a pile of AI output to read, at least give me the prompts," see `/agent-history`. 

## Contributing?
Feel free!

## Where Should I Look To Figure Out What's Going On Here; I'm A Baby Agent Session Goo Goo Ga Ga
Look in `/agent-history`. If a README or a messageboard exists there, check it out.
If not, `/agent-history/lindana-handover.md` is probably a good start, so you can get a sense of the actual goals of the project (recreational chaos).
You have access to the other agent sessions, just like human readers, but they're probably pretty big, so be careful about blindly pulling too much into context. 
Git history might be a better source-of-truth about recent progress until I've established some kind of plan here.

# The Not-Handwritten Part of the README

## Layout

- `src/Lindana/Syntax.hs` — AST and a round-trip pretty-printer
  (parsing rendered output yields an equal AST).
- `src/Lindana/Parser.hs` — megaparsec parser. Layout rule: newlines
  are insignificant inside brackets; at bracket depth zero a newline
  terminates a machine (so does a `}` closing a bag block, so
  one-line `Name { pat : action }` blocks parse).
- `src/Lindana/Runtime.hs` — the STM tuple bag and structural
  matcher (§3): racing matches, join patterns, `rd`/`in`, rest
  capture (§11.1).
- `src/Lindana/Machine.hs` — the machine loop/scheduler (§1, §2),
  the two-phase action layer + effect-runner (§7.2), and the named
  bag machinery (§6): one thread per machine, `out` is same-bag,
  `lob` crosses bags, cross-bag atomicity for free.
- `src/Lindana/Loader.hs` — the program loader: lowers a parsed
  `Program` into bag-tagged machines + per-bag initial tuples,
  enforces the §6 declaration rules, and installs the §6.4 default
  `Error` machine when the program declares no `Error` bag.
- `app/Main.hs` — `lindana <file.lind>`: parse, load, and run;
  exits with the program's status. `--parse` re-renders only.
- `test/Spec.hs` + `test/Lindana/` — hspec suite: parser round-trips,
  matcher, machine loop, effects, bags, loader.
- `examples/` — sample `.lind` files. `bags.lind` exercises named
  bags end-to-end; `throttle.lind` (§8.2) is a deliberately
  non-terminating long-runner — the CLI reports it as a deadlock when
  every machine ends up blocked.

## Building

```sh
stack build
stack test
stack exec lindana -- examples/bags.lind
```

## Trying the parser in ghci

```sh
stack ghci
```

```haskell
ghci> :set -XOverloadedStrings
ghci> import qualified Data.Text as T
ghci> import Lindana.Parser (parseProgram)
ghci> import Lindana.Syntax
ghci> fmap renderProgram (parseProgram "(Tick,), (ResetEpoch, n) : (ResetEpoch, n + 1)")
"(Tick,), rd..." -- renders the parsed AST back to source
```

## Grammar status

Implemented: machines, join patterns with `rd`/`in`, tuples with `!`
splice, Terse bracketed sequences `[a; b]`, `if/then/else`, verbs
(`say`, `exit`, `die`/`quit`, `sleep`, `lob`, `error`, `panic`),
builtin calls (`rand`, `typeOf`, `atomize`, `atos`), initial-bag
blocks, named bag blocks.

Not yet (handover §11): list/cons sugar,
string sugar beyond literals, effect bundles. Provisional (flip
worthy): pattern-side rest capture is trailing-only (§11.1), the
§11.10 top-level grammar (see the loader's header), and the §6.4
default-`Error`-machine installation rule.
