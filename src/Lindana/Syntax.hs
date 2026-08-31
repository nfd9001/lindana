-- | Abstract syntax for Lindana programs, plus a pretty-printer whose
-- output is itself valid Lindana source (round-trip friendly: parsing
-- the rendered output yields an equal AST).
--
-- This is a shell: syntax is illustrative pending the real grammar pass
-- (see lindana-handover.md §4). Not modelled yet: Terse->Restricted
-- desugaring. List/cons sugar (§11.5, provisional), casual-string
-- sugar (§9, provisional), and character sugar (§9, issue #12) are not
-- AST nodes: the parser desugars @[a, b, c]@ to nested 2-tuples ending
-- in the @Nil@ atom, @"..."@ to a cons-list of codepoint ints (the
-- same shape — plain Ints all the way down, §11.4), and @'x'@ to the
-- single codepoint Int (@''@ to @Nil@) at parse time, so the
-- pretty-printer renders the desugared forms — which round-trip. There
-- is no effect-bundle syntax and none is needed (§11.6, provisionally
-- resolved): the bundle is a machine reaction's post-commit action
-- list, a runtime concept — see "Lindana.Machine".
module Lindana.Syntax
  ( -- * AST
    Name
  , Program(..)
  , Decl(..)
  , PatElem(..)
  , ReadMode(..)
  , Pat(..)
  , Expr(..)
  , Op(..)
  , Action(..)
    -- * Pretty-printing
  , renderProgram
  , renderDecl
  , renderPatList
  , renderPat
  , renderActionSeq
  , renderAction
  , renderExpr
  ) where

import Data.List (intercalate)

type Name = String

-- | A whole program: a sequence of top-level declarations
-- (initial-bag block, bag blocks, bare machines for the implicit
-- @Global@ bag).
newtype Program = Program { progDecls :: [Decl] }
  deriving (Eq, Show)

data Decl
  = Bag Name [Decl]             -- ^ @Name { ... }@ — named bag of machines.
  | Initial [Expr]              -- ^ @{ ... }@ — initial bag tuples.
  | Machine [PatElem] [Action]  -- ^ @pat, pat : actions@ (join patterns).
  deriving (Eq, Show)

-- | Per-clause read mode. @Take@ = @in@ (consume, the default),
-- @Read@ = @rd@ (leave in the bag — the broadcast/fan-out mechanism).
data ReadMode = Take | Read
  deriving (Eq, Show)

data PatElem = PatElem ReadMode Pat
  deriving (Eq, Show)

data Pat
  = PVar Name                   -- ^ lowercase: variable
  | PAtom Name                  -- ^ capitalized: atom
  | PInt Integer
  | PDouble Double
  | PTuple [Pat]                -- ^ @()@, @(Tick,)@, @("add", a, b, c)@ —
                                --   string literals desugar (§9): a
                                --   pattern @"add"@ arrives here as the
                                --   codepoint cons-list @(97, (100, …))@.
  | PRest Name                  -- ^ @x!@ — trailing rest-capture (§11.1):
                                --   binds @x@ to a sub-tuple of the
                                --   matched tuple's remaining elements.
                                --   Trailing-only, var-only (parser
                                --   enforces); zero-or-more elements.
  deriving (Eq, Show)

data Op = Add | Sub | Mul | Div | Eq | Neq
  deriving (Eq, Show)

data Expr
  = EVar Name
  | EAtom Name
  | EInt Integer
  | EDouble Double
  | ETuple [Expr]               -- ^ string literals desugar (§9): an
                                --   expression @"hi"@ arrives here as the
                                --   codepoint cons-list @(104, (105, Nil))@.
  | ESplice Expr                -- ^ @e!@ — construction-side splice (§4).
  | ECall Name [Expr]           -- ^ builtin call, e.g. @rand(n)@, @typeOf(x)@.
  | EBin Op Expr Expr
  | ENeg Expr
  deriving (Eq, Show)

data Action
  = Out Expr                    -- ^ bare tuple emission (the default action).
  | Lob Name Expr               -- ^ @lob Bag (...)@ — cross-bag send (§6.1).
  | Say String [Expr]           -- ^ @say "fmt" args...@ — console side effect.
                                --   The format literal stays a raw
                                --   'String' on purpose: the say-position
                                --   is not an expression — the action
                                --   consumes the literal itself as a
                                --   format, never a bag value (§9;
                                --   provisional, flip-worthy).
  | Exit Expr
  | Die                         -- ^ @die@ \/ @quit@ — terminate this machine.
  | Sleep Expr                  -- ^ throttling back-off (§8); post-commit only.
  | Panic Expr                  -- ^ @panic e@ — fatal (§6.4).
  | Raise Expr                  -- ^ @error (...)@ — fire context into Error bag.
  | BytesBind Name Expr         -- ^ @bytesBind H [72, 105]@ (§9) — build a
                                --   UTF-8 bytestring from the codepoint list
                                --   and register it under the (compile-time-
                                --   chosen) atom handle. The runner emits a
                                --   @(Bytes, H)@ completion tuple into @Global@
                                --   once the side-table write lands.
  | BytesDestroy Expr           -- ^ @bytesDestroy e@ (§9) — drop the handle's
                                --   side-table entry (manual lifetime).
  | If Expr [Action] [Action]   -- ^ Terse @if@; branches are action sequences.
  deriving (Eq, Show)

--------------------------------------------------------------------------------
-- Pretty-printing
--------------------------------------------------------------------------------

renderProgram :: Program -> String
renderProgram (Program ds) = concatMap (\d -> renderDecl d ++ "\n") ds

renderDecl :: Decl -> String
renderDecl (Machine lhs body) = renderPatList lhs ++ " : " ++ renderActionSeq body
renderDecl (Initial ts) =
  "{\n" ++ concatMap (\t -> "  " ++ renderExpr t ++ ",\n") ts ++ "}"
renderDecl (Bag n ds) =
  n ++ " {\n"
  ++ concatMap (\d -> "  " ++ indent2 (renderDecl d) ++ "\n") ds
  ++ "}"

renderPatList :: [PatElem] -> String
renderPatList = intercalate ", " . map pe
  where
    pe (PatElem Take p) = renderPat p
    pe (PatElem Read p) = "rd " ++ renderPat p

renderPat :: Pat -> String
renderPat (PVar n)    = n
renderPat (PAtom n)   = n
renderPat (PInt i)    = show i
renderPat (PDouble d) = show d
renderPat (PRest n)   = n ++ "!"
renderPat (PTuple ps) = "(" ++ intercalate ", " (map renderPat ps) ++ ")"

-- | A single action renders bare; multiple render as a bracketed Terse
-- sequence @[a; b]@.
renderActionSeq :: [Action] -> String
renderActionSeq [a] = renderAction a
renderActionSeq as  = "[" ++ intercalate "; " (map renderAction as) ++ "]"

renderAction :: Action -> String
renderAction (Out e)      = renderExpr e
renderAction (Lob n e)    = "lob " ++ n ++ " " ++ renderExpr e
renderAction (Say f es)   = unwords ("say" : show f : map renderExpr es)
renderAction (Exit e)     = "exit " ++ renderExpr e
renderAction Die          = "die"
renderAction (Sleep e)    = "sleep " ++ renderExpr e
renderAction (Panic e)    = "panic " ++ renderExpr e
renderAction (Raise e)    = "error " ++ renderExpr e
renderAction (BytesBind h e) = "bytesBind " ++ h ++ " " ++ renderExpr e
renderAction (BytesDestroy e) = "bytesDestroy " ++ renderExpr e
renderAction (If c t e)   =
  "if " ++ renderExpr c ++ " then " ++ renderActionSeq t
  ++ " else " ++ renderActionSeq e

renderExpr :: Expr -> String
renderExpr (EVar n)     = n
renderExpr (EAtom n)    = n
renderExpr (EInt i)     = show i
renderExpr (EDouble d)  = show d
-- A one-element tuple needs a trailing comma to survive the round trip
-- (bare @(x)@ reparses as parenthesised grouping in expression position).
renderExpr (ETuple [e]) = "(" ++ renderElem e ++ ",)"
renderExpr (ETuple es)  = "(" ++ intercalate ", " (map renderElem es) ++ ")"
renderExpr (ESplice e)  = renderExpr e ++ "!"
renderExpr (ECall n es) = n ++ "(" ++ intercalate ", " (map renderExpr es) ++ ")"
renderExpr (EBin o a b) =
  "(" ++ renderExpr a ++ " " ++ renderOp o ++ " " ++ renderExpr b ++ ")"
renderExpr (ENeg e)     = "(-" ++ renderExpr e ++ ")"

renderElem :: Expr -> String
renderElem (ESplice e) = renderExpr e ++ "!"
renderElem e           = renderExpr e

renderOp :: Op -> String
renderOp Add = "+"
renderOp Sub = "-"
renderOp Mul = "*"
renderOp Div = "/"
renderOp Eq  = "=="
renderOp Neq = "!="

indent2 :: String -> String
indent2 = intercalate "\n" . map ("  " ++) . lines
