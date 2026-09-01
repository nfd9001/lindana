-- | Shared definitions of the lowered program shape: 'MachineDef' and
-- the two reserved bag names. This module exists so that both the
-- loader ("Lindana.Loader") and the machine/effect layer
-- ("Lindana.Machine", which also re-exports it) can speak of machines
-- and bags without a dependency cycle — the import machinery
-- ("Lindana.Import", used by the effect runner to load modules at
-- runtime, issue #17 §13.13) sits between them: Def ← Loader ←
-- Import ← Machine.
module Lindana.Def
  ( MachineDef (..)
  , globalBag
  , errorBag
  ) where

import Lindana.Syntax

-- | A machine definition: the bag it matches in (§6), its join
-- pattern (left) and action list (right). The @Def@ suffix
-- disambiguates from Syntax's @Machine@ Decl constructor.
--
-- 'machSfx' is the machine's ambient namespace suffix (§13.13): the
-- effective suffix of the module it was loaded from (@\"\"@ for
-- top-level machines). Two uses, both the runtime equivalent of
-- suffix-mangling an atom in the machine's source: the @error@ verb
-- routes to @'errorBag' ++ machSfx@ (so a module's errors land in its
-- own mangled Error bag), and an @import@ performed by this machine
-- propagates the ambient suffix to everything it loads.
data MachineDef = MachineDef
  { machBag  :: Name        -- ^ bag whose block the machine was declared in
  , machSfx  :: String      -- ^ ambient namespace suffix (§13.13; @\"\"@ at top level)
  , machJoin :: [PatElem]
  , machBody :: [Action]
  } deriving (Eq, Show)

-- | The name of the implicit bag bare top-level machines belong to
-- (§6). @Global@ effectively acts as the program's front door.
globalBag :: Name
globalBag = "Global"

-- | The name of the error bag (§6.4). An imported module's @error@
-- calls route to @errorBag ++ machSfx@ instead (§13.13) — the runtime
-- equivalent of suffix-mangling the @Error@ atom in its source.
errorBag :: Name
errorBag = "Error"
