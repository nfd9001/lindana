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
import Lindana.Machine (Hooks (..), defaultHooks, runLoaded, rrExit)
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
-- Parse errors are printed with megaparsec's usual caret
-- diagnostics; load errors (bag declaration rules, §6) as plain
-- messages on stderr.
main :: IO ()
main = do
  args <- getArgs
  (mSeed, rest) <- seedArgs args
  case rest of
    ["--parse", path] -> dump =<< parseOrDie path
    [path] -> loaded path mSeed =<< parseOrDie path
    _ -> do
      putStrLn "usage: lindana [--parse] [--seed N|random] <file.lind>"
      exitFailure
  where
    -- @--seed N|--seed random@, zero or once, anywhere before the file.
    seedArgs :: [String] -> IO (Maybe StdGen, [String])
    seedArgs ("--seed" : s : more) = do
      g <- case s of
        "random" -> Just <$> newStdGen
        _ -> case readMaybe s :: Maybe Int of
          Just n  -> pure (Just (mkStdGen n))
          Nothing -> do
            hPutStrLn stderr ("lindana: --seed wants an integer or 'random', got " ++ s)
            exitFailure
      (m, rest') <- seedArgs more
      pure (case m of Just g' -> Just g'; Nothing -> g, rest')  -- later --seed wins (the reroute precedent)
    seedArgs (x : more) = do
      (m, rest') <- seedArgs more
      pure (m, x : rest')
    seedArgs [] = pure (Nothing, [])

    parseOrDie path = do
      src <- TIO.readFile path
      case parseProgram src of
        Left err -> do
          putStr (errorBundlePretty err)
          exitFailure
        Right prog -> pure prog

    dump prog = putStrLn (renderProgram prog)

    loaded path mSeed prog = case loadProgram prog of
      Left err -> do
        hPutStrLn stderr ("load error: " ++ err)
        exitFailure
      Right l -> runIt path mSeed l

    runIt :: FilePath -> Maybe StdGen -> Loaded -> IO ()
    runIt path mSeed l = do
      -- Module imports (§13.13) search the main file's directory for
      -- <name>.lind; a bare filename searches ".".
      let hooks = case mSeed of
            Just g  -> defaultHooks { hookModDir = takeDirectory path
                                    , hookSeed  = g }
            Nothing -> defaultHooks { hookModDir = takeDirectory path }
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
