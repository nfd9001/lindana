{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the program loader (handover §13.5 step 4): AST →
-- bag-tagged machines + per-bag initial tuples, the §6 declaration
-- rules, the §11.10 top-level grammar decision, and the §6.4 default
-- @Error@ machine — exercised end-to-end (parse → load → run) where
-- the runtime behavior matters.
module Lindana.LoaderSpec (spec) where

import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Text as T
import System.Exit (ExitCode (..))

import Data.List (sort)
import Test.Hspec

import Lindana.Loader
import Lindana.Machine
import Lindana.Parser (parseProgram)
import Lindana.Runtime (Val (..), stringVal)
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
        Just [VTuple [VAtom "Error", stringVal "bad", VInt 7]]

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

  describe "no-LHS machines (§1 one-shot, issue #7)" $
    it "the issue #7 Hello World runs end-to-end: one-shot fires, then exit 0" $ do
      l <- loadOk $ unlines
        [ ": [say \"Hello world!\"; (Stop, 0)]"
        , "(Stop, c) : if c then [say \"Error, closing\"; exit c] else [exit c]"
        ]
      -- The loader must accept an empty join pattern (§1: runs once,
      -- unconditionally, at start) without mangling it. (The §6.4
      -- default Error machine is also present; filter it out.)
      let userMachs = [m | m <- loadedMachines l, machBag m /= errorBag]
      [oneshot, stopper] <- pure userMachs
      machBag oneshot `shouldBe` "Global"
      machJoin oneshot `shouldBe` []
      machBody stopper `shouldBe`
        [If (EVar "c")
            [Say "Error, closing" [], Exit (EVar "c")]
            [Exit (EVar "c")]]
      (said, rr) <- runCaptureSay (loadedMachines l) (loadedInitial l)
      said `shouldBe` ["Hello world!"]
      rrExit rr `shouldBe` ExitSuccess

  describe "list/cons sugar (§11.5)" $ do
    it "walks a list end-to-end: cons-pattern iterates, Nil-pattern exits" $ do
      l <- loadOk $ unlines
        [ "{ ([1, 2, 3],) }"
        , "([h | t],) : [say \"%i\" h; (t,)]"
        , "([],) : exit 0"
        ]
      (said, rr) <- runCaptureSay (loadedMachines l) (loadedInitial l)
      said `shouldBe` ["1", "2", "3"]
      rrExit rr `shouldBe` ExitSuccess

    it "a cons-pattern machine stays re-armed until the list is empty" $ do
      l <- loadOk $ unlines
        [ "{ ([7],) }"
        , "([h | t],) : (t,)"
        , "([],) : exit 0"
        ]
      r <- runLoaded silentHooks (loadedMachines l) (loadedInitial l)
      rrExit r `shouldBe` ExitSuccess

  describe "casual-string e2e (§9)" $ do
    it "a literal tag matches its literal: patterns and values desugar alike" $ do
      l <- loadOk $ unlines
        [ "{ (\"greet\", \"world\") }"
        , "(\"greet\", who) : [say \"hello, %s\" who; exit 0]"
        ]
      (said, rr) <- runCaptureSay (loadedMachines l) (loadedInitial l)
      said `shouldBe` ["hello, world"]
      rrExit rr `shouldBe` ExitSuccess

  describe "bytestring e2e (§9)" $ do
    it "static bind via no-LHS one-shot: (Bytes, H) gates, %b says the bytes" $ do
      l <- loadOk $ unlines
        [ ": [bytesBind Greeting [72, 105]; (Go,)]"
        , "(Bytes, Greeting), (Go,) : [say \"greeting: %b\" Greeting; (Done,)]"
        , "(Done,) : exit 0"
        ]
      (said, rr) <- runCaptureSay (loadedMachines l) (loadedInitial l)
      said `shouldBe` ["greeting: Hi"]
      rrExit rr `shouldBe` ExitSuccess

    it "handles are opaque: same bytes, distinct atoms (§9)" $ do
      l <- loadOk $ unlines
        [ ": [bytesBind A [72]; bytesBind B [72, 72]; (Go,)]"
        , "(Bytes, A), (Bytes, B), (Go,) :"
        , "  [ if bytesEqual(A, B) then (ContentEq,) else (ContentNeq,)"
        , "  ; if A == B then (SameAtom,) else (DifferentAtoms,)"
        , "  ; exit 0 ]"
        ]
      r <- runLoaded silentHooks (loadedMachines l) (loadedInitial l)
      sort (map renderVal (rrBag r)) `shouldBe`
        ["(ContentNeq)", "(DifferentAtoms)"]
      rrExit r `shouldBe` ExitSuccess

-- | Run loaded, capturing @say@ output and the result.
--
-- House rule, learned the hard way in the §9 e2e tests: a program
-- whose machines all die leaves the §6.4 default @Error@ machine
-- blocked forever, and termination then depends on the RTS's
-- @BlockedIndefinitelyOnSTM@ deadlock report — which is not reliable
-- under the test harness (flaky hangs). End e2e programs with an
-- explicit @exit@, not just @die@.
runCaptureSay :: [MachineDef] -> Map Name [Expr]
              -> IO ([String], RunResult)
runCaptureSay ms initial = do
  saidRef <- newIORef []
  let hooks = Hooks { hookSay = \s -> modifyIORef' saidRef (s :)
                    , hookPanic = \_ -> pure () }
  rr <- runLoaded hooks ms initial
  said <- reverse <$> readIORef saidRef
  pure (said, rr)

-- Hooks that keep end-to-end runs quiet (panic would otherwise hit
-- real stderr).
silentHooks :: Hooks
silentHooks = Hooks { hookSay = \_ -> pure (), hookPanic = \_ -> pure () }
