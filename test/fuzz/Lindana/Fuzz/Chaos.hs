-- | The Tier-1 chaos properties (issue #41, §11.13): the in-engine
-- chaos knob turned up, sweeping schedules instead of inputs.
--
-- The engine's timing knobs ('Chaos' in "Lindana.Machine") stir the
-- two points where a schedule is otherwise fixed: the machine
-- threads' internal timing (seeded micro-yields around match-commit
-- and bundle-push) and the effect queue's cross-bundle order
-- (shuffled picks), plus the §11.7 runner serialization itself
-- (multiple runners via 'runLoadedN'). A seeded knob makes the
-- engine's own randomness replayable — but the OS scheduler still
-- races, so unlike the Tier-0 properties these are statistical: the
-- seed pins the chaos, not the interleaving. That is the point: the
-- oracles below must hold for /every/ schedule the stir produces.
--
-- Hazards, documented not guarded (§12):
--
--   * A timed-out run is abandoned, not cancelled — the leaked
--     threads keep their own RTS alive (each run has a private one)
--     and die when they notice @rtsExit@ or are starved. A hang is a
--     finding either way; the leak is the harness's, not the
--     engine's. Known failure mode of that leak at soak scale
--     (§13.28): the abandoned runs compound — three examples
--     (@flaky@, @greeter@, @throttle@) have 'OHang' baselines by
--     design (no exit path / infinite demo loops), so every sweep
--     pick of one leaks a full run — and after a few dozen leaks the
--     whole harness process has been observed to wedge inside a
--     fresh 'runLoadedN', with even the outer 'timeout' never firing:
--     the in-process watchdog is NOT a containment boundary. The
--     recorded fix shape is process isolation per iteration (§11.13);
--     until then, soaks are a gamble — the wedge is rare,
--     environment-sensitive, and stalls the whole suite silently.
--   * GHC's @BlockedIndefinitelyOnSTM@ deadlock detection is
--     unreliable (the LoaderSpec note): a fully-blocked run may be
--     reaped as a clean @ExitSuccess@ with leftover tuples instead of
--     raising. Both baseline and chaos runs are equally subject to
--     it, so the comparison survives the heuristic — but a baseline
--     sample is one sample of a possibly schedule-noisy outcome; the
--     sweep is strict (baseline outcome == chaos outcome) and a
--     legitimately schedule-dependent example would show up as a
--     finding to investigate, not a lie to keep.
--
-- Properties:
--
--   1. 'propConserve' — tuple conservation under a stirred schedule
--      (the §3.1 contract, chaos-tested): two layers of machines
--      contesting over one bag, every @Job@ delivered exactly once,
--      nothing else left behind, whatever the knobs say.
--   2. 'propSweep' — a seed-sweep over the existing @examples/@
--      corpus: every example under a randomized chaos run ends in
--      the same normalized outcome (exit code, deadlock, hang) as its
--      no-chaos baseline. Deviations are findings: either a schedule
--      dependence the docs don't admit to, or a bug.
module Lindana.Fuzz.Chaos
  ( Outcome (..)
  , chaosSpecs
  , baselinesFor
  , runExample
  , genChaos
  ) where

import Control.Exception (SomeException, fromException, try)
import GHC.IO.Exception (BlockedIndefinitelyOnSTM (..))
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import System.Directory (getTemporaryDirectory)
import System.Exit (ExitCode (..))
import System.IO (hClose, openBinaryTempFile, stdin)
import System.Random (StdGen, mkStdGen)
import System.Timeout (timeout)
import Text.Megaparsec.Error (errorBundlePretty)

import Lindana.Def (MachineDef (..), globalBag)
import Lindana.Loader (loadProgram, loadedInitial, loadedMachines)
import Lindana.Machine (Chaos (..), Hooks (..), RunResult (..), runLoadedN)
import Lindana.Parser (parseProgram)
import Lindana.Runtime (Val (..))
import Lindana.Syntax

import Lindana.Fuzz.Gen
import Lindana.Fuzz.Spec (Property, PropertySpec (..))

--------------------------------------------------------------------------------
-- The harness
--------------------------------------------------------------------------------

-- | A run's normalized end state — what the oracles compare. A
-- crashed run (an exception escaping 'runLoadedN') is its own state,
-- carrying the exception's description.
data Outcome
  = OExit ExitCode      -- ^ the run returned: the program's exit status
  | OLoad String        -- ^ parse or load failure (the same source,
                        --   so both sides of a comparison see the same)
  | ODeadlock           -- ^ BlockedIndefinitelyOnSTM raised out of the run
  | OHang               -- ^ the watchdog fired; the run never returned
  | OCrash String       -- ^ an unexpected exception escaped the run
  deriving (Eq, Show)

-- | One chaos configuration, randomized per iteration: every knob
-- independently stirred (including, honestly, off — a no-op run is a
-- valid comparison too).
genChaos :: Rand Chaos
genChaos = do
  micro <- (== 0) <$> randR 0 2
  p <- elements [0, 0.25, 0.5, 0.9]
  runners <- randR 1 3
  pure Chaos { chaosMicro = micro, chaosShuffle = p, chaosRunners = runners }

-- | The knob off, spelled locally for the baselines (noChaos lives in
-- Machine but the baseline shape is the point: exactly the
-- historical engine).
flatChaos :: Chaos
flatChaos = Chaos { chaosMicro = False, chaosShuffle = 0, chaosRunners = 1 }

-- | Hooks for a harness run: say/panic captured into throwaway temp
-- files (a suite must not pollute its own output), the module search
-- pointed at @dir@, the knobs set. Returns the hooks and the cleanup
-- (the temp files are left behind, empty and harmless — the
-- MachineSpec precedent).
harnessHooks :: FilePath -> Chaos -> StdGen -> IO (Hooks, IO ())
harnessHooks dir cfg g = do
  d <- getTemporaryDirectory
  (_, hout) <- openBinaryTempFile d "lindana-fuzz-say"
  (_, herr) <- openBinaryTempFile d "lindana-fuzz-err"
  let hooks = Hooks
        { hookStdin     = stdin   -- never read; but a real Handle —
                                  -- newRTSWith sets the std fds'
                                  -- binary mode
        , hookStdout    = hout
        , hookStderr    = herr
        , hookPanic     = \_ -> pure ()
        , hookModDir    = dir
        , hookSeed      = mkStdGen 12345
        , hookChaos     = cfg
        , hookChaosSeed = g
        }
  pure (hooks, hClose hout >> hClose herr)

-- | Parse, load, and run one program under the given hooks, with a
-- watchdog; the end state is normalized to an 'Outcome'.
runExample :: Hooks -> Int -> T.Text -> IO Outcome
runExample hooks nRunners src =
  case parseProgram src of
    Left e   -> pure (OLoad (errorBundlePretty e))
    Right prog -> case loadProgram prog of
      Left err   -> pure (OLoad err)
      Right l -> do
        r <- try (timeout watchdog
                   (runLoadedN nRunners hooks (loadedMachines l)
                              (loadedInitial l)))
        pure $ case r :: Either SomeException (Maybe RunResult) of
          Right (Just rr) -> OExit (rrExit rr)
          Right Nothing   -> OHang
          Left e | Just BlockedIndefinitelyOnSTM <- fromException e -> ODeadlock
                 | otherwise -> OCrash (show e)
  where
    -- A hang is a finding either way; the watchdog keeps the suite
    -- from hanging with it. Generous: the corpus runs in ~1s worst
    -- case, so a 10s wall means something genuinely wedged.
    watchdog = 10 * 1000000

-- | The no-chaos baseline outcome of every corpus program — computed
-- once, so each sweep iteration costs one chaos run, not two.
baselinesFor :: [(FilePath, T.Text)] -> IO [(FilePath, Outcome)]
baselinesFor programs = mapM base programs
  where
    base (path, src) = do
      (h, cleanup) <- harnessHooks (dirOf path) flatChaos (mkStdGen 271828)
      o <- runExample h 1 src
      cleanup
      pure (path, o)
    -- The corpus paths are "<dir>/<file>.lind"; the module search is
    -- pointed at the program's own directory (the CLI precedent).
    dirOf = fst . break (== '/')

-- | The Tier-1 property specs, added to the suite's list.
chaosSpecs :: [(FilePath, T.Text)] -> [(FilePath, Outcome)] -> [PropertySpec]
chaosSpecs examples baselines =
  [ PropertySpec "tuple conservation under chaos (§3.1)" propConserve
  , PropertySpec "chaos sweep over the examples corpus (§11.13)"
                 (propSweep examples baselines)
  ]

--------------------------------------------------------------------------------
-- Property 1: tuple conservation under chaos (§3.1)
--------------------------------------------------------------------------------

-- | A machine that takes one tuple, emits one tuple, and dies.
takeOut :: Pat -> Expr -> MachineDef
takeOut pat out = MachineDef
  { machBag  = globalBag
  , machSfx  = ""
  , machIdle = False
  , machJoin = [PatElem Take pat]
  , machBody = [Out out, Die]
  }

-- | Two layers of machines contesting over @Global@, under a fully
-- randomized chaos configuration (including multi-runner drains):
--
--   * @n@ dispatchers, one per @n@ initial @(Do, i)@ tuples: take it,
--     emit @(Job, i)@, die.
--   * @n@ workers: take a @(Job, i)@, emit @(Done, i)@, die.
--
-- Contract (§3.1): every Take consumes exactly one tuple, contested
-- matches have exactly one winner, nothing lost, nothing duplicated —
-- so the final bag must be exactly @n@ @(Done, i)@ tuples whose @i@
-- multiset equals the jobs' multiset, with nothing else left behind
-- and a clean exit. Whatever the micro-yields, the shuffles, and the
-- concurrent runners do to the schedule, the tuple space obeys.
propConserve :: Property
propConserve seed = do
  let gen = do
        gn <- randR 1 15
        gJobs <- mapM (const (randR 0 4)) [1 :: Int .. gn]
        gCfg <- genChaos
        ggs <- randInt
        pure (gn, gJobs, gCfg, ggs)
      (n, jobs, cfg, gSeed) = evalRand gen seed
      dispatch = takeOut (PTuple [PAtom "Do", PVar "i"])
                         (ETuple [EAtom "Job", EVar "i"])
      worker = takeOut (PTuple [PAtom "Job", PVar "i"])
                       (ETuple [EAtom "Done", EVar "i"])
      machines = replicate n dispatch ++ replicate n worker
      initial = [ETuple [EAtom "Do", EInt (toInteger j)] | j <- jobs]
  (h, cleanup) <- harnessHooks "." cfg (mkStdGen gSeed)
  mo <- timeout watchdog
          (runLoadedN (chaosRunners cfg) h machines
                      (Map.singleton globalBag initial))
  cleanup
  case mo of
    Nothing -> pure (Just "run timed out (watchdog)")
    Just rr -> do
      let dones = [m | VTuple [VAtom "Done", VInt m] <- rrBag rr]
          others = filter (not . isDone) (rrBag rr)
      pure $ case () of
        _ | rrExit rr /= ExitSuccess ->
              Just ("exit was " ++ show (rrExit rr))
          | not (null others) ->
              Just ("leftover non-Done tuples:\n  " ++ show others)
          | List.sort dones /= List.sort (map toInteger jobs) ->
              Just ("conservation broke:\n  jobs:  " ++ show jobs
                    ++ "\n  dones: " ++ show dones)
          | otherwise -> Nothing
  where
    watchdog = 10 * 1000000

-- | Is this a @(Done, i)@ tuple?
isDone :: Val -> Bool
isDone (VTuple [VAtom "Done", VInt _]) = True
isDone _                               = False

--------------------------------------------------------------------------------
-- Property 2: chaos sweep over the examples corpus (§11.13)
--------------------------------------------------------------------------------

-- | One iteration: one example, one randomized chaos configuration,
-- one chaos seed — the run must end in exactly its no-chaos
-- baseline's 'Outcome'. This is the seed-sweep harness over the
-- existing examples corpus: if a program's outcome depends on the
-- engine's stirred schedule, either the program leaned on an
-- emergent order the docs don't promise (a documentation finding) or
-- the stir exposed a bug (an engine finding). Either way, the
-- counterexample names the file, both outcomes, and the seed.
propSweep :: [(FilePath, T.Text)] -> [(FilePath, Outcome)] -> Property
propSweep examples baselines seed
  | null examples = pure Nothing
  | otherwise = do
      let gen = do
            gPath <- elements [p | (p, _) <- examples]
            gCfg <- genChaos
            ggs <- randInt
            pure (gPath, gCfg, ggs)
          (path, cfg, gSeed) = evalRand gen seed
          src = maybe (error "propSweep: unknown example") id
                (lookup path examples)
          baseline = maybe (error "propSweep: no baseline") id
                     (lookup path baselines)
      (h, cleanup) <- harnessHooks (dirOf path) cfg (mkStdGen gSeed)
      o <- runExample h (chaosRunners cfg) src
      cleanup
      pure $ if o == baseline
        then Nothing
        else Just $
          "chaos run deviates from the no-chaos baseline:\n  example:  " ++ path
          ++ "\n  baseline: " ++ show baseline ++ "\n  chaos:    " ++ show o
          ++ "\n  chaos cfg: " ++ show cfg ++ ", seed " ++ show gSeed
  where
    dirOf = fst . break (== '/')
