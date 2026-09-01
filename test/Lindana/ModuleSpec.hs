{-# LANGUAGE OverloadedStrings #-}

-- | End-to-end tests for module support (issue #17, handover §13.13):
-- the @import@ effect loading @test/modules/*.lind@ at runtime —
-- suffix mangling, hide lists, the @(Imported, …)@ completion gate,
-- module singletons, recursive suffix propagation, the mangled-error
-- routing, and the pending-import shutdown race.
--
-- Module search is pointed at @test/modules@ via 'hookModDir'
-- (the CLI points it at the main file's directory instead).
-- Programs end in an explicit @exit@ (the §13.8 house rule), and
-- every run is wrapped in a timeout so a wrong test deadlocks as a
-- failure, not a hang. Where a test asserts on a module one-shot's
-- in-bag commit, it @sleep@s before exiting: the one-shot's commit
-- races only the final exit bundle, and the sleep gives it a wide,
-- documented margin.
module Lindana.ModuleSpec (spec) where

import Data.IORef
import Data.List (isInfixOf, sort)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import System.Exit (ExitCode (..))
import System.Timeout (timeout)

import Test.Hspec

import Lindana.Loader
import Lindana.Machine
import Lindana.Parser (parseProgram)
import Lindana.Runtime (Val (..))

-- | Parse + load a main program (inline source) and run it with the
-- module search pointed at @test/modules@, capturing @say@ and
-- @panic@ output. Times out at 10s (a hang is a failure).
runMain :: String -> IO ([String], [String], RunResult)
runMain src = do
  saidRef  <- newIORef []
  panicRef <- newIORef []
  p <- case parseProgram (T.pack src) of
    Left e   -> expectationFailure ("parse failed: " ++ show e) >> error "unreachable"
    Right p' -> pure p'
  l <- case loadProgram p of
    Left err -> expectationFailure ("load failed: " ++ err) >> error "unreachable"
    Right l' -> pure l'
  let hooks = Hooks { hookSay = \s -> modifyIORef' saidRef (s :)
                    , hookPanic = \s -> modifyIORef' panicRef (s :)
                    , hookModDir = "test/modules" }
  mrr <- timeout (10 * 1000000)
           (runLoaded hooks (loadedMachines l) (loadedInitial l))
  rr <- case mrr of
    Nothing -> expectationFailure "run timed out (deadlock?)" >> error "unreachable"
    Just rr -> pure rr
  said   <- reverse <$> readIORef saidRef
  panics <- reverse <$> readIORef panicRef
  pure (said, panics, rr)

-- | The standard preamble: bind the module-name handle, gate on its
-- @(Bytes, Mod)@ completion to bind the suffix handle, gate again.
-- Callers append their own @import@ line and machinery.
preamble :: String -> String -> [String]
preamble modName suffix =
  [ ": [bytesBind Mod \"" ++ modName ++ "\"; (S1,)]"
  , "(Bytes, Mod) : [bytesBind Sfx \"" ++ suffix ++ "\"; (S2,)]"
  ]

-- | The plain import line most tests start from.
importLine :: String
importLine = "(Bytes, Sfx) : import Mod Sfx []"

spec :: Spec
spec = describe "module import (§13.13, issue #17)" $ do

  it "loads a module at runtime; mangled atoms on both sides meet" $ do
    -- The module's machine and emitted tuple are Echo_v2 / Echoed_v2
    -- (mangled); the reply bag atom travels as data, unmangled.
    (said, panics, rr) <- runMain $ unlines $
      preamble "echo" "_v2" ++
      [ importLine
      , "(Imported, Mod, \"_v2\") : (Echo_v2, \"hi\", Reply)"
      , "Reply { (Echoed_v2, m) : [say \"got %s\" m; exit 0] }"
      ]
    said `shouldBe` ["got hi"]
    panics `shouldBe` []
    rrExit rr `shouldBe` ExitSuccess

  it "the one-shot module machine fires at spawn (no hide)" $ do
    (_, _, rr) <- runMain $ unlines $
      preamble "echo" "_v2" ++
      [ importLine
      , "(Imported, Mod, \"_v2\") : [sleep 100; exit 0]"
      ]
    Map.lookup "Boot_v2" (rrBags rr) `shouldBe`
      Just [VTuple [VAtom "Booted_v2"]]

  it "a hidden bag's machines are not imported (hide list, pre-mangle names)" $ do
    (_, _, rr) <- runMain $ unlines $
      preamble "echo" "_v2" ++
      [ "(Bytes, Sfx) : import Mod Sfx [Boot]"
      , "(Imported, Mod, \"_v2\") : [sleep 100; exit 0]"
      ]
    -- The boot one-shot was skipped, so nothing ever created Boot_v2.
    Map.lookup "Boot_v2" (rrBags rr) `shouldBe` Nothing

  it "repeat import is a singleton: one spawn, two completion tuples" $ do
    (said, panics, rr) <- runMain $ unlines $
      preamble "echo" "_v2" ++
      [ "(Bytes, Sfx) : [import Mod Sfx []; (Again,)]"
      , "(Again,) : import Mod Sfx []"
      -- Two Take clauses: both (Imported, …) tuples must exist — the
      -- repeat import still emits its completion.
      , "(Imported, Mod, \"_v2\"), (Imported, Mod, \"_v2\") : [sleep 100; exit 0]"
      ]
    rrExit rr `shouldBe` ExitSuccess
    panics `shouldBe` []
    said `shouldBe` []
    -- The one-shot boot machine spawned exactly once.
    Map.lookup "Boot_v2" (rrBags rr) `shouldBe` Just [VTuple [VAtom "Booted_v2"]]

  it "a missing module is a runner-safe fatal panic, exit 1" $ do
    (_, panics, rr) <- runMain $ unlines (preamble "nosuchmod" "_v2" ++ [importLine])
    rrExit rr `shouldBe` ExitFailure 1
    panics `shouldSatisfy` any ("nosuchmod" `isInfixOf`)

  it "the runtime preregisters Nil → \"\" (the free empty suffix)" $ do
    (_, _, rr) <- runMain ": exit 0"
    Map.lookup "Nil" (rrBytes rr) `shouldBe` Just ""

  it "the pending-import slot keeps the run alive past the last startup machine" $ do
    -- The one-shot main machine dies immediately after queueing the
    -- import; without the pending slot the run-alive check could fire
    -- before the import effect ever runs. Only the imported machine
    -- ends the program.
    (_, panics, rr) <- runMain ": [bytesBind Mod \"autoexit\"; import Mod Nil []]"
    rrExit rr `shouldBe` ExitFailure 7
    panics `shouldBe` []

  it "a nested import inherits the ambient suffix (recursion)" $ do
    -- outer is loaded with "_r"; outer's own import of inner is
    -- therefore effective-suffix "_r" as well — inner's atoms are
    -- Deep_r / InnerHi_r, and inner's completion tuple carries "_r".
    (said, panics, rr) <- runMain $ unlines $
      preamble "outer" "_r" ++
      [ importLine
      , "(Imported, InnerMod_r, \"_r\") : (Deep_r, Reply)"
      , "(Imported, Mod, \"_r\") : (Go_r, Reply)"
      , "Reply { (InnerHi_r,) : [say \"inner ok\"; (Done,)]"
      , "        (OuterHi_r,) : [say \"outer ok\"; (Done,)]"
      , "        (Done,), (Done,) : exit 0 }"
      ]
    sort said `shouldBe` ["inner ok", "outer ok"]
    panics `shouldBe` []
    rrExit rr `shouldBe` ExitSuccess

  it "a module's error verb routes to its own mangled Error bag (with handler)" $ do
    (said, panics, rr) <- runMain $ unlines $
      preamble "handled" "_x" ++
      [ importLine
      , "(Imported, Mod, \"_x\") : (Boom_x, Reply)"
      , "Reply { (Caught_x, msg) : [say \"caught %s\" msg; exit 0] }"
      ]
    said `shouldBe` ["caught bad"]
    panics `shouldBe` []
    rrExit rr `shouldBe` ExitSuccess
    -- The handler consumed the error tuple; the AboutTo tuple sits.
    Map.lookup "Reply" (rrBags rr) `shouldBe`
      Just [VTuple [VAtom "AboutTo_x"]]

  it "a module without an Error block gets the §6.4 default on its mangled bag" $ do
    (said, panics, rr) <- runMain $ unlines $
      preamble "noisy" "_x" ++
      [ importLine
      , "(Imported, Mod, \"_x\") : (Boom_x, Reply)"
      , "Reply { (AboutTo_x,) : say \"about\" }"
      ]
    rrExit rr `shouldBe` ExitFailure 1
    panics `shouldSatisfy` not . null
    -- The AboutTo lob committed in the same transaction as the error,
    -- and its say bundle was queued before the panic: FIFO order says
    -- it ran.
    said `shouldBe` ["about"]
