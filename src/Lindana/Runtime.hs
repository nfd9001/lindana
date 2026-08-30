{-# LANGUAGE ScopedTypeVariables #-}

-- | The STM tuple bag and structural matcher (handover §3) — the
-- runtime core of Lindana.
--
-- Scope of this sketch:
--
--   * One bag = one @TVar [Val]@ (§3's opening model). Named bags and
--     per-tag sharding (§6) will layer on top of this by holding
--     several of these and picking the right @TVar@s inside one
--     @atomically@ block; the thundering-herd mitigation is deferred
--     with them.
--   * Matching is purely structural (§3.2, §3.3): a match either
--     structurally succeeds — committing the machine — or fails. No
--     guards, no type checks, no rollback path.
--   * Join patterns (§3.4) are matched in one STM transaction; per-
--     clause read mode ('Take' vs 'Read') is honoured. Within a join,
--     'Take' clauses consume (each against a distinct tuple) and
--     'Read' clauses match without consuming.
--   * Racing matches (§3.1) need no code here: two transactions
--     matching the same tuple simply contend on commit, the loser
--     re-runs and finds the tuple gone. The deliberate absence of a
--     fairness guarantee is inherited from STM as designed.
--
-- One open question is answered provisionally here and must not be
-- treated as final (§11.2): repeated variables within one pattern
-- @(\"f\", a, a)@ are taken to require structural equality between the
-- positions (Prolog-style), rather than rebinding. Easy to flip later;
-- it lives entirely in 'matchPat'.
module Lindana.Runtime
  ( -- * Values
    Val(..)
  , Env
    -- * The bag
  , RBag (..)
  , newBag
  , newBagSTM
  , bagContents
  , outSTM
    -- * Matching (STM layer)
  , MatchResult(..)
  , matchJoinSTM
    -- * Blocking tuple-space verbs
  , inBag
  , rdBag
    -- * Non-blocking probes
  , inpBag
  , rdpBag
    -- * Expression evaluation (matcher-adjacent helper)
  , evalExpr
  , evalExprG
  , arith
  ) where

import Control.Concurrent.STM
import Data.Functor.Identity (Identity (..))
import Data.List (find, findIndex)
import qualified Data.Map.Strict as Map

import Lindana.Syntax

--------------------------------------------------------------------------------
-- Values
--------------------------------------------------------------------------------

-- | Runtime values. Deliberately matching the pattern/expr literal
-- kinds in "Lindana.Syntax": no list or string primitive (§9 — those
-- are sugar over tuples), and no bytestring handles yet (those are
-- just 'VAtom's plus a runtime side-table, per §9; side-table not
-- built yet).
data Val
  = VAtom Name
  | VInt Integer
  | VDouble Double
  | VStr String
  | VTuple [Val]
  deriving (Eq, Show)

-- | Bindings produced by a successful match.
type Env = Map.Map Name Val

--------------------------------------------------------------------------------
-- The bag
--------------------------------------------------------------------------------

-- | The bag. One bag = one @TVar [Val]@ (the §3 opening model). The
-- @R@ prefix ("runtime bag") disambiguates from Syntax's 'Bag' Decl
-- constructor; named bags and per-tag sharding (§6) will layer on top
-- of this by holding several of these and picking the right @TVar@s
-- inside one @atomically@ block, with the thundering-herd mitigation
-- (§3.1) deferred with them.
newtype RBag = RBag { bagTVar :: TVar [Val] }
  deriving (Eq)

-- | A fresh, empty bag.
newBag :: IO RBag
newBag = RBag <$> newTVarIO []

newBagSTM :: STM RBag
newBagSTM = RBag <$> newTVar []

-- | Snapshot of the bag's current contents (testing/inspection only —
-- machines themselves never do this; they match).
bagContents :: RBag -> IO [Val]
bagContents (RBag v) = readTVarIO v

-- | @out@ — emit a tuple into the bag. Wakeups of blocked matchers are
-- STM's business (and, with the single-TVar model, every out commits
-- invalidate every reader: the thundering herd of §3.1, to be sharded
-- away in §6.3).
outSTM :: RBag -> Val -> STM ()
outSTM (RBag v) t = modifyTVar' v (t :)

--------------------------------------------------------------------------------
-- Matching
--------------------------------------------------------------------------------

-- | A successful match: the values bound by each pattern element (in
-- clause order; for 'Read' clauses this is the value observed, not a
-- consumed one) plus the combined variable environment.
data MatchResult = MatchResult
  { matchedVals :: [Val]
  , matchEnv    :: Env
  } deriving (Eq, Show)

-- | Structural match of one pattern against one value, threading an
-- environment.
--
-- Repeated variables (§11.2, open): provisionally Prolog-style — a
-- second occurrence must bind to an /equal/ value, else the match
-- fails. Note the equality used is 'Val' equality, i.e. the same
-- @==@ the language gives users; nothing deeper, per §3.3.
matchPat :: Pat -> Val -> Env -> Maybe Env
matchPat (PVar n) v env = case Map.lookup n env of
  Just v' | v' == v   -> Just env
          | otherwise -> Nothing
  Nothing -> Just (Map.insert n v env)
matchPat (PAtom a) (VAtom b) env | a == b = Just env
matchPat (PInt i) (VInt j) env | i == j = Just env
matchPat (PDouble x) (VDouble y) env | x == y = Just env
matchPat (PStr s) (VStr t) env | s == t = Just env
matchPat (PTuple ps) (VTuple vs) env
  | length ps == length vs = foldl step (Just env) (zip ps vs)
  where
    step me (p, v) = me >>= \e -> matchPat p v e
matchPat _ _ _ = Nothing

-- | Match a join pattern (§3.4) against the bag, atomically.
--
-- Semantics of the sketch: clauses are processed left to right against
-- a working copy of the bag. A 'Take' clause removes the first
-- structurally-matching tuple; a 'Read' clause matches the first
-- structurally-matching tuple without removing it. A 'Read' clause
-- therefore never matches a tuple consumed earlier in the same join —
-- they compete over distinct tuples, which is what the §8.2 idiom
-- (request + stats consumed, epoch read) expects.
--
-- Returns 'Nothing' if no complete match exists — the caller decides
-- whether that means @retry@ (blocking verbs below) or a plain probe
-- failure. All-or-nothing falls out of STM: the write of the working
-- copy back only happens if the whole join matched, and any concurrent
-- commit that touched the bag re-runs us.
matchJoinSTM :: RBag -> [PatElem] -> STM (Maybe MatchResult)
matchJoinSTM (RBag v) clauses = do
  tuples <- readTVar v
  case matchClauses clauses tuples of
    Nothing            -> pure Nothing
    Just (vals, env, tuples') ->
      Just (MatchResult vals env) <$ writeTVar v tuples'
  where
    matchClauses
      :: [PatElem] -> [Val] -> Maybe ([Val], Env, [Val])
    matchClauses [] tuples' = Just ([], Map.empty, tuples')
    matchClauses (PatElem mode p : rest) tuples' = do
      (val, tuples1) <- pick mode p tuples'
      (vals, env, tuples2) <- matchClauses rest tuples1
      env' <- matchPat p val env
      pure (val : vals, env', tuples2)

    pick :: ReadMode -> Pat -> [Val] -> Maybe (Val, [Val])
    pick Take p tuples' = do
      i <- findIndex (\t -> case matchPat p t Map.empty of
                              Just _  -> True
                              Nothing -> False) tuples'
      -- Index-based removal: the tuple consumed by a later Take clause
      -- must not be one already consumed (or read) earlier in the join.
      pure (tuples' !! i, take i tuples' ++ drop (i + 1) tuples')
    pick Read p tuples' = do
      t <- find (\t' -> case matchPat p t' Map.empty of
                          Just _  -> True
                          Nothing -> False) tuples'
      pure (t, tuples')

--------------------------------------------------------------------------------
-- Blocking verbs (§3): `in` and `rd`
--------------------------------------------------------------------------------

-- | @in@ — blocking take. Blocks (STM @retry@) until a join match is
-- possible, then consumes its 'Take' clauses atomically.
inBag :: RBag -> [PatElem] -> IO MatchResult
inBag bag clauses = atomically $ do
  r <- matchJoinSTM bag clauses
  case r of
    Just m  -> pure m
    Nothing -> retry

-- | @rd@ — blocking read: as 'inBag' but no 'Take' clauses are
-- permitted (all clauses are 'Read'), so nothing is consumed. This is
-- the broadcast/fan-out mechanism (§3).
rdBag :: RBag -> [Pat] -> IO MatchResult
rdBag bag pats = inBag bag (map (PatElem Read) pats)

--------------------------------------------------------------------------------
-- Non-blocking probes: `inp` and `rdp`
--------------------------------------------------------------------------------

-- | @inp@ — probe: take if a match exists now, otherwise 'Nothing'
-- immediately. This is the primitive throttled machines must switch to
-- (§8.1) since they sleep between probes rather than blocking.
inpBag :: RBag -> [PatElem] -> IO (Maybe MatchResult)
inpBag bag clauses = atomically (matchJoinSTM bag clauses)

-- | @rdp@ — non-blocking read probe.
rdpBag :: RBag -> [Pat] -> IO (Maybe MatchResult)
rdpBag bag pats = inpBag bag (map (PatElem Read) pats)

--------------------------------------------------------------------------------
-- Expression evaluation
--------------------------------------------------------------------------------

-- | Evaluate a construction-side expression to a value, given the
-- environment bound by the match. This is the pure, builtin-free
-- specialisation of 'evalExprG' — see there for the real story.
--
-- Still partial on 'EBin' arithmetic over non-numeric operands (the
-- @error@ routing of §3.3 is an action-layer concern); 'evalExprG'
-- carries 'ECall' builtins in its carrier instead.
evalExpr :: Env -> Expr -> Val
evalExpr env e = runIdentity (evalExprG pureBuiltin env e)
  where
    pureBuiltin n _ = Identity
      (error ("evalExpr: builtin " ++ n ++ " not implemented (action layer, §7)"))

-- | Generalised expression evaluation. The @builtin@ callback owns
-- @f(x)@ calls; the /action layer/ instantiates the carrier @f@ as
-- 'STM' so that stateful builtins (@rand@'s seed, per §8) evaluate
-- /inside/ the same transaction that matches and emits — keeping
-- "read the join patterns, decide, write replacement tuples" (§8.2
-- note) atomic. The pure 'evalExpr' instantiates @f ~ Identity@.
--
-- Arithmetic type errors remain Haskell-level @error@s here; routing
-- them through the @error@ verb is the action layer's job (§3.3).
evalExprG :: Monad f
  => (Name -> [Val] -> f Val)   -- ^ builtin name, evaluated args
  -> Env -> Expr -> f Val
evalExprG builtin env e = case e of
  EVar n -> case Map.lookup n env of
    Just v  -> pure v
    Nothing -> error ("evalExpr: unbound variable " ++ n)
  EAtom n      -> pure (VAtom n)
  EInt i       -> pure (VInt i)
  EDouble d    -> pure (VDouble d)
  EStr s       -> pure (VStr s)
  ETuple es    -> VTuple . concat <$> traverse (evalElemG builtin env) es
  ESplice x    -> do  -- full-tuple splice (§4): flattens one level
    v <- evalExprG builtin env x
    pure (case v of
      VTuple vs -> VTuple vs
      _         -> v)     -- degenerate: splicing a non-tuple is itself
  EBin op a b  -> arith op <$> evalExprG builtin env a
                           <*> evalExprG builtin env b
  ENeg x       -> arith Sub (VInt 0) <$> evalExprG builtin env x
  ECall n es   -> builtin n =<< traverse (evalExprG builtin env) es

-- | Evaluate one element of a tuple in construction position:
-- normally a singleton list; a spliced element contributes its
-- contents (zero or more values) directly.
evalElemG :: Monad f
  => (Name -> [Val] -> f Val) -> Env -> Expr -> f [Val]
evalElemG builtin env (ESplice x) = do
  v <- evalExprG builtin env x
  pure (case v of VTuple vs -> vs; _ -> [v])
evalElemG builtin env e = (:[]) <$> evalExprG builtin env e

arith :: Op -> Val -> Val -> Val
arith op (VInt a) (VInt b)       = VInt (intOp op a b)
arith op (VDouble a) (VDouble b) = VDouble (dblOp op a b)
arith _ _ _ = error "arith: non-numeric operands (must route via error, §3.3)"

-- Numeric helpers live at top level rather than in a @where@: GHC 9.0
-- only scopes a @where@ over the equations it follows, and @arith@'s
-- first equations need these.
intOp :: Op -> Integer -> Integer -> Integer
intOp Add = (+)
intOp Sub = (-)
intOp Mul = (*)
intOp Div = div
intOp Eq  = \a b -> if a == b then 1 else 0
intOp Neq = \a b -> if a /= b then 1 else 0

dblOp :: Op -> Double -> Double -> Double
dblOp Add = (+)
dblOp Sub = (-)
dblOp Mul = (*)
dblOp Div = (/)
dblOp Eq  = \a b -> if a == b then 1 else 0
dblOp Neq = \a b -> if a /= b then 1 else 0
