{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the program loader (handover §13.5 step 4): AST →
-- bag-tagged machines + per-bag initial tuples, the §6 declaration
-- rules, the §11.10 top-level grammar decision, and the §6.4 default
-- @Error@ machine — exercised end-to-end (parse → load → run) where
-- the runtime behavior matters.
module Lindana.LoaderSpec (spec) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text as T
import System.Directory (getTemporaryDirectory)
import System.Exit (ExitCode (..))
import System.IO (hClose, openBinaryTempFile, stderr, stdin)
import System.Timeout (timeout)

import Data.List (sort)
import System.Random (mkStdGen)
import Test.Hspec

import Lindana.Loader
import Lindana.Machine
import Lindana.Parser (parseProgram)
import Lindana.Runtime (Val (..), stringVal)
import Lindana.Syntax

-- | The §6.4 default Error machine, by shape (LoaderSpec's oldest
-- tests filter it out of machine lists; the loader appends it when
-- the program declares no Error bag).
isDefaultError :: MachineDef -> Bool
isDefaultError m = machBag m == errorBag
                   && machBody m == [Panic (EVar "c")]
                   && machJoin m == [PatElem Take (PTuple [PRest "c"])]

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
      -- The §6.4 default Error machine is appended by the loader, and
      -- the §13.15 default Prelude import machine is prepended (both
      -- filtered/skipped here); scope the check to the user's machines.
      map machBag (filter (\m -> not (isDefaultError m)
                                 && m /= preludeImportMachine)
                          (loadedMachines l))
        `shouldBe` ["Global"]

    it "machines inside a bag block are tagged with that bag" $ do
      l <- loadOk $ unlines
        [ "Workers {"
        , "  (Ping,) : (Pong,)"
        , "  (Pong,) : die"
        , "}"
        , "(Tick,) : die"
        ]
      -- Error + the two user bags' machines, plus two Global-tagged
      -- synthetics: the user's bare (Tick,) machine and the §13.15
      -- default Prelude import one-shot.
      sort (map machBag (loadedMachines l))
        `shouldBe` ["Error", "Global", "Global", "Workers", "Workers"]

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
      -- The synthetic Prelude import machine (a bare-style one-shot on
      -- Global) must not trip the "pick one style" check above.
      sort (map machBag (loadedMachines l))
        `shouldBe` ["Error", "Global", "Global"]

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
      h <- silentHooks
      r <- runLoaded h (loadedMachines l) (loadedInitial l)
      rrExit r `shouldBe` ExitFailure 1

    it "an empty Error { } block swallows errors silently end-to-end" $ do
      l <- loadOk "{ (Boom,) }\nError { }\n(Boom,) : [error (\"bad\", 7); die]"
      h <- silentHooks
      r <- runLoaded h (loadedMachines l) (loadedInitial l)
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
      h <- silentHooks
      r <- runLoaded h (loadedMachines l) (loadedInitial l)
      rrExit r `shouldBe` ExitSuccess

  describe "no-LHS machines (§1 one-shot, issue #7)" $
    it "the issue #7 Hello World runs end-to-end: one-shot fires, then exit 0" $ do
      l <- loadOk $ unlines
        [ ": [say \"Hello world!\"; (Stop, 0)]"
        , "(Stop, c) : if c then [say \"Error, closing\"; exit c] else [exit c]"
        ]
      -- The loader must accept an empty join pattern (§1: runs once,
      -- unconditionally, at start) without mangling it. (The §6.4
      -- default Error machine and the §13.15 Prelude import machine
      -- are also present; filter both out.)
      let userMachs = [m | m <- loadedMachines l
                         , not (isDefaultError m)
                         , m /= preludeImportMachine]
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
      h <- silentHooks
      r <- runLoaded h (loadedMachines l) (loadedInitial l)
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
      -- The prelude's one-shots would add their own completion tuples
      -- to Global, so this exact-bag test opts out via the pragma.
      l <- loadOk $ unlines
        [ "{-# no-prelude #-}"
        , ": [bytesBind A [72]; bytesBind B [72, 72]; (Go,)]"
        , "(Bytes, A), (Bytes, B), (Go,) :"
        , "  [ if bytesEqual(A, B) then (ContentEq,) else (ContentNeq,)"
        , "  ; if A == B then (SameAtom,) else (DifferentAtoms,)"
        , "  ; exit 0 ]"
        ]
      h <- silentHooks
      r <- runLoaded h (loadedMachines l) (loadedInitial l)
      sort (map renderVal (rrBag r)) `shouldBe`
        ["(ContentNeq)", "(DifferentAtoms)"]
      rrExit r `shouldBe` ExitSuccess

  describe "character sugar e2e (§9, issue #12)" $ do
    it "char literals match, cons into strings, and build bytestrings" $ do
      l <- loadOk $ unlines
        [ "{ ('A', 3) }"
        , "('A', n) : [say \"got %i\" n; (Next,)]"
        , "(Next,) : (Built, ['o', 'k'])"
        , "(Built, cs) : [say \"%s\" cs; (Bind,)]"
        , "(Bind,) : [bytesBind Word ['O', 'k']; (Fin,)]"
        , "(Bytes, Word), (Fin,) : [say \"%b\" Word; exit 0]"
        ]
      (said, rr) <- runCaptureSay (loadedMachines l) (loadedInitial l)
      said `shouldBe` ["got 3", "ok", "Ok"]
      rrExit rr `shouldBe` ExitSuccess

  -- §13.24 (issue #18's stretch goal): a "..." literal in fwrite's
  -- bytestring position promotes — the desugar is bytesBind AutoN +
  -- fwrite, sharing one action list, so the bundle's FIFO drain lands
  -- bind before write and no consumer needs the gate.
  describe "inline auto-promotion e2e (§9, issue #18 stretch goal, §13.24)" $ do
    it "a literal fwrites as an anonymous bytestring, no gate needed" $ do
      l <- loadOk $ unlines
        [ ": [fwrite Stdout \"inline hi\"; say \"\"; exit 0]"
        ]
      (said, rr) <- runCaptureSay (loadedMachines l) (loadedInitial l)
      said `shouldBe` ["inline hi"]
      rrExit rr `shouldBe` ExitSuccess
    it "several promotions in one bundle write in byte-exact order" $ do
      l <- loadOk $ unlines
        [ ": [fwrite Stdout \"a\"; fwrite Stdout \"b\"; fwrite Stdout \"c\"; say \"\"; exit 0]"
        ]
      (said, rr) <- runCaptureSay (loadedMachines l) (loadedInitial l)
      said `shouldBe` ["abc"]
      rrExit rr `shouldBe` ExitSuccess
    it "promotion composes with the fd verbs: a promoted literal into a file, read back" $ do
      path <- tmpFdPath
      l <- loadOk $ unlines
        [ ": [fopen F \"" ++ path ++ "\" W"
        , "  ; fwrite F \"from a promoted literal\""
        , "  ; fclose F; fopen G \"" ++ path ++ "\" R; fread G"
        , "  ; say \"%b\" G; exit 0]"
        ]
      (said, rr) <- runCaptureSay (loadedMachines l) (loadedInitial l)
      said `shouldBe` ["from a promoted literal"]
      rrExit rr `shouldBe` ExitSuccess

  describe "bytesRead: the identity invariant e2e (§9, issue #12)" $ do
    it "bytesRead of a bind matches the original string literal pattern" $ do
      l <- loadOk $ unlines
        [ ": [bytesBind Word \"Ok\"; (Go,)]"
        , "(Bytes, Word), (Go,) : (Read, bytesRead(Word))"
        -- the read-back list IS the codepoints "Ok" builds, so the
        -- string-literal pattern matches structurally — the issue's
        -- "string in and out of ByteString is the identity" invariant
        , "(Read, \"Ok\") : [say \"bytesRead round-trips; matched the \\\"Ok\\\" pattern\"; (Done,)]"
        , "(Done,) : exit 0"
        ]
      (said, rr) <- runCaptureSay (loadedMachines l) (loadedInitial l)
      said `shouldBe` ["bytesRead round-trips; matched the \"Ok\" pattern"]
      rrExit rr `shouldBe` ExitSuccess

  -- Issue #24: ordering comparisons, end-to-end through
  -- parse → load → run. Ordering ops gate branches on numerics;
  -- bytesCompare is the bytestring's enriched lexicographic version.
  describe "comparisons e2e (issue #24)" $ do
    it "ordering ops gate branches; bytesCompare orders handles lexicographically" $ do
      l <- loadOk $ unlines
        [ "{-# no-prelude #-}"
        , ": [bytesBind A \"apple\"; bytesBind B \"apricot\"; (Go,)]"
        , "(Bytes, A), (Bytes, B), (Go,) :"
        , "  [ if bytesCompare(A, B) < 0 then say \"lex: apple first\" else say \"lex: oops\""
        , "  ; if 2 + 2 >= 4 then say \"arith ok\" else say \"arith oops\""
        , "  ; if 1 <= 0 then exit 1 else exit 0 ]"
        ]
      (said, rr) <- runCaptureSay (loadedMachines l) (loadedInitial l)
      sort said `shouldBe` ["arith ok", "lex: apple first"]
      rrExit rr `shouldBe` ExitSuccess

  -- §13.15 (issue #17 part 3): the default Prelude import. The loader
  -- prepends a synthetic one-shot ': import Prelude Nil []' to every
  -- top-level program (after the pragma check); the import effect
  -- loads the prelude from the builtin registry and its one-shot
  -- machines preregister their statics. All programs here end in an
  -- explicit 'exit' (the §13.8 house rule) and gate on completion
  -- tuples — the prelude's binds are deferred effects, so consumers
  -- must join on the (Bytes, H) gates (§9).
  describe "the default Prelude import (§13.15, issue #17 part 3)" $ do
    it "prepends the synthetic import machine by default" $ do
      l <- loadOk "(Ping,) : die"
      head (loadedMachines l) `shouldBe` preludeImportMachine
      machBag preludeImportMachine `shouldBe` "Global"
      machJoin preludeImportMachine `shouldBe` []
      machBody preludeImportMachine
        `shouldBe` [Import (EAtom "Prelude") (EAtom "Nil") (EAtom "Nil")]

    it "{-# no-prelude #-} suppresses it" $ do
      l <- loadOk "{-# no-prelude #-}\n(Ping,) : die"
      loadedMachines l `shouldNotContain` [preludeImportMachine]

    it "the prelude's statics are bound by default (e2e)" $ do
      -- Gate on the (Bytes, Version) completion tuple: the prelude's
      -- binds are deferred effects run by the effect runner, so a
      -- consumer must join on the gate, not race it.
      l <- loadOk $ unlines
        [ "(Bytes, Version) : [say \"lindana %b\" Version; (D,)]"
        , "(D,) : exit 0"
        ]
      (said, rr) <- runCaptureSay (loadedMachines l) (loadedInitial l)
      said `shouldBe` ["lindana 0.1.0.0"]
      rrExit rr `shouldBe` ExitSuccess
      -- The whole gate set: both static binds landed, and the default
      -- import emitted its completion tuple (the empty suffix renders
      -- as the Nil atom).
      let bs = rrBytes rr
      Map.lookup "Newline" bs `shouldBe` Just (encodeUtf8 (T.pack "\n"))
      Map.lookup "Version" bs `shouldBe` Just (encodeUtf8 (T.pack "0.1.0.0"))
      rrBag rr `shouldContain`
        [VTuple [VAtom "Imported", VAtom "Prelude", VAtom "Nil"]]

    it "pragma + explicit import brings it back with a hide list (e2e)" $ do
      -- The customization story: opt out, then import explicitly and
      -- hide what you don't want. Version's machine is skipped (no
      -- (Bytes, Version) gate ever lands); Newline still binds.
      l <- loadOk $ unlines
        [ "{-# no-prelude #-}"
        , ": import Prelude Nil [Version]"
        , "(Bytes, Newline) : [say \"nl%b\" Newline; (D,)]"
        , "(D,) : exit 0"
        ]
      (said, rr) <- runCaptureSay (loadedMachines l) (loadedInitial l)
      -- §13.18: capture reads the Stdout fd's byte stream — the %b
      -- content's own newline and say's trailing newline split as two.
      said `shouldBe` ["nl", ""]
      rrExit rr `shouldBe` ExitSuccess
      Map.member "Version" (rrBytes rr) `shouldBe` False
      Map.lookup "Newline" (rrBytes rr) `shouldBe` Just (encodeUtf8 (T.pack "\n"))

    it "an explicit import without the pragma is a singleton repeat (e2e)" $ do
      -- First import wins (§13.13): the default import got there
      -- first, so the explicit one is a skip — but still emits its
      -- completion. The join of two (Imported, Prelude, …) takes
      -- proves both completions exist and (via exit 0) that the run
      -- terminated cleanly with the prelude spawned exactly once.
      l <- loadOk $ unlines
        [ ": import Prelude Nil []"
        , "(Imported, Prelude, Nil), (Imported, Prelude, Nil) : exit 0"
        ]
      h <- silentHooks
      r <- runLoaded h (loadedMachines l) (loadedInitial l)
      rrExit r `shouldBe` ExitSuccess

    it "a repeat import settles its pending slot (e2e regression)" $ do
      -- §13.13's "−1 on skip" was not implemented: a repeat import
      -- leaked its pending-import slot, so a program relying on the
      -- run-alive check (live == 0) instead of exit hung forever once
      -- the default Prelude import made repeat imports routine. No
      -- exit here on purpose — termination comes from live == 0, and
      -- Error { } keeps the §6.4 default machine out of the count.
      l <- loadOk $ unlines
        [ "Error { }"
        , ": import Prelude Nil []"
        , "(Imported, Prelude, Nil), (Imported, Prelude, Nil) : [(Done,); die]"
        ]
      mr <- timeout (10 * 1000000)
              (silentHooks >>= \h -> runLoaded h (loadedMachines l) (loadedInitial l))
      case mr of
        Nothing -> expectationFailure "run hung: repeat import leaked its pending slot"
        Just r  -> rrExit r `shouldBe` ExitSuccess

-- | Run loaded, capturing @say@ output and the result.
--
-- House rule, learned the hard way in the §9 e2e tests: a program
-- whose machines all die leaves the §6.4 default @Error@ machine
-- blocked forever, and termination then depends on the RTS's
-- @BlockedIndefinitelyOnSTM@ deadlock report — which is not reliable
-- under the test harness (flaky hangs). End e2e programs with an
-- explicit @exit@, not just @die@.
--
-- §13.18: @say@ is un-magicked — capture is the @Stdout@ fd's OS
-- handle (a scratch temp file), read back after the run.
runCaptureSay :: [MachineDef] -> Map Name [Expr]
              -> IO ([String], RunResult)
runCaptureSay ms initial = do
  d <- getTemporaryDirectory
  (p, hout) <- openBinaryTempFile d "lindana-say-test"
  let hooks = Hooks { hookStdin  = stdin
                    , hookStdout = hout
                    , hookStderr = stderr
                    , hookPanic = \_ -> pure ()
                    , hookModDir = ".", hookSeed = mkStdGen 12345
                    , hookChaos = noChaos, hookChaosSeed = mkStdGen 271828 }
  rr <- runLoaded hooks ms initial
  hClose hout
  said <- lines <$> readFile p
  pure (said, rr)

-- | Hooks that keep end-to-end runs quiet: @say@ (the Stdout fd) and
-- @panic@ both land in scratch files instead of the test runner's
-- output. IO: the scratch handles need opening.
silentHooks :: IO Hooks
silentHooks = do
  d <- getTemporaryDirectory
  (_, hout) <- openBinaryTempFile d "lindana-say-test"
  (_, herr) <- openBinaryTempFile d "lindana-say-test"
  pure Hooks
    { hookStdin  = stdin
    , hookStdout = hout
    , hookStderr = herr
    , hookPanic  = \_ -> pure ()
    , hookModDir = ".", hookSeed = mkStdGen 12345
    , hookChaos = noChaos, hookChaosSeed = mkStdGen 271828 }

-- | A unique scratch file (created empty) for fd e2e tests, left in
-- the OS temp dir — empty and harmless (the ModuleSpec twin's
-- sibling).
tmpFdPath :: IO FilePath
tmpFdPath = do
  d <- getTemporaryDirectory
  (p, h) <- openBinaryTempFile d "lindana-fd-test"
  hClose h
  pure p
