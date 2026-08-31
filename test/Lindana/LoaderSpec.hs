{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the program loader (handover §13.5 step 4): AST →
-- bag-tagged machines + per-bag initial tuples, the §6 declaration
-- rules, the §11.10 top-level grammar decision, and the §6.4 default
-- @Error@ machine — exercised end-to-end (parse → load → run) where
-- the runtime behavior matters.
module Lindana.LoaderSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import System.Exit (ExitCode (..))

import Data.List (sort)
import Test.Hspec

import Lindana.Loader
import Lindana.Machine
import Lindana.Parser (parseProgram)
import Lindana.Runtime (Val (..))
import Lindana.Syntax

-- | Parse and load, failing the test on parse or load errors.
loadOk :: String -> IO Loaded
loadOk src = do
  p <- case parseProgram (T.pack src) of
    Left e   -> expectationFailure ("parse failed: " ++ show e) >> error "unreachable"
    Right p' -> pure p'
  case loadProgram p of
    Left err -> expectationFailure ("load failed: " ++ err) >> error "unreachable"
    Right l  -> pure l

loadFails :: String -> IO String
loadFails src = do
  p <- case parseProgram (T.pack src) of
    Left e   -> expectationFailure ("parse failed: " ++ show e) >> error "unreachable"
    Right p' -> pure p'
  case loadProgram p of
    Left err -> pure err
    Right _  -> expectationFailure "expected a load error" >> error "unreachable"

spec :: Spec
spec = do
  describe "bag scoping (§6)" $ do
    it "bare top-level machines belong to Global" $ do
      l <- loadOk "(Ping,) : die"
      -- The §6.4 default Error machine is appended by the loader; scope
      -- the check to the user's machines.
      map machBag (filter (\m -> machBag m /= "Error" || machBody m /= [Panic (EVar "c")]) (loadedMachines l))
        `shouldBe` ["Global"]

    it "machines inside a bag block are tagged with that bag" $ do
      l <- loadOk $ unlines
        [ "Workers {"
        , "  (Ping,) : (Pong,)"
        , "  (Pong,) : die"
        , "}"
        , "(Tick,) : die"
        ]
      sort (map machBag (loadedMachines l))
        `shouldBe` ["Error", "Global", "Workers", "Workers"]

    it "a { … } block inside a bag block is that bag's initial state (§11.10)" $ do
      l <- loadOk $ unlines
        [ "Workers {"
        , "  {"
        , "    (Ping,)"
        , "  }"
        , "  (Ping,) : die"
        , "}"
        ]
      loadedInitial l `shouldBe` Map.singleton "Workers" [ETuple [EAtom "Ping"]]

    it "a top-level { … } block is Global's initial state (§11.10)" $ do
      l <- loadOk "{ (Tick,) }\n(Tick,) : die"
      loadedInitial l `shouldBe` Map.singleton "Global" [ETuple [EAtom "Tick"]]

  describe "declaration rules (§6)" $ do
    it "rejects a bag declared in two places (single declaration site)" $ do
      err <- loadFails $ unlines
        [ "W { (Ping,) : die }"
        , "W { (Pong,) : die }"
        ]
      err `shouldContain` "more than one place"

    it "rejects mixing bare machines with an explicit Global block" $ do
      err <- loadFails $ unlines
        [ "Global {"
        , "  (Ping,) : die"
        , "}"
        , "(Pong,) : die"
        ]
      err `shouldContain` "pick one style"

    it "rejects nested bag blocks (bags are flat)" $ do
      err <- loadFails $ unlines
        [ "Outer {"
        , "  Inner {"
        , "    (Ping,) : die"
        , "  }"
        , "}"
        ]
      err `shouldContain` "nested bag block"

    it "rejects two top-level initial blocks" $ do
      err <- loadFails "{ (Tick,) }\n{ (Tock,) }"
      err `shouldContain` "more than one top-level"

    it "rejects two initial blocks in one bag" $ do
      err <- loadFails $ unlines
        [ "W {"
        , "  { (Ping,) }"
        , "  { (Pong,) }"
        , "}"
        ]
      err `shouldContain` "more than one"

    it "an explicit Global block with machines (no bare machines) loads fine" $ do
      l <- loadOk $ unlines
        [ "Global {"
        , "  (Ping,) : die"
        , "}"
        ]
      sort (map machBag (loadedMachines l)) `shouldBe` ["Error", "Global"]

  describe "the §6.4 default Error machine" $ do
    it "is installed when the program declares no Error bag" $ do
      l <- loadOk "(Ping,) : die"
      map machBag (loadedMachines l) `shouldContain` ["Error"]
      let dm = head [m | m <- loadedMachines l, machBag m == "Error"]
      machJoin dm `shouldBe` [PatElem Take (PTuple [PRest "c"])]
      machBody dm `shouldBe` [Panic (EVar "c")]

    it "is not installed when the program declares Error { } (swallow-all)" $ do
      l <- loadOk "Error { }\n(Ping,) : die"
      map machBag (loadedMachines l) `shouldNotContain` ["Error"]

    it "is not installed when the program declares its own Error machines" $ do
      l <- loadOk $ unlines
        [ "Error {"
        , "  (Error, msg) : die"
        , "}"
        ]
      -- Exactly one Error-bagged machine: the user's own (die body),
      -- with no @(c!) : panic c@ default alongside it.
      let errMachs = [m | m <- loadedMachines l, machBag m == "Error"]
      length errMachs `shouldBe` 1
      machBody (head errMachs) `shouldBe` [Die]

    it "makes error fatal end-to-end: error verb → default machine → panic" $ do
      l <- loadOk "{ (Boom,) }\n(Boom,) : [error (\"bad\", 7); die]"
      r <- runLoaded silentHooks (loadedMachines l) (loadedInitial l)
      rrExit r `shouldBe` ExitFailure 1

    it "an empty Error { } block swallows errors silently end-to-end" $ do
      l <- loadOk "{ (Boom,) }\nError { }\n(Boom,) : [error (\"bad\", 7); die]"
      r <- runLoaded silentHooks (loadedMachines l) (loadedInitial l)
      rrExit r `shouldBe` ExitSuccess
      Map.lookup "Error" (rrBags r) `shouldBe`
        Just [VTuple [VAtom "Error", VStr "bad", VInt 7]]

    it "a user Error machine replaces the default end-to-end" $ do
      l <- loadOk $ unlines
        [ "{ (Boom,) }"
        , "Error {"
        , "  (Error, \"recoverable\", n) : die"
        , "}"
        , "(Boom,) : [error (\"recoverable\", 1); die]"
        ]
      r <- runLoaded silentHooks (loadedMachines l) (loadedInitial l)
      rrExit r `shouldBe` ExitSuccess

-- Hooks that keep end-to-end runs quiet (panic would otherwise hit
-- real stderr).
silentHooks :: Hooks
silentHooks = Hooks { hookSay = \_ -> pure (), hookPanic = \_ -> pure () }
