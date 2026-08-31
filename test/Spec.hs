{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Text as T

import Control.Monad (void)
import Data.Either (isLeft)

import Test.Hspec

import Lindana.Parser (parseProgram)
import Lindana.MachineSpec (spec)
import qualified Lindana.LoaderSpec as LoaderSpec
import qualified Lindana.RuntimeSpec as RuntimeSpec
import Lindana.Syntax
  ( Action (..), Decl (..), Expr (..), Pat (..), PatElem (..)
  , ReadMode (..), Program, progDecls, renderProgram
  )
import Text.Megaparsec.Error (errorBundlePretty)

-- The §8.2 self-throttling example from the handover, verbatim.
throttleSrc :: T.Text
throttleSrc = T.unlines
  [ "{"
  , "  (ResetEpoch, 0),"
  , "  (Stats, Add, 0, 0)"
  , "}"
  , ""
  , "(Tick,), (ResetEpoch, n) : (ResetEpoch, n + 1)"
  , ""
  , "(\"add\", a, b, c), (Stats, Add, count, epoch), rd(ResetEpoch, e) :"
  , "  if epoch != e then"
  , "    [(Stats, Add, 0, e); (\"add\", a, b, c)]"
  , "  else if rand(count) == 0 then"
  , "    [(Stats, Add, 0, epoch); (c!, a + b)]"
  , "  else"
  , "    [(Stats, Add, count + 1, epoch); sleep(rand(count) * 5); (\"add\", a, b, c)]"
  ]

-- The §10 toy example, updated to current conventions
-- (capitalized = atom; bracketed Terse sequences).
toySrc :: T.Text
toySrc = T.unlines
  [ "{"
  , "  (Add, 1, 2, (\"Print\",))"
  , "}"
  , ""
  , "(Add, a, b, c) : (c!, a + b)"
  , "(Print, s) : [say \"Sum is %i\" s; (Stop, 1)]"
  , "(Stop, c) : if c then [say \"Error, closing\"; exit c] else [exit c]"
  ]

parseOk :: T.Text -> IO Program
parseOk src = case parseProgram src of
  Left e   -> expectationFailure (errorBundlePretty e) >> error "unreachable"
  Right p  -> pure p

roundTrips :: T.Text -> Bool
roundTrips src = case parseProgram src of
  Left _  -> False
  Right p -> case parseProgram (T.pack (renderProgram p)) of
    Right p' -> p' == p
    Left _   -> False

main :: IO ()
main = hspec $ do
  describe "Lindana.Parser" $ do
    it "parses the §8.2 self-throttling example (initial bag + 2 machines)" $ do
      p <- parseOk throttleSrc
      progDecls p `shouldHaveLength` 3

    it "parses the §10 toy example" $ do
      p <- parseOk toySrc
      progDecls p `shouldHaveLength` 4

    it "round-trips the throttling example through the pretty-printer" $
      roundTrips throttleSrc `shouldBe` True

    it "round-trips the toy example through the pretty-printer" $
      roundTrips toySrc `shouldBe` True

    it "parses trailing rest-capture and round-trips it (§11.1)" $ do
      p <- parseOk "(c!) : die"
      progDecls p `shouldHaveLength` 1
      roundTrips "(c!) : die" `shouldBe` True
      void (parseOk "(Ping, rest!) : (Pong, rest!)")

    it "rejects mid rest-capture (trailing-only, §11.1)" $
      parseProgram "(a, b!, c) : die" `shouldSatisfy` isLeft

    it "rejects rest-capture on a non-variable (§11.1: var-only)" $
      parseProgram "(Foo!) : die" `shouldSatisfy` isLeft

    it "parses a one-line bag block (§6): } ends the machine" $ do
      roundTrips "W { (Ping,) : die }" `shouldBe` True
      p <- parseOk "W { (Ping,) : die }\n(Tick,) : die"
      progDecls p `shouldHaveLength` 2

    -- §11.5 list/cons sugar (provisional): literals and patterns are
    -- parse-time sugar over nested 2-tuples with the Nil sentinel atom;
    -- the AST has no list nodes, so rendering shows the desugared form
    -- (still round-trip friendly).
    describe "list/cons sugar (§11.5)" $ do
      let cons h t = ETuple [h, t]
          nil = EAtom "Nil"
      it "desugars a literal to nested 2-tuples ending in Nil" $ do
        p <- parseOk "{ ([1, 2, 3],) }"
        progDecls p `shouldBe`
          [Initial [ETuple [cons (EInt 1) (cons (EInt 2) (cons (EInt 3) nil))]]]
      it "desugars [] to Nil" $ do
        p <- parseOk "{ ([]) }"
        progDecls p `shouldBe` [Initial [ETuple [nil]]]
      it "conses onto an arbitrary tail with [h | t]" $ do
        p <- parseOk "{ ([a, b | t],) }"
        progDecls p `shouldBe`
          [Initial [ETuple [cons (EVar "a") (cons (EVar "b") (EVar "t"))]]]
      it "desugars a pattern [h | t] to a 2-tuple pattern" $ do
        p <- parseOk "([h | t],) : die"
        progDecls p `shouldBe`
          [Machine [PatElem Take (PTuple [PTuple [PVar "h", PVar "t"]])] [Die]]
      it "desugars the empty pattern [] to Nil" $ do
        p <- parseOk "([],) : die"
        progDecls p `shouldBe`
          [Machine [PatElem Take (PTuple [PAtom "Nil"])] [Die]]
      it "allows multi-head patterns [a, b | t]" $ do
        p <- parseOk "([a, b | t],) : die"
        progDecls p `shouldBe`
          [Machine [PatElem Take (PTuple [PTuple [PVar "a", PTuple [PVar "b", PVar "t"]]])] [Die]]
      it "nests: lists of lists" $ do
        p <- parseOk "{ ([[1], []],) }"
        progDecls p `shouldBe`
          [Initial [ETuple [cons (cons (EInt 1) nil) (cons nil nil)]]]
      it "round-trips through the pretty-printer (rendered as the desugared tuples)" $
        roundTrips "{ ([1, 2, 3],) }\n([],) : die" `shouldBe` True

    it "parses a no-LHS machine (§1 one-shot): the issue #7 Hello World" $ do
      p <- parseOk $ T.unlines
        [ ": [say \"Hello world!\"; (Stop, 0)]"
        , "(Stop, c) : if c then [say \"Error, closing\"; exit c] else [exit c]"
        ]
      progDecls p `shouldHaveLength` 2
      roundTrips ": [say \"Hello world!\"; (Stop, 0)]" `shouldBe` True
  spec
  LoaderSpec.spec
  RuntimeSpec.spec
  where
    shouldHaveLength xs n = length xs `shouldBe` n
