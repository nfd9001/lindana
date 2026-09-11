-- | The Lindana Prelude (issue #17 part 3, handover §13.15): a
-- /builtin module/ — source embedded in the RTS, loaded through the
-- ordinary §13.13 import machinery. Imported by default in the
-- top-level file (the loader prepends a synthetic one-shot
-- @: import Prelude Nil []@ — see "Lindana.Loader"), prefixless: the
-- empty suffix means every atom here is spelled exactly as written
-- and its machines run on the plain @Global@ bag, indistinguishable
-- from the program's own.
--
-- Opt-out is the @{-# no-prelude #-}@ pragma (top level only); after
-- opting out, an explicit @import Prelude Nil […]@ brings it back
-- with whatever hide list you want. Without the pragma an explicit
-- import is a harmless singleton repeat (first import wins — the
-- default import got there first; documented hazard, per the
-- messageboard note).
--
-- Provisional decisions made here (flip-worthy, per the house style):
--
--   * /One-shot preregistration machines only./ A looping service
--     machine in the default import would keep /every/ program alive
--     forever (the §1 loop keeping the run alive is the spec, §1) —
--     so the default Prelude contains only §1 empty-pattern one-shots
--     that bind statics and die. Looping stdlib services belong in
--     opt-in modules (the issue's basic-stdlib ambition continues
--     there, and in issue #18's file descriptors).
--
--   * /One bag per static/, so the import's hide list can pick them
--     off individually ('Lindana.Import.hideBags' hides bag blocks'
--     machines, pre-mangle names).
--
--   * @Error { }@ is declared deliberately: the prelude's own
--     lowering then installs no §6.4 default Error machine, and the
--     /top-level/ program's own default (or user Error block) alone
--     owns the plain Error bag. Without this, every program would
--     carry two racing @(c!) : panic c@ machines on Error (§3.1).
--
--   * /The builtin registry shadows disk/: a user file named
--     @Prelude.lind@ next to the program is shadowed — the Prelude is
--     RTS-owned, its name effectively reserved. (Flip: consult disk
--     first.)
--
--   * /Builtins are not injectable/ (a plain constant here, not a
--     @Hooks@ field — flipping this later would touch every Hooks
--     record literal in the tests). Tests exercise the mechanism via
--     the pragma and hide lists instead.
--
--   * The @Nil → \"\"@ preregistration (§13.13) deliberately stays in
--     the RTS ('rtsBytes' in "Lindana.Machine"), /not/ here: the
--     empty-suffix spelling must work for programs that pragma the
--     prelude away. The prelude's name handle is seeded the same way
--     (@Prelude → "Prelude"@ — @bytesBind Prelude "Prelude"@ is the
--     manual spelling of the default import's first half); neither
--     entry is special: both are clobberable and destroyable like any
--     side-table entry.
module Lindana.Prelude
  ( -- * The Prelude module
    preludeName
  , preludeSource
    -- * The builtin module registry
  , builtinModules
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

import Lindana.Syntax (Name)

-- | The prelude's module name — also the bytestring handle the
-- default-import machine uses (@bytesBind Prelude "Prelude"@ being
-- the manual spelling; the contents equal the name, so @(Imported,
-- Prelude, …)@ reads plainly). Deliberately collidable, like every
-- atom (§4).
preludeName :: Name
preludeName = "Prelude"

-- | The prelude's source, parsed fresh by each import (the §13.13
-- import machinery does the hiding, mangling, and lowering — the
-- effective suffix of the default import is empty, so nothing mangles).
--
-- @Version@ is kept in sync with @lindana.cabal@'s @version:@ by hand.
preludeSource :: String
preludeSource = unlines
  [ "-- Lindana Prelude (§13.15, issue #17 part 3): imported by default"
  , "-- in the top-level file, prefixless. One-shot preregistration"
  , "-- machines only (a looping service would keep every program"
  , "-- alive forever — services live in opt-in modules). One bag per"
  , "-- static, so an import hide list can pick them off individually."
  , "Error { }"
  , ""
  , "Newline { : bytesBind Newline \"\\n\" }"
  , "Version { : bytesBind Version \"0.1.0.0\" }"
  ]

-- | Modules the RTS ships inside itself, consulted by the @import@
-- effect before disk (builtins shadow user files — module header).
-- Currently just the prelude; stdlib services added later land here
-- (or as ordinary @.lind@ files — the Accursed question of which is
-- left open on purpose).
builtinModules :: Map Name Text
builtinModules = Map.singleton preludeName (T.pack preludeSource)
