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
import System.Exit (ExitCode (..))
import System.Timeout (timeout)

import Test.Hspec

import Lindana.Machine
import Lindana.Runtime (Val (..))
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

machine :: [PatElem] -> [Action] -> MachineDef
machine = MachineDef

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
      _ <- runProgramWith hooks [m] [t [EAtom "Go"]]
      output <- readIORef said
      reverse output `shouldBe` ["first", "second"]

    it "die drops the rest of the bundle" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Say "before" [], Die, Say "after" [] ]
      _ <- runProgramWith hooks [m] [t [EAtom "Go"]]
      output <- readIORef said
      reverse output `shouldBe` ["before"]

    it "tuple-space writes commit before deferred effects (§8.2 note)" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Out (t [EAtom "Marked"]), Sleep (int 50), Say "late" [], Die ]
      r <- runProgramWith hooks [m] [t [EAtom "Go"]]
      rrBag r `shouldSatisfy` elem (VTuple [VAtom "Marked"])
      output <- readIORef said
      reverse output `shouldBe` ["late"]

    it "say formats %i and %s" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (PTuple [a "Go", v "n", v "s"]))
            [ Say "n is %i, s is %s" [EVar "n", EVar "s"], Die ]
      _ <- runProgramWith hooks [m]
             [t [EAtom "Go", int 42, EStr "hi"]]
      output <- readIORef said
      reverse output `shouldBe` ["n is 42, s is hi"]

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
      r <- runProgramWith hooks [m] [t [EAtom "Go"]]
      rrExit r `shouldBe` ExitFailure 1
      msgs <- readIORef panics
      reverse msgs `shouldBe` ["(Bad, 1)"]

    it "a blocked machine alone keeps the program alive (watchdog needed)" $ do
      let blocked = machine (take1 (p1 "Never")) []
      r <- timeout 150000 (runProgram [blocked] [])
      r `shouldBe` Nothing

  describe "error verb (§6.4, degenerate pre-§6 form)" $ do
    it "fires an (Error, …) tuple into the bag" $ do
      let m = machine (take1 (p1 "Boom"))
            [ Raise (t [EAtom "Bad", int 7]), Die ]
      r <- runProgram [m] [t [EAtom "Boom"]]
      rrBag r `shouldBe` [VTuple [VAtom "Error", VAtom "Bad", VInt 7]]

  describe "builtins (action layer, §3.3)" $ do
    it "typeOf yields the type atoms (§4)" $ do
      let m = machine (take1 (p1 "Go"))
            [ Out (t [ ECall "typeOf" [int 42]
                     , ECall "typeOf" [EDouble 1.5]
                     , ECall "typeOf" [EAtom "Foo"]
                     , ECall "typeOf" [t []]
                     ])
            , Die ]
      r <- runProgram [m] [t [EAtom "Go"]]
      rrBag r `shouldBe` [VTuple
        [VAtom "Int", VAtom "Double", VAtom "Atom", VAtom "Tuple"]]

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

    it "atomize/atos round-trip (§4)" $ do
      let m = machine (take1 (p1 "Go"))
            [ Out (t [ ECall "atos" [ECall "atomize" [EStr "Foo"]]
                     , ECall "typeOf" [ECall "atomize" [EStr "Foo"]] ])
            , Die ]
      r <- runProgram [m] [t [EAtom "Go"]]
      rrBag r `shouldBe` [VTuple [VStr "Foo", VAtom "Atom"]]

  describe "lob accumulation (§6.2 preview)" $ do
    it "lob to an unknown bag creates a machineless accumulator" $ do
      let m = machine (take1 (p1 "Go"))
            [ Lob "Log" (t [EAtom "Bar"]), Lob "Log" (t [EAtom "Baz"]), Die ]
      r <- runProgram [m] [t [EAtom "Go"]]
      rrBag r `shouldBe` []           -- nothing landed in the main bag
      Map.lookup "Log" (rrBags r) `shouldBe`
        Just [VTuple [VAtom "Baz"], VTuple [VAtom "Bar"]]

  describe "two-phase split (§8.2 note)" $ do
    it "sleep defers say effects but not tuple writes" $ do
      (hooks, said, _) <- captureHooks
      let m = machine (take1 (p1 "Go"))
            [ Out (t [EAtom "Marked"]), Sleep (int 40), Say "after-slept" [], Die ]
      r <- runProgramWith hooks [m] [t [EAtom "Go"]]
      rrBag r `shouldBe` [VTuple [VAtom "Marked"]]
      output <- readIORef said
      reverse output `shouldBe` ["after-slept"]
