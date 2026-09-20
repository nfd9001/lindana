-- | The fuzzing properties (issue #41, Tier 0): independent
-- implementations as oracles, run against the real ones over
-- generated cases. No shrinking — the seed is the replay mechanism
-- (@LINDANA_FUZZ_SEED=<seed>@ regenerates every case deterministically:
-- FuzzMain splits the master seed per iteration, and the property
-- bodies do all generation from that iteration's sub-seed).
--
-- Properties:
--
--   1. 'matchPat' vs. a requirement-tree model (an independent
--      structural matcher: 'modelPat').
--   2. 'matchJoinSTM' vs. an oracle join matcher built on 'modelPat'
--      ('oracleJoin'), plus a bag-content check (the bag after is the
--      bag before minus the Take clauses' picks, in order).
--   3. 'casualString'\\/'stringVal' round-trips over random strings and
--      a scalar sweep; surrogate codepoints (D800..DFFF) error — the
--      bug this suite exists to keep pinning (found here before the
--      fix: they silently became U+FFFD at the encodeUtf8 boundary).
--   4. Parser round-trip on generated ASTs: render, reparse, equal.
--   5. Corpus mutation fuzzing: byte-mutated examples and test
--      modules parse to a 'Left' or a round-tripping 'Right' — never
--      a crash.
module Lindana.Fuzz.Spec
  ( PropertySpec (..)
  , Property
  , propertySpecs
  , scalarValues
  , isSurrogate
  , modelPat
  , oracleJoin
  , matchReq
  , Req (..)
  , reqOf
  ) where

import Control.Exception (SomeException, evaluate, try)
import Control.Concurrent.STM (atomically, readTVar)
import Data.Char (ord)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import System.Random (StdGen)
import Text.Megaparsec.Error (errorBundlePretty)

import Lindana.Parser (parseProgram)
import Lindana.Runtime
import Lindana.Syntax

import Lindana.Fuzz.Gen

--------------------------------------------------------------------------------
-- The property harness
--------------------------------------------------------------------------------

-- | A property body: given the iteration's sub-seed, generate a case
-- and run its checks in IO (STM needs it; Haskell-level @error@s —
-- which ARE the contract for some code paths, §3.3 — are caught with
-- 'try'). Returns the counterexample description on failure.
type Property = StdGen -> IO (Maybe String)

-- | One property's spec.
data PropertySpec = PropertySpec
  { propName :: String
  , propBody :: Property
  }

propertySpecs :: [(FilePath, T.Text)] -> [PropertySpec]
propertySpecs corpus =
  [ PropertySpec "matchPat vs model (§3.2)"                propMatchPat
  , PropertySpec "matchJoinSTM vs oracle (§3.4)"           propJoin
  , PropertySpec "casualString/stringVal round-trip (§9)"  propStrings
  , PropertySpec "parser round-trip on generated ASTs"     propRoundTrip
  , PropertySpec "corpus mutation never crashes"           (propCorpus corpus)
  ]

--------------------------------------------------------------------------------
-- Property 1: matchPat vs an independent model
--------------------------------------------------------------------------------

-- | The model's requirement tree — a different formulation from
-- 'matchPat''s env-threading recursion: requirements match values
-- positionally, with an explicit arity rule and an explicit rest rule.
data Req
  = RVar Name
  | RAtom Name
  | RInt Integer
  | RDouble Double
  | RTuple [Req]              -- ^ exact arity, elementwise
  | RRest [Req] Name          -- ^ fixed prefix reqs, then the rest binds
  deriving (Eq, Show)

-- | Pat → Req. The parser guarantees 'PRest' is trailing and
-- var-only; a top-level @x!@ pattern is @RRest [] n@.
reqOf :: Pat -> Req
reqOf (PVar n)    = RVar n
reqOf (PAtom a)   = RAtom a
reqOf (PInt i)    = RInt i
reqOf (PDouble d) = RDouble d
reqOf (PRest n)   = RRest [] n
reqOf (PTuple ps) = case reverse ps of
  (PRest n : fixedRev) -> RRest (map reqOf (reverse fixedRev)) n
  _                    -> RTuple (map reqOf ps)

-- | The model matcher. Bind-or-equal on repeats (§11.2), structural
-- equality on leaves, exact tuple arity, rest = sub-tuple of the
-- remaining elements — and a tuple requirement never matches a
-- non-tuple.
modelPat :: Pat -> Val -> Env -> Maybe Env
modelPat p v env = matchReq (reqOf p) v env

matchReq :: Req -> Val -> Env -> Maybe Env
matchReq (RVar n) v env = case Map.lookup n env of
  Just v' | v == v'   -> Just env
          | otherwise -> Nothing
  Nothing -> Just (Map.insert n v env)
matchReq (RAtom a) (VAtom b) env | a == b = Just env
matchReq (RInt i) (VInt j) env | i == j = Just env
matchReq (RDouble x) (VDouble y) env | x == y = Just env
matchReq (RTuple rs) (VTuple vs) env
  | length rs == length vs = foldM2 matchReq rs vs env
matchReq (RRest fixed n) (VTuple vs) env
  | length fixed <= length vs =
      let k = length fixed
      in do env1 <- foldM2 matchReq fixed (take k vs) env
            matchReq (RVar n) (VTuple (drop k vs)) env1
matchReq _ _ _ = Nothing

-- | A two-argument fold with a threaded result.
foldM2 :: (a -> b -> c -> Maybe c) -> [a] -> [b] -> c -> Maybe c
foldM2 f = go
  where
    go [] [] z = Just z
    go (a : as) (b : bs) z = f a b z >>= go as bs
    go _ _ _ = Nothing

propMatchPat :: Property
propMatchPat seed = pure result
  where
    (p, v, env) = evalRand gen seed
    gen = do
      depth <- randR 0 2
      pat <- genPat depth
      val <- genVal (depth + 1)
      -- Random pre-bound variables, so the §11.2 repeated-variable
      -- rule gets exercised from both the bind and the check side.
      preBinds <- listOf 2 ((,) <$> genVarName <*> genVal 1)
      pure (pat, val, Map.fromList preBinds)
    impl = matchPat p v env
    model = modelPat p v env
    result
      | impl == model = Nothing
      | otherwise = Just $ "matchPat disagrees with model:\n  pattern: " ++ show p
             ++ "\n  value:   " ++ show v
             ++ "\n  env:     " ++ show env
             ++ "\n  impl:    " ++ show impl
             ++ "\n  model:   " ++ show model

--------------------------------------------------------------------------------
-- Property 2: matchJoinSTM vs an oracle join
--------------------------------------------------------------------------------

-- | The documented §3.4 semantics, re-derived independently: clauses
-- left to right against a working copy; a Take consumes the FIRST
-- tuple structurally matching /with a fresh env/ (matchJoinSTM's pick
-- matches against 'Map.empty'), then the pick is re-checked against
-- the accumulated env; a Read matches without consuming and never
-- sees a tuple consumed earlier in the join. Returns the matched
-- values, the env, and the leftover bag (in order).
oracleJoin :: [PatElem] -> [Val] -> Maybe ([Val], Env, [Val])
oracleJoin clauses tuples0 = go clauses (zip [0 :: Int ..] tuples0)
  where
    go [] avail = Just ([], Map.empty, map snd avail)
    go (PatElem mode p : rest) avail = do
      (v, avail') <- pickAny mode p avail
      (vals, env, leftover) <- go rest avail'
      env' <- modelPat p v env
      pure (v : vals, env', leftover)

    pickAny Take p avail = case filter (matchesFresh p) avail of
      []           -> Nothing
      ((i, v) : _) ->
        let (before, atAndAfter) = span ((/= i) . fst) avail
            after = drop 1 atAndAfter
        in Just (v, before ++ after)
    pickAny Read p avail = case filter (matchesFresh p) avail of
      []           -> Nothing
      ((_, v) : _) -> Just (v, avail)

    matchesFresh p (_, v) = case modelPat p v Map.empty of
      Just _  -> True
      Nothing -> False

propJoin :: Property
propJoin seed = do
  let gen = do
        n <- randR 0 6
        gTuples <- mapM (const (genVal 2)) [1 :: Int .. n]
        gClauses <- genJoin
        pure (gTuples, gClauses)
      (tuples, clauses) = evalRand gen seed
  r <- atomically $ do
    bag <- newBagSTM
    -- outSTM prepends; load reversed so the TVar order equals the
    -- oracle's scan order (the 'tuples' list, left to right).
    mapM_ (outSTM bag) (reverse tuples)
    mr <- matchJoinSTM bag clauses
    after <- bagContentsSTM bag
    pure (fmap (\m -> (matchedVals m, matchEnv m)) mr, after)
  pure $ case (r, oracleJoin clauses tuples) of
    ((Nothing, after), Nothing)
      | after == tuples -> Nothing
      | otherwise -> Just $ "no match, but the bag changed:\n  clauses: "
          ++ show clauses ++ "\n  bag: " ++ show tuples
          ++ "\n  after: " ++ show after
    ((Nothing, _), Just e) -> Just $
      "matchJoinSTM found nothing; oracle matched:\n  oracle: " ++ show e
      ++ "\n  clauses: " ++ show clauses ++ "\n  bag: " ++ show tuples
    ((Just (vals, env), _), Nothing) -> Just $
      "matchJoinSTM matched; oracle found nothing:\n  impl: " ++ show (vals, env)
      ++ "\n  clauses: " ++ show clauses ++ "\n  bag: " ++ show tuples
    ((Just (vals, env), after), Just (vals', env', leftover))
      | vals == vals' && env == env' && after == leftover -> Nothing
      | otherwise -> Just $
          "matchJoinSTM disagrees with oracle:\n  clauses: " ++ show clauses
          ++ "\n  bag:     " ++ show tuples
          ++ "\n  impl:    " ++ show (vals, env, after)
          ++ "\n  oracle:  " ++ show (vals', env', leftover)
  where
    bagContentsSTM (RBag v) = readTVar v

--------------------------------------------------------------------------------
-- Property 3: casual strings (§9)
--------------------------------------------------------------------------------

-- | Every Unicode scalar value — surrogates genuinely excluded this
-- time (D800..DFFF), since casualString errors on them (property 3c
-- pins that separately).
scalarValues :: [Integer]
scalarValues = [0 .. 0xD7FF] ++ [0xE000 .. 0x10FFFF]

isSurrogate :: Integer -> Bool
isSurrogate n = 0xD800 <= n && n <= 0xDFFF

-- | A surrogate (D800..DFFF) is an honest error (§3.3). NOINLINE: an
-- @error@ thrown in pure code can escape 'try' when the throwing
-- thunk is floated into a CAF by the optimizer (the classic
-- catching-pure-exceptions pitfall); making the probe opaque keeps
-- the throw inside the try'd action.
surProbe :: Integer -> Int
surProbe n = sum (map ord (casualString (stringVal [toEnum (fromInteger n)])))
{-# NOINLINE surProbe #-}

propStrings :: Property
propStrings seed = do
  let gen = do
        k <- randR 0 20
        gCps <- mapM (const scalarCodepoint) [1 :: Int .. k]
        gCp <- scalarCodepoint
        gSur <- randR 0xD800 0xDFFF
        pure (gCps, gCp, toInteger gSur)
      (cps, cp, sur) = evalRand gen seed
      -- Codepoints are Integer; a Haskell String is what stringVal eats.
      s = map (toEnum . fromInteger) cps :: String
      c = toEnum (fromInteger cp) :: Char

  -- (a) random strings over scalars round-trip both ways (pure, total)
  let roundTrip = casualString (stringVal s) == s
               && stringVal (casualString (stringVal s)) == stringVal s
  -- (b) one scalar check
  let singleOk = casualString (stringVal [c]) == [c]
  -- (c) a surrogate is an honest error now (the pre-fuzz behavior:
  --     silent U+FFFD at the encodeUtf8 boundary — the bug that
  --     motivated this property)
  surRes <- try (evaluate (surProbe sur)) :: IO (Either SomeException Int)
  let surErr = either (const True) (const False) surRes
  pure $ case () of
    _ | not roundTrip -> Just ("string round-trip failed on " ++ show s)
      | not singleOk  -> Just ("single codepoint round-trip failed on " ++ show cp)
      | not surErr    -> Just ("surrogate " ++ show sur ++ " did not error")
      | otherwise     -> Nothing
  where
    scalarCodepoint = do
      i <- randR 0 (length scalarValues - 1)
      pure (scalarValues !! i)

--------------------------------------------------------------------------------
-- Property 4: parser round-trip on generated ASTs
--------------------------------------------------------------------------------

propRoundTrip :: Property
propRoundTrip seed = do
  let gen = do
        gD <- randR 0 2
        gProg <- genProgram gD
        pure (gD, gProg)
      (d, prog) = evalRand gen seed
      src = renderProgram prog
  -- Force the parse fully (render the result — the renderer prints
  -- every field, so this forces the whole AST), then compare ASTs.
  r <- try (evaluate (either (const 0) (length . renderProgram)
                       (parseProgram (T.pack src))))
  case (parseProgram (T.pack src), r :: Either SomeException Int) of
    (Right p', Right _) | p' == prog -> pure Nothing
    (Right _, Left e) -> pure $ Just $
      "parse of a render threw:\n  depth: " ++ show d ++ "\n  error: " ++ show e
      ++ "\n  source:\n" ++ src
    (Right p', _) -> pure $ Just $
      "round-trip failed (reparse differs):\n  depth: " ++ show d
      ++ "\n  source:\n" ++ src
      ++ "\n  original: " ++ show prog ++ "\n  reparsed: " ++ show p'
    (Left e, Right _) -> pure $ Just $
      "rendered source does not parse:\n  depth: " ++ show d ++ "\n  source:\n" ++ src
      ++ "\n  parse error:\n" ++ errorBundlePretty e
    (Left _, Left _) -> pure $ Just $
      "rendered source fails to parse AND the parse threw?? depth: " ++ show d
      ++ "\n  source:\n" ++ src

--------------------------------------------------------------------------------
-- Property 5: corpus mutation never crashes the parser
--------------------------------------------------------------------------------

propCorpus :: [(FilePath, T.Text)] -> Property
propCorpus corpus seed = do
  if null corpus
    then pure Nothing
    else do
      let gen = do
            (gPath, gSrc) <- elements corpus
            gMut <- mutateText gSrc
            pure (gPath, gMut)
          (path, mutated) = evalRand gen seed
      r <- try (evaluate (case parseProgram mutated of
                            Left _  -> "left"
                            Right p -> "right:" ++ show (length (renderProgram p))))
      pure $ case r :: Either SomeException String of
        Right _ -> Nothing
        Left e  -> Just $
          "parse of a mutated corpus file crashed:\n  file: " ++ path
          ++ "\n  error: " ++ show e
          ++ "\n  mutated source:\n" ++ T.unpack mutated
