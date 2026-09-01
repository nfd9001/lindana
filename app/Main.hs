{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (throwIO, try)
import Control.Exception (fromException)
import GHC.IO.Exception (BlockedIndefinitelyOnSTM (..))
import System.Environment (getArgs)
import System.Exit
import System.FilePath (takeDirectory)
import System.IO (hPutStrLn, stderr)

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
-- Parse errors are printed with megaparsec's usual caret
-- diagnostics; load errors (bag declaration rules, §6) as plain
-- messages on stderr.
main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--parse", path] -> dump =<< parseOrDie path
    [path] -> loaded path =<< parseOrDie path
    _ -> do
      putStrLn "usage: lindana [--parse] <file.lind>"
      exitFailure
  where
    parseOrDie path = do
      src <- TIO.readFile path
      case parseProgram src of
        Left err -> do
          putStr (errorBundlePretty err)
          exitFailure
        Right prog -> pure prog

    dump prog = putStrLn (renderProgram prog)

    loaded path prog = case loadProgram prog of
      Left err -> do
        hPutStrLn stderr ("load error: " ++ err)
        exitFailure
      Right l -> runIt path l

    runIt :: FilePath -> Loaded -> IO ()
    runIt path l = do
      -- Module imports (§13.13) search the main file's directory for
      -- <name>.lind; a bare filename searches ".".
      let hooks = defaultHooks { hookModDir = takeDirectory path }
      -- A machine blocked on a match that never arrives keeps the run
      -- alive (§1); if every thread is then blocked, the RTS raises
      -- BlockedIndefinitelyOnSTM. Report it as the deadlock it is.
      r <- try (runLoaded hooks (loadedMachines l) (loadedInitial l))
      case r of
        Right res -> exitWith (rrExit res)
        Left e | Just BlockedIndefinitelyOnSTM <- fromException e -> do
          hPutStrLn stderr
            ("lindana: deadlock — every machine is blocked on a match "
             ++ "that never arrives; such programs need an exit/die path")
          exitFailure
        Left e -> throwIO e
