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
import System.Directory (getTemporaryDirectory)
import System.Exit (ExitCode (..))
import System.IO (hClose, openBinaryTempFile, stderr, stdin)
import System.Timeout (timeout)

import Test.Hspec

import Lindana.Loader
import Lindana.Machine
import Lindana.Parser (parseProgram)
import Lindana.Runtime (Val (..))

-- | Parse + load a main program (inline source) and run it with the
-- module search pointed at @test/modules@, capturing @say@ and
-- @panic@ output. Times out at 10s (a hang is a failure).
-- §13.18: @say@ is un-magicked — capture is the @Stdout@ fd's OS
-- handle (a scratch temp file), read back after the run.
runMain :: String -> IO ([String], [String], RunResult)
runMain src = do
  panicRef <- newIORef []
  d <- getTemporaryDirectory
  (sayFile, hout) <- openBinaryTempFile d "lindana-say-test"
  p <- case parseProgram (T.pack src) of
    Left e   -> expectationFailure ("parse failed: " ++ show e) >> error "unreachable"
    Right p' -> pure p'
  l <- case loadProgram p of
    Left err -> expectationFailure ("load failed: " ++ err) >> error "unreachable"
    Right l' -> pure l'
  let hooks = Hooks { hookStdin  = stdin
                    , hookStdout = hout
                    , hookStderr = stderr
                    , hookPanic = \s -> modifyIORef' panicRef (s :)
                    , hookModDir = "test/modules" }
  mrr <- timeout (10 * 1000000)
           (runLoaded hooks (loadedMachines l) (loadedInitial l))
  rr <- case mrr of
    Nothing -> expectationFailure "run timed out (deadlock?)" >> error "unreachable"
    Just rr -> pure rr
  hClose hout
  said   <- lines <$> readFile sayFile
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

  -- §13.14 (issue #17): the error-reroute effect, end to end. The
  -- reroute commits in the same transaction that emits the (Routed,)
  -- witness, so when Boom_x fires the table is certainly installed —
  -- no startup race.
  describe "error reroute (§13.14, issue #17)" $ do
    it "top level collects a module's errors: reroute Error_v2 Sink" $ do
      -- Module-wide spelling: naming the module's mangled Error bag
      -- reroutes "all bags in the module". The collector machine's
      -- pattern keys on the tag (Error_v2 — stable provenance), not
      -- on its own bag's name.
      (said, panics, rr) <- runMain $ unlines $
        preamble "noisy" "_v2" ++
        [ "(Bytes, Sfx) : import Mod Sfx []"
        , "(Imported, Mod, \"_v2\") : [reroute Error_v2 Sink; (Routed,)]"
        , "(Routed,) : (Boom_v2, Go)"
        , "Sink { (Error_v2, \"bad\", r) : [say \"collected %a\" r; exit 0] }"
        ]
      said `shouldBe` ["collected Go"]
      panics `shouldBe` []
      rrExit rr `shouldBe` ExitSuccess
      -- The §6.4 default machine on the mangled bag (installed by the
      -- import — noisy declares no Error block) never fired: the tuple
      -- went to Sink instead, and the mangled bag sits empty.
      Map.lookup "Error_v2" (rrBags rr) `shouldBe` Just []

    it "last update wins: a second reroute replaces the first" $ do
      (said, panics, rr) <- runMain $ unlines $
        preamble "noisy" "_v2" ++
        [ "(Bytes, Sfx) : import Mod Sfx []"
        , "(Imported, Mod, \"_v2\") :"
        , "  [reroute Error_v2 Sink1; reroute Error_v2 Sink2; (Routed,)]"
        , "(Routed,) : (Boom_v2, Go)"
        , "Sink2 { (Error_v2, c!) : exit 0 }"
        ]
      said `shouldBe` []
      panics `shouldBe` []
      rrExit rr `shouldBe` ExitSuccess
      -- Sink1 never received anything: the second reroute replaced
      -- the first before the error fired. Sink2 exists and its
      -- collector consumed the tuple (exit 0, no panics — the routing
      -- demonstrably went through Sink2).
      Map.lookup "Sink1" (rrBags rr) `shouldBe` Nothing
      Map.lookup "Sink2" (rrBags rr) `shouldBe` Just []
      Map.lookup "Error_v2" (rrBags rr) `shouldBe` Just []

    it "a module reroutes its own errors from within (mangled args)" $ do
      -- The module writes `reroute Error Tmp` (pre-mangle); both args
      -- mangle, so the install is Error_v2 → Tmp_v2 — the module
      -- reroutes its OWN module-wide error stream to one of its own
      -- bags. It cannot name the real top-level Error: its written
      -- `Error` is its own mangled bag (consistent with the
      -- no-Global-exemption story, §13.13).
      (said, panics, rr) <- runMain $ unlines $
        preamble "selfroute" "_v2" ++
        [ "(Bytes, Sfx) : import Mod Sfx []"
        -- Join both witnesses: the import completion AND the module's
        -- (Ready_v2,) — out'd by the module's one-shot in the same
        -- transaction as its reroute write, so when this fires the
        -- reroute is certainly installed. No startup race.
        , "(Imported, Mod, \"_v2\"), (Ready_v2,) : (Boom_v2, Reply)"
        , "Reply { (Caught_v2, msg) : [say \"caught %s\" msg; exit 0] }"
        ]
      said `shouldBe` ["caught bad"]
      panics `shouldBe` []
      rrExit rr `shouldBe` ExitSuccess
      -- The tuple went through Tmp_v2 (the module's own reroute
      -- target): its handler consumed it. Without the reroute the
      -- §6.4 default on Error_v2 would have panicked instead.
      Map.lookup "Tmp_v2" (rrBags rr) `shouldBe` Just []
      Map.lookup "Error_v2" (rrBags rr) `shouldBe` Just []

  -- §13.17 (issue #18): fds travel as data across the import boundary.
  -- The module's fwrite mentions only variables (its own atom mentions
  -- would mangle); the caller opens the file, opens the fd and payload
  -- atoms as data, and reads the written content back through a fresh
  -- read-mode handle.
  it "a module fwrites through a caller-passed fd (fd-as-data)" $ do
    path <- tmpFdPath
    (said, panics, rr) <- runMain $ unlines $
      preamble "fdwriter" "_v2" ++
      [ importLine
      , ": fopen F \"" ++ path ++ "\" W"
      , "(Fopen, F) : bytesBind Payload \"hello from the top level\""
      , "(Bytes, Payload), (Imported, Mod, \"_v2\") :"
      , "  lob Boot_v2 (Go_v2, F, Payload, Reply)"
      , "Reply { (Done_v2, f) : [fclose f; fopen G \"" ++ path ++ "\" R; fread G; (Read,)]"
      -- The reader lives in Reply too: the (Read,) tuple is out'd into
      -- the emitting machine's OWN bag (§6), not Global.
      , "        (Read,) : [say \"%b\" G; exit 0] }"
      ]
    said `shouldBe` ["hello from the top level"]
    panics `shouldBe` []
    rrExit rr `shouldBe` ExitSuccess

  it "a module reroutes its own says with sayfd (fd as data, §13.18)" $ do
    -- The module's written `sayfd Boot out` is `sayfd Boot_v2 out`
    -- after mangling — its OWN bag, and the fd arrives as data (the
    -- fdwriter pattern). Its say lands in the caller's file, while
    -- the top level's own say (Stdout, captured) is untouched.
    path <- tmpFdPath
    (said, panics, rr) <- runMain $ unlines $
      preamble "sayfdmod" "_v2" ++
      [ importLine
      , ": fopen F \"" ++ path ++ "\" W"
      , "(Fopen, F), (Imported, Mod, \"_v2\") :"
      , "  lob Boot_v2 (Go_v2, F, Reply)"
      , "Reply { (Done_v2,) : [fclose F; fopen G \"" ++ path ++ "\" R; fread G; (Read,)]"
      , "        (Read,) : [say \"%b\" G; exit 0] }"
      ]
    -- The file holds say's full line ("module says here\n"); the %b
    -- read-back re-says it, so the capture sees the line plus the
    -- read-back line.
    said `shouldBe` ["module says here", ""]
    panics `shouldBe` []
    rrExit rr `shouldBe` ExitSuccess

  -- §13.23 (issue #18 part 3): a module bytesNew's an anonymous
  -- string. The fresh handle is runtime data — never written in any
  -- source, so it needs no namespace (only source mentions mangle) —
  -- and the gate tuple lands in Global per the gate convention, which
  -- the module's own machines cannot reach; the caller gates on it and
  -- puts the handle to work (fd-as-data).
  it "a module bytesNew's an anonymous string; the caller consumes the gate (§13.23)" $ do
    -- no-prelude: the prelude's own (Bytes, Newline/Version) static
    -- gates would race the module's fresh gate for the (Bytes, h)
    -- take (no ordering guarantee, §5) — pragma them out of the run.
    (said, panics, rr) <- runMain $ unlines $
      [ "{-# no-prelude #-}" ] ++
      preamble "bytesnewmod" "_v2" ++
      [ importLine
      , "(Imported, Mod, \"_v2\"), (Bytes, h) : [fwrite Stdout h; exit 0]"
      ]
    said `shouldBe` ["module-made"]
    panics `shouldBe` []
    rrExit rr `shouldBe` ExitSuccess

  -- §13.24 (issue #18's stretch goal): a module auto-promotes a
  -- "..." literal. The module fwrites through an fd it is handed as
  -- data (fdwriter pattern — a module cannot mention Stdout); its
  -- literal promotes to bytesBind Auto0, an ordinary source atom that
  -- mangles to Auto0_v2, namespaced like everything else (and distinct
  -- from main's own Auto0 below — the two coexist). Same-bundle FIFO
  -- lands the promoted bind before its write; the gate is an unconsumed
  -- stray in Global.
  it "a module auto-promotes a literal; the promoted handle mangles (§13.24)" $ do
    path <- tmpFdPath
    (said, panics, rr) <- runMain $ unlines $
      preamble "promotemod" "_v2" ++
      [ importLine
      , ": fopen F \"" ++ path ++ "\" W"
      , "(Fopen, F), (Imported, Mod, \"_v2\") :"
      , "  [fwrite Stdout \"main-made\"; say \"\"; lob Boot_v2 (Go_v2, F, Reply)]"
      , "Reply { (Done_v2,) : [fclose F; fopen G \"" ++ path ++ "\" R; fread G; (Read,)]"
      , "        (Read,) : [say \"%b\" G; exit 0] }"
      ]
    said `shouldBe` ["main-made", "module-made"]
    panics `shouldBe` []
    rrExit rr `shouldBe` ExitSuccess

  -- §13.25: import-position promotion. A top-level program can spell
  -- the whole import as literals — both "..." positions desugar to
  -- bytesBind AutoN + import, no manual bind dance. The gate's suffix
  -- is the module name's CONTENTS' effective suffix (data), so the
  -- consumer gates on a distinctive suffix — "" would be
  -- indistinguishable from the prelude's (Imported, Prelude, "")
  -- tuple (and the gate's handle is the anonymous Auto atom, a
  -- compiler-generated name the consumer does not spell).
  it "a promoted import loads a module; the consumer gates on the suffix (§13.25)" $ do
    (said, panics, rr) <- runMain $ unlines
      [ ": import \"echo\" \"_v2\" []"
      , "(Imported, nh, \"_v2\") : (Echo_v2, \"hi\", Reply)"
      , "Reply { (Echoed_v2, m) : [say \"got %s\" m; exit 0] }"
      ]
    said `shouldBe` ["got hi"]
    panics `shouldBe` []
    rrExit rr `shouldBe` ExitSuccess

  -- §13.25: a module's own import promotes too — its Auto atoms mangle
  -- with the module's suffix (importprom imports with ambient suffix
  -- _v2, so Auto0_v2/Auto1_v2), the promoted binds land under the
  -- mangled names, and the import reads them back consistently.
  -- Shape of the §13.13 outer/inner recursion test.
  it "a module's import promotes its literals; the handles mangle (§13.25)" $ do
    (said, panics, rr) <- runMain $ unlines $
      preamble "importprom" "_v2" ++
      [ importLine
      , "(Imported, Mod, \"_v2\") : (Go_v2, Reply)"
      , "Reply { (InnerHi_v2,) : [say \"inner via promoted import\"; exit 0] }"
      ]
    said `shouldBe` ["inner via promoted import"]
    panics `shouldBe` []
    rrExit rr `shouldBe` ExitSuccess

  -- §11.12: quiet's only machine is a one-shot that dies, and it
  -- declares no Error block — so the import installs the module's
  -- default Error machine, which is idle-exempt and must not keep
  -- the run alive once every user machine is gone. Before the fix
  -- this shape false-deadlocked (10s timeout = failure).
  it "a module's default Error machine is idle-exempt (§11.12)" $ do
    (said, panics, rr) <- runMain $ unlines
      [ ": [bytesBind Mod \"quiet\"; bytesBind Sfx \"_v2\"; import Mod Sfx []; die]"
      ]
    said `shouldBe` []
    panics `shouldBe` []
    rrExit rr `shouldBe` ExitSuccess

-- | A unique scratch file (created empty) for the §13.17 fd test,
-- left in the OS temp dir — empty and harmless.
tmpFdPath :: IO FilePath
tmpFdPath = do
  d <- getTemporaryDirectory
  (p, h) <- openBinaryTempFile d "lindana-fd-mod-test"
  hClose h
  pure p
