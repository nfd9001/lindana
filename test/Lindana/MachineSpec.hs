{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the machine loop / scheduler (§1, §2) and the action
-- layer + effect-runner (§3.3, §7.2) — handover §13.3 steps 1–2.
--
-- Programs in these tests must terminate: a looping machine blocked on
-- a match that never arrives keeps the run alive (that is the §1 loop
-- working as specified), so test machines end in @die@ (or the
-- program exits).
module Lindana.MachineSpec (spec) where

import Data.Char (ord)
import qualified Data.ByteString as BS
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.List (isInfixOf, sort)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import System.Directory (getTemporaryDirectory)
import System.Exit (ExitCode (..))
import System.IO (hClose, openBinaryFile, openBinaryTempFile, stderr, stdin,
                  IOMode (ReadMode))
import System.Timeout (timeout)
import Control.Monad (unless)

import Test.Hspec

import Lindana.Machine
import Lindana.Loader (loadProgram, loadedInitial, loadedMachines)
import Lindana.Parser (parseProgram)
import Lindana.Runtime (Val (..), stringVal)
import Lindana.Syntax

--------------------------------------------------------------------------------
-- Shorthands
--------------------------------------------------------------------------------

a :: Name -> Pat
a = PAtom

v :: Name -> Pat
v = PVar

t :: [Expr] -> Expr
t = ETuple

int :: Integer -> Expr
int = EInt

-- | A cons-list literal (§11.5 desugaring): nested 2-tuples ending in
-- the Nil atom.
consL :: [Expr] -> Expr
consL = foldr (\e acc -> ETuple [e, acc]) (EAtom "Nil")

-- | A string literal in its desugared shape (§9): a casual-string
-- cons-list of codepoints as an expression.
str :: String -> Expr
str = consL . map (int . toInteger . ord)

machine :: [PatElem] -> [Action] -> MachineDef
machine j b = MachineDef globalBag "" False j b

-- | Run with hooks, all initial tuples in @Global@ (the pre-§6
-- shape the older tests were written against).
runGlobal :: Hooks -> [MachineDef] -> [Expr] -> IO RunResult
runGlobal hooks ms tuples =
  runProgramWith hooks ms (Map.singleton globalBag tuples)

-- | A single-element tuple pattern @\"Tag\"@ as @('Tag',)@.
p1 :: Name -> Pat
p1 n = PTuple [a n]

take1 :: Pat -> [PatElem]
take1 p = [PatElem Take p]

-- | Capture @say@ output (§13.18: say is un-magicked — its stream
-- goes through the Stdout fd, so capture is a /Handle/ (a scratch
-- temp file), read back after the run) and @panic@ messages. @said@
-- is an IO action: it closes the capture handle (first call only) and
-- returns the lines said.
captureHooks :: IO (Hooks, IO [String], IORef [String])
captureHooks = do
  panics <- newIORef []
  d <- getTemporaryDirectory
  (p, hout) <- openBinaryTempFile d "lindana-say-test"
  let hooks = Hooks
        { hookStdin  = stdin
        , hookStdout = hout
        , hookStderr = stderr
        , hookPanic  = \m -> modifyIORef' panics (m :)
        , hookModDir = "."
        }
  closedRef <- newIORef False
  let said = do
        c <- readIORef closedRef
        unless c $ do
          writeIORef closedRef True
          hClose hout
        lines <$> readFile p
  pure (hooks, said, panics)

-- | §13.17: a unique scratch file path (created empty), for fopen
-- tests. Left in the OS temp dir — empty and harmless.
tmpPath :: IO FilePath
tmpPath = do
  d <- getTemporaryDirectory
  (p, h) <- openBinaryTempFile d "lindana-fd-test"
  hClose h
  pure p

--------------------------------------------------------------------------------
-- The machine loop (§1)
--------------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "shutdown: the idle-exempt default Error machine (§11.12)" $ do
    -- Parse + load + run with say/panic capture, 10s timeout (a hang
    -- is a failure). The loader appends the §6.4 default Error
    -- machine when the program declares no Error bag — exactly the
    -- shape §11.12 is about.
    let runLoadedSrc src = do
          p <- case parseProgram (T.pack src) of
            Left e   -> expectationFailure ("parse failed: " ++ show e) >> error "unreachable"
            Right p' -> pure p'
          l <- case loadProgram p of
            Left err -> expectationFailure ("load failed: " ++ err) >> error "unreachable"
            Right l' -> pure l'
          (hooks, said, panics) <- captureHooks
          mrr <- timeout (10 * 1000000)
                   (runLoaded hooks (loadedMachines l) (loadedInitial l))
          rr <- case mrr of
            Nothing -> expectationFailure "run timed out (deadlock?)" >> error "unreachable"
            Just rr -> pure rr
          said' <- said
          panics' <- reverse <$> readIORef panics
          pure (said', panics', rr)

    it "a program whose machines all die ends cleanly without an Error block" $ do
      (said, panics, rr) <- runLoadedSrc $ unlines
        [ "{ (Tick,) }"
        , "(Tick,) : [say \"hi\"; die]"
        ]
      said `shouldBe` ["hi"]
      panics `shouldBe` []
      rrExit rr `shouldBe` ExitSuccess

    it "an error tuple at shutdown still gets its guaranteed panic" $ do
      -- The panic message renders the tuple structurally (%a-style:
      -- the payload is a codepoint cons-list), so assert on the hook
      -- firing, not on a substring.
      (_, panics, rr) <- runLoadedSrc ": [error (\"boom\", 7)]"
      length panics `shouldBe` 1
      rrExit rr `shouldBe` ExitFailure 1

  describe "the machine loop (§1)" $ do
    it "capture + splice round-trip through the full loop (§11.1)" $ do
      -- (Ping, 1, 2) → machine (Ping, rest!) : out (Pong, rest!) →
      -- (Pong, 1, 2): the construction splice is the inverse of the
      -- pattern capture — the continuation-passing core, end to end.
      let m = machine (take1 (PTuple [a "Ping", PRest "rest"]))
            [ Out (t [EAtom "Pong", ESplice (EVar "rest")]), Die ]
      r <- runProgram [m] [t [EAtom "Ping", int 1, int 2]]
      rrBag r `shouldBe` [VTuple [VAtom "Pong", VInt 1, VInt 2]]

    it "reacts to a matching tuple (the §10 toy program, current syntax)" $ do
      let add = machine (take1 (PTuple [a "Add", v "a", v "b", v "c"]))
            [ Out (ETuple [ESplice (EVar "c"), EBin Add (EVar "a") (EVar "b")])
            , Die ]
          printer = machine (take1 (PTuple [a "Print", v "s"]))
            [ Out (t [EAtom "Done", EVar "s"]), Die ]
      r <- runProgram [add, printer]
             [t [EAtom "Add", int 1, int 2, t [EAtom "Print"]]]
      rrBag r `shouldBe` [VTuple [VAtom "Done", VInt 3]]

    it "loops by default until told to die" $ do
      let tick = machine (take1 (PTuple [a "Tick", v "n"]))
            [ If (EBin Eq (EVar "n") (EInt 5))
                 [Out (t [EAtom "Done", EVar "n"]), Die]
                 [Out (t [EAtom "Tick", EBin Add (EVar "n") (EInt 1)])] ]
      r <- runProgram [tick] [t [EAtom "Tick", int 0]]
      rrBag r `shouldBe` [VTuple [VAtom "Done", VInt 5]]

    it "an empty-pattern machine runs once, unconditionally, at start (§1)" $ do
      let boot = machine [] [Out (t [EAtom "Boot", int 1])]
      r <- runProgram [boot] []
      rrBag r `shouldContain` [VTuple [VAtom "Boot", VInt 1]]

    it "a one-shot's emissions are visible to later matches (init idiom, §1)" $ do
      let boot = machine [] [Out (t [EAtom "Ready"])]
          consumer = machine (take1 (PTuple [a "Ready"]))
            [Out (t [EAtom "Saw"]), Die]
      r <- runProgram [boot, consumer] []
      rrBag r `shouldBe` [VTuple [VAtom "Saw"]]

  describe "racing matches across machines (§3.1)" $ do
    it "every contested tuple gets exactly one winner; nothing is lost" $ do
      let worker = machine (take1 (PTuple [a "Job", v "n"]))
            [Out (t [EAtom "Done", EVar "n"]), Die]
          n = 20 :: Int
      r <- runProgram (replicate n worker)
             [t [EAtom "Job", int (toInteger i)] | i <- [1 .. toInteger n]]
      let dones = [x | x@(VTuple [VAtom "Done", VInt _]) <- rrBag r]
          jobs  = [x | x@(VTuple [VAtom "Job",  _]) <- rrBag r]
      length dones `shouldBe` n
      jobs `shouldBe` []
      -- Each value appears exactly once: no double-handling.
      let vals = [n' | VTuple [VAtom "Done", VInt n'] <- dones]
      sort vals `shouldBe` [1 .. toInteger n]

  describe "continuation pipelines (§4, §5)" $ do
    it "hands work through ! splices and continuation atoms; conserves" $ do
      let first = machine (take1 (PTuple [a "Job", v "n"]))
            [Out (t [EAtom "Cont", EVar "n"]), Die]
          second = machine (take1 (PTuple [a "Cont", v "n"]))
            [Out (t [EAtom "Fin", EVar "n"]), Die]
      r <- runProgram [first, first, second, second]
             [t [EAtom "Job", int 1], t [EAtom "Job", int 2]]
      let fins = [n' | VTuple [VAtom "Fin", VInt n'] <- rrBag r]
      sort fins `shouldBe` [1, 2]
      rrBag r `shouldSatisfy` all (\x -> case x of
        VTuple [VAtom "Fin", _] -> True; _ -> False)

  describe "effects (§7.2)" $ do
    it "say effects run in action order within a bundle" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Say "first" [], Sleep (int 5), Say "second" [], Die ]
      _ <- runGlobal hooks [m] [t [EAtom "Go"]]
      output <- said
      output `shouldBe` ["first", "second"]

    it "die drops the rest of the bundle" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Say "before" [], Die, Say "after" [] ]
      _ <- runGlobal hooks [m] [t [EAtom "Go"]]
      output <- said
      output `shouldBe` ["before"]

    it "tuple-space writes commit before deferred effects (§8.2 note)" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Out (t [EAtom "Marked"]), Sleep (int 50), Say "late" [], Die ]
      r <- runGlobal hooks [m] [t [EAtom "Go"]]
      rrBag r `shouldSatisfy` elem (VTuple [VAtom "Marked"])
      output <- said
      output `shouldBe` ["late"]

    it "say formats %i and %s" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (PTuple [a "Go", v "n", v "s"]))
            [ Say "n is %i, s is %s" [EVar "n", EVar "s"], Die ]
      _ <- runGlobal hooks [m]
             [t [EAtom "Go", int 42, consL [int 104, int 105]]]
      output <- said
      output `shouldBe` ["n is 42, s is hi"]

    it "say %s decodes a casual string, escapes and non-ASCII included (§9)" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (PTuple [a "Go", v "s"]))
            [ Say "<%s>" [EVar "s"], Die ]
      _ <- runGlobal hooks [m]
             [t [EAtom "Go", consL [int 72, int 105, int 10, int 9786]]]
      -- §13.18: the capture reads the Stdout fd's byte stream — a
      -- say's own trailing newline is the only separator, so the %s
      -- content's embedded newline splits like any line break would.
      output <- said
      output `shouldBe` ["<Hi", "\9786>"]

  describe "termination verbs" $ do
    it "exit terminates the program with the given code" $ do
      let stopper = machine (take1 (PTuple [a "Stop", v "c"])) [Exit (EVar "c")]
          -- A still-blocked machine: exit must end the program anyway.
          blocked = machine (take1 (p1 "Never")) []
      r <- runProgram [stopper, blocked] [t [EAtom "Stop", int 3]]
      rrExit r `shouldBe` ExitFailure 3

    it "exit 0 is success" $ do
      let stopper = machine (take1 (p1 "Stop")) [Exit (int 0)]
      r <- runProgram [stopper] [t [EAtom "Stop"]]
      rrExit r `shouldBe` ExitSuccess

    it "panic is fatal and reports via the panic hook (§6.4)" $ do
      (hooks, _, panics) <- captureHooks
      let m = machine (take1 (p1 "Go")) [Panic (t [EAtom "Bad", int 1])]
      r <- runGlobal hooks [m] [t [EAtom "Go"]]
      rrExit r `shouldBe` ExitFailure 1
      msgs <- readIORef panics
      reverse msgs `shouldBe` ["(Bad, 1)"]

    it "a blocked machine alone keeps the program alive (watchdog needed)" $ do
      let blocked = machine (take1 (p1 "Never")) []
      r <- timeout 150000 (runProgram [blocked] [])
      r `shouldBe` Nothing

  describe "error verb (§6.4)" $ do
    it "fires an (Error, …) tuple into the named Error bag, not Global" $ do
      -- No Error machine here: the tuple simply sits in the Error bag
      -- (the default machine is the loader's business — LoaderSpec).
      let m = machine (take1 (p1 "Boom"))
            [ Raise (t [EAtom "Bad", int 7]), Die ]
      r <- runProgram [m] [t [EAtom "Boom"]]
      rrExit r `shouldBe` ExitSuccess
      rrBag r `shouldBe` []
      Map.lookup "Error" (rrBags r) `shouldBe`
        Just [VTuple [VAtom "Error", VAtom "Bad", VInt 7]]

  -- §13.14 (issue #17): the error-reroute effect. `reroute Src Tgt`
  -- installs Src → Tgt in the RTS table (in-transaction, last update
  -- wins); the error verb consults it — bag-specific key first, then
  -- the machine's module's mangled Error bag ("all bags in the
  -- module"; at top level that key IS the plain Error bag), then the
  -- default. The tag stays the original mangled Error bag: stable
  -- provenance, independent of the delivery bag.
  describe "error reroute (§13.14, issue #17)" $ do
    it "reroutes a bag's errors into the target (target created on demand)" $ do
      -- The target need not exist when the reroute commits: Sink has
      -- no machines and no initial tuples — bagForSTM creates it as a
      -- machineless accumulator (§6.2), and the tuple sits there.
      -- Boomer is gated on (Routed,) so the reroute is certainly
      -- installed before the error fires (both commit in the router's
      -- one transaction).
      let router = MachineDef "Router" "" False (take1 (p1 "Go"))
            [ Reroute (EAtom "W") (EAtom "Sink")
            , Lob (EAtom "W") (t [EAtom "Routed"]), Die ]
          boomer = MachineDef "W" "" False (take1 (p1 "Routed"))
            [ Raise (t [EAtom "Bad", int 7]), Die ]
      r <- runLoaded defaultHooks [router, boomer]
             (Map.fromList [("Router", [t [EAtom "Go"]])])
      Map.lookup "Sink" (rrBags r) `shouldBe`
        Just [VTuple [VAtom "Error", VAtom "Bad", VInt 7]]
      -- The default Error bag was never even created: the tuple went
      -- straight to the reroute target.
      Map.lookup "Error" (rrBags r) `shouldBe` Nothing
    it "module-wide: rerouting the mangled Error bag catches all the module's bags" $
      do
      -- "All bags in the module" (issue #17): a module machine's
      -- errors land in Error ++ machSfx before any reroute, so
      -- rerouting that name catches machines from /any/ of the
      -- module's bags. The tag stays Error_v2 (provenance).
      let router = MachineDef "Router" "" False (take1 (p1 "Go"))
            [ Reroute (EAtom "Error_v2") (EAtom "Sink")
            , Lob (EAtom "W_v2") (t [EAtom "Routed"]), Die ]
          boomer = MachineDef "W_v2" "_v2" False (take1 (p1 "Routed"))
            [ Raise (t [EAtom "Bad", int 7]), Die ]
      r <- runLoaded defaultHooks [router, boomer]
             (Map.fromList [("Router", [t [EAtom "Go"]])])
      Map.lookup "Sink" (rrBags r) `shouldBe`
        Just [VTuple [VAtom "Error_v2", VAtom "Bad", VInt 7]]
      Map.lookup "Error_v2" (rrBags r) `shouldBe` Nothing
    it "top-level-wide: reroute Error Log catches every top-level machine" $
      do
      -- At top level (machSfx == "") the module-wide key IS the plain
      -- Error bag, so `reroute Error Log` is "all bags in the (top-
      -- level) module": boomer lives in bag W, not Error, and is
      -- still caught.
      let router = MachineDef "Router" "" False (take1 (p1 "Go"))
            [ Reroute (EAtom "Error") (EAtom "Log")
            , Lob (EAtom "W") (t [EAtom "Routed"]), Die ]
          boomer = MachineDef "W" "" False (take1 (p1 "Routed"))
            [ Raise (t [EAtom "Bad", int 7]), Die ]
      r <- runLoaded defaultHooks [router, boomer]
             (Map.fromList [("Router", [t [EAtom "Go"]])])
      Map.lookup "Log" (rrBags r) `shouldBe`
        Just [VTuple [VAtom "Error", VAtom "Bad", VInt 7]]
      Map.lookup "Error" (rrBags r) `shouldBe` Nothing
    it "last update wins: a second reroute replaces the first" $
      do
      -- Both reroutes commit in one transaction, sequentially — the
      -- second insert wins, deterministically. Concurrent reroutes
      -- from different machines would race instead (STM commit
      -- order), which is the same "last committer wins" chaos as any
      -- racing match (§3.1) — documented, not guarded.
      let router = MachineDef "Router" "" False (take1 (p1 "Go"))
            [ Reroute (EAtom "W") (EAtom "Sink1")
            , Reroute (EAtom "W") (EAtom "Sink2")
            , Lob (EAtom "W") (t [EAtom "Routed"]), Die ]
          boomer = MachineDef "W" "" False (take1 (p1 "Routed"))
            [ Raise (t [EAtom "Bad", int 7]), Die ]
      r <- runLoaded defaultHooks [router, boomer]
             (Map.fromList [("Router", [t [EAtom "Go"]])])
      Map.lookup "Sink2" (rrBags r) `shouldBe`
        Just [VTuple [VAtom "Error", VAtom "Bad", VInt 7]]
      Map.lookup "Sink1" (rrBags r) `shouldBe` Nothing

  describe "named bags (§6)" $ do
    it "a machine only matches the bag whose block declared it" $ do
      -- (Work,) lands in bag W, not Global: the Global machine never
      -- fires, the W machine does. Bags isolate (§6 split). The W
      -- machine exits — a machine blocked forever on a tuple another
      -- bag consumed is exactly the isolation being tested, and the
      -- §1 loop would otherwise keep the run alive (correctly).
      let globalM = machine (take1 (p1 "Work")) [Out (t [EAtom "GlobalFired"]), Die]
          wM      = MachineDef "W" "" False (take1 (p1 "Work"))
                      [Out (t [EAtom "WFired"]), Exit (int 0)]
      r <- runLoaded defaultHooks [globalM, wM]
             (Map.fromList [("W", [t [EAtom "Work"]]),
                            (globalBag, [t [EAtom "Unrelated"]])])
      rrExit r `shouldBe` ExitSuccess
      rrBag r `shouldSatisfy` elem (VTuple [VAtom "Unrelated"])
      rrBag r `shouldNotSatisfy` elem (VTuple [VAtom "GlobalFired"])
      Map.lookup "W" (rrBags r) `shouldBe` Just [VTuple [VAtom "WFired"]]

    it "out emits into the machine's own bag (continuations stay home)" $ do
      -- Two workers in bag W hand off via bare out; Global never sees it.
      let w1 = MachineDef "W" "" False (take1 (p1 "Ping")) [Out (t [EAtom "Pong"]), Die]
          w2 = MachineDef "W" "" False (take1 (p1 "Pong")) [Out (t [EAtom "Done"]), Die]
      r <- runLoaded defaultHooks [w1, w2] (Map.singleton "W" [t [EAtom "Ping"]])
      rrBag r `shouldBe` []
      Map.lookup "W" (rrBags r) `shouldBe` Just [VTuple [VAtom "Done"]]

    it "lob crosses bags: Global machine feeds a named bag's machine (§6.1, §6.2 drain)" $ do
      -- The tuple is lob'd before W's machine ever matches: the §6.2
      -- handoff must not lose it. out+lob in one body commit atomically.
      let feeder = machine (take1 (p1 "Go"))
            [ Out (t [EAtom "Fed"]), Lob (EAtom "W") (t [EAtom "Work", int 3]), Die ]
          worker = MachineDef "W" "" False (take1 (PTuple [a "Work", v "n"]))
            [ Out (t [EAtom "Got", EVar "n"]), Die ]
      r <- runLoaded defaultHooks [feeder, worker]
             (Map.singleton globalBag [t [EAtom "Go"]])
      rrExit r `shouldBe` ExitSuccess
      Map.lookup "W" (rrBags r) `shouldBe`
        Just [VTuple [VAtom "Got", VInt 3]]
      rrBag r `shouldBe` [VTuple [VAtom "Fed"]]

    it "a machineless bag accumulates without any machine existing yet (§6.2)" $ do
      -- §6.2: lob into a bag nobody matches — cheap accumulation, no
      -- machines needed for it to exist.
      let m = machine (take1 (p1 "Go"))
            [ Lob (EAtom "Log") (t [EAtom "Bar"]), Die ]
      r <- runLoaded defaultHooks [m] (Map.singleton globalBag [t [EAtom "Go"]])
      Map.lookup "Log" (rrBags r) `shouldBe` Just [VTuple [VAtom "Bar"]]

    it "lob Global routes to the main bag" $ do
      let m = machine (take1 (p1 "Go")) [Lob (EAtom globalBag) (t [EAtom "Home"]), Die]
      r <- runProgram [m] [t [EAtom "Go"]]
      Map.lookup globalBag (rrBags r) `shouldBe` Nothing
      -- The match consumed (Go,); what is left is the lob'd (Home,).
      rrBag r `shouldBe` [VTuple [VAtom "Home"]]

  describe "builtins (action layer, §3.3)" $ do
    it "typeOf yields the type atoms (§4)" $ do
      let m = machine (take1 (p1 "Go"))
            [ Out (t [ ECall "typeOf" [int 42]
                     , ECall "typeOf" [EDouble 1.5]
                     , ECall "typeOf" [EAtom "Foo"]
                     , ECall "typeOf" [t []]
                     , -- A casual string is a cons-list: its shape is
                       -- Tuple — there is no Str tag (§9, §11.4).
                       ECall "typeOf" [consL [int 65]]
                     ])
            , Die ]
      r <- runProgram [m] [t [EAtom "Go"]]
      rrBag r `shouldBe` [VTuple
        [VAtom "Int", VAtom "Double", VAtom "Atom", VAtom "Tuple", VAtom "Tuple"]]

    it "rand stays in range and is deterministic across runs (fixed seed)" $ do
      let roller = machine (take1 (p1 "Roll"))
            [Out (t [EAtom "Rolled", ECall "rand" [int 10]]), Die]
          run' = runProgram [roller] [t [EAtom "Roll"]]
      r1 <- run'
      r2 <- run'
      let rolls = [n | VTuple [VAtom "Rolled", VInt n] <- rrBag r1]
      length (rrBag r1) `shouldBe` 1
      all (\n' -> n' >= 0 && n' < 10) rolls `shouldBe` True
      rrBag r2 `shouldBe` rrBag r1

    it "rand(2) is not a strict alternator (bounded-range gen)" $ do
      -- Hand-rolled LCG + low-bit sampling alternated 0,1,0,1…;
      -- the splitmix-backed StdGen must not. Draw four coins and
      -- require three consecutive identical values (impossible under
      -- strict alternation); deterministic under the fixed seed.
      let roller = machine (take1 (p1 "Roll"))
            [ Out (t [ EAtom "C1", ECall "rand" [int 2]
                     , ECall "rand" [int 2]
                     , ECall "rand" [int 2]
                     , ECall "rand" [int 2] ])
            , Die ]
      r <- runProgram [roller] [t [EAtom "Roll"]]
      let coins = [c | VTuple (VAtom "C1" : cs) <- rrBag r
                     , VInt c <- cs]
      length coins `shouldBe` 4
      coins `shouldSatisfy` (\cs' -> or (zipWith (==) cs' (drop 2 cs')))

    it "atomize/atos round-trip (§4), over casual strings (§9)" $ do
      let m = machine (take1 (p1 "Go"))
            [ Out (t [ ECall "atos" [ECall "atomize" [consL [int 70, int 111, int 111]]]
                     , ECall "typeOf" [ECall "atomize" [consL [int 70, int 111, int 111]]] ])
            , Die ]
      r <- runProgram [m] [t [EAtom "Go"]]
      -- atos hands back a casual string: the codepoint cons-list the
      -- §9 literal sugar builds — no VStr, no special type.
      rrBag r `shouldBe` [VTuple [stringVal "Foo", VAtom "Atom"]]

    it "atomize of an uncapitalized string aborts the machine's transaction (§4)" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Out (t [EAtom "Seen"])
            , Out (t [ECall "atomize" [consL [int 108, int 97, int 116, int 101]]]) ]
      r <- runGlobal hooks [m] [t [EAtom "Go"]]
      -- The interpret-time §4 panic (provisionally a Haskell error)
      -- kills the transaction: the Out never commits, the tuple stays
      -- in the bag, no effects leak.
      rrBag r `shouldBe` [VTuple [VAtom "Go"]]
      output <- said
      output `shouldBe` []

  describe "lob accumulation (§6.2 preview)" $ do
    it "lob to an unknown bag creates a machineless accumulator" $ do
      let m = machine (take1 (p1 "Go"))
            [ Lob (EAtom "Log") (t [EAtom "Bar"]), Lob (EAtom "Log") (t [EAtom "Baz"]), Die ]
      r <- runProgram [m] [t [EAtom "Go"]]
      rrBag r `shouldBe` []           -- nothing landed in the main bag
      Map.lookup "Log" (rrBags r) `shouldBe`
        Just [VTuple [VAtom "Baz"], VTuple [VAtom "Bar"]]

  describe "two-phase split (§8.2 note)" $ do
    it "sleep defers say effects but not tuple writes" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Out (t [EAtom "Marked"]), Sleep (int 40), Say "after-slept" [], Die ]
      r <- runGlobal hooks [m] [t [EAtom "Go"]]
      rrBag r `shouldBe` [VTuple [VAtom "Marked"]]
      output <- said
      output `shouldBe` ["after-slept"]

  describe "ordering comparisons (issue #24)" $ do
    it "orders ints and doubles; comparisons drive branches" $ do
      let m = machine (take1 (p1 "Go"))
            [ If (EBin Lt (int 1) (int 2)) [Out (t [EAtom "LtYes"])] [Out (t [EAtom "LtNo"])]
            , If (EBin Le (int 2) (int 1)) [Out (t [EAtom "LeYes"])] [Out (t [EAtom "LeNo"])]
            , If (EBin Ge (EDouble 2.0) (EDouble 2.0)) [Out (t [EAtom "GeDbl"])] [Out (t [EAtom "GeNo"])]
            , Die ]
      r <- runProgram [m] [t [EAtom "Go"]]
      sort (map renderVal (rrBag r)) `shouldBe` ["(GeDbl)", "(LeNo)", "(LtYes)"]

    it "mixed int/double ordering is an error, like mixed arithmetic (§11.3)" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Out (t [EAtom "Seen"])
            , If (EBin Lt (int 1) (EDouble 2.0))
                 [Out (t [EAtom "Less"])] [Out (t [EAtom "More"])] ]
      r <- runGlobal hooks [m] [t [EAtom "Go"]]
      rrBag r `shouldBe` [VTuple [VAtom "Go"]]
      output <- said
      output `shouldBe` []

    it "atoms order nowhere: < on two atoms aborts the machine's transaction" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Out (t [EAtom "Seen"])
            , If (EBin Lt (EAtom "A") (EAtom "B"))
                 [Out (t [EAtom "Less"])] [Out (t [EAtom "More"])] ]
      r <- runGlobal hooks [m] [t [EAtom "Go"]]
      -- The interpret-time error kills the transaction: the Out never
      -- commits, the tuple stays in the bag, no effects leak.
      rrBag r `shouldBe` [VTuple [VAtom "Go"]]
      output <- said
      output `shouldBe` []

    it "an atom never orders against a number (issue #24)" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Out (t [EAtom "Seen"])
            , If (EBin Lt (EAtom "A") (int 3))
                 [Out (t [EAtom "Less"])] [Out (t [EAtom "More"])] ]
      r <- runGlobal hooks [m] [t [EAtom "Go"]]
      rrBag r `shouldBe` [VTuple [VAtom "Go"]]
      output <- said
      output `shouldBe` []

  describe "bytestring side-table (§9)" $ do
    it "bytesBind registers a UTF-8 bytestring and emits (Bytes, H) completion" $ do
      let m = machine []
            [ BytesBind "Greeting" (consL [int 72, int 105, int 9786]), Die ]
      r <- runProgram [m] []
      Map.lookup "Greeting" (rrBytes r) `shouldBe`
        Just (encodeUtf8 (T.pack "Hi\9786"))
      rrBag r `shouldBe` [VTuple [VAtom "Bytes", VAtom "Greeting"]]

    it "bytesDestroy removes the side-table entry" $ do
      let m = machine []
            [ BytesBind "G" (consL [int 65]), BytesDestroy (EAtom "G"), Die ]
      r <- runProgram [m] []
      -- Only the destroy target is gone; the two preregistered entries
      -- survive (§13.13 Nil → "" — the free empty suffix — and §13.15
      -- Prelude → "Prelude" — the default import's name handle; either
      -- may itself be clobbered/destroyed).
      rrBytes r `shouldBe` Map.fromList
        [("Nil", ""), ("Prelude", encodeUtf8 (T.pack "Prelude"))]

    it "bytesEqual compares contents; == stays pure atom identity (§9)" $ do
      -- Gate on the (Bytes, H) completion tuples: the binds are
      -- deferred effects, so consumers must join on them (§9).
      let m = machine (concat
              [ take1 (PTuple [a "Bytes", a "A"])
              , take1 (PTuple [a "Bytes", a "B"])
              , take1 (p1 "Go") ])
            [ If (ECall "bytesEqual" [EAtom "A", EAtom "B"])
                 [Out (t [EAtom "ContentEq"])] [Out (t [EAtom "ContentNeq"])]
            , If (EBin Eq (EAtom "A") (EAtom "B"))
                 [Out (t [EAtom "SameAtom"])] [Out (t [EAtom "DistinctAtoms"])]
            , Die ]
          b = machine [] [ BytesBind "A" (consL [int 72])
                         , BytesBind "B" (consL [int 72, int 72]), Die ]
      -- B holds different bytes, so the two verdicts must disagree.
      r <- runProgram [m, b] [t [EAtom "Go"]]
      sort (map renderVal (rrBag r)) `shouldBe`
        ["(ContentNeq)", "(DistinctAtoms)"]

    it "bytesEqual is true for two handles with identical bytes" $ do
      let m = machine (concat
              [ take1 (PTuple [a "Bytes", a "A"])
              , take1 (PTuple [a "Bytes", a "B"])
              , take1 (p1 "Go") ])
            [ If (ECall "bytesEqual" [EAtom "A", EAtom "B"])
                 [Out (t [EAtom "ContentEq"]), Die]
                 [Die] ]
          b = machine [] [ BytesBind "A" (consL [int 72])
                         , BytesBind "B" (consL [int 72]), Die ]
      r <- runProgram [m, b] [t [EAtom "Go"]]
      rrBag r `shouldBe` [VTuple [VAtom "ContentEq"]]

    it "say %b decodes the handle's bytes" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (concat
              [ take1 (PTuple [a "Bytes", a "G"]), take1 (p1 "Go") ])
            [ Say "<%b>" [EAtom "G"], Die ]
          b = machine [] [ BytesBind "G" (consL [int 72, int 105]), Die ]
      _ <- runGlobal hooks [m, b] [t [EAtom "Go"]]
      output <- said
      output `shouldBe` ["<Hi>"]

    it "bytesEqual on an unbound handle aborts the machine's transaction" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Out (t [EAtom "Seen"])
            , If (ECall "bytesEqual" [EAtom "Nope", EAtom "Nope"]) [Die] [Die] ]
      r <- runGlobal hooks [m] [t [EAtom "Go"]]
      -- The interpret-time error kills the transaction: the Out never
      -- commits, the tuple stays in the bag, no effects leak.
      rrBag r `shouldBe` [VTuple [VAtom "Go"]]
      output <- said
      output `shouldBe` []

    it "bytesCompare orders contents lexicographically (§9, issue #24)" $ do
      -- Gate on the (Bytes, H) completion tuples: the binds are
      -- deferred effects, so consumers must join on them (§9).
      let m = machine (concat
              [ take1 (PTuple [a "Bytes", a "A"])
              , take1 (PTuple [a "Bytes", a "B"])
              , take1 (PTuple [a "Bytes", a "C"])
              , take1 (p1 "Go") ])
            [ Out (t [EAtom "AB", ECall "bytesCompare" [EAtom "A", EAtom "B"]])
            , Out (t [EAtom "BA", ECall "bytesCompare" [EAtom "B", EAtom "A"]])
            , Out (t [EAtom "AC", ECall "bytesCompare" [EAtom "A", EAtom "C"]])
            , Die ]
          b = machine [] [ BytesBind "A" (consL [int 97, int 112, int 112])   -- "app"
                         , BytesBind "B" (consL [int 97, int 112, int 114])   -- "apr"
                         , BytesBind "C" (consL [int 97, int 112, int 112])   -- "app" again
                         , Die ]
      r <- runProgram [m, b] [t [EAtom "Go"]]
      -- C holds the same bytes as A under a distinct handle: the
      -- comparison is of contents, and equality is 0.
      sort (map renderVal (rrBag r)) `shouldBe`
        ["(AB, -1)", "(AC, 0)", "(BA, 1)"]

    it "bytesCompare on an unbound handle aborts the machine's transaction (issue #24)" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Out (t [EAtom "Seen"])
            , Out (t [ECall "bytesCompare" [EAtom "Nope", EAtom "Nope"]]) ]
      r <- runGlobal hooks [m] [t [EAtom "Go"]]
      rrBag r `shouldBe` [VTuple [VAtom "Go"]]
      output <- said
      output `shouldBe` []

  describe "bytesRead — the decode-back path (§9, issue #12)" $ do
    it "decodes the handle's bytes back into the codepoint cons-list" $ do
      -- Gate on the (Bytes, H) completion tuple: the bind is a
      -- deferred effect, so the read must come after it lands (§9).
      let m = machine (take1 (PTuple [a "Bytes", a "G"]))
            [ Out (ECall "bytesRead" [EAtom "G"]), Die ]
          b = machine [] [ BytesBind "G" (consL [int 72, int 105, int 9786]), Die ]
      r <- runProgram [m, b] []
      rrBag r `shouldBe` [stringVal "Hi\9786"]
    it "is the identity: bytesRead of a bind returns the same list, shape included" $ do
      -- The issue's invariant: "running a string in and out of
      -- ByteString is like passing it through the identity function."
      -- The read-back Val must equal the original list — not merely
      -- render the same — so structural matching against a string
      -- literal pattern just works.
      let cps = consL [int 79, int 107]
          m = machine (take1 (PTuple [a "Bytes", a "W"]))
            [ Out (ECall "bytesRead" [EAtom "W"]), Die ]
          b = machine [] [ BytesBind "W" cps, Die ]
      r <- runProgram [m, b] []
      rrBag r `shouldBe` [stringVal "Ok"]
      rrBag r `shouldBe` [VTuple [VInt 79, VTuple [VInt 107, VAtom "Nil"]]]
    it "on an unbound handle aborts the machine's transaction" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Out (ECall "bytesRead" [EAtom "Nope"]), Die ]
      r <- runGlobal hooks [m] [t [EAtom "Go"]]
      rrBag r `shouldBe` [VTuple [VAtom "Go"]]
      output <- said
      output `shouldBe` []

    it "== between atom literals is identity even without bytes bound" $ do
      let m = machine (take1 (p1 "Go"))
            [ If (EBin Eq (EAtom "A") (EAtom "A"))
                 [Out (t [EAtom "Same"]), Die]
                 [Die] ]
      r <- runProgram [m] [t [EAtom "Go"]]
      rrBag r `shouldBe` [VTuple [VAtom "Same"]]

  describe "bytesNew — runtime-fresh handles (§9, issue #18 part 3)" $ do
    it "registers a fresh handle and emits the ordinary (Bytes, H) gate" $ do
      -- The consumer grabs the handle from the gate — it is data, never
      -- written in the source. Flat counter from 0 (the ACont
      -- precedent); nothing named Bytes0 is registered yet.
      let m = machine (take1 (PTuple [a "Bytes", v "h"]))
            [ Out (t [EAtom "Got", EVar "h"]), Die ]
          b = machine [] [ BytesNew (str "Hi"), Die ]
      r <- runProgram [m, b] []
      rrBag r `shouldBe` [VTuple [VAtom "Got", VAtom "Bytes0"]]
    it "the fresh handle's content is the string bytesNew was given" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (PTuple [a "Bytes", v "h"]))
            [ Say "got: %b" [EVar "h"], Die ]
          b = machine [] [ BytesNew (consL [int 72, int 105, int 9786]), Die ]
      _ <- runGlobal hooks [m, b] []
      output <- said
      output `shouldBe` ["got: Hi\9786"]
    it "two anonymous bytestrings get distinct handles and contents" $ do
      -- Either machine can grab either gate (the honest race, §3.1):
      -- the verdict must be 0 ("aa" /= "bb") whichever way it lands.
      let n1 = machine [] [ BytesNew (str "aa"), Die ]
          n2 = machine [] [ BytesNew (str "bb"), Die ]
          m1 = machine (take1 (PTuple [a "Bytes", v "h"]))
                 [ Out (t [EAtom "Have", EVar "h"]), Die ]
          m2 = machine [ PatElem Take (PTuple [a "Bytes", v "h2"])
                       , PatElem Take (PTuple [a "Have", v "h1"]) ]
                 [ Out (t [EAtom "Verdict"
                          , ECall "bytesEqual" [EVar "h1", EVar "h2"]])
                 , Die ]
      r <- runProgram [m1, m2, n1, n2] []
      VTuple [VAtom "Verdict", VInt 0] `elem` rrBag r `shouldBe` True
    it "skips a name an earlier bind already landed (same-bundle FIFO)" $ do
      -- The name is picked at EFFECT time: the Bytes0 bind earlier in
      -- the same action list lands first, so the fresh pick passes it
      -- over (the commit-time side-table does not have it yet — the
      -- EffImport precedent, effect-time reads honor landed state).
      -- Two identical collectors split the two gates between them (the
      -- honest race, §3.1).
      let b = machine [] [ BytesBind "Bytes0" (str "taken")
                         , BytesNew (str "fresh"), Die ]
          m = machine (take1 (PTuple [a "Bytes", v "h"]))
                [ Out (t [EAtom "Got", EVar "h"]), Die ]
      r <- runProgram [m, m, b] []
      VTuple [VAtom "Got", VAtom "Bytes0"] `elem` rrBag r `shouldBe` True
      VTuple [VAtom "Got", VAtom "Bytes1"] `elem` rrBag r `shouldBe` True
      length (rrBag r) `shouldBe` 2
    it "the fresh handle travels as data: a variable fwrites through it" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (PTuple [a "Bytes", v "h"]))
            [ FWrite (EAtom "Stdout") (EVar "h"), Say "done" [], Die ]
          b = machine [] [ BytesNew (str "via fd"), Die ]
      _ <- runGlobal hooks [m, b] []
      output <- said   -- the Stdout capture is byte-exact; "done" rides
                       -- the same stream after the fwrite's bytes
      output `shouldBe` ["via fddone"]

  describe "file descriptors (§13.17, issue #18)" $ do
    it "writes then reads back a file through the bytestring side-table" $ do
      (hooks, said, _) <- captureHooks
      path <- tmpPath
      let w = machine [] [ FOpen "F" (str path) (EAtom "W"), Die ]
          b = machine (take1 (PTuple [a "Fopen", a "F"]))
                [ BytesBind "S" (str "hello"), Die ]
          wr = machine (take1 (PTuple [a "Bytes", a "S"]))
                 [ FWrite (EAtom "F") (EAtom "S"), Die ]
          cl = machine (take1 (PTuple [a "Fwrote", a "F"]))
                 [ FClose (EAtom "F"), FOpen "G" (str path) (EAtom "R"), Die ]
          rd = machine (take1 (PTuple [a "Fopen", a "G"]))
                 [ FRead (EAtom "G"), Die ]
          out = machine (take1 (PTuple [a "Fread", a "G"]))
                 [ Say "%b" [EAtom "G"], Exit (int 0) ]
      r <- runGlobal hooks [w, b, wr, cl, rd, out] []
      rrExit r `shouldBe` ExitSuccess
      said >>= (`shouldBe` ["hello"])
      Map.lookup "G" (rrBytes r) `shouldBe` Just "hello"
    it "content survives the round-trip as UTF-8 bytes" $ do
      (hooks, _, _) <- captureHooks
      path <- tmpPath
      let content = "h\xE9llo \x2192 \x2603"
          w = machine [] [ FOpen "F" (str path) (EAtom "W"), Die ]
          b = machine (take1 (PTuple [a "Fopen", a "F"]))
                [ BytesBind "S" (str content), Die ]
          wr = machine (take1 (PTuple [a "Bytes", a "S"]))
                 [ FWrite (EAtom "F") (EAtom "S"), FClose (EAtom "F")
                 , FOpen "G" (str path) (EAtom "R"), FRead (EAtom "G")
                 , Exit (int 0) ]
      r <- runGlobal hooks [w, b, wr] []
      rrExit r `shouldBe` ExitSuccess
      Map.lookup "G" (rrBytes r) `shouldBe` Just (encodeUtf8 (T.pack content))
    it "a second fread sees the empty remainder (content is consumed)" $ do
      (hooks, said, _) <- captureHooks
      path <- tmpPath
      let w = machine [] [ FOpen "F" (str path) (EAtom "W"), Die ]
          b = machine (take1 (PTuple [a "Fopen", a "F"]))
                [ BytesBind "S" (str "abc"), Die ]
          wr = machine (take1 (PTuple [a "Bytes", a "S"]))
                 [ FWrite (EAtom "F") (EAtom "S"), Die ]
          cl = machine (take1 (PTuple [a "Fwrote", a "F"]))
                 [ FClose (EAtom "F"), FOpen "G" (str path) (EAtom "R"), Die ]
          rd = machine (take1 (PTuple [a "Fopen", a "G"]))
                 [ FRead (EAtom "G"), FRead (EAtom "G"), Die ]
          out = machine (take1 (PTuple [a "Fread", a "G"]))
                 [ Say "[%b]" [EAtom "G"], Exit (int 0) ]
      r <- runGlobal hooks [w, b, wr, cl, rd, out] []
      rrExit r `shouldBe` ExitSuccess
      said >>= (`shouldBe` ["[]"])
      Map.lookup "G" (rrBytes r) `shouldBe` Just ""
    it "fopen on a missing file is a runner-safe fatal: exit 1, no silent runner death" $ do
      (hooks, _, panics) <- captureHooks
      let m = machine [] [ FOpen "F" (str "/nonexistent/lindana-fd/xyz") (EAtom "R"), Die ]
      r <- runGlobal hooks [m] []
      rrExit r `shouldBe` ExitFailure 1
      readIORef panics >>= pure . reverse >>= (`shouldSatisfy` not . null)
    it "fread on a write-mode handle is a runner-safe fatal" $ do
      (hooks, _, panics) <- captureHooks
      path <- tmpPath
      let m = machine [] [ FOpen "F" (str path) (EAtom "W"), FRead (EAtom "F"), Die ]
      r <- runGlobal hooks [m] []
      rrExit r `shouldBe` ExitFailure 1
      readIORef panics >>= pure . reverse >>=
        (`shouldSatisfy` any ("not open for reading" `isInfixOf`))
    it "fwrite on a read-mode handle is a runner-safe fatal" $ do
      (hooks, _, panics) <- captureHooks
      path <- tmpPath
      let m = machine [] [ FOpen "F" (str path) (EAtom "R")
                         , BytesBind "S" (str "x")
                         , FWrite (EAtom "F") (EAtom "S"), Die ]
      r <- runGlobal hooks [m] []
      rrExit r `shouldBe` ExitFailure 1
      readIORef panics >>= pure . reverse >>=
        (`shouldSatisfy` any ("not open for writing" `isInfixOf`))
    it "fwrite through an unknown fd handle is a runner-safe fatal" $ do
      (hooks, _, panics) <- captureHooks
      path <- tmpPath
      let m = machine [] [ FOpen "F" (str path) (EAtom "W")
                         , BytesBind "S" (str "x")
                         , FWrite (EAtom "Nope") (EAtom "S"), Die ]
      r <- runGlobal hooks [m] []
      rrExit r `shouldBe` ExitFailure 1
      readIORef panics >>= pure . reverse >>=
        (`shouldSatisfy` any ("unknown fd handle" `isInfixOf`))
    it "fwrite from an unknown bytestring handle is a runner-safe fatal" $ do
      (hooks, _, panics) <- captureHooks
      path <- tmpPath
      let m = machine [] [ FOpen "F" (str path) (EAtom "W")
                         , FWrite (EAtom "F") (EAtom "Nope"), Die ]
      r <- runGlobal hooks [m] []
      rrExit r `shouldBe` ExitFailure 1
      readIORef panics >>= pure . reverse >>=
        (`shouldSatisfy` any ("unknown bytestring handle" `isInfixOf`))
    it "fclose is idempotent: closing an unknown handle is a no-op" $ do
      (hooks, _, panics) <- captureHooks
      let m = machine [] [ FClose (EAtom "Nope"), Exit (int 0) ]
      r <- runGlobal hooks [m] []
      rrExit r `shouldBe` ExitSuccess
      readIORef panics >>= pure . reverse >>= (`shouldBe` [])
    it "handles travel as data: variables fwrite through the fd and bytes they were given" $ do
      (hooks, said, _) <- captureHooks
      path <- tmpPath
      let w = machine [] [ FOpen "F" (str path) (EAtom "W"), Die ]
          b = machine (take1 (PTuple [a "Fopen", a "F"]))
                [ BytesBind "S" (str "data!"), Die ]
          -- The fd and the source bytestring both arrive as atoms in
          -- tuples; the action mentions only variables.
          wr = machine (take1 (PTuple [a "Go", v "h"])
                        ++ take1 (PTuple [a "Bytes", v "s"]))
                 [ FWrite (EVar "h") (EVar "s"), Die ]
          cl = machine (take1 (PTuple [a "Fwrote", a "F"]))
                 [ FClose (EAtom "F"), FOpen "G" (str path) (EAtom "R"), Die ]
          rd = machine (take1 (PTuple [a "Fopen", a "G"]))
                 [ FRead (EAtom "G"), Die ]
          out = machine (take1 (PTuple [a "Fread", a "G"]))
                 [ Say "%b" [EAtom "G"], Exit (int 0) ]
      r <- runGlobal hooks [w, b, wr, cl, rd, out]
             [t [EAtom "Go", EAtom "F"]]
      rrExit r `shouldBe` ExitSuccess
      said >>= (`shouldBe` ["data!"])
    it "a repeated fopen on the same handle wins last (both completions emit)" $ do
      (hooks, _, panics) <- captureHooks
      pathA <- tmpPath
      pathB <- tmpPath
      let f1 = machine [] [ FOpen "F" (str pathA) (EAtom "W"), Die ]
          f2 = machine [PatElem Read (PTuple [a "Fopen", a "F"])]
                 [ FOpen "F" (str pathB) (EAtom "W"), Die ]
          b  = machine (take1 (PTuple [a "Fopen", a "F"])
                        ++ take1 (PTuple [a "Fopen", a "F"]))
                 [ BytesBind "S" (str "b"), FWrite (EAtom "F") (EAtom "S")
                 , FClose (EAtom "F"), Exit (int 0) ]
      r <- runGlobal hooks [f1, f2, b] []
      rrExit r `shouldBe` ExitSuccess
      readIORef panics >>= pure . reverse >>= (`shouldBe` [])
      -- The write landed through pathB's handle: last fopen wins.
      BS.readFile pathB `shouldReturn` "b"
      BS.readFile pathA `shouldReturn` ""

  describe "std fds + un-magicked say (§13.18, issue #18 part 2)" $ do
    it "the std fds are preregistered: fwrite Stdout is the say path, in order" $ do
      (hooks, said, _) <- captureHooks
      let b = machine []
            [ BytesBind "A" (str "a"), BytesBind "B" (str "b"), Die ]
          m = machine (take1 (PTuple [a "Bytes", a "A"])
                        ++ take1 (PTuple [a "Bytes", a "B"]))
                [ FWrite (EAtom "Stdout") (EAtom "A"), Say "mid" []
                , FWrite (EAtom "Stdout") (EAtom "B"), Exit (int 0) ]
      r <- runGlobal hooks [b, m] []
      rrExit r `shouldBe` ExitSuccess
      -- say and fwrite share one fd: one byte stream, in bundle
      -- order. fwrite is byte-exact (no newline of its own); say
      -- writes a line. The file reads "a" "mid\n" "b\n".
      said >>= (`shouldBe` ["amid", "b"])
    it "fwrite Stderr goes through the Stderr fd" $ do
      d <- getTemporaryDirectory
      (_, hout) <- openBinaryTempFile d "lindana-say-test"
      (perr, herr) <- openBinaryTempFile d "lindana-say-test"
      let hooks = Hooks { hookStdin = stdin, hookStdout = hout
                        , hookStderr = herr, hookPanic = \_ -> pure ()
                        , hookModDir = "." }
          b = machine [] [ BytesBind "E" (str "err!"), Die ]
          m = machine (take1 (PTuple [a "Bytes", a "E"]))
                [ FWrite (EAtom "Stderr") (EAtom "E"), Exit (int 0) ]
      r <- runGlobal hooks [b, m] []
      rrExit r `shouldBe` ExitSuccess
      hClose herr
      BS.readFile perr `shouldReturn` "err!"
    it "fread Stdin blocks for a line; lines keep coming; EOF reads as the empty remainder" $ do
      d <- getTemporaryDirectory
      (_, hout) <- openBinaryTempFile d "lindana-say-test"
      (pin, hin) <- openBinaryTempFile d "lindana-stdin-test"
      BS.hPut hin (encodeUtf8 (T.pack "alpha\nbeta"))   -- no trailing newline:
      hClose hin                                        -- the last line is partial
      hin' <- openBinaryFile pin ReadMode
      let hooks = Hooks { hookStdin = hin', hookStdout = hout
                        , hookStderr = stderr, hookPanic = \_ -> pure ()
                        , hookModDir = "." }
          -- Three reads through the line-mode fd, each gated on the
          -- previous read's (Fread, Stdin) tuple (the gate exists only
          -- after the read effect ran) plus a counter tuple. The
          -- whole-remainder semantics would deliver "alpha\nbeta" in
          -- ONE read — three reads with "alpha", "beta", "" is the
          -- line story, and the empty third read is EOF (the honest
          -- empty remainder; the fd is NOT spent — lines keep coming
          -- until EOF, and it stays EOF after).
          r1 = machine [] [ FRead (EAtom "Stdin"), Out (t [EAtom "C", int 1]), Die ]
          r2 = machine (take1 (PTuple [a "C", v "n"])
                        ++ take1 (PTuple [a "Fread", a "Stdin"]))
                 [ Out (t [EAtom "R", ECall "bytesRead" [EAtom "Stdin"]])
                 , If (EBin Eq (EVar "n") (int 3)) [Exit (int 0)]
                     [ FRead (EAtom "Stdin")
                     , Out (t [EAtom "C", EBin Add (EVar "n") (int 1)]) ] ]
      r <- runGlobal hooks [r1, r2] []
      rrExit r `shouldBe` ExitSuccess
      -- The three gated reads deliver "alpha", "beta", "" (counter-
      -- ordered); the bag's listing order is accidental (§3), so sort.
      sort (map renderVal (rrBag r)) `shouldBe`
        sort (map (\s -> renderVal (VTuple [VAtom "R", stringVal s]))
                  ["alpha", "beta", ""])
    it "sayfd Bag Fd routes a bag's says to the fd (bag-specific tier)" $ do
      (hooks, said, _) <- captureHooks
      path <- tmpPath
      let router = machine []
                 [ FOpen "F" (str path) (EAtom "W")
                 , SayFd (EAtom "B") (EAtom "F")
                 , Lob (EAtom "B") (t [EAtom "Routed"]), Die ]
          mA = machine [] [ Say "from-a" [], Die ]
          mB = MachineDef "B" "" False (take1 (PTuple [a "Routed"]))
                 [ Say "from-b" [], FClose (EAtom "F"), Exit (int 0) ]
      r <- runGlobal hooks [router, mA, mB] []
      rrExit r `shouldBe` ExitSuccess
      -- a's say (bag Global) still goes to Stdout; b's say (bag B) is
      -- rerouted through the fopen'd file. The gate is LOBBED into B
      -- (mB's own bag, §6.1) and makes the install-vs-say order
      -- deterministic. F is closed before the test reads the file —
      -- GHC's per-Handle locking keeps an open handle's file locked.
      said >>= (`shouldBe` ["from-a"])
      BS.readFile path `shouldReturn` "from-b\n"
    it "sayfd module-wide tier: the mangled Error bag catches all of a module's machines" $ do
      (hooks, said, _) <- captureHooks
      path <- tmpPath
      let router = machine []
                 [ FOpen "F" (str path) (EAtom "W")
                 , SayFd (EAtom "Error_v2") (EAtom "F")
                 -- The gate has to cross into m2's OWN bag (§6.1): a
                 -- machBag "Log_v2" machine matches Log_v2, not Global.
                 , Lob (EAtom "Log_v2") (t [EAtom "Routed"]), Die ]
          -- machSfx "_v2": its module-wide key is Error_v2 (§13.14's
          -- convention, §13.18's table).
          m2 = MachineDef "Log_v2" "_v2" False (take1 (PTuple [a "Routed"]))
                 [ Say "m2" [], FClose (EAtom "F"), Exit (int 0) ]
          plain = machine (take1 (PTuple [a "Go"])) [ Say "p" [], Die ]
      r <- runGlobal hooks [router, m2, plain] [t [EAtom "Go"]]
      rrExit r `shouldBe` ExitSuccess
      -- The _v2 machine's says land in the file; the plain machine's
      -- (sfx "", module-wide key Error) still go to Stdout.
      said >>= (`shouldBe` ["p"])
      BS.readFile path `shouldReturn` "m2\n"
    it "last update wins: the second sayfd in one action list takes" $ do
      (hooks, _, _) <- captureHooks
      path1 <- tmpPath
      path2 <- tmpPath
      let router = machine []
                 [ FOpen "F1" (str path1) (EAtom "W")
                 , FOpen "F2" (str path2) (EAtom "W")
                 , SayFd (EAtom "B") (EAtom "F1")
                 , SayFd (EAtom "B") (EAtom "F2")
                 , Lob (EAtom "B") (t [EAtom "Routed"]), Die ]
          b = MachineDef "B" "" False (take1 (PTuple [a "Routed"]))
                 [ Say "twice-routed" [], FClose (EAtom "F1")
                 , FClose (EAtom "F2"), Exit (int 0) ]
      r <- runGlobal hooks [router, b] []
      rrExit r `shouldBe` ExitSuccess
      BS.readFile path1 `shouldReturn` ""
      BS.readFile path2 `shouldReturn` "twice-routed\n"
    it "an unroutable fd is the say effect's honest runner-safe fatal" $ do
      (hooks, _, panics) <- captureHooks
      let router = machine []
                 [ SayFd (EAtom "Global") (EAtom "NoSuch")
                 , Out (t [EAtom "Routed"]), Die ]
          b = machine (take1 (PTuple [a "Routed"]))
                 [ Say "boom" [], Exit (int 0) ]
      r <- runGlobal hooks [router, b] []
      rrExit r `shouldBe` ExitFailure 1
      readIORef panics >>= pure . reverse >>=
        (`shouldSatisfy` any ("say: unknown fd handle NoSuch" `isInfixOf`))
    it "fclose Stdout makes every later say an honest fatal (std fds are ordinary)" $ do
      (hooks, _, panics) <- captureHooks
      let m = machine [] [ FClose (EAtom "Stdout"), Say "boom" [], Die ]
      r <- runGlobal hooks [m] []
      rrExit r `shouldBe` ExitFailure 1
      readIORef panics >>= pure . reverse >>=
        (`shouldSatisfy` any ("say: unknown fd handle Stdout" `isInfixOf`))
    it "fclose Stdin is honest too: further freads fatal" $ do
      (hooks, _, panics) <- captureHooks
      let m = machine [] [ FClose (EAtom "Stdin"), FRead (EAtom "Stdin"), Die ]
      r <- runGlobal hooks [m] []
      rrExit r `shouldBe` ExitFailure 1
      readIORef panics >>= pure . reverse >>=
        (`shouldSatisfy` any ("fread: unknown fd handle Stdin" `isInfixOf`))

