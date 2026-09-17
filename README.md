# Lindana

A recreational programming language about race conditions. The design
lives in [`agent-history/lindana-handover.md`](agent-history/lindana-handover.md)
— the spec-of-record — and the implementation history lives alongside
it in [`agent-history/`](agent-history/). `lindana <file.lind>` runs
programs.

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

# Building

```sh
stack build
stack test
stack exec lindana -- examples/bags.lind
```

# Trying the parser in ghci

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
