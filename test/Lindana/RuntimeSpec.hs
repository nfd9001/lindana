{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the STM tuple bag + structural matcher (handover §3).
module Lindana.RuntimeSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently, mapConcurrently_, async, wait)
import Control.Concurrent.STM (atomically)
import qualified Data.Map.Strict as Map

import Test.Hspec

import Lindana.Runtime
import Lindana.Syntax

--------------------------------------------------------------------------------
-- Shorthands
--------------------------------------------------------------------------------

a :: Name -> Pat
a = PAtom

v :: Name -> Pat
v = PVar

p1 :: Name -> Pat
p1 n = PTuple [a n]

-- | @pat@ as a single Take clause.
take1 :: Pat -> [PatElem]
take1 p = [PatElem Take p]

atom :: Name -> Val
atom = VAtom

t :: [Val] -> Val
t = VTuple

--------------------------------------------------------------------------------
-- Structural matching
--------------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "structural matching (§3.2)" $ do
    it "binds a variable to the whole matched value" $ do
      Just env <- matchOne (v "x") (atom "Foo")
      matchEnv env `shouldBe` Map.fromList [("x", atom "Foo")]

    it "matches atoms by exact name" $ do
      r <- matchOne (a "Tick") (atom "Tick")
      r `shouldSatisfy` matchesSucceed
      r2 <- matchOne (a "Tick") (atom "Tock")
      r2 `shouldSatisfy` matchesFail

    it "is case-sensitive (capitalized = atom, §4)" $ do
      r <- matchOne (a "Foo") (atom "foo")
      r `shouldSatisfy` matchesFail

    it "matches int and double literals by kind" $ do
      r1 <- matchOne (PInt 1) (VInt 1)
      r1 `shouldSatisfy` matchesSucceed
      -- 1 (int) and 1.0 (double) are different literal kinds; the
      -- matcher is structural, and mixed numeric promotion is an open
      -- question (§11.3) — provisionally they do not cross-match.
      r2 <- matchOne (PInt 1) (VDouble 1.0)
      r2 `shouldSatisfy` matchesFail

    it "requires tuple arity to agree" $ do
      r <- matchOne (PTuple [a "Tick"]) (t [atom "Tick", VInt 0])
      r `shouldSatisfy` matchesFail

    it "matches nested tuple patterns" $ do
      r <- matchOne (PTuple [a "Add", v "c"]) (t [atom "Add", t [atom "Print"]])
      fmap matchEnv r `shouldBe` Just (Map.fromList [("c", t [atom "Print"])])

    it "requires repeated variables to bind equal values (§11.2, provisional)" $ do
      r1 <- matchOne (PTuple [v "a", v "a"]) (t [VInt 3, VInt 3])
      r1 `shouldSatisfy` matchesSucceed
      r2 <- matchOne (PTuple [v "a", v "a"]) (t [VInt 3, VInt 4])
      r2 `shouldSatisfy` matchesFail

  describe "take vs read (§3)" $ do
    it "take consumes the tuple" $ do
      bag <- newBag
      atomically (outSTM bag (t [atom "Tick"]))
      _ <- inBag bag (take1 (p1 "Tick"))
      bagContents bag `shouldReturn` []

    it "read leaves the tuple in the bag" $ do
      bag <- newBag
      atomically (outSTM bag (t [atom "Tick"]))
      m <- rdBag bag [p1 "Tick"]
      matchedVals m `shouldBe` [t [atom "Tick"]]
      length <$> bagContents bag `shouldReturn` 1

  describe "join patterns (§3.4)" $ do
    let addPat  = PTuple [a "Add", v "a", v "b", v "c"]
        statsPat = PTuple [a "Stats", a "Add", v "n", v "e"]
        epochPat = PTuple [a "ResetEpoch", v "r"]
        join = [ PatElem Take addPat
               , PatElem Take statsPat
               , PatElem Read epochPat
               ]

    it "matches all clauses in one transaction; reads survive" $ do
      bag <- newBag
      atomically $ do
        outSTM bag (t [atom "Add", VInt 1, VInt 2, atom "Print"])
        outSTM bag (t [atom "Stats", atom "Add", VInt 0, VInt 0])
        outSTM bag (t [atom "ResetEpoch", VInt 5])
      m <- inBag bag join
      matchEnv m `shouldBe` Map.fromList
        [ ("a", VInt 1), ("b", VInt 2), ("c", atom "Print")
        , ("n", VInt 0), ("e", VInt 0), ("r", VInt 5) ]
      -- The two takes are consumed; the read survives (broadcast).
      bagContents bag `shouldReturn` [t [atom "ResetEpoch", VInt 5]]

    it "requires distinct tuples for each take clause" $ do
      bag <- newBag
      atomically (outSTM bag (t [atom "Solo"]))
      r <- inpBag bag [ PatElem Take (p1 "Solo")
                      , PatElem Take (p1 "Solo") ]
      r `shouldSatisfy` matchesFail
      -- Nothing was consumed by the failed join.
      length <$> bagContents bag `shouldReturn` 1

    it "matches nothing when any clause fails" $ do
      bag <- newBag
      atomically (outSTM bag (t [atom "Add", VInt 1, VInt 2, atom "Print"]))
      r <- inpBag bag join  -- Stats/ResetEpoch tuples absent
      r `shouldSatisfy` matchesFail

  describe "probes inp/rdp (§8.1)" $ do
    it "inp takes when possible and reports failure without blocking" $ do
      bag <- newBag
      atomically (outSTM bag (t [atom "Tick"]))
      Just m <- inpBag bag (take1 (p1 "Tick"))
      matchedVals m `shouldBe` [t [atom "Tick"]]
      Nothing <- inpBag bag (take1 (p1 "Tick"))
      pure ()

    it "rdp observes without consuming" $ do
      bag <- newBag
      atomically (outSTM bag (t [atom "Tick"]))
      Just m <- rdpBag bag [p1 "Tick"]
      matchedVals m `shouldBe` [t [atom "Tick"]]
      length <$> bagContents bag `shouldReturn` 1

  describe "blocking in (§3)" $ do
    it "blocks until a matching tuple appears, then binds" $ do
      bag <- newBag
      hdl <- async (inBag bag (take1 (PTuple [a "Add", v "a", v "b"])))
      threadDelay 50000  -- give the blocked thread time to start retrying
      atomically (outSTM bag (t [atom "Add", VInt 20, VInt 22]))
      m <- wait hdl
      matchEnv m `shouldBe` Map.fromList [("a", VInt 20), ("b", VInt 22)]

  describe "racing matches (§3.1)" $ do
    it "exactly one contender wins a contested tuple" $ do
      bag <- newBag
      atomically (outSTM bag (t [atom "Prize"]))
      let contender () = atomically (matchJoinSTM bag (take1 (p1 "Prize")))
      results <- mapConcurrently contender (replicate 16 ())
      length (filter (\x -> case x of Just _ -> True; Nothing -> False) results)
        `shouldBe` 1

    it "concurrent producers + consumers conserve the tuples" $ do
      bag <- newBag
      let n = 200 :: Int
          producer i = atomically (outSTM bag (t [atom "Job", VInt (toInteger i)]))
          -- Consumers probe non-blockingly (probes are the §8.1
          -- primitive) and keep draining until the bag is empty. The
          -- bag never grows again (producers finished first), so one
          -- Nothing observation is conclusive.
          consumer () = go (0 :: Int)
            where
              go k = do
                mr <- inpBag bag (take1 (PTuple [a "Job", v "i"]))
                case mr of
                  Just _  -> go (k + 1)
                  Nothing -> pure k
      mapConcurrently_ producer [1 .. n]
      taken <- sum <$> mapConcurrently consumer (replicate (n `div` 2) ())
      taken `shouldBe` n
      bagContents bag `shouldReturn` []

  describe "trailing rest capture (§11.1, provisional)" $ do
    let cap = PRest   -- shorthand below: rest! is PRest "rest" etc.

    it "captures the remaining elements as a sub-tuple" $ do
      r <- matchOne (PTuple [a "Ping", v "first", cap "rest"])
                    (t [atom "Ping", VInt 1, VInt 2, VInt 3])
      fmap matchEnv r `shouldBe` Just (Map.fromList
        [ ("first", VInt 1), ("rest", t [VInt 2, VInt 3]) ])

    it "captures zero elements when the tuple is exhausted (zero-or-more)" $ do
      r <- matchOne (PTuple [a "Ping", cap "rest"]) (t [atom "Ping"])
      fmap matchEnv r `shouldBe` Just (Map.fromList [("rest", t [])])

    it "(c!) matches any tuple, capturing the whole thing (the Error shape)" $ do
      r1 <- matchOne (PTuple [cap "c"]) (t [atom "Bad", VInt 7])
      fmap matchEnv r1 `shouldBe`
        Just (Map.fromList [("c", t [atom "Bad", VInt 7])])
      r2 <- matchOne (PTuple [cap "c"]) (t [])
      fmap matchEnv r2 `shouldBe` Just (Map.fromList [("c", t [])])

    it "does not match a non-tuple (matcher stays structural, §3.2)" $ do
      r <- matchOne (PTuple [cap "c"]) (atom "Foo")
      r `shouldSatisfy` matchesFail

    it "a capture name repeated with a plain element honours §11.2 equality" $ do
      -- (n, n!): the capture is checked against the earlier binding
      -- rather than overwriting it. n! is a TUPLE of the remaining
      -- elements, so the first element must equal that sub-tuple:
      --   ((X, Y), X, Y):  n = (X, Y), n! = (X, Y)  → equal
      --   ((X, Y), X, Z):  n! = (X, Z)              → different
      r1 <- matchOne (PTuple [v "n", cap "n"])
                     (t [t [atom "X", atom "Y"], atom "X", atom "Y"])
      r1 `shouldSatisfy` matchesSucceed
      r2 <- matchOne (PTuple [v "n", cap "n"])
                     (t [t [atom "X", atom "Y"], atom "X", atom "Z"])
      r2 `shouldSatisfy` matchesFail

  describe "expression evaluation (construction side)" $ do
    let env = Map.fromList
          [ ("a", VInt 20), ("b", VInt 22)
          , ("c", t [atom "Print"]) ]

    it "evaluates arithmetic and variables" $ do
      evalExpr env (EBin Add (EVar "a") (EVar "b")) `shouldBe` VInt 42

    it "splices a bound tuple into a constructed tuple (§4)" $ do
      evalExpr env (ETuple [ESplice (EVar "c"), EBin Add (EVar "a") (EVar "b")])
        `shouldBe` t [atom "Print", VInt 42]

-- | Probe one Take pattern against a bag containing exactly @val@:
-- the workhorse for structural-match tests.
matchOne :: Pat -> Val -> IO (Maybe MatchResult)
matchOne p val = do
  bag <- newBag
  atomically (outSTM bag val)
  inpBag bag (take1 p)

matchesSucceed :: Maybe MatchResult -> Bool
matchesSucceed = maybe False (const True)

matchesFail :: Maybe MatchResult -> Bool
matchesFail = maybe True (const False)
