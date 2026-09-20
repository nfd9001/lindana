{-# LANGUAGE TupleSections #-}

-- | Random generators for the fuzzing suite (issue #41).
--
-- Hand-rolled over "System.Random" — the only RNG the library already
-- depends on (no QuickCheck/Hedgehog dep; the seed /is/ the replay
-- mechanism: a failing iteration is reported with the master seed and
-- its index, and @LINDANA_FUZZ_SEED=<seed>@ regenerates the exact
-- failing case, no shrinking needed. Provisional, flip-worthy: if
-- shrinking earns its keep later, swap the carrier for a real library
-- and keep the domain generators).
--
-- The domain generators produce *well-typed* Lindana shapes — the
-- parser's own constraints (trailing-only rest capture, the reserved
-- words, the §13.24 literal-only auto-promotion, @say@'s raw-string
-- format) are encoded here so generated ASTs render and reparse.
module Lindana.Fuzz.Gen
  ( -- * The carrier
    Rand
  , evalRand
  , randIO
    -- * Combinators
  , randInt
  , randR
  , choose
  , elements
  , weighted
  , listOf
    -- * Name generators
  , genVarName
  , genAtomName
  , genBagName
    -- * Value / pattern generators
  , genVal
  , genPat
  , genJoin
    -- * AST generators
  , genExpr
  , genTupleExpr
  , genAction
  , genActionSeq
  , genDecl
  , genProgram
    -- * Corpus mutation
  , mutateText
  ) where

import qualified Data.Set as Set
import qualified Data.Text as T
import System.Random (StdGen, uniformR, newStdGen)

import Lindana.Parser (reservedWords)
import Lindana.Runtime (Val (..))
import Lindana.Syntax

--------------------------------------------------------------------------------
-- The carrier: StdGen threading, hand-rolled
--------------------------------------------------------------------------------

newtype Rand a = Rand { unRand :: StdGen -> (a, StdGen) }

instance Functor Rand where
  fmap f (Rand g) = Rand $ \s -> let (a, s') = g s in (f a, s')

instance Applicative Rand where
  pure a = Rand (a,)
  Rand f <*> Rand g = Rand $ \s ->
    let (h, s1) = f s
        (a, s2) = g s1
    in (h a, s2)

instance Monad Rand where
  Rand g >>= f = Rand $ \s ->
    let (a, s1) = g s
        Rand h = f a
    in h s1

-- | Run a generator from a seed.
evalRand :: Rand a -> StdGen -> a
evalRand g s = fst (unRand g s)

-- | Run a generator from system entropy.
randIO :: Rand a -> IO a
randIO g = do
  s <- newStdGen
  pure (evalRand g s)

--------------------------------------------------------------------------------
-- Combinators
--------------------------------------------------------------------------------

-- | Raw Int draw (the GHC 9.0 'System.Random' API: 'next' + 'split').
randInt :: Rand Int
randInt = Rand $ \s ->
  let (i, s') = uniformR (minBound, maxBound) s in (i, s')

-- | Uniform over a range (inclusive; proper sampling via 'uniformR').
randR :: Int -> Int -> Rand Int
randR lo hi = Rand $ \s -> uniformR (lo, hi) s

-- | Uniform over a list; empty list is the caller's bug.
elements :: [a] -> Rand a
elements xs = (xs !!) <$> randR 0 (length xs - 1)

-- | Weighted choice: (weight, generator) pairs.
weighted :: [(Int, Rand a)] -> Rand a
weighted opts = do
  let total = sum (map fst opts)
      pick n ((w, g) : rest)
        | n < w     = g
        | otherwise = pick (n - w) rest
      pick _ [] = error "weighted: empty"
  n <- randR 0 (total - 1)
  pick n opts

choose :: Int -> Int -> Rand Int
choose = randR

-- | A list of 0..n elements (nonempty variants: filter).
listOf :: Int -> Rand a -> Rand [a]
listOf n g = do
  k <- randR 0 n
  mapM (const g) [1 .. k]

--------------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------------

-- | Small vocabularies keep the generators chatty about the
-- interesting corners (repeats, collisions) instead of the boring
-- ones (name variety).
varVocab, atomVocab :: [String]
varVocab  = ["x", "y", "n", "c", "rest", "n1", "tail"]
atomVocab = ["Go", "Ping", "Job", "Done", "Print", "Stop", "Stats",
             "Add", "True", "False", "Nil", "Bytes", "Error", "Global"]

-- | A lowercase identifier that is not a reserved word (the parser's
-- 'varIdent' rejects those).
genVarName :: Rand String
genVarName = elements (filter (`Set.notMember` reservedWords') varVocab)
  where reservedWords' = Set.map T.unpack reservedWords

-- | A capitalized identifier. Atoms carry no reserved check in the
-- parser (every reserved word is lowercase), so the vocab goes
-- through as-is.
genAtomName :: Rand String
genAtomName = elements atomVocab

-- | A bag name: an atom, same rules.
genBagName :: Rand String
genBagName = genAtomName

--------------------------------------------------------------------------------
-- Values / patterns (the matcher properties)
--------------------------------------------------------------------------------

-- | Depth-limited runtime value. Doubles are quarters in @[0, 10^7)@ —
-- exactly representable, so 'show' renders plain decimal notation,
-- which is all the parser's 'doubleLit' accepts (no exponent form).
genVal :: Int -> Rand Val
genVal 0 = weighted
  [ (3, VAtom <$> genAtomName)
  , (3, VInt . toInteger <$> randR (-20) 100)
  , (2, VDouble . (/ 4) . fromIntegral <$> randR 0 28000000)
  ]
genVal d = weighted
  [ (5, genVal 0)
  , (3, VTuple <$> listOf' 0 4 (genVal (d - 1)))
  ]
  where
    listOf' lo hi g = do
      k <- randR lo hi
      mapM (const g) [1 .. k]

-- | A leaf pattern.
genLeafPat :: Rand Pat
genLeafPat = weighted
  [ (3, PVar <$> genVarName)
  , (3, PAtom <$> genAtomName)
  , (3, PInt . toInteger <$> randR 0 50)
  , (2, PDouble . (/ 4) . fromIntegral <$> randR 0 400)
  ]

-- | Depth-limited pattern. Rest capture (@PRest@) only ever trails a
-- tuple — the parser enforces trailing-only, var-only (§11.1), and the
-- generator obeys so rendered ASTs reparse.
genPat :: Int -> Rand Pat
genPat 0 = genLeafPat
genPat d = weighted
  [ (6, genLeafPat)
  , (4, genTuplePat (d - 1))
  ]
  where
    genTuplePat d' = do
      fixed <- mapM (const (genPat d')) =<< randList 0 3
      withRest <- weighted [(2, pure True), (3, pure False)]
      case withRest of
        False -> pure (PTuple fixed)
        True -> do
          n <- genVarName
          pure (PTuple (fixed ++ [PRest n]))
    randList lo hi = do
      k <- randR lo hi
      pure [1 .. k]

-- | A join: 1–3 clauses, Take or Read (§3.4).
genJoin :: Rand [PatElem]
genJoin = do
  k <- randR 1 3
  mapM clause [1 .. k]
  where
    clause _ = do
      d <- randR 0 1
      p <- genPat d
      mode <- weighted [(3, pure Take), (2, pure Read)]
      pure (PatElem mode p)

--------------------------------------------------------------------------------
-- Expressions / actions / programs (the parser round-trip property)
--------------------------------------------------------------------------------

-- | Depth-limited expression. Constraints that keep renders parseable:
--
--   * non-negative Ints and quarter doubles (the parser has no signed
--     literals; @ENeg@ carries the negatives),
--   * @ECall@ only the seven builtins, at their true arities,
--   * @ESplice@ only ever wraps a non-splice expression /inside/ a
--     tuple or list element (the bang is a tuple-position concept).
genExpr :: Int -> Rand Expr
genExpr 0 = weighted
  [ (3, EVar <$> genVarName)
  , (3, EAtom <$> genAtomName)
  , (3, EInt . toInteger <$> randR 0 100)
  , (2, EDouble . (/ 4) . fromIntegral <$> randR 0 400)
  ]
genExpr d = weighted
  [ (6, genExpr 0)
  , (3, genTupleExpr (d - 1) False)
  , (2, EBin <$> genOp <*> genExpr (d - 1) <*> genExpr (d - 1))
  , (1, ENeg <$> genExpr 0)
  , (1, genCall)
  ]
  where
    genOp = elements [Add, Sub, Mul, Div, Eq, Neq, Lt, Gt, Le, Ge]
    genCall = do
      (n, arity) <- elements
        [ ("rand", 1 :: Int), ("typeOf", 1), ("atomize", 1), ("atos", 1)
        , ("bytesEqual", 2), ("bytesRead", 1), ("bytesCompare", 2)
        ]
      ECall n <$> mapM (const (genExpr (d - 1))) [1 .. arity]

-- | A tuple. @Out@, @Raise@, @lob@'s target tuple and initial-bag
-- tuples are parsed by 'tupleExpr' directly — every element goes
-- through 'tupleElem', so @!@ splices survive the round trip. A tuple
-- nested inside another expression is parsed by 'parenExpr', whose
-- grouping path drops a spliced element (the bang after a bare
-- parenthesized expr never reaches 'tupleElem') — so splices are
-- only generated when @allowSplice@ is set, which the callers below
-- pass only for the direct-'tupleExpr' positions.
genTupleExpr :: Int -> Bool -> Rand Expr
genTupleExpr d allowSplice = do
  k <- randR 0 3
  es <- mapM genElem [1 :: Int .. k]
  pure (ETuple es)
  where
    genElem _
      | not allowSplice = genExpr (d - 1)
      | otherwise = weighted
          [ (4, genExpr (d - 1))
          , (1, ESplice <$> spliceable)
          ]
    spliceable = weighted
      [ (3, EVar <$> genVarName)
      , (2, genTupleExpr (d - 1) False)
      , (2, EAtom <$> genAtomName)
      ]

-- | @say@'s format stays a raw 'String' — the one literal the parser
-- keeps whole. 'show' escapes it, and the parser's escapes cover
-- \\n \\t \\" \\\\ only, so the generator sticks to printable ASCII
-- plus newline and tab.
genSayFormat :: Rand String
genSayFormat = do
  k <- randR 0 12
  mapM (const one) [1 .. k]
  where
    one = weighted
      [ (6, elements ['a' .. 'z'])
      , (2, elements ['A' .. 'Z'])
      , (2, elements "0123456789 ")
      , (2, elements "%i%s ")
      , (1, elements "\n\t")
      ]

-- | One action. Only shapes the parser accepts as written (see the
-- per-verb constraints in Lindana.Syntax).
genAction :: Int -> Rand Action
genAction d = weighted
  [ (3, Out <$> genTupleExpr (d - 1) True)
  , (2, pure Die)
  , (2, Exit <$> genExpr (d - 1))
  , (2, Sleep <$> genExpr 0)
  , (1, Panic <$> genExpr (d - 1))
  , (1, Raise <$> genTupleExpr (d - 1) True)
  , (1, Say <$> genSayFormat <*> mapM (const (genExpr 0)) [1 :: Int .. 1])
  , (1, Lob <$> genBagTarget <*> genTupleExpr (d - 1) True)
  , (1, Reroute <$> genBagTarget <*> genBagTarget)
  , (1, SayFd <$> genBagTarget <*> genBagTarget)
  , (1, BytesBind <$> genAtomName <*> genExpr (d - 1))
  , (1, BytesDestroy <$> genExpr (d - 1))
  , (1, BytesNew <$> genExpr (d - 1))
  , (1, FClose <$> genExpr (d - 1))
  , (1, FRead <$> genExpr (d - 1))
  , (1, FWrite <$> genExpr (d - 1) <*> genExpr (d - 1))
  , (1, FOpen <$> genAtomName <*> genExpr (d - 1) <*> genExpr 0)
  , (1, Import <$> genExpr 0 <*> genExpr 0 <*> genExpr 0)
  , (1, ifAction)
  ]
  where
    genBagTarget = weighted
      [ (2, EAtom <$> genBagName)
      , (1, EVar <$> genVarName)
      ]
    ifAction = do
      c <- genExpr (d - 1)
      t <- genActionSeq (d - 1)
      e <- genActionSeq (d - 1)
      pure (If c t e)

-- | A nonempty action sequence (a machine body or an @if@ branch).
genActionSeq :: Int -> Rand [Action]
genActionSeq d = do
  k <- randR 1 3
  mapM (const (genAction d)) [1 .. k]

-- | A declaration. Constraints:
--
--   * bags are flat (nested bag blocks are a parse error),
--   * pragmas are top-level only and only the known @no-prelude@,
--   * machine bodies are nonempty (an empty body is a parse error).
genDecl :: Int -> Rand Decl
genDecl d = weighted
  [ (6, joinMachine)
  , (2, Initial <$> listOf 3 (genTupleExpr (d - 1) True))
  , (2, Bag <$> genBagName <*> inner)
  , (1, pure (Pragma "no-prelude"))
  ]
  where
    joinMachine = do
      n <- randR 0 2
      lhs <- mapM (const (joinClause (d - 1))) [1 .. n]
      body <- genActionSeq d
      pure (Machine lhs body)
    joinClause d' = do
      p <- genPat d'
      mode <- weighted [(3, pure Take), (2, pure Read)]
      pure (PatElem mode p)
    inner =
      if d <= 1
        then pure []
        else (: []) <$> weighted
          [ (5, joinMachine')
          , (2, Initial <$> listOf 2 (genTupleExpr (d - 1) True))
          ]
          where joinMachine' = do
                  n <- randR 0 2
                  lhs <- mapM (const (joinClause (d - 1))) [1 .. n]
                  body <- genActionSeq d
                  pure (Machine lhs body)

-- | A whole program: 1–6 top-level declarations. Bag-in-bag and
-- pragma-in-bag stay out (parse errors, not loader rules).
genProgram :: Int -> Rand Program
genProgram = \d -> do
  k <- randR 1 6
  ds <- mapM (const (genDecl d)) [1 .. k]
  pure (Program ds)

--------------------------------------------------------------------------------
-- Corpus mutation (parse-robustness fuzzing)
--------------------------------------------------------------------------------

-- | Byte-level mutation of source text: drop, replace, insert, or
-- truncate at a random offset. Inserted characters are printable
-- ASCII or newline — enough to explore the parser's grammar, and
-- every inserted char is a char the renderer's 'show' could emit.
mutateText :: T.Text -> Rand T.Text
mutateText t
  | T.null t = pure (T.singleton '\n')
  | otherwise = do
      i <- randR 0 (T.length t - 1)
      c <- genChar
      weighted
        [ (2, pure (T.take i t <> T.drop (i + 1) t))          -- drop
        , (2, pure (T.take i t <> T.singleton c <> T.drop (i + 1) t))  -- replace
        , (2, pure (T.take i t <> T.singleton c <> T.drop i t))        -- insert
        , (1, pure (T.take i t))                              -- truncate
        ]
  where
    genChar = weighted
      [ (6, elements ['a' .. 'z'])
      , (3, elements ['A' .. 'Z'])
      , (3, elements "0123456789(){},:[]")
      , (2, elements " \n\t")
      , (1, elements "!\"#%&'*+-./;<=>?@^_`|~")
      ]
