{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (throwIO, try)
import Control.Exception (fromException)
import Data.Maybe (fromMaybe)
import GHC.IO.Exception (BlockedIndefinitelyOnSTM (..))
import System.Environment (getArgs)
import System.Exit
import System.FilePath (takeDirectory)
import System.IO (hPutStrLn, stderr)
import System.Random (StdGen, mkStdGen, newStdGen)
import Text.Read (readMaybe)

import qualified Data.Text.IO as TIO

import Text.Megaparsec.Error (errorBundlePretty)

import Lindana.Loader (Loaded, loadProgram, loadedInitial, loadedMachines)
import Lindana.Machine (Hooks (..), defaultHooks, fullChaos, noChaos, runLoaded,
                        rrExit)
import Lindana.Parser (parseProgram)
import Lindana.Syntax (renderProgram)

-- | @lindana <file.lind>@ parses, loads, and runs a Lindana program,
-- exiting with the program's exit status (@exit@\/@panic@).
--
-- @lindana --parse <file.lind>@ is the old development tool: parse
-- and dump the re-rendered AST.
--
-- @lindana --seed N <file.lind>@ pins @rand@'s seed (issue #41):
-- reproducible runs. @--seed random@ draws the seed from system
-- entropy. Default: the historical fixed constant — runs are
-- deterministic out of the box (provisional, flip-worthy).
--
-- @lindana --chaos N|random <file.lind>@ turns on the §11.13
-- in-engine chaos knob (issue #41 Tier 1) with the given seed:
-- seeded micro-yields around match-commit and bundle-push, and
-- shuffled cross-bundle effect-queue picks ('fullChaos'). The
-- engine's own timing becomes deliberately chaotic — reproducible
-- chaos; a failing chaos run replays with the same seed. Default:
-- off ('noChaos') — exactly the historical engine.
--
-- Parse errors are printed with megaparsec's usual caret
-- diagnostics; load errors (bag declaration rules, §6) as plain
-- messages on stderr.
main :: IO ()
main = do
  args <- getArgs
  (mSeed, mChaos, rest) <- flags args
  case rest of
    ["--parse", path] -> dump =<< parseOrDie path
    [path] -> loaded path mSeed mChaos =<< parseOrDie path
    _ -> do
      putStrLn "usage: lindana [--parse] [--seed N|random] [--chaos N|random] <file.lind>"
      exitFailure
  where
    -- @--seed N|--seed random@ and @--chaos N|--chaos random@, each
    -- zero or once, anywhere before the file. Later occurrences win
    -- (the reroute precedent).
    flags :: [String] -> IO (Maybe StdGen, Maybe StdGen, [String])
    flags ("--seed" : s : more) = do
      g <- intOrRandom s
      (m, mc, rest') <- flags more
      pure (pick m g, mc, rest')
    flags ("--chaos" : s : more) = do
      g <- intOrRandom s
      (ms, m, rest') <- flags more
      pure (ms, pick m g, rest')
    flags (x : more) = do
      (m, mc, rest') <- flags more
      pure (m, mc, x : rest')
    flags [] = pure (Nothing, Nothing, [])

    intOrRandom s = case s of
      "random" -> Just <$> newStdGen
      _ -> case readMaybe s :: Maybe Int of
        Just n  -> pure (Just (mkStdGen n))
        Nothing -> do
          hPutStrLn stderr
            ("lindana: --seed/--chaos want an integer or 'random', got " ++ s)
          exitFailure
    pick m g = case m of Just g' -> Just g'; Nothing -> g

    parseOrDie path = do
      src <- TIO.readFile path
      case parseProgram src of
        Left err -> do
          putStr (errorBundlePretty err)
          exitFailure
        Right prog -> pure prog

    dump prog = putStrLn (renderProgram prog)

    loaded path mSeed mChaos prog = case loadProgram prog of
      Left err -> do
        hPutStrLn stderr ("load error: " ++ err)
        exitFailure
      Right l -> runIt path mSeed mChaos l

    runIt :: FilePath -> Maybe StdGen -> Maybe StdGen -> Loaded -> IO ()
    runIt path mSeed mChaos l = do
      -- Module imports (§13.13) search the main file's directory for
      -- <name>.lind; a bare filename searches ".".
      let hooks = defaultHooks
            { hookModDir = takeDirectory path
            , hookSeed = fromMaybe (hookSeed defaultHooks) mSeed
            , hookChaos = maybe noChaos (const fullChaos) mChaos
            , hookChaosSeed = fromMaybe (hookChaosSeed defaultHooks) mChaos
            }
      -- A machine blocked on a match that never arrives keeps the run
      -- alive (§1); if every thread is then blocked, the RTS raises
      -- BlockedIndefinitelyOnSTM. Report it as the deadlock it is.
      r <- try (runLoaded hooks (loadedMachines l) (loadedInitial l))
      case r of
        Right res -> exitWith (rrExit res)
        Left e | Just BlockedIndefinitelyOnSTM <- fromException e -> do
          hPutStrLn stderr
            ("lindana: deadlock — every machine is blocked on a match "
             ++ "that never arrives (a machine that would end in die "
             ++ "still has to fire first); such programs need an exit path")
          exitFailure
        Left e -> throwIO e
