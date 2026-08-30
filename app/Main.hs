{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitFailure)

import qualified Data.Text.IO as TIO

import Text.Megaparsec.Error (errorBundlePretty)

import Lindana.Parser (parseProgram)
import Lindana.Syntax (renderProgram)

-- | Development tool: parse a .lind file and dump the re-rendered AST.
-- Parse errors are printed with megaparsec's usual caret diagnostics.
main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> do
      src <- TIO.readFile path
      case parseProgram src of
        Left err -> do
          putStr (errorBundlePretty err)
          exitFailure
        Right prog -> putStrLn (renderProgram prog)
    _ -> putStrLn "usage: lindana <file.lind>"
