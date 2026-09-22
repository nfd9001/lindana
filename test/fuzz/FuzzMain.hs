-- | The fuzzing suite driver (issue #41).
--
-- Seedable and iteration-countable via environment variables:
--
--   * @LINDANA_FUZZ_SEED@ — an integer master seed. Every iteration
--     draws its generator sub-seed deterministically from it, so any
--     failure replays exactly. Default: system entropy (and the
--     drawn seed is printed, so an entropy run's failures replay too).
--   * @LINDANA_FUZZ_ITERS@ — iterations per property. Default: 100
--     (fast enough for @stack test@; scale up for a soak).
--
-- On the first failure: report the property, the master seed, the
-- iteration index, and the counterexample; exit 1. Replay with
-- @LINDANA_FUZZ_SEED=<seed>@.
--
-- §11.13 (issue #41 Tier 1): the chaos properties ("Lindana.Fuzz.Chaos")
-- run after the Tier-0 ones — the in-engine chaos knob turned up over
-- a contested schedule, and a seed-sweep of the examples corpus.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_)
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesDirectoryExist, listDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hFlush, hPutStrLn, stderr)
import System.Random (mkStdGen, randomIO, split)
import Text.Read (readMaybe)

import Lindana.Fuzz.Chaos (baselinesFor, chaosSpecs)
import Lindana.Fuzz.Spec (PropertySpec (..), propertySpecs)

main :: IO ()
main = do
  (masterSeed, fromEntropy) <- seedFromEnv
  iters <- itersFromEnv
  corpus <- loadCorpus
  -- The chaos sweep runs whole programs, not fragments: only the
  -- examples are runnable programs (the test modules are import
  -- fragments, Tier-0 property 5's corpus).
  let runCorpus = [(p, t) | (p, t) <- corpus, "examples/" `isPrefixOf` p]
  baselines <- baselinesFor runCorpus
  let specs = propertySpecs corpus ++ chaosSpecs runCorpus baselines
  putStrLn $ "lindana-fuzz: seed=" ++ show masterSeed
          ++ (if fromEntropy then " (entropy; replay with LINDANA_FUZZ_SEED)" else "")
          ++ " iters=" ++ show iters
          ++ " corpus=" ++ show (length corpus)
          ++ " examples=" ++ show (length runCorpus)
  forM_ specs $ \spec -> do
    -- Per-property progress on stderr: a stalled property (the
    -- §13.28 wedge) otherwise stalls the whole suite with zero
    -- output — this line at least names the victim.
    hPutStrLn stderr ("  running " ++ propName spec)
    hFlush stderr
    outcome <- runProperty spec iters masterSeed
    case outcome of
      Nothing -> putStrLn ("  PASS " ++ propName spec
                           ++ " (" ++ show iters ++ " iters)")
      Just (i, msg) -> do
        hPutStrLn stderr $
          "FAIL " ++ propName spec
          ++ " (iteration " ++ show i
          ++ ", master seed " ++ show masterSeed
          ++ "; replay: LINDANA_FUZZ_SEED=" ++ show masterSeed ++ ")\n"
          ++ msg
        exitWith (ExitFailure 1)
  putStrLn "lindana-fuzz: all properties held"

-- | The master seed: env-pinned, or drawn from entropy (reported, so
-- the run is still replayable).
seedFromEnv :: IO (Int, Bool)
seedFromEnv = do
  mv <- lookupEnv "LINDANA_FUZZ_SEED"
  case mv >>= readMaybe of
    Just n  -> pure (n, False)
    Nothing -> do
      n <- randomIO :: IO Int
      pure (abs n, True)

itersFromEnv :: IO Int
itersFromEnv = do
  mv <- lookupEnv "LINDANA_FUZZ_ITERS"
  pure (fromMaybe 100 (mv >>= readMaybe))

-- | Each property draws its sub-seed by splitting the master once per
-- iteration — deterministic given the master seed.
runProperty :: PropertySpec -> Int -> Int -> IO (Maybe (Int, String))
runProperty spec n master = go 1 (mkStdGen master)
  where
    go i g
      | i > n = pure Nothing
      | otherwise = do
          let (g1, g') = split g
          r <- try (propBody spec g1)
          case r :: Either SomeException (Maybe String) of
            -- A property that throws (not via its own try) is itself
            -- a finding.
            Left e          -> pure (Just (i, "uncaught exception: " ++ show e))
            Right Nothing   -> go (i + 1) g'
            Right (Just msg) -> pure (Just (i, msg))

-- | The mutation corpus: the examples and the test modules, as they
-- sit in the package tree (cwd is the package root under stack test).
loadCorpus :: IO [(FilePath, T.Text)]
loadCorpus = concat <$> mapM filesIn ["examples", "test" </> "modules"]
  where
    filesIn dir = do
      ok <- doesDirectoryExist dir
      if not ok
        then pure []
        else do
          fs <- sort . filter (".lind" `isSuffixOf`) <$> listDirectory dir
          concat <$> mapM (\f -> do
                    t <- TIO.readFile (dir </> f)
                    pure [(dir </> f, t)]) fs
