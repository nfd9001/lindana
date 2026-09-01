-- | The program loader (handover §13.5 step 4): lowers a parsed
-- 'Program' into the runtime's shape — bag-tagged 'MachineDef's and
-- per-bag initial tuples — ready for "Lindana.Machine"''s
-- @runLoaded@.
--
-- Bag scoping (§6): bare top-level machines belong to the implicit
-- @Global@ bag; machines declared inside @Name { … }@ match that bag.
-- A given bag's machines can only be declared in one place (§6's
-- single-declaration-site rule), so the loader rejects duplicate bag
-- blocks — and also rejects bare top-level machines in a program that
-- declares an explicit @Global@ block ("pick one style, don't mix").
--
-- The §11.10 top-level grammar question is provisionally resolved
-- here (a design decision to be ratified like any other, per the
-- house style):
--
--   * A @{ … }@ initial-tuple block belongs to its nearest enclosing
--     bag — at top level that is @Global@ (the "front door" initial
--     state), inside @Name { … }@ it is @Name@'s initial state.
--   * At most one initial block per bag.
--   * Nothing else nests: a bag block may not contain another bag
--     block (bags are flat, §6; sharding is an internal concern,
--     §6.3).
--
-- The §6.4 default @Error@ machine is installed here: if the program
-- declares no @Error@ bag at all, @(c!) : panic c@ is appended —
-- @c@ captures the whole @(Error, …)@ tuple (§11.1 rest capture) and
-- @panic@ makes it fatal. A user-declared @Error { … }@ block, even
-- an empty one ("silently swallow all errors"), fully replaces the
-- default — it is never installed alongside a user block.
module Lindana.Loader
  ( -- * Loading
    Loaded (..)
  , loadProgram
  , loadProgramWith
  ) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)

import Lindana.Def (MachineDef (..), globalBag, errorBag)
import Lindana.Syntax

-- | A lowered program: bag-tagged machine definitions and per-bag
-- initial tuples (evaluated, with builtins available, by the RTS at
-- startup).
data Loaded = Loaded
  { loadedMachines :: [MachineDef]     -- ^ includes the §6.4 default
                                       --   @Error@ machine when installed
  , loadedInitial  :: Map Name [Expr]  -- ^ initial tuples per bag name
  } deriving (Eq, Show)

-- | Lower a 'Program', or fail with a human-readable load error.
-- The §6.4 default @Error@ machine is installed on the plain @Error@
-- bag — the top-level entry point.
loadProgram :: Program -> Either String Loaded
loadProgram = loadProgramWith errorBag

-- | 'loadProgram' with the §6.4 default Error machine's bag name as a
-- parameter: modules imported at runtime (issue #17, §13.13) mangle
-- every atom in their source with a namespace suffix, and their
-- @error@ verb routes to the mangled Error bag — so when the module
-- declares no Error bag of its own, the default @panic@ machine goes
-- there too. The mangling itself happens before lowering (see
-- "Lindana.Import"); this only decides where the default machine
-- matches.
loadProgramWith :: Name -> Program -> Either String Loaded
loadProgramWith errBag (Program ds) = do
  -- Top level: bag blocks, at most one initial block (Global's), and
  -- (maybe) bare machines for the implicit Global bag.
  (topInit, topMachs, bagBlocks) <- walkTop ds Nothing [] []
  let bagNames = map fst bagBlocks
  -- §6: single declaration site per bag name.
  case duplicates bagNames of
    (b : _) -> Left ("bag " ++ show b ++ " declared in more than one place"
                     ++ " (single declaration site per bag, §6)")
    [] -> pure ()
  -- §6: bare top-level machines and an explicit Global block are two
  -- styles for the same thing — pick one, don't mix.
  case (not (null topMachs), globalBag `elem` bagNames) of
    (True, True) -> Left
      ("bare top-level machines cannot be mixed with an explicit "
       ++ globalBag ++ " block (§6: pick one style)")
    _ -> pure ()
  -- Machines and initial tuples per bag, flattening the blocks.
  (bagMachs, bagInits) <- foldMapBags bagBlocks
  let allMachs = map (machine globalBag) topMachs ++ bagMachs
      defaultError
        -- §6.4: the default Error machine exists only when the program
        -- declares no Error bag of its own — a user block, even empty,
        -- fully replaces it; the default never coexists with one.
        -- @errBag@ is the plain Error bag at top level, the mangled
        -- @Error ++ suffix@ for an imported module (§13.13).
        | errBag `elem` bagNames = []
        | otherwise              = [defaultErrorMachine errBag]
      initialMap = Map.fromList [ (n, es) | (n, Just es) <- globalInit : bagInits ]
      globalInit = (globalBag, topInit)
  pure Loaded
    { loadedMachines = allMachs ++ defaultError
    , loadedInitial  = initialMap
    }

-- | The §6.4 default Error machine: @(c!) : panic c@, installed on
-- the given bag name (plain @Error@ at top level, the mangled
-- @Error ++ suffix@ for an imported module, §13.13). The rest
-- capture (§11.1) matches any tuple — which is all the Error bag
-- ever accumulates — and binds the whole thing to @c@ for @panic@.
defaultErrorMachine :: Name -> MachineDef
defaultErrorMachine bag = MachineDef
  { machBag  = bag
  , machSfx  = ""      -- the default machine speaks for the module itself;
                       -- the error routing that matters is its BAG name
  , machJoin = [PatElem Take (PTuple [PRest "c"])]
  , machBody = [Panic (EVar "c")]
  }

-- | Tag a machine with its bag (ambient suffix empty — top-level and
-- pre-import lowering; "Lindana.Import.lowerModule" sets @machSfx@
-- for loaded modules).
machine :: Name -> Decl -> MachineDef
machine bag (Machine lhs body) =
  MachineDef bag "" lhs body
machine _ d = error ("loader invariant: non-machine reached machine(): " ++ show d)

-- | Walk the top-level declarations.
walkTop :: [Decl]
        -> Maybe [Expr]                  -- ^ accumulated top-level initial block
        -> [Decl]                        -- ^ accumulated bare machines
        -> [(Name, [Decl])]              -- ^ accumulated bag blocks
        -> Either String (Maybe [Expr], [Decl], [(Name, [Decl])])
walkTop [] i m b = Right (i, reverse m, reverse b)
walkTop (d : ds) i m b = case d of
  Initial es | Just _ <- i -> Left "more than one top-level { … } initial block"
             | otherwise   -> walkTop ds (Just es) m b
  Machine{} -> walkTop ds i (d : m) b
  Bag n inner -> do
    inner' <- walkBag inner
    walkTop ds i m ((n, inner') : b)

-- | Walk the inside of one bag block: machines and (at most one)
-- initial block for that bag. Nested bag blocks are rejected (§6:
-- bags are flat; §6.3's sharding is internal, not a user construct).
walkBag :: [Decl] -> Either String [Decl]
walkBag = go []
  where
    go acc [] = Right (reverse acc)
    go _ (Bag _ _ : _) = Left
      "nested bag block: bags are flat — declare bags at top level (§6)"
    go acc (d : ds) = go (d : acc) ds

-- | Flatten the bag blocks into bag-tagged machines and per-bag
-- initial tuples (at most one initial block per bag, enforced here).
foldMapBags :: [(Name, [Decl])]
            -> Either String ([MachineDef], [(Name, Maybe [Expr])])
foldMapBags blocks = go blocks [] []
  where
    go [] ms is = Right (reverse ms, reverse is)
    go ((n, inner) : rest) ms is = do
      (ms', mi) <- foldInner n inner [] Nothing
      case (mi, lookup n is) of
        (Just _, Just _) -> Left
          ("bag " ++ show n ++ " has more than one { … } initial block")
        _ -> go rest (reverse ms' ++ ms) ((n, mi) : is)
    foldInner _ [] ms mi = Right (reverse ms, mi)
    foldInner _ (Initial _ : _) _ Just{} = Left
      "bag has more than one { … } initial block"
    foldInner n (Initial es : ds) ms _ = foldInner n ds ms (Just es)
    foldInner n (Machine lhs body : ds) ms mi =
      foldInner n ds (machine n (Machine lhs body) : ms) mi
    foldInner _ (d : _) _ _ = Left
      ("loader invariant: unexpected declaration inside bag block: " ++ show d)

-- | First repeated element, if any.
duplicates :: Eq a => [a] -> [a]
duplicates xs = [x | (i, x) <- zip [0 :: Int ..] xs, x `elem` take i xs]
