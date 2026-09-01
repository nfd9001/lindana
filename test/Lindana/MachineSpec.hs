{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the machine loop / scheduler (§1, §2) and the action
-- layer + effect-runner (§3.3, §7.2) — handover §13.3 steps 1–2.
--
-- Programs in these tests must terminate: a looping machine blocked on
-- a match that never arrives keeps the run alive (that is the §1 loop
-- working as specified), so test machines end in @die@ (or the
-- program exits).
module Lindana.MachineSpec (spec) where

import Data.IORef
import qualified Data.Map.Strict as Map
import Data.List (sort)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import System.Exit (ExitCode (..))
import System.Timeout (timeout)

import Test.Hspec

import Lindana.Machine
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

machine :: [PatElem] -> [Action] -> MachineDef
machine = MachineDef globalBag ""

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

-- | Capture @say@ output and @panic@ messages.
captureHooks :: IO (Hooks, IORef [String], IORef [String])
captureHooks = do
  said   <- newIORef []
  panics <- newIORef []
  let hooks = Hooks
        { hookSay   = \s -> modifyIORef' said (s :)
        , hookPanic = \m -> modifyIORef' panics (m :)
        }
  pure (hooks, said, panics)

--------------------------------------------------------------------------------
-- The machine loop (§1)
--------------------------------------------------------------------------------

spec :: Spec
spec = do
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
      output <- readIORef said
      reverse output `shouldBe` ["first", "second"]

    it "die drops the rest of the bundle" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Say "before" [], Die, Say "after" [] ]
      _ <- runGlobal hooks [m] [t [EAtom "Go"]]
      output <- readIORef said
      reverse output `shouldBe` ["before"]

    it "tuple-space writes commit before deferred effects (§8.2 note)" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Out (t [EAtom "Marked"]), Sleep (int 50), Say "late" [], Die ]
      r <- runGlobal hooks [m] [t [EAtom "Go"]]
      rrBag r `shouldSatisfy` elem (VTuple [VAtom "Marked"])
      output <- readIORef said
      reverse output `shouldBe` ["late"]

    it "say formats %i and %s" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (PTuple [a "Go", v "n", v "s"]))
            [ Say "n is %i, s is %s" [EVar "n", EVar "s"], Die ]
      _ <- runGlobal hooks [m]
             [t [EAtom "Go", int 42, consL [int 104, int 105]]]
      output <- readIORef said
      reverse output `shouldBe` ["n is 42, s is hi"]

    it "say %s decodes a casual string, escapes and non-ASCII included (§9)" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (PTuple [a "Go", v "s"]))
            [ Say "<%s>" [EVar "s"], Die ]
      _ <- runGlobal hooks [m]
             [t [EAtom "Go", consL [int 72, int 105, int 10, int 9786]]]
      output <- readIORef said
      reverse output `shouldBe` ["<Hi\n\9786>"]

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

  describe "named bags (§6)" $ do
    it "a machine only matches the bag whose block declared it" $ do
      -- (Work,) lands in bag W, not Global: the Global machine never
      -- fires, the W machine does. Bags isolate (§6 split). The W
      -- machine exits — a machine blocked forever on a tuple another
      -- bag consumed is exactly the isolation being tested, and the
      -- §1 loop would otherwise keep the run alive (correctly).
      let globalM = machine (take1 (p1 "Work")) [Out (t [EAtom "GlobalFired"]), Die]
          wM      = MachineDef "W" "" (take1 (p1 "Work"))
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
      let w1 = MachineDef "W" "" (take1 (p1 "Ping")) [Out (t [EAtom "Pong"]), Die]
          w2 = MachineDef "W" "" (take1 (p1 "Pong")) [Out (t [EAtom "Done"]), Die]
      r <- runLoaded defaultHooks [w1, w2] (Map.singleton "W" [t [EAtom "Ping"]])
      rrBag r `shouldBe` []
      Map.lookup "W" (rrBags r) `shouldBe` Just [VTuple [VAtom "Done"]]

    it "lob crosses bags: Global machine feeds a named bag's machine (§6.1, §6.2 drain)" $ do
      -- The tuple is lob'd before W's machine ever matches: the §6.2
      -- handoff must not lose it. out+lob in one body commit atomically.
      let feeder = machine (take1 (p1 "Go"))
            [ Out (t [EAtom "Fed"]), Lob (EAtom "W") (t [EAtom "Work", int 3]), Die ]
          worker = MachineDef "W" "" (take1 (PTuple [a "Work", v "n"]))
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
      output <- readIORef said
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
      output <- readIORef said
      reverse output `shouldBe` ["after-slept"]

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
      -- Only the destroy target is gone; the §13.13 preregistered
      -- Nil → "" entry survives (it may itself be clobbered/destroyed).
      rrBytes r `shouldBe` Map.singleton "Nil" ""

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
      output <- readIORef said
      reverse output `shouldBe` ["<Hi>"]

    it "bytesEqual on an unbound handle aborts the machine's transaction" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Out (t [EAtom "Seen"])
            , If (ECall "bytesEqual" [EAtom "Nope", EAtom "Nope"]) [Die] [Die] ]
      r <- runGlobal hooks [m] [t [EAtom "Go"]]
      -- The interpret-time error kills the transaction: the Out never
      -- commits, the tuple stays in the bag, no effects leak.
      rrBag r `shouldBe` [VTuple [VAtom "Go"]]
      output <- readIORef said
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
      output <- readIORef said
      output `shouldBe` []

    it "== between atom literals is identity even without bytes bound" $ do
      let m = machine (take1 (p1 "Go"))
            [ If (EBin Eq (EAtom "A") (EAtom "A"))
                 [Out (t [EAtom "Same"]), Die]
                 [Die] ]
      r <- runProgram [m] [t [EAtom "Go"]]
      rrBag r `shouldBe` [VTuple [VAtom "Same"]]
