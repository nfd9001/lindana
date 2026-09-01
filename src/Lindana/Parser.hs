{-# LANGUAGE OverloadedStrings #-}

-- | Megaparsec parser for Lindana source text.
--
-- Layout strategy (handover §1 "one line by convention"): the parser
-- threads a bracket-nesting @Int@ state. Inside any @()@ @[]@ @{}@
-- grouping, newlines are insignificant whitespace; at depth zero a
-- newline is significant — it terminates a machine. Newlines are also
-- permitted after the structural separators @:@, @then@ and @else@ so
-- multi-line Terse machines like the §8.2 throttling example parse.
--
-- Deliberately not yet implemented (open questions §11): effect
-- bundles. No-LHS machines (§1 one-shots) are supported: @: actions@
-- parses as a machine with an empty join pattern.
--
-- List/cons sugar (§11.5, provisionally resolved) is desugared at
-- parse time: @[a, b, c]@ is nested 2-tuples ending in the @Nil@ atom,
-- @[h | t]@ conses onto an arbitrary tail expression/pattern, @[]@ is
-- @Nil@. Casual-string sugar (§9, provisionally resolved) likewise:
-- @\"...\"@ in expression or pattern position desugars to a cons-list
-- of codepoint ints — the same shape the list literal builds; plain
-- Ints all the way down, no Char type (§11.4, provisionally resolved).
-- Character sugar (§9, issue #12) completes the picture: @'x'@ is the
-- single codepoint as a plain Int, @''@ is a synonym for @Nil@, and
-- multiple codepoints wrapped in @''@ are a parse error (use a
-- string). All three are purely syntactic — the AST has no list,
-- string, or char nodes, so the pretty-printer renders the desugared
-- form (which round-trips). The one string literal that survives as a raw
-- 'String' is @say@'s format: that position is not an expression, the
-- action consumes the literal as a format.
module Lindana.Parser
  ( parseProgram
  , PError
  ) where

import Control.Monad (void, when)
import qualified Control.Monad.State.Strict as St
import Control.Monad.Trans.Class (lift)
import Data.Char (digitToInt, ord)
import Data.List (foldl')
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Text (Text)
import Data.Void (Void)
import Text.Megaparsec
import Text.Megaparsec.Char

import qualified Data.Set as Set
import qualified Data.Text as T

import Lindana.Syntax

type PError = ParseErrorBundle Text Void

-- | megaparsec 9 no longer re-exports 'chainl1'; local copy.
chainl1 :: Parser a -> Parser (a -> a -> a) -> Parser a
chainl1 p op = p >>= go
  where
    go x = (do f <- op; y <- p; go (f x y)) <|> pure x

-- | Bracket nesting depth: > 0 means we are inside @()@ \/ @[]@ \/ @{}@
-- where newlines are insignificant. At depth 0 a newline terminates a
-- machine.
type Parser = ParsecT Void Text (St.State Int)

parseProgram :: Text -> Either PError Program
parseProgram src = St.evalState (runParserT programP "" src) 0

--------------------------------------------------------------------------------
-- Lexer
--------------------------------------------------------------------------------

reservedWords :: Set.Set Text
reservedWords = Set.fromList
  [ "in", "inp", "rd", "out"
  , "if", "then", "else"
  , "say", "exit", "die", "quit", "sleep"
  , "lob", "error", "panic"
  , "rand", "typeOf", "atomize", "atos"
  , "bytesBind", "bytesDestroy", "bytesEqual", "bytesRead"
  , "import", "reroute"
  ]

-- | Whitespace consumer. At depth 0: spaces, tabs, CRs and @--@ line
-- comments, but never newlines. Inside brackets: all whitespace.
ws :: Parser ()
ws = hidden (skipMany (plainSpace <|> lineComment))
  where
    plainSpace = do
      d <- lift St.get
      if d > (0 :: Int)
        then void spaceChar
        else void (char ' ' <|> char '\t' <|> char '\r')
    lineComment = string "--" *> skipMany (noneOf ("\n" :: String))

-- | Skip blank and comment-only lines (used at declaration positions
-- and after the structural separators @:@, @then@, @else@).
skipLines :: Parser ()
skipLines = skipMany (ws >> void (char '\n') >> ws)

lexeme :: Parser a -> Parser a
lexeme p = p <* ws

symbolT :: Text -> Parser ()
symbolT s = lexeme (void (string s))

-- | A symbol that may not be followed by @=@ (so tuple splice @!@ never
-- swallows @!=@).
bangSym :: Parser ()
bangSym = lexeme (void (string "!") <* notFollowedBy (char '='))

-- | Reserved word. The identifier-boundary check must happen BEFORE
-- the trailing-whitespace consume: with @lexeme (string w) <*
-- notFollowedBy identChar@, the lexeme's whitespace consume would move
-- the position past e.g. the space in @if c@, and @c@ would then make
-- the boundary check reject the keyword.
rword :: Text -> Parser ()
rword w = try (void (string w) <* notFollowedBy identChar) <* ws

identChar :: Parser Char
identChar = alphaNumChar <|> char '_' <|> char '\''

checkReserved :: String -> Parser ()
checkReserved n =
  when (Set.member (T.pack n) reservedWords) $
    fail ("reserved word: " ++ n)

-- | Lowercase identifier: a variable (capitalized = atom, §4 — the
-- inverse of Prolog, on purpose).
varIdent :: Parser String
varIdent = lexeme $ do
  c <- lowerChar
  rest <- many identChar
  let n = c : rest
  n <$ checkReserved n

-- | Capitalized identifier: atom \/ type tag \/ bag name.
atomIdent :: Parser String
atomIdent = lexeme $ do
  c <- upperChar
  rest <- many identChar
  pure (c : rest)

intLit :: Parser Integer
intLit = lexeme (digits <* notFollowedBy (char '.'))
  where
    digits = foldl' (\a c -> a * 10 + toInteger (digitToInt c)) 0
               <$> some digitChar

doubleLit :: Parser Double
doubleLit = lexeme . try $ do
  ip <- some digitChar
  _ <- char '.'
  fp <- some digitChar
  pure (read (ip ++ '.' : fp) :: Double)

-- | A string literal, escapes resolved. In expression or pattern
-- position this is immediately desugared to codepoints (§9 sugar,
-- see 'strExpr'/'strPat'); the one raw consumer is @say@'s format.
stringLit :: Parser String
stringLit = lexeme $ do
  _ <- char '"'
  manyTill (escape <|> noneOf ("\"\\" :: String)) (char '"')
  where
    escape = char '\\' *> choice
      [ '\n' <$ char 'n'
      , '\t' <$ char 't'
      , '"'  <$ char '"'
      , '\\' <$ char '\\'
      ]

-- | Bracketed group: opening char, contents with newlines allowed
-- (depth bumped), closing char. Used for @()@ and @[]@ — NOT for @{}@
-- bag blocks, whose declarations are newline-separated.
grouped :: Char -> Char -> Parser a -> Parser a
grouped open close p = do
  _ <- char open
  lift (St.modify' (+ (1 :: Int)))
  ws
  r <- p
  lift (St.modify' (subtract 1))
  _ <- char close
  ws
  pure r

-- | Structural separator that tolerates surrounding newlines: @:@,
-- @then@, @else@.
sepKw :: Text -> Parser ()
sepKw w = skipLines >> rword w >> skipLines

-- | A machine ends at end-of-line (or EOF). Only reachable at depth 0.
-- A @}@ at depth 0 also ends a machine — it can only be the closing
-- brace of an enclosing bag block (@Name { (Ping,) : die }@ on one
-- line); the block's own parser consumes it next.
endOfMachine :: Parser ()
endOfMachine = try (ws >> char '\n' >> ws >> skipLines)
           <|> try (ws >> void (lookAhead (char '}')))
           <|> (ws >> eof)

--------------------------------------------------------------------------------
-- Patterns
--------------------------------------------------------------------------------

patternP :: Parser Pat
patternP = choice
  [ listPat
  , tuplePat
  , PAtom   <$> atomIdent
  , PVar    <$> varIdent
  , PDouble <$> doubleLit
  , PInt    <$> intLit
  , strPat
  , charPat
  ]

-- | Character literal, escapes resolved: the contents between two
-- quotes. Empty is legal (@''@ — the issue #12 Nil synonym); more than
-- one codepoint is the caller's parse error (use a string, §9).
charLit :: Parser String
charLit = lexeme $ do
  _ <- char '\''
  manyTill (cescape <|> noneOf ("'\\" :: String)) (char '\'')
  where
    cescape = char '\\' *> choice
      [ '\n' <$ char 'n'
      , '\t' <$ char 't'
      , '\'' <$ char '\''
      , '\\' <$ char '\\'
      ]

-- | Character sugar (§9, issue #12, provisional): @'+'@ desugars to
-- the plain codepoint Int @43@ — no Char type, plain Ints all the way
-- down (§11.4) — so @'a'@ IS @97@ and builds lists and bytestrings
-- like any other codepoint. @''@ is a synonym for the @Nil@ atom (an
-- empty char is an empty something). Wrapping multiple codepoints is a
-- parse error — that's what string sugar is for (§9). No AST node:
-- the renderer emits the desugared form.
charPat :: Parser Pat
charPat = do
  cs <- charLit
  case cs of
    []  -> pure (PAtom "Nil")
    [c] -> pure (PInt (toInteger (ord c)))
    _   -> fail "multiple codepoints in '…' — use a string (§9)"

-- | Casual-string pattern sugar (§9, provisional): @\"add\"@
-- desugars to the codepoint cons-list pattern @(97, (100, (100, Nil)))@ —
-- the same shape the §11.5 list pattern builds, so structural matching
-- needs no new cases. Plain Ints all the way down (§11.4, provisionally
-- resolved): no Char, no PStr node.
strPat :: Parser Pat
strPat = (foldr (\c p -> PTuple [PInt (toInteger (ord c)), p]) (PAtom "Nil"))
           <$> stringLit

-- | List/cons pattern sugar (§11.5, provisional): @[p1, p2 | t]@
-- desugars to @(p1, (p2, t))@, @[]@ to the @Nil@ atom. Elements are
-- plain patterns — rest-capture @var!@ is a tuple-level concept (the
-- cons tail @| t@ is the list-shaped way to bind the remainder).
listPat :: Parser Pat
listPat = grouped '[' ']' $ do
  mhs <- optional elems
  pure (mk mhs)
  where
    elems = do
      hs <- patternP `sepBy1` symbolT ","
      mt <- optional (symbolT "|" *> patternP)
      pure (hs, mt)
    mk Nothing                  = PAtom "Nil"
    mk (Just (hs, mt)) =
      foldr (\p acc -> PTuple [p, acc]) (fromMaybe (PAtom "Nil") mt) hs

-- | Tuple pattern. A trailing comma marks arity, e.g. @(Tick,)@;
-- @()@ is the empty tuple. An element followed by @!@ is a rest
-- capture (§11.1, provisionally resolved): it must be a variable
-- (@var!@ — a capture needs somewhere to bind) and it must be the
-- LAST element. Mid and trailing capture are mutually exclusive
-- without language extensions: mid captures make the alignment of
-- intervening fixed elements indeterminate under the natural
-- "find an assignment" reading (e.g. where does @c@ sit in
-- @(a, b!, c, d!)@?). The trailing form needs no such reasoning —
-- "everything after position N".
tuplePat :: Parser Pat
tuplePat = grouped '(' ')' $ do
  ps <- patElem' `sepEndBy` symbolT ","
  trailingOnly ps
  pure (PTuple ps)
  where
    patElem' = do
      p <- patternP
      spliced <- isJust <$> optional bangSym
      case (spliced, p) of
        (False, _)      -> pure p
        (True, PVar n)  -> pure (PRest n)
        (True, _)       -> fail "pattern rest-capture binds a variable: write var! (§11.1)"
    -- Any PRest must be the final element.
    trailingOnly []       = pure ()
    trailingOnly [_]      = pure ()
    trailingOnly (PRest _ : _) =
      fail "mid rest-capture: only trailing capture is supported (§11.1)"
    trailingOnly (_ : ps) = trailingOnly ps

patElemP :: Parser PatElem
patElemP = choice
  [ rword "rd" *> (PatElem Read <$> patternP)
  , (\p -> PatElem Take p) <$> patternP
  ]

--------------------------------------------------------------------------------
-- Expressions
--------------------------------------------------------------------------------

exprP :: Parser Expr
exprP = chainl1 addP (binop Eq "==" <|> binop Neq "!=")
  where
    binop o s = (\a b -> EBin o a b) <$ symbolT s

addP :: Parser Expr
addP = chainl1 mulP (plus <|> minus)
  where
    plus  = (\a b -> EBin Add a b) <$ symbolT "+"
    minus = (\a b -> EBin Sub a b) <$ symbolT "-"

mulP :: Parser Expr
mulP = chainl1 primP (times <|> divide)
  where
    times  = (\a b -> EBin Mul a b) <$ symbolT "*"
    divide = (\a b -> EBin Div a b) <$ symbolT "/"

primP :: Parser Expr
primP = choice
  [ callP
  , parenExpr
  , listExpr
  , strExpr
  , charExpr
  , EDouble <$> doubleLit
  , EInt    <$> intLit
  , EAtom   <$> atomIdent
  , EVar    <$> varIdent
  , ENeg    <$> (symbolT "-" *> primP)
  ]

-- | Casual-string literal sugar (§9, provisional): @\"hi\"@ desugars
-- to @(104, (105, Nil))@ — a cons-list of codepoint ints, the same
-- shape the §11.5 list literal builds (@[104, 105]@ IS @\"hi\"@).
-- Plain Ints all the way down (§11.4, provisionally resolved); no
-- EStr node, so the renderer emits the desugared form.
strExpr :: Parser Expr
strExpr = (foldr (\c e -> ETuple [EInt (toInteger (ord c)), e]) (EAtom "Nil"))
            <$> stringLit

-- | Character sugar in expression position — see 'charPat' (the
-- desugaring is the same, over 'Expr').
charExpr :: Parser Expr
charExpr = do
  cs <- charLit
  case cs of
    []  -> pure (EAtom "Nil")
    [c] -> pure (EInt (toInteger (ord c)))
    _   -> fail "multiple codepoints in '…' — use a string (§9)"

-- | Builtin function application: @rand(n)@, @typeOf(x)@, @atomize s@,
-- @atos a@.
callP :: Parser Expr
callP = choice
  [ rword (T.pack n) *> (ECall n <$> grouped '(' ')' (exprP `sepBy` symbolT ","))
  | n <- ["rand", "typeOf", "atomize", "atos", "bytesEqual", "bytesRead"] :: [String]
  ]

-- | Parenthesised expression: with no comma it is grouping, with a
-- comma (or trailing comma) it is a tuple. @()@ is the empty tuple.
parenExpr :: Parser Expr
parenExpr = grouped '(' ')' $ do
  mf <- optional exprP
  case mf of
    Nothing -> pure (ETuple [])
    Just e -> do
      hasComma <- isJust <$> optional (symbolT ",")
      if not hasComma
        then pure e
        else do
          me2 <- optional tupleElem
          case me2 of
            Nothing -> pure (ETuple [e])       -- trailing comma: 1-tuple
            Just e2 -> do
              more <- many (symbolT "," *> optional tupleElem)
              pure (ETuple (e : e2 : catMaybes more))

-- | Element of a tuple in construction position: an expression with an
-- optional trailing @!@ splice (§4 — the continuation-passing core).
tupleElem :: Parser Expr
tupleElem = do
  e <- exprP
  spliced <- isJust <$> optional bangSym
  pure (if spliced then ESplice e else e)

-- | Parentheses always mean tuple here (action\/tuple context, unlike
-- 'parenExpr').
tupleExpr :: Parser Expr
tupleExpr =
  ETuple <$> grouped '(' ')' (tupleElem `sepEndBy` symbolT ",")

-- | List/cons literal sugar (§11.5, provisional): @[e1, e2, e3]@
-- desugars to @(e1, (e2, (e3, Nil)))@, @[h | t]@ conses onto an
-- arbitrary tail expression, @[]@ is the @Nil@ atom. Elements are
-- tuple elements (so @!@ splice works), same as in tuples.
listExpr :: Parser Expr
listExpr = grouped '[' ']' $ do
  mhs <- optional elems
  pure (mk mhs)
  where
    elems = do
      hs <- tupleElem `sepBy1` symbolT ","
      mt <- optional (symbolT "|" *> tupleElem)
      pure (hs, mt)
    mk Nothing                  = EAtom "Nil"
    mk (Just (hs, mt)) =
      foldr (\e acc -> ETuple [e, acc]) (fromMaybe (EAtom "Nil") mt) hs

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

actionListP :: Parser [Action]
actionListP = bracketSeq <|> (:[]) <$> actionP
  where
    bracketSeq = grouped '[' ']' (actionP `sepBy` symbolT ";")

actionP :: Parser Action
actionP = choice
  [ ifP
  , lobP
  , rerouteP
  , bytesBindP
  , bytesDestroyP
  , importP
  , sayP
  , exitP
  , sleepP
  , panicP
  , errorP
  , rword "die"  *> pure Die
  , rword "quit" *> pure Die
  , Out <$> tupleExpr
  ]

-- | A bag name in action position: usually a capitalized atom as
-- written, but a lowercase variable is legal — the bag name travels
-- as data (issue #17, §13.13: modules reply into caller-named bags,
-- since their own mentions of @Global@ are mangled away). Shared by
-- @lob@'s target and @reroute@'s source and target.
bagTarget :: Parser Expr
bagTarget = (EAtom <$> atomIdent) <|> (EVar <$> varIdent)

ifP :: Parser Action
ifP = do
  rword "if"
  c <- exprP
  sepKw "then"
  t <- actionListP
  sepKw "else"
  e <- actionListP
  pure (If c t e)

lobP :: Parser Action
-- The target is usually a capitalized atom, but a lowercase variable
-- is legal: the bag name as data (issue #17, §13.13 — modules reply
-- into caller-named bags).
lobP = rword "lob" *> (Lob <$> bagTarget <*> tupleExpr)

-- | Issue #17 (§13.14): @reroute Src Tgt@ — both arguments are bag
-- names (atoms, or variables holding bag names as data): errors raised
-- by machines declared in bag @Src@ land in bag @Tgt@ instead of the
-- Error bag. @Tgt@ may also be a module's mangled Error bag, which
-- stands for "all bags in the module" (§13.14).
rerouteP :: Parser Action
rerouteP = rword "reroute" *> (Reroute <$> bagTarget <*> bagTarget)

sayP :: Parser Action
sayP = do
  rword "say"
  f <- stringLit
  args <- sayArgs
  pure (Say f args)
  where
    -- Greedy args, but never cross a newline: at depth 0 the newline
    -- that terminates this machine must not be swallowed by the next
    -- argument (a '(' on the following line is a new machine, not an
    -- argument).
    sayArgs = many (try (lookAhead argStart >> exprP))
    argStart = void (letterChar <|> digitChar <|> char '"' <|> char '('
                     <|> char '-')

exitP :: Parser Action
exitP = rword "exit" *> (Exit <$> exprP)

sleepP :: Parser Action
sleepP = rword "sleep" *> (Sleep <$> exprP)

panicP :: Parser Action
panicP = rword "panic" *> (Panic <$> exprP)

errorP :: Parser Action
errorP = rword "error" *> (Raise <$> tupleExpr)

-- | §9 bytestring verbs. The handle of @bytesBind@ is a capitalized
-- atom — compile-time-chosen, per the §6.4/§8 one-shot pattern for
-- statics (the completion tuple @(Bytes, H)@ is what consumers join
-- on). @bytesDestroy@ takes any expression (which must evaluate to an
-- atom).
bytesBindP :: Parser Action
bytesBindP = rword "bytesBind" *> (BytesBind <$> atomIdent <*> exprP)

bytesDestroyP :: Parser Action
bytesDestroyP = rword "bytesDestroy" *> (BytesDestroy <$> exprP)

-- | Issue #17 (§13.13): @import H S Hide@ — three expressions: the
-- module-name handle, the namespace-suffix handle, and the hide list
-- (a cons-list of atoms; @[]@ for none). The handles' /contents/ are
-- looked up in the bytestring side-table by the effect runner, so
-- module names are runtime data.

importP :: Parser Action
importP = rword "import" *> (Import <$> exprP <*> exprP <*> exprP)

--------------------------------------------------------------------------------
-- Declarations & program
--------------------------------------------------------------------------------

programP :: Parser Program
programP = do
  ws
  ds <- many (try (skipLines >> declInner))
  ws
  skipLines
  eof
  pure (Program ds)

declInner :: Parser Decl
declInner = choice
  [ bagBlockP
  , initialBlockP
  , machineP
  ]

-- | @Name { ... }@ — a named bag. Braces do NOT raise the newline
-- depth: machines inside are one-per-line, like at top level.
bagBlockP :: Parser Decl
bagBlockP = do
  n <- try (atomIdent <* char '{')
  ws
  ds <- many (try (skipLines >> declInner))
  ws
  skipLines
  _ <- char '}'
  ws
  pure (Bag n ds)

-- | @{ ... }@ — initial bag tuples. Comma-separated, newlines allowed
-- (this group does raise the newline depth).
initialBlockP :: Parser Decl
initialBlockP = do
  ts <- grouped '{' '}' (tupleExpr `sepEndBy` symbolT ",")
  endOfMachine
  pure (Initial ts)

machineP :: Parser Decl
machineP = do
  -- §1: the LHS may be empty — a no-LHS machine (@: actions@) runs
  -- once, unconditionally, at program start, then terminates. The
  -- colon is kept so the one-shot form is visually distinct from an
  -- expression-led line.
  lhs <- patElemP `sepBy` symbolT ","
  sepKw ":"
  body <- actionListP
  endOfMachine
  pure (Machine lhs body)
