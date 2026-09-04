-- | Module support (issue #17, handover §13.13): loading Lindana
-- source at runtime as /modules/, with suffix namespaces and hide
-- lists.
--
-- The @import@ action (Syntax's 'Import') is a deferred effect: the
-- effect runner calls 'parseModuleFile' + 'lowerModule' here to turn
-- @<moddir>/<name>.lind@ into bag-tagged machines + initial tuples,
-- which it then spawns/outs mid-run ("adding more machines during
-- runtime" — the thing issue #17 was also an excuse to build).
--
-- The pieces and their provisional decisions (all flip-worthy, per
-- the house style):
--
--   * /Search:/ the module name arrives as the /contents of a
--     bytestring handle/ (module names are runtime data); the module
--     file is @<moddir>/<name>.lind@, where @<moddir>@ is the
--     injectable 'Lindana.Machine.Hooks' @hookModDir@ (the CLI points
--     it at the main file's directory). The search name is /never/
--     suffixed — suffixed files don't exist; the suffix is purely a
--     namespace for the atoms.
--
--   * /Suffix mangling/ ('mangleProgram'): the module's effective
--     suffix (ambient suffix of the importing module, if any, plus
--     the written one) is appended to every atom mentioned in its
--     source: bag block names, atom patterns and expressions, @lob@
--     targets, @bytesBind@ handles. No exemptions — not @Error@ (the
--     runtime routes a module's @error@ verb to the mangled Error bag
--     instead, see "Lindana.Machine"), and not @Global@ (a module
--     therefore cannot name the real front door; it replies into
--     whatever bag its caller passes as /data/ — the §4 continuation
--     philosophy: the caller shapes what happens next). Casual-string
--     and say-format literals are data, not atoms, and are /not/
--     mangled — an @atomize \"Foo\"@ inside a module names @Foo@, not
--     @Foo ++ suffix@ (documented hazard). One deliberate exemption:
--     the hide-list expression of a nested @import@ is left alone —
--     it names the /target/ module's pre-mangle API.
--
--   * /Hide lists/ ('hideBags'): atoms naming module bags whose
--     machines are skipped (pre-mangle names — or the same with the
--     suffix appended, so a module importing a module can hide
--     either way). Only machines are hidden; the bags' initial
--     tuples still load, and @lob@ from outside can still create the
--     bag as a machineless accumulator (§6.2).
--
--   * /Recursion:/ the module's own @import@s get the ambient suffix
--     propagated through 'Lindana.Def.MachineDef''s @machSfx@ — the
--     effective suffix of a nested import is ambient ++ written, and
--     everything it loads is mangled with that.
--
--   * /Singletons/ (in "Lindana.Machine", which owns the registry):
--     a module is loaded at most once per @(name, effective suffix)@
--     pair; repeat imports skip the load but still emit the
--     @(Imported, H, suffix)@ completion tuple into @Global@. This
--     also makes self- and mutual-import cycles terminate. Hazard:
--     first import wins — a hide list on a later repeat import of an
--     already-loaded pair has no effect.
module Lindana.Import
  ( -- * Loading a module's source
    parseModuleFile
  , lowerModule
    -- * The mangling pass (exported for tests)
  , mangleProgram
  , hideBags
  ) where

import Control.Exception (IOException, try)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Text.IO as TIO
import System.IO.Error (isDoesNotExistError)

import Text.Megaparsec.Error (errorBundlePretty)

import Lindana.Def (MachineDef (..), errorBag)
import Lindana.Loader (loadProgramWith, loadedInitial, loadedMachines)
import Lindana.Parser (parseProgram)
import Lindana.Syntax

--------------------------------------------------------------------------------
-- Finding and parsing the source
--------------------------------------------------------------------------------

-- | Read and parse @<dir>/<name>.lind@. A missing file is a normal
-- 'Left' (the effect runner turns it into a fatal, runner-safe
-- @panic@); other IO errors propagate.
parseModuleFile :: FilePath -> String -> IO (Either String Program)
parseModuleFile dir name = do
  let path = dir ++ "/" ++ name ++ ".lind"
  r <- try (TIO.readFile path)
  case r of
    Left e
      | isDoesNotExistError e ->
          pure (Left ("no module file: " ++ path))
      | otherwise -> pure (Left (show (e :: IOException)))
    Right src -> pure $ case parseProgram src of
      Left err -> Left ("parse error in " ++ path ++ ":\n"
                        ++ errorBundlePretty err)
      Right p  -> Right p

--------------------------------------------------------------------------------
-- Hide lists
--------------------------------------------------------------------------------

-- | Drop the machines declared on hidden bags (issue #17: "accept a
-- list of atoms to hide: import none of the machines on that bag").
-- Hidden names are matched against the module's /pre-mangle/ bag
-- names — or the same with the suffix appended, so a module importing
-- a module can hide either way. Only machines are dropped: initial
-- tuples still load, and @lob@ from outside can still create the bag
-- as a machineless accumulator (§6.2).
hideBags :: [Name] -> String -> Program -> Program
hideBags hidden sfx (Program ds) = Program (map go ds)
  where
    hiddenSet = Map.fromList [ (n, ()) | n <- hidden ++ map (++ sfx) hidden ]
    go (Bag n inner)
      | Map.member n hiddenSet = Bag n (filter keep inner)
      | otherwise              = Bag n inner
    go d = d
    keep Machine{} = False
    keep _         = True

--------------------------------------------------------------------------------
-- Suffix mangling
--------------------------------------------------------------------------------

-- | Append the effective namespace suffix to every atom mentioned in
-- the module's source (see the module header for what counts and what
-- is deliberately exempt). The suffix is raw concatenation: the
-- caller writes the separator they want (@\"_v2\"@, not @\"v2\"@).
mangleProgram :: String -> Program -> Program
mangleProgram sfx (Program ds) = Program (map (mangleDecl sfx) ds)

mangleDecl :: String -> Decl -> Decl
mangleDecl sfx (Bag n inner) = Bag (n ++ sfx) (map mangleDecl' inner)
  where
    mangleDecl' (Machine lhs body) =
      Machine (map (manglePatElem sfx) lhs) (map (mangleAction sfx) body)
    -- An initial block's atoms are data in the module's own bags:
    -- mangled like any other mention.
    mangleDecl' (Initial es) = Initial (map (mangleExpr sfx) es)
    mangleDecl' d            = d
mangleDecl sfx (Machine lhs body) =
  Machine (map (manglePatElem sfx) lhs) (map (mangleAction sfx) body)
mangleDecl _ d = d

manglePatElem :: String -> PatElem -> PatElem
manglePatElem sfx (PatElem m p) = PatElem m (manglePat sfx p)

manglePat :: String -> Pat -> Pat
manglePat sfx p = case p of
  PAtom n    -> PAtom (n ++ sfx)
  PTuple ps  -> PTuple (map (manglePat sfx) ps)
  PVar _     -> p
  PRest _    -> p
  PInt _     -> p
  PDouble _  -> p

mangleAction :: String -> Action -> Action
mangleAction sfx a = case a of
  -- The target expression: an atom mention of the module's own bag
  -- mangles; a variable (bag name as data) must not.
  Lob n e        -> Lob (mangleExpr sfx n) (mangleExpr sfx e)
  BytesBind h e  -> BytesBind (h ++ sfx) (mangleExpr sfx e)
  -- The hide list names the target module's pre-mangle API: exempt
  -- (module header). The name/suffix handles are this module's own
  -- atoms: mangled, consistent with its own bytesBind of them.
  Import h s hide -> Import (mangleExpr sfx h) (mangleExpr sfx s) hide
  -- §13.14: both reroute arguments are atom mentions of bags — mangled
  -- like any other mention. A module can therefore only reroute its
  -- OWN bags (its written `Error` mangles to the module's mangled
  -- Error bag — rerouting "all bags in this module" to one of its own
  -- bags); it cannot name the real top-level Error, consistent with
  -- the no-Global-exemption story (module header).
  Reroute src tgt -> Reroute (mangleExpr sfx src) (mangleExpr sfx tgt)
  Say f es       -> Say f (map (mangleExpr sfx) es)   -- format is data
  Out e          -> Out (mangleExpr sfx e)
  Exit e         -> Exit (mangleExpr sfx e)
  Sleep e        -> Sleep (mangleExpr sfx e)
  Panic e        -> Panic (mangleExpr sfx e)
  Raise e        -> Raise (mangleExpr sfx e)
  -- error's target bag is routed at runtime (errorBag ++ machSfx):
  -- no AST rewrite needed.
  BytesDestroy e -> BytesDestroy (mangleExpr sfx e)
  Die            -> a
  If c t e       -> If (mangleExpr sfx c)
                       (map (mangleAction sfx) t)
                       (map (mangleAction sfx) e)

mangleExpr :: String -> Expr -> Expr
mangleExpr sfx e = case e of
  -- Nil is exempt: it is the cons-list spine sentinel (§11.5/§9 —
  -- string and list literals end in it), not an ordinary mention.
  -- Mangling it would corrupt every literal in the module. Hazard:
  -- a module using Nil as ordinary data keeps it unsuffixed too.
  EAtom "Nil" -> e
  EAtom n     -> EAtom (n ++ sfx)
  ETuple es   -> ETuple (map mangleElem es)
  ESplice x   -> ESplice (mangleExpr sfx x)
  ECall n es  -> ECall n (map (mangleExpr sfx) es)  -- builtin names aren't atoms
  EBin o a b  -> EBin o (mangleExpr sfx a) (mangleExpr sfx b)
  ENeg x      -> ENeg (mangleExpr sfx x)
  EVar _      -> e
  EInt _      -> e
  EDouble _   -> e
  where
    mangleElem (ESplice x) = ESplice (mangleExpr sfx x)
    mangleElem x           = mangleExpr sfx x

--------------------------------------------------------------------------------
-- Lowering
--------------------------------------------------------------------------------

-- | Hide, mangle, and lower a module: bag-tagged machines (with
-- @machSfx@ set to the effective suffix — the loader leaves it empty)
-- and per-bag initial tuples with mangled bag names. The §6.4
-- default Error machine, when the module declares no Error bag, is
-- installed on the /mangled/ Error bag — where the runtime routes the
-- module's @error@ calls ("Lindana.Machine").
lowerModule :: [Name] -> String -> Program
            -> Either String ([MachineDef], Map Name [Expr])
lowerModule hidden sfx prog =
  case loadProgramWith (errorBag ++ sfx)
                       (mangleProgram sfx (hideBags hidden sfx prog)) of
    Left err  -> Left err
    Right low -> pure
      ( [ m { machSfx = sfx } | m <- loadedMachines low ]
      , loadedInitial low
      )
