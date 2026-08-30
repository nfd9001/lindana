# Lindana

A recreational programming language about race conditions. See
`agent-history/lindana-handover.md` for the design; this is the
implementation shell (parser + AST, no runtime yet).

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
  terminates a machine ("one line by convention").
- `app/Main.hs` — `lindana <file.lind>`: parse + re-render a file.
- `test/Spec.hs` — hspec suite: parses the handover's §8.2 and §10
  examples and checks pretty-printer round-trips.
- `examples/` — sample `.lind` files.

## Building

```sh
stack build
stack test
stack exec lindana -- examples/throttle.lind
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

Not yet (handover §11): pattern-side rest-capture, list/cons sugar,
string sugar beyond literals, effect bundles, the runtime itself.
