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
- `src/Lindana/Def.hs` — the lowered machine shape (`MachineDef`)
  and reserved bag names, shared by loader, import, and machine
  layers (kept in its own module so "Lindana.Import" can sit between
  loader and machine without a cycle).
- `src/Lindana/Import.hs` — module loading (issue #17, §13.13):
  finds `<name>.lind` at runtime, drops hidden bags' machines,
  suffix-mangles every atom in the module's source, and lowers it
  with the module's own mangled Error bag.
- `src/Lindana/Machine.hs` — the machine loop/scheduler (§1, §2),
  the two-phase action layer + effect-runner (§7.2), the named
  bag machinery (§6), the §9 bytestring side-table (`rtsBytes`):
  one thread per machine, `out` is same-bag, `lob` crosses bags,
  cross-bag atomicity for free. Also owns the §13.13 `import`
  effect: spawns module machines mid-run, keeps the module registry
  (singleton per name + suffix), and emits the `(Imported, H, suffix)`
  completion gate.
- `src/Lindana/Loader.hs` — the program loader: lowers a parsed
  `Program` into bag-tagged machines + per-bag initial tuples,
  enforces the §6 declaration rules, and installs the §6.4 default
  `Error` machine when the program declares no `Error` bag.
- `app/Main.hs` — `lindana <file.lind>`: parse, load, and run;
  exits with the program's status. `--parse` re-renders only.
- `test/Spec.hs` + `test/Lindana/` — hspec suite: parser round-trips,
  matcher, machine loop, effects, bags, loader.
- `examples/` — sample `.lind` files. `hello.lind` is the issue #7
  no-LHS one-shot Hello World; `bags.lind` exercises named
  bags end-to-end; `lists.lind` (§11.5) sums a list via cons-pattern
  sugar; `strings.lind` (§9) shows casual-string literals matching
  and decoding; `chars.lind` (§9, issue #12) shows character sugar
  matching, consing into strings, and building bytestrings;
  `bytes.lind` (§9) binds bytestring handles and
  contrasts `bytesEqual` with `==`; `imports.lind` + `greeter.lind`
  (§13.13) load a module at runtime with a namespace suffix and
  gate on the `(Imported, …)` completion tuple; `brainfuck.lind`
  (§13.12) is a Brainfuck interpreter — zipper program and tape,
  jump-table brackets, CPS reversal via `!` splice — that runs the
  classic Hello World!; `throttle.lind` (§8.2) is a
  deliberately non-terminating long-runner — the CLI reports it as a
  deadlock when every machine ends up blocked.

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

Implemented: machines (including no-LHS one-shot machines, §1: `:` at
the start of a line), join patterns with `rd`/`in`, tuples with `!`
splice, list/cons sugar (§11.5, provisional: `[a, b, c]` literals and
`[h | t]` patterns desugar at parse time to nested 2-tuples ending in
the `Nil` atom — rendering shows the desugared form), casual-string
sugar (§9, provisional: `"..."` literals desugar at parse time to the
same cons-list shape over codepoint `Int`s — plain Ints all the way
down, no `Char`/`Str` type; `say %s` decodes, `atomize`/`atos`
convert), character sugar (§9, issue #12, provisional: `'x'` is the
single codepoint as a plain Int, `''` is a synonym for `Nil`, and
multi-codepoint `'…'` is a parse error — use a string), Terse bracketed
sequences `[a; b]`, `if/then/else`, verbs
(`say` with `%b` for bytestring handles, `exit`, `die`/`quit`,
`sleep`, `lob`, `error`, `panic`, `bytesBind`, `bytesDestroy`),
builtin calls (`rand`, `typeOf`, `atomize`, `atos`, `bytesEqual`,
`bytesRead`),
initial-bag blocks, named bag blocks, the §9 bytestring side-table
(opaque atom handles; `==` is pure atom identity, `bytesEqual`
compares contents; binds emit a `(Bytes, H)` completion tuple;
`bytesRead` decodes a handle back into the codepoint list — a string
in and out of ByteString is the identity, §9/issue #12), and module
import (§13.13, issue #17, provisional: `import H S Hide` loads
`<name>.lind` at runtime from bytestring handles, suffix-mangles its
atoms — a namespace — and spawns its machines mid-run; hide lists
skip bags; `Nil → ""` is preregistered so the empty suffix is free;
`lob`'s target may be a variable: bag names as data).
Effect bundles need no syntax (§11.6, provisionally resolved): a
reaction's post-commit action list *is* the bundle.

Not yet (handover §11): mixed int/double arithmetic, effect-runner
scope, unified error routing. Provisional (flip
worthy): pattern-side rest capture is trailing-only (§11.1), the
list/cons sugar desugaring (§11.5), the string-literal desugaring
(§9), the character-literal desugaring (§9, issue #12), the
§11.10 top-level grammar (see the loader's header), and the §6.4
default-`Error`-machine installation rule.
