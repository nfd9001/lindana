-- | The machine loop / scheduler (§1, §2) and the action layer +
-- effect-runner (§3.3, §7.2) — handover §13.3 steps 1 and 2.
--
-- The shape of the runtime:
--
--   * One thread per machine, spawned by 'runProgram'. Machines loop
--     by default: match → interpret → re-arm. @die@ (or a terminal
--     @exit@\/@panic@) ends the thread. Empty-pattern machines (§1)
--     run once at start and terminate. The §5 @AContN@
--     cross-invocation chaos needs no code — it simply falls out of
--     this loop re-arming.
--
--   * Two-phase interpreter (§8.2's note, made structural): the
--     transaction is "read the join patterns, decide, write
--     replacement tuples". Tuple-space verbs (@out@, @lob@, and
--     @error@'s Error-tuple write) execute inside that transaction,
--     atomically with the match and each other. Every irrevocable
--     verb (@say@, @sleep@, @exit@, @panic@) comes back as a
--     deferred /bundle/ of effects, pushed post-commit.
--
--   * The 'effectRunner' is a single thread draining bundles FIFO
--     from a 'TQueue', one bundle live at a time — sequencing and
--     synchronization from ordinary primitives, per §7.2, with no
--     rollback on partial failure. Provisionally one /global/ runner
--     (§7.3 still open); bytestring side-table work (§9) doesn't
--     exist yet, so the "route @create@\/@destroy@ through it?"
--     question doesn't arise yet either.
--
-- Provisional decisions made here (flip-worthy, per the house style):
--
--   * @exit@ terminates the /whole program/ with the evaluated code
--     (both §10 usages read that way); @die@ terminates only the
--     machine.
--   * Truthiness (§9, open §11): falsy = @VInt 0@, @VDouble 0.0@,
--     @VAtom \"False\"@; everything else (including @()@) truthy.
--   * @error e@ is @lob Error (…)@ proper (§6.4): the @(Error, …)@
--     tuple lands in the named @Error@ bag. When the program declares
--     no @Error@ bag of its own, the loader installs the §6.4 default
--     machine @(c!) : panic c@; a user-declared @Error { … }@ block —
--     even an empty one, "silently swallow all errors" — fully
--     replaces it. See "Lindana.Loader".
--   * Named bags (§6): machines match the bag whose block they are
--     declared in (@"Global"@ for bare top-level machines); @out@
--     emits into the machine's /own/ bag; @lob@ is the only cross-bag
--     send (§6.1). A bag name not seen before is created on demand —
--     since a machineless accumulator and a live bag are the same
--     structure here (one 'TVar'), the §6.2 drain-on-first-machine
--     handoff is free: tuples accumulated before the bag had machines
--     are simply already in the 'TVar' its machines match against,
--     and no tuple can be lost or double-delivered.
--   * @rand@'s seed is a fixed constant: runs are deterministic —
--     reproducible chaos.
--   * Shutdown is abrupt: once every machine is done or the program
--     has exited, remaining threads are cancelled. A machine
--     committing concurrently with shutdown may or may not land its
--     final write — accepted for now.
module Lindana.Machine
  ( -- * The RTS
    RTS (..)
  , Hooks (..)
  , defaultHooks
  , newRTS
  , newRTSWith
  , globalBag
  , errorBag
  , bagForSTM
    -- * Machines
  , MachineDef (..)
  , Bundle (..)
  , Effect (..)
    -- * The interpreter (action layer)
  , interpretActions
  , evalR
  , rtsBuiltin
    -- * Effect formatting
  , formatSay
  , renderVal
    -- * Running programs
  , RunResult (..)
  , runProgram
  , runProgramWith
  , runLoaded
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (unless, when)
import Data.List (intercalate)
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import System.Random (StdGen, mkStdGen, uniformR)
import System.Exit (ExitCode (..))
import System.IO (hPutStrLn, stderr)

import Lindana.Runtime
import Lindana.Syntax

--------------------------------------------------------------------------------
-- The RTS
--------------------------------------------------------------------------------

-- | The name of the implicit bag bare top-level machines belong to
-- (§6). @Global@ effectively acts as the program's front door.
globalBag :: Name
globalBag = "Global"

-- | The name of the error bag (§6.4).
errorBag :: Name
errorBag = "Error"

-- | The runtime system: @Global@'s matchable bag, the effect queue,
-- the @rand@ seed, the live-machine count, the program exit status,
-- and the named bags (§6) — machineless @lob@ accumulators and bags
-- with machines alike; they are the same structure.
data RTS = RTS
  { rtsBag   :: RBag                  -- ^ @Global@'s bag
  , rtsQueue :: TQueue Bundle
  , rtsSeed  :: TVar StdGen           -- ^ @rand@'s state (§8): splitmix
                                      -- via System.Random; pure + fixed
                                      -- seed, so evaluable in STM and
                                      -- runs stay deterministic
  , rtsLive  :: TVar Int              -- ^ live machine threads
  , rtsExit  :: TVar (Maybe ExitCode)
  , rtsStop  :: TVar Bool             -- ^ graceful effect-runner shutdown
  , rtsBags  :: TVar (Map Name RBag)  -- ^ named bags other than @Global@
                                      --   (§6): machineless accumulators
                                      --   and live bags alike
  , rtsHooks :: Hooks
  }

-- | Injectable effect targets, so tests can observe @say@\/@panic@
-- without touching real stdio.
data Hooks = Hooks
  { hookSay   :: String -> IO ()   -- ^ default: stdout
  , hookPanic :: String -> IO ()   -- ^ default: stderr
  }

defaultHooks :: Hooks
defaultHooks = Hooks
  { hookSay   = putStrLn
  , hookPanic = hPutStrLn stderr . ("panic: " ++)
  }

-- | A fresh RTS (fixed @rand@ seed: deterministic runs).
newRTS :: IO RTS
newRTS = newRTSWith defaultHooks

newRTSWith :: Hooks -> IO RTS
newRTSWith hooks = atomically $ do
  bag   <- newBagSTM
  queue <- newTQueue
  live  <- newTVar 0
  exit  <- newTVar Nothing
  stop  <- newTVar False
  seed  <- newTVar (mkStdGen 12345)
  bags  <- newTVar Map.empty
  pure RTS { rtsBag = bag, rtsQueue = queue, rtsSeed = seed
           , rtsLive = live, rtsExit = exit, rtsStop = stop
           , rtsBags = bags, rtsHooks = hooks
           }

-- | Resolve a bag name to its 'RBag' (§6). @Global@ is the main bag;
-- any other name is found in 'rtsBags' or created on demand. On-demand
-- creation is how @lob@ makes machineless accumulators (§6.2), and it
-- is why the §6.2 drain-on-first-machine handoff needs no code: an
-- accumulator and a live bag are the /same/ structure (one 'TVar'),
-- so tuples accumulated before the bag has machines are already in
-- place when its machines start matching — the handoff is one 'TVar'
-- and therefore trivially atomic (nothing can be lost or
-- double-delivered). Runs in the caller's transaction, so a body
-- mixing same-bag @out@ and cross-bag @lob@ commits as one atomic
-- unit — cross-bag atomicity for free, exactly as §6.1 predicted.
bagForSTM :: RTS -> Name -> STM RBag
bagForSTM rts n
  | n == globalBag = pure (rtsBag rts)
  | otherwise = do
      bags <- readTVar (rtsBags rts)
      case Map.lookup n bags of
        Just b  -> pure b
        Nothing -> do
          b <- newBagSTM
          writeTVar (rtsBags rts) (Map.insert n b bags)
          pure b

-- | @lob@ — push into a named bag (§6.1): the only way to send across
-- a bag boundary. A bag not seen before is created on demand as a
-- machineless accumulator (§6.2): nothing matches against it, so
-- accumulation is cheap, and any ordering it shows is accidental,
-- never a promise.
lobSTM :: RTS -> Name -> Val -> STM ()
lobSTM rts bagName t = do
  bag <- bagForSTM rts bagName
  outSTM bag t

--------------------------------------------------------------------------------
-- Machines
--------------------------------------------------------------------------------

-- | A machine definition: the bag it matches in (§6), its join
-- pattern (left) and action list (right). The @Def@ suffix
-- disambiguates from Syntax's @Machine@ Decl constructor.
data MachineDef = MachineDef
  { machBag  :: Name        -- ^ bag whose block the machine was declared in
  , machJoin :: [PatElem]
  , machBody :: [Action]
  } deriving (Eq, Show)

-- | A bundle of deferred effects (§7.2): queued post-commit, drained
-- FIFO by the effect-runner, one bundle live at a time.
newtype Bundle = Bundle { bundleEffects :: [Effect] }
  deriving (Eq, Show)

-- | Side-effecting verbs. Tuple-space writes are /not/ here — those
-- commit in the matching transaction. Termination effects
-- ('EffExit'/'EffPanic') end the bundle: the program is over, later
-- effects are dropped (§7.2 gives no rollback; here not even a queue).
data Effect
  = EffSay String [Val]   -- ^ @say "fmt" args…@ (@%i@, @%s@, @%a@, @%%@)
  | EffSleep Int          -- ^ @sleep e@ — milliseconds (provisional unit)
  | EffExit Val           -- ^ @exit e@ — terminate the program
  | EffPanic Val          -- ^ @panic e@ — fatal (§6.4)
  deriving (Eq, Show)

--------------------------------------------------------------------------------
-- The interpreter (action layer, §3.3 + §7)
--------------------------------------------------------------------------------

-- | Evaluate an expression with the RTS's STM builtins.
evalR :: RTS -> Env -> Expr -> STM Val
evalR rts env = evalExprG (rtsBuiltin rts) env

-- | The builtins (§3.3, §7). These run /inside the matching
-- transaction/ — that's what keeps "read the join patterns, decide,
-- write replacement tuples" (§8.2 note) atomic even when the decision
-- uses @rand@: the generator state is an ordinary 'TVar' in the RTS,
-- and 'uniformR' is pure, so the step is an ordinary STM read/write.
--
-- Malformed calls (unknown builtin, wrong arity/kind) are provisional
-- Haskell-level errors — unified @error@-verb routing pending the
-- effect-grammar pass (§7.3). @atomize@ of an uncapitalized string is
-- specified (§4) as fatal @panic@; expression position can't queue an
-- effect, so provisionally it is a Haskell error that kills the
-- machine thread (the 'finally' in 'machineThread' keeps the live
-- count honest).
rtsBuiltin :: RTS -> Name -> [Val] -> STM Val
rtsBuiltin rts name args = case (name, args) of
  ("rand", [VInt n])
    | n <= 0    -> pure (VInt 0)   -- provisional: rand of non-positive is 0
    | otherwise -> do
        g <- readTVar (rtsSeed rts)
        let (v, g') = uniformR (0, n - 1) g
        writeTVar (rtsSeed rts) g'
        pure (VInt (toInteger v))
  ("typeOf", [v])     -> pure (VAtom (typeTag v))
  ("atomize", [VStr s])
    | capitalized s   -> pure (VAtom s)
    | otherwise       -> error "atomize: string must be capitalized (§4: panic)"
  ("atos", [VAtom n]) -> pure (VStr n)
  _ -> error ("evalExpr: unknown builtin or bad arity: " ++ name)

capitalized :: String -> Bool
capitalized (c : _) = c `elem` ['A' .. 'Z']
capitalized []      = False

typeTag :: Val -> Name
typeTag VAtom{}   = "Atom"
typeTag VInt{}    = "Int"
typeTag VDouble{} = "Double"
typeTag VStr{}    = "Str"
typeTag VTuple{}  = "Tuple"

-- | Interpret an action list in the matching transaction. Tuple-space
-- verbs execute immediately (they are the transaction); irrevocable
-- verbs accumulate into a deferred bundle. Returns the bundle and
-- whether the machine survives to re-arm ('False' iff the list ended
-- in @die@\/@exit@\/@panic@).
--
-- @if@ is an action combinator, not a verb: it selects a branch and
-- splices it ahead of the remaining actions — no sequencing
-- primitives beyond that (Terse desugaring, §5, will lower into this
-- same action list).
-- The bag argument is the machine's own bag (§6): @out@ is same-bag
-- emission — within a bag it is Linda semantics, and the continuation
-- idiom (@(c!, a + b)@) only works if the continuation lands where
-- the matching machines are. Cross-bag traffic goes through @lob@
-- exclusively (§6.1).
interpretActions :: RTS -> RBag -> Env -> [Action] -> STM ([Effect], Bool)
interpretActions rts bag env = go []
  where
    go acc [] = pure (reverse acc, True)
    go acc (act : rest) = case act of
      Out e -> do
        t <- evalR rts env e
        outSTM bag t
        go acc rest
      Lob bagName e -> do
        t <- evalR rts env e
        lobSTM rts bagName t
        go acc rest
      Say f es -> do
        vs <- mapM (evalR rts env) es
        go (EffSay f vs : acc) rest
      Sleep e -> do
        t <- evalR rts env e
        go (effSleep t : acc) rest
      Die -> pure (reverse acc, False)   -- no effect: thread bookkeeping
      Exit x -> do
        v <- evalR rts env x
        pure (reverse (EffExit v : acc), False)
      Panic x -> do
        v <- evalR rts env x
        pure (reverse (EffPanic v : acc), False)
      Raise e -> do
        t <- evalR rts env e
        ebag <- bagForSTM rts errorBag
        outSTM ebag (errorTuple t)
        go acc rest
      If c th el -> do
        b <- truthy <$> evalR rts env c
        go acc ((if b then th else el) ++ rest)

    effSleep v = case v of
      VInt n    -> EffSleep (fromInteger n)   -- milliseconds
      VDouble d -> EffSleep (round (d * 1000))
      _ -> error "sleep: non-numeric operand (action-layer check, §3.3)"

-- | @error e@ (§6.4): an @(Error, …)@ tuple into the named @Error@
-- bag (conceptually sugar over @lob Error …@); a tuple argument's
-- contents are spliced in. With no user @Error@ declarations the
-- loader installs the default machine @(c!) : panic c@; an empty
-- user @Error { }@ block means "silently swallow all errors".
errorTuple :: Val -> Val
errorTuple v = VTuple (VAtom "Error" : case v of
  VTuple vs -> vs
  _         -> [v])

-- | §9 truthiness (provisional, see module header). The unifying rule
-- is open (§11); @VAtom \"False\"@ participates because §9 makes
-- @True@\/@False@ ordinary atoms.
truthy :: Val -> Bool
truthy (VInt 0)        = False
truthy (VDouble 0.0)   = False
truthy (VAtom "False") = False
truthy _               = True

--------------------------------------------------------------------------------
-- Machine threads: the loop (§1)
--------------------------------------------------------------------------------

-- | One thread per machine. Machines loop by default: match →
-- interpret → re-arm. @die@ (or terminal @exit@\/@panic@) ends the
-- thread; an empty-pattern machine runs once, unconditionally, at
-- start (§1).
machineThread :: RTS -> RBag -> MachineDef -> IO ()
machineThread rts bag m = go `finally` decLive
  where
    decLive = atomically (modifyTVar' (rtsLive rts) (subtract 1))

    go
      | null (machJoin m) = do   -- §1: one-shot, unconditionally, at start
          (effs, _) <- atomically
            (interpretActions rts bag Map.empty (machBody m))
          push effs
          pure ()                -- implicitly terminates after firing
      | otherwise = loop

    loop = do
      (effs, survived) <- atomically $ do
        mr <- matchJoinSTM bag (machJoin m)
        case mr of
          Nothing -> retry
          Just mt ->
            -- Commit point (§3.2): the match is committed for good —
            -- no retry can reach back. Interpret the body in the same
            -- transaction so its tuple-space writes land atomically
            -- with the match (the §8.2 note); irrevocables come back
            -- as a deferred bundle for the effect-runner (§7.2).
            interpretActions rts bag (matchEnv mt) (machBody m)
      push effs
      when survived loop

    push effs =
      unless (null effs) $
        atomically (writeTQueue (rtsQueue rts) (Bundle effs))

--------------------------------------------------------------------------------
-- The effect-runner (§7.2)
--------------------------------------------------------------------------------

-- | Drains bundles FIFO from the 'TQueue', one bundle fully live at a
-- time: sequencing and synchronization from a single thread and a
-- queue — no bespoke machinery, per §7.2. Provisionally global (§7.3
-- open): unrelated bags' I/O serializes against each other.
-- | Drains bundles FIFO from the 'TQueue', one bundle fully live at a
-- time: sequencing and synchronization from a single thread and a
-- queue — no bespoke machinery, per §7.2. Provisionally global (§7.3
-- open): unrelated bags' I/O serializes against each other.
--
-- Shutdown is graceful: once @rtsStop@ is set, the runner finishes its
-- current bundle, drains the queue, and returns — every queued bundle
-- is fully executed before a program run returns. Cancelling the
-- runner instead would drop a bundle mid-@sleep@; we never do.
effectRunner :: RTS -> IO ()
effectRunner rts = loop
  where
    loop = do
      mb <- atomically $ do
        stop <- readTVar (rtsStop rts)
        b    <- tryReadTQueue (rtsQueue rts)
        case (b, stop) of
          (Just _, _)      -> pure b
          (Nothing, False) -> retry         -- keep waiting for bundles
          (Nothing, True)  -> pure Nothing
      case mb of
        Nothing            -> pure ()   -- queue empty and stopping
        Just (Bundle effs) -> runBundle rts effs >> loop

-- | Run one bundle's effects sequentially. No rollback on partial
-- failure (§7.2's final bullet): a failed effect leaves earlier
-- effects done; checking success is the programmer's job. @exit@\/@panic@
-- end the bundle (and the program) — later effects are dropped.
runBundle :: RTS -> [Effect] -> IO ()
runBundle rts = go
  where
    go [] = pure ()
    go (e : es) = case e of
      EffSay f vs -> hookSay (rtsHooks rts) (formatSay f vs) >> go es
      EffSleep ms -> threadDelay (ms * 1000) >> go es
      EffExit v   -> atomically (setExit rts (exitCodeOf v))  -- program over
      EffPanic v  -> do
        hookPanic (rtsHooks rts) (renderVal v)
        atomically (setExit rts (ExitFailure 1))

setExit :: RTS -> ExitCode -> STM ()
setExit rts c = writeTVar (rtsExit rts) (Just c)

-- | @say@ formatting: @%i@ int, @%s@ string, @%a@ render-any, @%%@ a
-- literal @%@. Mismatched arg counts are provisional Haskell errors
-- (pending unified @error@ routing, §3.3).
formatSay :: String -> [Val] -> String
formatSay fmt = go fmt
  where
    go ('%' : 'i' : cs) (VInt n : as)   = show n ++ go cs as
    go ('%' : 's' : cs) (VStr s : as)   = s ++ go cs as
    go ('%' : 'a' : cs) (v : as)        = renderVal v ++ go cs as
    go ('%' : '%' : cs) as              = '%' : go cs as
    go ('%' : _ : _) []                 = error "say: too few arguments"
    go ('%' : _) _                      = error "say: bad directive or dangling %"
    go (c : cs) as                      = c : go cs as
    go [] []                            = []
    go [] (_ : _)                       = error "say: too many arguments"

-- | Crude value rendering (panic messages, @%a@).
renderVal :: Val -> String
renderVal (VAtom n)   = n
renderVal (VInt n)    = show n
renderVal (VDouble d) = show d
renderVal (VStr s)    = show s
renderVal (VTuple vs) = "(" ++ intercalate ", " (map renderVal vs) ++ ")"

exitCodeOf :: Val -> ExitCode
exitCodeOf (VInt n)
  | n == 0    = ExitSuccess
  | otherwise = ExitFailure (fromInteger (n `mod` 256))
exitCodeOf _ = ExitFailure 1

--------------------------------------------------------------------------------
-- Running a program
--------------------------------------------------------------------------------

data RunResult = RunResult
  { rrExit :: ExitCode        -- ^ program exit status (@exit@\/@panic@)
  , rrBag  :: [Val]           -- ^ final contents of @Global@
  , rrBags :: Map Name [Val]  -- ^ final contents of every other named
                              --   bag (§6): machineless accumulators
                              --   and live bags alike
  } deriving (Eq, Show)

-- | Run a @Global@-only program: initial tuples land in @Global@ in
-- one transaction, then one thread per machine. Convenience for tests
-- and callers that have not crossed into named bags (§6); the loader
-- ('Lindana.Loader.loadProgram') produces the general shape.
-- Returns when every machine has terminated (die, one-shot, or
-- exception) or the program has exited. A machine blocked on a match
-- that will never arrive keeps the count up — that is the §1 loop
-- doing its job, not a bug; such programs need @exit@ or @die@ paths
-- (or an external watchdog) to finish.
runProgram :: [MachineDef] -> [Expr] -> IO RunResult
runProgram machines initial =
  runProgramWith defaultHooks machines (Map.singleton globalBag initial)

runProgramWith :: Hooks -> [MachineDef] -> Map Name [Expr] -> IO RunResult
runProgramWith hooks machines initial =
  runLoaded hooks machines initial

-- | Run a loaded program (§6): one thread per machine, each matching
-- the bag its 'MachineDef' names; initial tuples land per bag. Bags
-- are resolved (and created on demand) through 'bagForSTM', so a
-- machine's bag and any @lob@ target with the same name are the same
-- structure.
runLoaded :: Hooks -> [MachineDef] -> Map Name [Expr] -> IO RunResult
runLoaded hooks machines initial = do
  rts <- newRTSWith hooks
  atomically $ do
    mapM_ (\(n, es) ->
              mapM_ (\e -> do
                       v <- evalR rts Map.empty e
                       b <- bagForSTM rts n
                       outSTM b v)
                 es)
          (Map.toList initial)
    writeTVar (rtsLive rts) (length machines)
  -- Resolve each machine's bag up front: the bag is fixed for the
  -- machine's lifetime (its declaration site named it), and resolving
  -- once keeps the loop from re-reading the bag map on every re-arm.
  mbags <- mapM (\m -> do
                    b <- atomically (bagForSTM rts (machBag m))
                    pure (m, b))
                machines
  runner <- async (effectRunner rts)
  mths   <- mapM (\(m, b) -> async (machineThread rts b m)) mbags
  atomically $ do
    live <- readTVar (rtsLive rts)
    ex   <- readTVar (rtsExit rts)
    check (live <= (0 :: Int) || isJust ex)
  -- Shutdown: machines first (no new bundles after this), then ask
  -- the runner to stop; it finishes the current bundle and drains the
  -- queue, so every queued bundle is fully executed before
  -- runProgram returns.
  mapM_ cancel mths
  atomically (writeTVar (rtsStop rts) True)
  wait runner
  bag   <- bagContents (rtsBag rts)
  bags  <- traverse bagContents =<< readTVarIO (rtsBags rts)
  ex    <- readTVarIO (rtsExit rts)
  pure (RunResult (fromMaybe ExitSuccess ex) bag bags)
