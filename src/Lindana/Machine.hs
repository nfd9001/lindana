-- | The machine loop / scheduler (§1, §2) and the action layer +
-- effect-runner (§3.3, §7.2) — handover §13.3 steps 1 and 2.
--
-- The shape of the runtime:
--
--   * One thread per machine, spawned by 'runProgram'. Machines loop
--     by default: match → interpret → re-arm. @die@ (or a terminal
--     @exit@\/@panic@) ends the thread. Empty-pattern machines (§1)
--     run once at start and terminate. The §5 @AContN@
--     cross-invocation chaos needs no code — it simply falls out of
--     this loop re-arming.
--
--   * Two-phase interpreter (§8.2's note, made structural): the
--     transaction is "read the join patterns, decide, write
--     replacement tuples". Tuple-space verbs (@out@, @lob@, and
--     @error@'s Error-tuple write) execute inside that transaction,
--     atomically with the match and each other. Every irrevocable
--     verb (@say@, @sleep@, @exit@, @panic@, @bytesBind@,
--     @bytesDestroy@, @bytesNew@) comes back as a deferred /bundle/ of effects,
--     pushed post-commit.
--
--   * The 'effectRunner' is a single thread draining bundles FIFO
--     from a 'TQueue', one bundle live at a time — sequencing and
--     synchronization from ordinary primitives, per §7.2, with no
--     rollback on partial failure. Provisionally one /global/ runner
--     (§7.3 still open). Bytestring side-table work (§9) routes
--     through it too (§11.8, provisionally resolved): a bind writes
--     'rtsBytes' and emits the @(Bytes, H)@ completion tuple into
--     @Global@; a destroy just drops the entry; @bytesNew@ (issue #18
--     part 3) picks a fresh handle in-transaction ('freshBytesSTM')
--     and lands as the very same bind effect.
--
--   * Module import (issue #17, §13.13): the @import@ effect loads a
--     module file at runtime (via "Lindana.Import"), suffix-mangles
--     its atoms, and spawns its machines /while the program runs/ —
--     the RTS gains a loaded-modules registry (singleton per
--     @(name, effective suffix)@) and a list of dynamically spawned
--     machine threads, cancelled at shutdown like the startup ones.
--     A module's machines carry 'Lindana.Def.MachineDef''s @machSfx@
--     (the ambient namespace suffix): the @error@ verb routes to
--     @Error ++ machSfx@ — the runtime equivalent of suffix-mangling
--     that atom — and a nested @import@ propagates the ambient
--     suffix. Import failure (missing file, parse/load error, bad
--     handle) is a runner-safe fatal: the message goes to the panic
--     hook and the program exits 1 — the runner thread does NOT die
--     silently the way it does on a @say@ format error (§13.12's
--     debugging tale).
--
--   * Error rerouting (issue #17, §13.14): @reroute Src Tgt@ writes
--     into 'rtsReroute', and the @error@ verb consults the table —
--     errors raised by machines declared in bag @Src@ land in @Tgt@
--     instead of the Error bag. A module-wide reroute is spelled by
--     naming the module's mangled Error bag (@Error ++ suffix@), which
--     stands for "all bags in the module" (all of a module's machines'
--     errors land there before any reroute, so rerouting that name
--     catches them all). Bag-specific keys take precedence over
--     module-wide keys. The table is global — any machine can reroute
--     any other bag's error stream, which is exactly as Accursed as it
--     sounds (documented hazard, not guarded; §12).
--
--   * The Prelude (issue #17 part 3, §13.15): the RTS ships a
--     /builtin module/ ("Lindana.Prelude") imported by default in the
--     top-level file — the loader prepends a synthetic one-shot
--     @: import Prelude Nil []@ ('Lindana.Loader.preludeImportMachine'),
--     and this module's @importOnce@ resolves the name from the
--     builtin registry (shadowing disk) before @hookModDir@. The
--     prelude's name handle @Prelude@ is seeded in 'rtsBytes' next to
--     @Nil → ""@; neither entry is special. One-shot preregistration
--     machines only — a looping service in the default import would
--     keep every program alive forever.
--
--   * Idle-exempt machines (§11.12, branch `runtime/idle-shutdown`):
--     the §6.4 default Error machine has @machIdle = True@ — it is
--     not counted in 'rtsLive' and does not keep the run alive, so a
--     program whose user machines all @die@ ends cleanly even though
--     the default machine is still parked. The run-alive check waits
--     for idle bags to drain first, so a final error tuple still
--     gets its guaranteed panic. Why: the parked default machine
--     otherwise false-deadlocks every all-die program (the §1
--     shutdown story told machines to end in @die@, and the most
--     natural shape for that had no Error block and no @exit@).
--
-- §11.6 (effect-bundle grammar) is provisionally resolved here as a
-- decision note rather than syntax: the bundle /is/ a machine
-- reaction's post-commit action list — the 'Effect' list this
-- interpreter returns and the runner drains. There is no concrete
-- syntax to write, and none is wanted: bundles are a runtime concept,
-- not a user construct (the user already writes the action list; the
-- transaction/deferred split is the implementation of §7.2/§8.2).
--
-- Provisional decisions made here (flip-worthy, per the house style):
--
--   * @exit@ terminates the /whole program/ with the evaluated code
--     (both §10 usages read that way); @die@ terminates only the
--     machine.
--   * Truthiness (§9, open §11): falsy = @VInt 0@, @VDouble 0.0@,
--     @VAtom \"False\"@; everything else (including @()@) truthy.
--   * @error e@ is @lob Error (…)@ proper (§6.4): the @(Error, …)@
--     tuple lands in the named @Error@ bag. When the program declares
--     no @Error@ bag of its own, the loader installs the §6.4 default
--     machine @(c!) : panic c@; a user-declared @Error { … }@ block —
--     even an empty one, "silently swallow all errors" — fully
--     replaces it. See "Lindana.Loader".
--   * Named bags (§6): machines match the bag whose block they are
--     declared in (@"Global"@ for bare top-level machines); @out@
--     emits into the machine's /own/ bag; @lob@ is the only cross-bag
--     send (§6.1). A bag name not seen before is created on demand —
--     since a machineless accumulator and a live bag are the same
--     structure here (one 'TVar'), the §6.2 drain-on-first-machine
--     handoff is free: tuples accumulated before the bag had machines
--     are simply already in the 'TVar' its machines match against,
--     and no tuple can be lost or double-delivered.
--   * @rand@'s seed defaults to a fixed constant ('defaultHooks'
--     carries @mkStdGen 12345@): runs are deterministic by default —
--     reproducible chaos. The seed is now plumbing ('Hooks.hookSeed',
--     issue #41): the CLI's @--seed N|--seed random@ and the fuzzing
--     suite drive it; an entropy default is the flip-worthy alternative
--     (§11).
--   * Shutdown is abrupt: once every machine is done or the program
--     has exited, remaining threads are cancelled. A machine
--     committing concurrently with shutdown may or may not land its
--     final write — accepted for now.
module Lindana.Machine
  ( -- * The RTS
    RTS (..)
  , Hooks (..)
  , defaultHooks
  , newRTS
  , newRTSWith
  , globalBag
  , errorBag
  , bagForSTM
    -- * Machines
  , MachineDef (..)
  , Bundle (..)
  , Effect (..)
    -- * The interpreter (action layer)
  , interpretActions
  , evalR
  , rtsBuiltin
  , sayTargetSTM
    -- * Effect formatting
  , formatSay
  , renderVal
    -- * Running programs
  , RunResult (..)
  , runProgram
  , runProgramWith
  , runLoaded
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception (finally, try)
import Control.Exception (SomeException)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.Char (chr, ord)
import Data.List (intercalate)
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import System.Random (StdGen, mkStdGen, uniformR)
import System.Exit (ExitCode (..))
import System.IO (Handle, IOMode (ReadMode, WriteMode), hClose, hFlush,
                  hSetBinaryMode, hPutStrLn, openFile, stderr, stdin, stdout,
                  stderr)
import System.IO.Error (isEOFError)
import qualified Data.ByteString as BS

import Lindana.Def (MachineDef (..), globalBag, errorBag)
import Lindana.Import (lowerModule, parseModuleFile, parseModuleSource)
import Lindana.Prelude (builtinModules, preludeName)
import Lindana.Runtime
import Lindana.Syntax

--------------------------------------------------------------------------------
-- The RTS
--------------------------------------------------------------------------------

-- | The runtime system: @Global@'s matchable bag, the effect queue,
-- the @rand@ seed, the live-machine count, the program exit status,
-- the named bags (§6) — machineless @lob@ accumulators and bags
-- with machines alike; they are the same structure — the §9
-- bytestring side-table, and the §13.13 module-import state.
data RTS = RTS
  { rtsBag   :: RBag                  -- ^ @Global@'s bag
  , rtsQueue :: TQueue Bundle
  , rtsSeed  :: TVar StdGen           -- ^ @rand@'s state (§8): splitmix
                                      -- via System.Random; pure + seed from
                                      -- 'Hooks.hookSeed' (fixed by default),
                                      -- so evaluable in STM and runs stay
                                      -- deterministic
  , rtsLive  :: TVar Int              -- ^ live machine threads, plus one
                                      -- slot per pending (queued but not
                                      -- yet run) @import@ effect — the
                                      -- pending slot is what keeps the
                                      -- run-alive check from firing while
                                      -- an import bundle is still queued
                                      -- (§13.13). Idle-exempt machines
                                      -- (machIdle, §11.12 — the default
                                      -- Error machine) are not counted:
                                      -- they never terminate, and must
                                      -- not keep the run alive.
  , rtsExit  :: TVar (Maybe ExitCode)
  , rtsStop  :: TVar Bool             -- ^ graceful effect-runner shutdown
  , rtsBags  :: TVar (Map Name RBag)  -- ^ named bags other than @Global@
                                      --   (§6): machineless accumulators
                                      --   and live bags alike
  , rtsBytes :: TVar (Map Name ByteString)  -- ^ §9 bytestring side-table:
                                      --   opaque atom handle → UTF-8
                                      --   bytes. To the matcher a handle
                                      --   is just an ordinary atom; only
                                      --   the @bytes*@ verbs reach in.
                                      --   Preregistered: @Nil → ""@ —
                                      --   the free empty import suffix
                                      --   (§13.13); not special, may be
                                      --   clobbered or destroyed like
                                      --   any handle.
  , rtsMods  :: TVar (Map (Name, String) ())  -- ^ §13.13 module registry:
                                      --   (search name, effective suffix)
                                      --   pairs already loaded — modules
                                      --   are singletons; also what makes
                                      --   import cycles terminate
  , rtsExtra :: TVar [Async ()]       -- ^ §13.13 machine threads spawned
                                      --   by @import@ mid-run, cancelled
                                      --   at shutdown like the startup ones
  , rtsReroute :: TVar (Map Name Name)  -- ^ §13.14 error-reroute table:
                                      --   source bag name (or a module's
                                      --   mangled Error bag, standing for
                                      --   "all bags in the module") →
                                      --   target bag name. Written by
                                      --   @reroute Src Tgt@ (last update
                                      --   wins: plain 'Map.insert'), read
                                      --   by the @error@ verb's routing.
  , rtsSayFd :: TVar (Map Name Name)  -- ^ §13.18 say-FD route table (the
                                      --   §13.14 sister): bag name → fd
                                      --   handle that bag's @say@s go
                                      --   through (bag key first, then the
                                      --   module's mangled Error bag, then
                                      --   default @Stdout@). Written by
                                      --   @sayfd Bag Fd@, read by the
                                      --   @say@ verb's routing.
  , rtsFds :: TVar (Map Name FdState) -- ^ §13.17 fd table (issue #18):
                                      --   opaque atom handle → open OS
                                      --   handle + mode. To the matcher a
                                      --   handle is just an ordinary atom;
                                      --   only the @f*@ verbs (and now
                                      --   @say@) reach in. Preregistered
                                      --   at start (§13.18): @Stdin@
                                      --   (read, line mode), @Stdout@ and
                                      --   @Stderr@ (write) — ordinary
                                      --   entries, nothing special: last
                                      --   @fopen@ on a name wins, closing
                                      --   the superseded OS handle first
                                      --   (a silent leak would keep the
                                      --   file locked and un-reopenable;
                                      --   flip-worthy), and @fclose
                                      --   Stdout@ makes every later @say@
                                      --   a fatal, honestly.
  , rtsFresh :: TVar Int              -- ^ fresh-name counter (§9, issue
                                      --   #18 part 3): @bytesNew@'s
                                      --   runtime-generated handles count
                                      --   flatly up from 0 (@Bytes0@,
                                      --   @Bytes1@, … — the @ACont@
                                      --   precedent), skipping any name
                                      --   already in 'rtsBytes'. A plain
                                      --   counter, not @rand@: determinism
                                      --   (runs are reproducible) and no
                                      --   burning the shared seed.
  , rtsHooks :: Hooks
  }

-- | Injectable effect environment. With @say@ un-magicked (§13.18)
-- there is no @say@ callback any more: output goes through the fd
-- table, so what tests inject are the /std Handles/ the std fds are
-- preregistered with — point @hookStdout@ at a scratch file to
-- capture a program's @say@ stream. @panic@ is still a callback: it
-- is fatal, never routed, and stays hook-based (§13.14).
data Hooks = Hooks
  { hookStdin  :: Handle           -- ^ default: 'stdin' — the @Stdin@
                                   --   fd's OS handle (@fread@ blocks
                                   --   for a line)
  , hookStdout :: Handle           -- ^ default: 'stdout' — the @Stdout@
                                   --   fd's OS handle (and @say@'s target)
  , hookStderr :: Handle           -- ^ default: 'stderr' — the @Stderr@
                                   --   fd's OS handle
  , hookPanic  :: String -> IO ()  -- ^ default: stderr, @"panic: "@-prefixed
  , hookModDir :: FilePath         -- ^ directory @import@ searches for
                                   --   @<name>.lind@ module files
                                   --   (§13.13); default: @"."@. The
                                   --   CLI sets it to the main file's
                                   --   directory. Provisional home for
                                   --   this knob (flip-worthy).
  , hookSeed  :: StdGen            -- ^ @rand@'s initial seed (§8, issue
                                   --   #41): default the historical fixed
                                   --   constant @mkStdGen 12345@ — runs
                                   --   stay reproducible out of the box.
                                   --   The CLI's @--seed N|--seed random@
                                   --   and the fuzzing suite override;
                                   --   an entropy default is the
                                   --   flip-worthy alternative (§11).
                                   --   Provisional home for this knob
                                   --   (same precedent as 'hookModDir').
  }

defaultHooks :: Hooks
defaultHooks = Hooks
  { hookStdin  = stdin
  , hookStdout = stdout
  , hookStderr = stderr
  , hookPanic  = hPutStrLn stderr . ("panic: " ++)
  , hookModDir = "."
  , hookSeed   = mkStdGen 12345
  }

-- | §13.18: the std fd-table names. Ordinary atoms — @fopen@ can
-- shadow them (last wins), @fclose@ can drop them, @say@ fatals
-- honestly when its routed fd is gone.
stdFdIn, stdFdOut, stdFdErr :: Name
stdFdIn  = "Stdin"
stdFdOut = "Stdout"
stdFdErr = "Stderr"

-- | A fresh RTS (seed from 'Hooks.hookSeed' — the historical fixed
-- constant by default: deterministic runs; the std fds preregistered
-- binary — @say@ and @fwrite@ write UTF-8\/raw bytes).
newRTS :: IO RTS
newRTS = newRTSWith defaultHooks

newRTSWith :: Hooks -> IO RTS
newRTSWith hooks = do
  let hin  = hookStdin hooks
      hout = hookStdout hooks
      herr = hookStderr hooks
  mapM_ (\x -> hSetBinaryMode x True) [hin, hout, herr]
  atomically $ do
    bag   <- newBagSTM
    queue <- newTQueue
    live  <- newTVar 0
    exit  <- newTVar Nothing
    stop  <- newTVar False
    seed  <- newTVar (hookSeed hooks)
    bags  <- newTVar Map.empty
    -- §13.13 + §13.15: two bytestrings preregistered — Nil → "" (the
    -- free empty import suffix, §13.13) and the prelude's name handle
    -- Prelude → "Prelude" (what the §13.15 default-import machine's
    -- @import Prelude Nil []@ reads; @bytesBind Prelude "Prelude"@ is
    -- the manual spelling). Neither is special: bytesBind Nil … or
    -- bytesDestroy Prelude clobbers/drops either like any handle.
    bytes <- newTVar (Map.fromList
      [ ("Nil", encodeUtf8 (T.pack ""))
      , (preludeName, encodeUtf8 (T.pack preludeName))
      ])
    mods  <- newTVar Map.empty
    extra <- newTVar []
    reroute <- newTVar Map.empty
    sayFd <- newTVar Map.empty
    -- §13.18 (issue #18 part 2): the std fds, preregistered — ordinary
    -- fd-table entries, nothing special. @Stdin@ is the line-mode read
    -- fd (@fread@ blocks for a line); @Stdout@/@Stderr@ are write fds,
    -- and @say@'s default route is @Stdout@.
    fds   <- newTVar (Map.fromList
      [ (stdFdIn,  FdState hin  FdRead  False True)
      , (stdFdOut, FdState hout FdWrite False False)
      , (stdFdErr, FdState herr FdWrite False False)
      ])
    fresh <- newTVar 0
    pure RTS { rtsBag = bag, rtsQueue = queue, rtsSeed = seed
             , rtsLive = live, rtsExit = exit, rtsStop = stop
             , rtsBags = bags, rtsBytes = bytes
             , rtsMods = mods, rtsExtra = extra
             , rtsReroute = reroute, rtsSayFd = sayFd
             , rtsHooks = hooks
             , rtsFds = fds, rtsFresh = fresh
             }

-- | Resolve a bag name to its 'RBag' (§6). @Global@ is the main bag;
-- any other name is found in 'rtsBags' or created on demand. On-demand
-- creation is how @lob@ makes machineless accumulators (§6.2), and it
-- is why the §6.2 drain-on-first-machine handoff needs no code: an
-- accumulator and a live bag are the /same/ structure (one 'TVar'),
-- so tuples accumulated before the bag has machines are already in
-- place when its machines start matching — the handoff is one 'TVar'
-- and therefore trivially atomic (nothing can be lost or
-- double-delivered). Runs in the caller's transaction, so a body
-- mixing same-bag @out@ and cross-bag @lob@ commits as one atomic
-- unit — cross-bag atomicity for free, exactly as §6.1 predicted.
bagForSTM :: RTS -> Name -> STM RBag
bagForSTM rts n
  | n == globalBag = pure (rtsBag rts)
  | otherwise = do
      bags <- readTVar (rtsBags rts)
      case Map.lookup n bags of
        Just b  -> pure b
        Nothing -> do
          b <- newBagSTM
          writeTVar (rtsBags rts) (Map.insert n b bags)
          pure b

-- | @lob@ — push into a named bag (§6.1): the only way to send across
-- a bag boundary. A bag not seen before is created on demand as a
-- machineless accumulator (§6.2): nothing matches against it, so
-- accumulation is cheap, and any ordering it shows is accidental,
-- never a promise.
lobSTM :: RTS -> Name -> Val -> STM ()
lobSTM rts bagName t = do
  bag <- bagForSTM rts bagName
  outSTM bag t

--------------------------------------------------------------------------------
-- Machines
--------------------------------------------------------------------------------

-- MachineDef now lives in "Lindana.Def" (imported and re-exported
-- above): the import machinery ("Lindana.Import", used by the
-- effect runner below) needs it too, and it must not depend on the
-- machine layer — see the Def module header.

-- | A bundle of deferred effects (§7.2): queued post-commit, drained
-- FIFO by the effect-runner, one bundle live at a time.
newtype Bundle = Bundle { bundleEffects :: [Effect] }
  deriving (Eq, Show)

-- | Side-effecting verbs. Tuple-space writes are /not/ here — those
-- commit in the matching transaction. Termination effects
-- ('EffExit'/'EffPanic') end the bundle: the program is over, later
-- effects are dropped (§7.2 gives no rollback; here not even a queue).
data Effect
  = EffSay Name String [Val]  -- ^ @say "fmt" args…@ (@%i@, @%s@, @%a@,
                          -- @%b@, @%%@) — §13.18: the first field is
                          -- the fd the formatted line is written
                          -- through, resolved in-transaction via
                          -- 'sayTargetSTM' (default @Stdout@); say
                          -- is no longer a magic console write.
  | EffSleep Int          -- ^ @sleep e@ — milliseconds (provisional unit)
  | EffExit Val           -- ^ @exit e@ — terminate the program
  | EffPanic Val          -- ^ @panic e@ — fatal (§6.4)
  | EffBytesBind Name [Int] -- ^ @bytesBind H cps@ (§9) — register the
                          --   UTF-8 encoding of the codepoints under the
                          --   atom handle, then emit @(Bytes, H)@ into
                          --   @Global@ (the bind's completion tuple,
                          --   the deterministic gate for consumers).
                          --   Also @bytesNew@'s landing spot (§9, issue
                          --   #18 part 3) is a sibling effect —
                          --   'EffBytesNew' carries the codepoints and
                          --   picks the fresh handle at effect time.
  | EffBytesDestroy Name  -- ^ @bytesDestroy H@ (§9) — drop the entry;
                          --   later lookups are the user's to guard
  | EffBytesNew [Int]     -- ^ @bytesNew cps@ (§9, issue #18 part 3) —
                          --   register the UTF-8 encoding of the
                          --   codepoints under a runtime-fresh handle
                          --   ('freshBytesSTM', picked HERE at effect
                          --   time: every earlier-landed bind counts
                          --   against the name skip), then emit the
                          --   ordinary @(Bytes, H)@ gate into @Global@ —
                          --   H the fresh handle, delivered as data.
  | EffImport Name Name [Name] String
                          -- ^ @import H S Hide@ (§13.13) — load a module
                          --   at runtime: name handle, suffix handle,
                          --   hidden bag names, ambient suffix. Carries
                          --   /handles/, not contents: the bytes are
                          --   read at effect time, so a rebind between
                          --   commit and run is honored. Fails as a
                          --   runner-safe fatal (see module header).
  | EffFopen Name String FdMode
                          -- ^ @fopen H Path Mode@ (§13.17) — open the
                          --   file (path + mode resolved in-transaction,
                          --   the @bytesBind@ precedent) and register it
                          --   in 'rtsFds' under the atom handle; emits
                          --   @(Fopen, H)@ into @Global@. Failure
                          --   (missing file, bad mode) is a runner-safe
                          --   fatal, the §13.13 import precedent.
  | EffFclose Name        -- ^ @fclose H@ (§13.17) — close and drop;
                          --   unknown handle is a no-op (idempotent).
  | EffFread Name         -- ^ @fread H@ (§13.17) — read the entire
                          --   remaining content through a read-mode
                          --   handle into the bytestring side-table under
                          --   the same handle (clobbering); emits
                          --   @(Fread, H)@ into @Global@.
  | EffFwrite Name Name   -- ^ @fwrite H S@ (§13.17) — write the bytes
                          --   named by @S@ (bytestring side-table) through
                          --   write-mode handle @H@, flushed; emits
                          --   @(Fwrote, H)@ into @Global@.
  deriving (Eq, Show)

--------------------------------------------------------------------------------
-- File descriptors (§13.17, issue #18)
--------------------------------------------------------------------------------

-- | How an fd-table entry was opened. Provisionally just @R@ (read,
-- position at start; @fread@ reads the entire remaining content — for
-- a regular file that's the whole file) and @W@ (write, truncating;
-- append is the obvious flip-worthy third mode, recorded on the
-- messageboard).
data FdMode = FdRead | FdWrite
  deriving (Eq, Show)

-- | One fd-table entry: the OS handle and the mode it was opened in.
-- The table is keyed by the Lindana atom handle @fopen@ declared.
-- @fdSpent@ marks a read-mode handle whose entire remaining content
-- has already been pulled by @fread@: strict 'BS.hGetContents' closes
-- the OS handle as it reads, and the honest "remaining content" of a
-- spent read fd is the empty bytestring — further @fread@s clobber
-- the handle's side-table entry with @""@ and emit the completion
-- tuple again (fclose on a spent handle is a harmless no-op).
data FdState = FdState
  { fdHandle :: Handle
  , fdMode   :: FdMode
  , fdSpent  :: Bool
  , fdLine   :: Bool   -- ^ §13.18: line-mode read fd (@Stdin@ only):
                       --   @fread@ blocks for one line ('BS.hGetLine');
                       --   EOF reads as the honest empty remainder.
                       --   Never spent by a read — lines keep coming.
  }

instance Show FdState where
  show (FdState _ m _ l) =
    "FdState { fdMode = " ++ show m ++ ", fdLine = " ++ show l ++ " }"

--------------------------------------------------------------------------------
-- The interpreter (action layer, §3.3 + §7)
--------------------------------------------------------------------------------

-- | Evaluate an expression with the RTS's STM builtins.
evalR :: RTS -> Env -> Expr -> STM Val
evalR rts env = evalExprG (rtsBuiltin rts) env

-- | The builtins (§3.3, §7). These run /inside the matching
-- transaction/ — that's what keeps "read the join patterns, decide,
-- write replacement tuples" (§8.2 note) atomic even when the decision
-- uses @rand@: the generator state is an ordinary 'TVar' in the RTS,
-- and 'uniformR' is pure, so the step is an ordinary STM read/write.
--
-- Malformed calls (unknown builtin, wrong arity/kind) are provisional
-- Haskell-level errors — unified @error@-verb routing still pending
-- (§7.3). @atomize@ of an uncapitalized string is specified (§4) as
-- fatal @panic@; expression position can't queue an effect, so
-- provisionally it is a Haskell error that kills the machine thread
-- (the 'finally' in 'machineThread' keeps the live count honest).
--
-- With casual-string sugar (§9), @atomize@ consumes a codepoint
-- cons-list and decodes it ('casualString') before the capitalization
-- check; @atos@ hands back a casual string ('stringVal') — there is
-- no Str type (§11.4). @bytesEqual@ compares contents via the
-- side-table; @bytesCompare@ (issue #24) is the bytestring's enriched
-- ordering comparison — lexicographic (bytewise) on the contents,
-- @-1@/@0@/@1@ as plain Ints; @==@ on handles still compares only the
-- handles. @bytesRead@ is the decode-back path (§9, issue #12):
-- the handle's bytes decoded as UTF-8 into the codepoint cons-list
-- the bind consumed, so a string run in and out of the side-table is
-- the identity.
rtsBuiltin :: RTS -> Name -> [Val] -> STM Val
rtsBuiltin rts name args = case (name, args) of
  ("rand", [VInt n])
    | n <= 0    -> pure (VInt 0)   -- provisional: rand of non-positive is 0
    | otherwise -> do
        g <- readTVar (rtsSeed rts)
        let (v, g') = uniformR (0, n - 1) g
        writeTVar (rtsSeed rts) g'
        pure (VInt (toInteger v))
  ("typeOf", [v])     -> pure (VAtom (typeTag v))
  ("atomize", [v])
    | capitalized s   -> pure (VAtom s)
    | otherwise       -> error "atomize: string must be capitalized (§4: panic)"
    where s = casualString v
  ("atos", [VAtom n]) -> pure (stringVal n)
  -- §9: content comparison is a verb's job, reaching into the
  -- side-table; @==@ never does (it stays pure atom identity).
  ("bytesEqual", [VAtom x, VAtom y]) -> do
    m <- readTVar (rtsBytes rts)
    case (Map.lookup x m, Map.lookup y m) of
      (Just a, Just b) -> pure (VInt (if a == b then 1 else 0))
      _ -> error ("bytesEqual: unknown bytestring handle(s): " ++ x ++ ", " ++ y)
  -- §9 (issue #24): the bytestring's "enriched versions" of the
  -- ordering comparisons — lexicographic (bytewise) ordering of the
  -- CONTENTS, one builtin returning @-1@/@0@/@1@ (from which @<@,
  -- @<=@, @>@, @>=@ derive by comparison against 0) rather than four
  -- dedicated predicates. @==@ on handles stays pure atom identity —
  -- comparing handles compares the handles; reaching into the
  -- side-table is a verb's job, like @bytesEqual@. Missing handle:
  -- provisional Haskell error, same routing as @bytesEqual@ and @%b@
  -- (unified error routing pending, §3.3/§7.3).
  ("bytesCompare", [VAtom x, VAtom y]) -> do
    m <- readTVar (rtsBytes rts)
    case (Map.lookup x m, Map.lookup y m) of
      (Just a, Just b) -> pure (VInt (case compare a b of
                                       LT -> -1
                                       EQ -> 0
                                       GT -> 1))
      _ -> error ("bytesCompare: unknown bytestring handle(s): " ++ x ++ ", " ++ y)
  -- §9 (issue #12, bullet 3): the identity invariant — bytes go in via
  -- @bytesBind@, the same codepoints come back out. The result is the
  -- exact shape @bytesBind@ consumed (a 'stringVal' cons-list), so
  -- @bytesBind H l … bytesRead(H)@ round-trips @l@ unchanged and
  -- structural matching against a string/char/list literal pattern
  -- just works. Missing handle or invalid UTF-8: provisional Haskell
  -- errors, same routing as @bytesEqual@ and @%b@ (unified error
  -- routing pending, §3.3/§7.3). Invalid UTF-8 is unreachable through
  -- @bytesBind@ (it only registers 'encodeUtf8' of codepoints) — the
  -- check is for symmetry with @%b@ and any future byte source.
  ("bytesRead", [VAtom h]) -> do
    m <- readTVar (rtsBytes rts)
    case Map.lookup h m of
      Nothing -> error ("bytesRead: unknown bytestring handle " ++ h)
      Just bs -> case decodeUtf8' bs of
        Right txt -> pure (stringVal (T.unpack txt))
        Left _    -> error ("bytesRead: bytestring " ++ h ++ " is not valid UTF-8")
  _ -> error ("evalExpr: unknown builtin or bad arity: " ++ name)

capitalized :: String -> Bool
capitalized (c : _) = c `elem` ['A' .. 'Z']
capitalized []      = False

typeTag :: Val -> Name
typeTag VAtom{}   = "Atom"
typeTag VInt{}    = "Int"
typeTag VDouble{} = "Double"
typeTag VTuple{}  = "Tuple"
-- No Str tag (§9): a casual string is a cons-list — its shape is
-- Tuple, and interpretation is up to the consuming action.

-- | Interpret an action list in the matching transaction. Tuple-space
-- verbs execute immediately (they are the transaction); irrevocable
-- verbs accumulate into a deferred bundle. Returns the bundle and
-- whether the machine survives to re-arm ('False' iff the list ended
-- in @die@\/@exit@\/@panic@).
--
-- @if@ is an action combinator, not a verb: it selects a branch and
-- splices it ahead of the remaining actions — no sequencing
-- primitives beyond that (Terse desugaring, §5, will lower into this
-- same action list).
-- The bag argument is the machine's own bag (§6): @out@ is same-bag
-- emission — within a bag it is Linda semantics, and the continuation
-- idiom (@(c!, a + b)@) only works if the continuation lands where
-- the matching machines are. Cross-bag traffic goes through @lob@
-- exclusively (§6.1). The @bagName@ argument is that bag's name —
-- the @error@ verb's reroute lookup (§13.14) keys on it.
--
-- The @sfx@ argument is the machine's ambient namespace suffix
-- (§13.13, 'Lindana.Def.MachineDef'’s @machSfx@): @error@ routes to
-- @Error ++ sfx@ — the runtime equivalent of suffix-mangling that
-- atom in an imported module's source — and @import@ propagates the
-- ambient suffix to everything the import loads.
interpretActions :: RTS -> RBag -> String -> Name -> Env -> [Action]
                -> STM ([Effect], Bool)
interpretActions rts bag sfx bagName env = go []
  where
    go acc [] = pure (reverse acc, True)
    go acc (act : rest) = case act of
      Out e -> do
        t <- evalR rts env e
        outSTM bag t
        go acc rest
      Lob tgtE e -> do
        n <- evalR rts env tgtE
        tgt <- case n of
          VAtom bn -> pure bn
          _ -> error "lob: target must be an atom (a bag name, §6.1)"
        t <- evalR rts env e
        lobSTM rts tgt t
        go acc rest
      Say f es -> do
        vs <- mapM (evalR rts env) es
        -- §13.18: say's fd is resolved in-transaction — the reroute
        -- (§13.14) semantics: a sayfd installed by this machine
        -- earlier in the same action list is honored, the routed fd
        -- travels with the deferred bundle, and a concurrent sayfd
        -- from another machine racing this one is ordinary §3.1
        -- STM-commit chaos. The effect writes through the fd table
        -- like any fwrite (say is un-magicked); a routed fd that is
        -- closed/unknown by run time fatals honestly (runner-safe).
        tgt <- sayTargetSTM rts bagName sfx
        go (EffSay tgt f vs : acc) rest
      Sleep e -> do
        t <- evalR rts env e
        go (effSleep t : acc) rest
      Die -> pure (reverse acc, False)   -- no effect: thread bookkeeping
      Exit x -> do
        v <- evalR rts env x
        pure (reverse (EffExit v : acc), False)
      Panic x -> do
        v <- evalR rts env x
        pure (reverse (EffPanic v : acc), False)
      Raise e -> do
        t <- evalR rts env e
        -- §13.13 + §13.14: the tuple goes to the machine's mangled
        -- Error bag (Error ++ ambient suffix — the plain Error bag at
        -- top level, §6.4), after consulting the reroute table (bag-
        -- specific first, then module-wide; see 'errorTargetSTM').
        -- The tag stays the ORIGINAL mangled Error bag: provenance —
        -- "an error from this machine's module" — travels with the
        -- tuple and is stable no matter where a reroute delivers it,
        -- so a collector can match (Error, rest!) / (Error_v2, rest!)
        -- without caring which bag it lives on.
        tgt <- errorTargetSTM rts bagName sfx
        ebag <- bagForSTM rts tgt
        outSTM ebag (errorTuple (errorBag ++ sfx) t)
        go acc rest
      BytesBind h e -> do
        cps <- codepoints <$> evalR rts env e
        go (EffBytesBind h cps : acc) rest
      BytesDestroy e -> do
        v <- evalR rts env e
        n <- case v of
          VAtom n -> pure n
          _ -> error "bytesDestroy: handle must be an atom (§9)"
        go (EffBytesDestroy n : acc) rest
      BytesNew e -> do
        -- §9 (issue #18 part 3): a bytestring for an otherwise-anonymous
        -- string. Only the CONTENT resolves in-transaction (the bytesBind
        -- precedent); the FRESH NAME is picked at EFFECT time
        -- ('EffBytesNew' — the EffImport precedent: effect-time reads
        -- honor the landed state, and every earlier-landed bind —
        -- including one earlier in this same bundle — counts against
        -- the name skip). The gate tuple is the ordinary @(Bytes, H)@,
        -- H the fresh handle.
        cps <- codepoints <$> evalR rts env e
        go (EffBytesNew cps : acc) rest
      Import nh sh hide -> do
        -- §13.13: a pending-import slot in the live count, claimed
        -- NOW in-transaction. The run-alive check (@live == 0@) must
        -- not fire while an import bundle is still queued — all
        -- startup machines may have died since it was queued. The
        -- effect settles the slot: +k machines − 1 slot when it
        -- loads, −1 on skip or failure.
        modifyTVar' (rtsLive rts) (+ 1)
        nhv <- evalR rts env nh
        shv <- evalR rts env sh
        hv  <- evalR rts env hide
        hs <- atomList hv
        go (EffImport (atomHandle nhv) (atomHandle shv) hs sfx : acc) rest
      Reroute srcE tgtE -> do
        -- §13.14: write the reroute table now, in-transaction — the
        -- write commits atomically with the match that performed it,
        -- so no error can be routed by a half-installed reroute (last
        -- update wins on purpose, issue #17). Targets are NOT checked
        -- to exist: an unknown target is an §6.2 machineless
        -- accumulator (or a future module's bag) — that is the
        -- Accursed point (documented hazard, not guarded; §12).
        sv <- evalR rts env srcE
        tv <- evalR rts env tgtE
        src <- atomName sv
        tgt <- atomName tv
        modifyTVar' (rtsReroute rts) (Map.insert src tgt)
        go acc rest
      SayFd srcE tgtE -> do
        -- §13.18: the say-FD reroute sister effect (issue #18 part
        -- 2) — exactly the §13.14 design with a different table:
        -- @sayfd Bag Fd@ repoints what fd @say@s by machines declared
        -- in @Bag@ go through (in-transaction install, last update
        -- wins). Targets are NOT checked against the fd table (the
        -- reroute precedent): routing to a not-yet-opened fd is the
        -- §6.2 accumulator story — the say effect fatals honestly at
        -- run time if the fd never appears.
        sv <- evalR rts env srcE
        tv <- evalR rts env tgtE
        src <- atomName sv
        tgt <- atomName tv
        modifyTVar' (rtsSayFd rts) (Map.insert src tgt)
        go acc rest
      FOpen h pE mE -> do
        -- §13.17: path and mode resolve in-transaction (the bytesBind
        -- precedent — the declaration site's data is fixed at commit);
        -- the OS open happens in the effect runner. Emitting a
        -- completion tuple lets consumers gate like on (Bytes, H).
        pv <- evalR rts env pE
        mv <- evalR rts env mE
        m <- case mv of
          VAtom "R" -> pure FdRead
          VAtom "W" -> pure FdWrite
          _ -> error "fopen: mode must be the atom R or W (§13.17, §3.3)"
        go (EffFopen h (casualString pv) m : acc) rest
      FClose hE -> do
        hv <- evalR rts env hE
        go (EffFclose (atomHandle hv) : acc) rest
      FRead hE -> do
        hv <- evalR rts env hE
        go (EffFread (atomHandle hv) : acc) rest
      FWrite hE sE -> do
        hv <- evalR rts env hE
        sv <- evalR rts env sE
        go (EffFwrite (atomHandle hv) (atomHandle sv) : acc) rest
      If c th el -> do
        b <- truthy <$> evalR rts env c
        go acc ((if b then th else el) ++ rest)

    effSleep v = case v of
      VInt n    -> EffSleep (fromInteger n)   -- milliseconds
      VDouble d -> EffSleep (round (d * 1000))
      _ -> error "sleep: non-numeric operand (action-layer check, §3.3)"

-- | §9: a byte/int list is a cons-list of @VInt@ codepoints ending in
-- the @Nil@ atom — exactly what the §11.5 list literal (or now a
-- @\"...\"@ string literal, §9) builds. Shape and range are the
-- action layer's check (§3.3), same as @sleep@; the decoding itself is
-- shared with the other string-consuming actions via Runtime's
-- 'casualString'.
codepoints :: Val -> [Int]
codepoints = map ord . casualString

-- | §9 (issue #18 part 3): pick a runtime-fresh bytestring handle —
-- @bytesNew@'s name source. Flat counter (@Bytes0@, @Bytes1@, … — the
-- @ACont@ precedent; the issue's "randomly? flatly, like ACont?") with
-- a skip: a candidate already present in the side-table (a user's
-- @bytesBind Bytes3 …@, say) is passed over, so generation never
-- collides with what exists. Runs at EFFECT time, in the runner: every
-- earlier-landed bind — including one earlier in the same bundle —
-- counts against the skip, and bundles drain FIFO through the single
-- runner (§11.7), so two @bytesNew@s can never pick the same name.
-- What this cannot prevent is a user bind QUEUED AFTER the bytesNew
-- clobbering the fresh handle — manual-lifetime chaos, opt-out as
-- usual (§12). The counter itself makes generation deterministic (no
-- @rand@ burn — runs stay reproducible), and the returned handle is
-- runtime data — nothing in any source names it, so it never mangles
-- (only source mentions mangle, the hide-list precedent).
freshBytesSTM :: RTS -> STM Name
freshBytesSTM rts = go
  where
    go = do
      n <- readTVar (rtsFresh rts)
      writeTVar (rtsFresh rts) (n + 1)
      let cand = "Bytes" ++ show n
      bytes <- readTVar (rtsBytes rts)
      if Map.member cand bytes then go else pure cand

-- | §13.13: @import@'s name and suffix arguments must be bytestring
-- handles — atoms (the contents are looked up in the side-table by
-- the effect). Anything else is the provisional Haskell-level error,
-- same routing as the other action-layer checks (§3.3).
atomHandle :: Val -> Name
atomHandle (VAtom n) = n
atomHandle _ =
  error "import: name and suffix must be bytestring handles (atoms, §13.13)"

-- | §13.14: @reroute@'s and §13.18 @sayfd@'s source and target must
-- be atoms (bag names — the parser also accepts variables holding bag
-- names as data, the §13.13 @lob@-target extension). Anything else is
-- the provisional Haskell-level error, same routing as the other
-- action-layer checks (§3.3).
atomName :: Val -> STM Name
atomName (VAtom n) = pure n
atomName _ =
  error "reroute/sayfd: source and target must be bag names (atoms, §13.14/§13.18)"

-- | §13.13: the hide list is a cons-list of atoms (the §11.5 list
-- literal shape, or @[]@) naming module bags whose machines are not
-- imported ('Lindana.Import.hideBags' matches pre-mangle names).
atomList :: Val -> STM [Name]
atomList (VAtom "Nil")            = pure []
atomList (VTuple [VAtom n, rest]) = (n :) <$> atomList rest
atomList (VTuple _) =
  error "import: hide list elements must be atoms (§13.13)"
atomList _ =
  error "import: hide list must be a cons-list of atoms (§13.13)"

-- | The @error@ verb's routing decision (§6.4 + §13.14). @bag@ is the
-- machine's own bag; @sfx@ its module's ambient suffix.
--
-- The routing, in precedence order:
--
--   1. /Bag-specific reroute/ (§13.14): @rtsReroute@ keyed by the
--      machine's own bag name.
--   2. /Module-wide reroute/ (§13.14): @rtsReroute@ keyed by the
--      machine's module's mangled Error bag (@'errorBag' ++ sfx@) —
--      the reroute action's spelling for "all bags in the module":
--      every module machine's errors land there before any reroute,
--      so rerouting that name catches them all. At top level
--      (@sfx == ""@) this key /is/ the default Error bag, so a plain
--      @reroute Error Log@ reroutes every top-level machine's errors.
--   3. /The bag the tuple actually goes to/ — the default: the
--      machine's mangled Error bag (@'errorBag' ++ sfx@, the plain
--      Error bag at top level). A module's own @Error { … }@ handler
--      block, mangled like everything else, catches its own errors
--      here.
--
-- Resolving through 'bagForSTM' at routing time means a reroute table
-- written /before/ the target bag exists is honored — the §6.2
-- accumulator semantics: rerouting to a bag whose machines have not
-- been declared or imported yet just accumulates there until they
-- start matching (issue #17's "for Accursedness, all you need is the
-- source and target bucket").
errorTargetSTM :: RTS -> Name -> String -> STM Name
errorTargetSTM rts bag sfx = do
  rr <- readTVar (rtsReroute rts)
  let mangled = errorBag ++ sfx
  pure $ case Map.lookup bag rr of
    Just tgt -> tgt               -- 1. bag-specific reroute wins
    Nothing -> case Map.lookup mangled rr of
      Just tgt  -> tgt            -- 2. module-wide reroute: at top
                                  --    level (sfx == "") this key IS
                                  --    the default, so a plain
                                  --    @reroute Error Log@ catches
                                  --    every top-level machine's
                                  --    errors — "all bags in the
                                  --    module", issue #17
      Nothing   -> mangled        -- 3. the machine's mangled Error bag

-- | §13.18: the @say@ verb's fd routing decision — 'errorTargetSTM''s
-- design, one tier for the fd table (§13.14's sister, issue #18 part
-- 2). @bag@ is the machine's own bag; @sfx@ its module's ambient
-- suffix. In precedence order:
--
--   1. /Bag-specific route/ (@sayfd Bag Fd@): keyed by the machine's
--      own bag name.
--   2. /Module-wide route/: keyed by the machine's module's mangled
--      Error bag (@'errorBag' ++ sfx@) — the same convention that
--      stands for "all bags in the module" in §13.14 (it is the only
--      per-module name a module's source can spell, and every module
--      machine consults it). At top level (@sfx == ""@) this key IS
--      plain @Error@, so @sayfd Error Fd@ catches every top-level
--      machine's says.
--   3. /The default/: @Stdout@ — pre-un-magicking behavior exactly.
--
-- Resolved in-transaction (the interpretActions Say case); the
-- chosen fd is /not/ checked against the fd table here — an unknown
-- fd is the say effect's honest runner-safe fatal at run time (the
-- reroute "targets not checked" precedent). The hazard that a table
-- name like @Error ++ suffix@ can collide with a real bag is §13.14's,
-- shared verbatim here (documented, not guarded).
sayTargetSTM :: RTS -> Name -> String -> STM Name
sayTargetSTM rts bag sfx = do
  rr <- readTVar (rtsSayFd rts)
  let mangled = errorBag ++ sfx
  pure $ case Map.lookup bag rr of
    Just tgt -> tgt               -- 1. bag-specific sayfd wins
    Nothing -> case Map.lookup mangled rr of
      Just tgt  -> tgt            -- 2. module-wide: at top level
                                  --    (sfx == "") this key IS plain
                                  --    Error, so @sayfd Error Fd@
                                  --    catches every top-level
                                  --    machine's says
      Nothing   -> stdFdOut       -- 3. the default Stdout

-- | @error e@ (§6.4): an @(Error, …)@ tuple into the named @Error@
-- bag (conceptually sugar over @lob Error …@); a tuple argument's
-- contents are spliced in. With no user @Error@ declarations the
-- loader installs the default machine @(c!) : panic c@; an empty
-- user @Error { }@ block means "silently swallow all errors".
-- The @tag@ argument is the tuple's leading atom: the machine's
-- mangled Error bag name — @Error@ at top level, @Error ++ suffix@
-- for an imported module's machines (§13.13) — so a module's own
-- @Error { … }@ handler block, mangled the same way, matches its own
-- error tuples, and the tag is stable provenance even when a reroute
-- (§13.14) delivers the tuple somewhere else.
errorTuple :: Name -> Val -> Val
errorTuple tag v = VTuple (VAtom tag : case v of
  VTuple vs -> vs
  _         -> [v])

-- | §9 truthiness (provisional, see module header). The unifying rule
-- is open (§11); @VAtom \"False\"@ participates because §9 makes
-- @True@\/@False@ ordinary atoms.
truthy :: Val -> Bool
truthy (VInt 0)        = False
truthy (VDouble 0.0)   = False
truthy (VAtom "False") = False
truthy _               = True

--------------------------------------------------------------------------------
-- Machine threads: the loop (§1)
--------------------------------------------------------------------------------

-- | One thread per machine. Machines loop by default: match →
-- interpret → re-arm. @die@ (or terminal @exit@\/@panic@) ends the
-- thread; an empty-pattern machine runs once, unconditionally, at
-- start (§1).
machineThread :: RTS -> RBag -> MachineDef -> IO ()
machineThread rts bag m = go `finally` decLive
  where
    -- Idle-exempt machines (§11.12) are not counted in the live total
    -- — they park forever by design — so they never decrement it.
    decLive = unless (machIdle m) $
      atomically (modifyTVar' (rtsLive rts) (subtract 1))

    go
      | null (machJoin m) = do   -- §1: one-shot, unconditionally, at start
          (effs, _) <- atomically
            (interpretActions rts bag (machSfx m) (machBag m) Map.empty
                              (machBody m))
          push effs
          pure ()                -- implicitly terminates after firing
      | otherwise = loop

    loop = do
      (effs, survived) <- atomically $ do
        mr <- matchJoinSTM bag (machJoin m)
        case mr of
          Nothing -> retry
          Just mt ->
            -- Commit point (§3.2): the match is committed for good —
            -- no retry can reach back. Interpret the body in the same
            -- transaction so its tuple-space writes land atomically
            -- with the match (the §8.2 note); irrevocables come back
            -- as a deferred bundle for the effect-runner (§7.2).
            interpretActions rts bag (machSfx m) (machBag m) (matchEnv mt)
                             (machBody m)
      push effs
      when survived loop

    push effs =
      unless (null effs) $
        atomically (writeTQueue (rtsQueue rts) (Bundle effs))

--------------------------------------------------------------------------------
-- The effect-runner (§7.2)
--------------------------------------------------------------------------------

-- | Drains bundles FIFO from the 'TQueue', one bundle fully live at a
-- time: sequencing and synchronization from a single thread and a
-- queue — no bespoke machinery, per §7.2. Provisionally global (§7.3
-- open): unrelated bags' I/O serializes against each other.
-- | Drains bundles FIFO from the 'TQueue', one bundle fully live at a
-- time: sequencing and synchronization from a single thread and a
-- queue — no bespoke machinery, per §7.2. Provisionally global (§7.3
-- open): unrelated bags' I/O serializes against each other.
--
-- Shutdown is graceful: once @rtsStop@ is set, the runner finishes its
-- current bundle, drains the queue, and returns — every queued bundle
-- is fully executed before a program run returns. Cancelling the
-- runner instead would drop a bundle mid-@sleep@; we never do.
effectRunner :: RTS -> IO ()
effectRunner rts = loop
  where
    loop = do
      mb <- atomically $ do
        stop <- readTVar (rtsStop rts)
        b    <- tryReadTQueue (rtsQueue rts)
        case (b, stop) of
          (Just _, _)      -> pure b
          (Nothing, False) -> retry         -- keep waiting for bundles
          (Nothing, True)  -> pure Nothing
      case mb of
        Nothing            -> pure ()   -- queue empty and stopping
        Just (Bundle effs) -> runBundle rts effs >> loop

-- | Run one bundle's effects sequentially. No rollback on partial
-- failure (§7.2's final bullet): a failed effect leaves earlier
-- effects done; checking success is the programmer's job. @exit@\/@panic@
-- end the bundle (and the program) — later effects are dropped.
runBundle :: RTS -> [Effect] -> IO ()
runBundle rts = go
  where
    go [] = pure ()
    go (e : es) = case e of
      EffSay tgt f vs -> do
        -- §13.18: say is un-magicked — the formatted line (plus its
        -- newline) goes through the fd table like any fwrite: looked
        -- up at effect time (a fclose Stdout between queueing and run
        -- fatals, honestly), BS.hPut + hFlush (the fwrite precedent).
        -- Unknown fd / wrong mode are runner-safe fatals (§13.17).
        fds <- readTVarIO (rtsFds rts)
        m <- readTVarIO (rtsBytes rts)
        case Map.lookup tgt fds of
          Nothing -> fdFailed rts ("say: unknown fd handle " ++ tgt)
          Just fd | fdMode fd /= FdWrite ->
            fdFailed rts ("say: handle " ++ tgt ++ " is not open for writing")
                  | otherwise -> do
            r <- try (BS.hPut (fdHandle fd)
                        (encodeUtf8 (T.pack (formatSay m f vs ++ "\n")))
                        >> hFlush (fdHandle fd))
            case r of
              Right () -> go es
              Left exc -> fdFailed rts ("say " ++ tgt ++ ": "
                                        ++ show (exc :: SomeException))
      EffSleep ms -> threadDelay (ms * 1000) >> go es
      EffExit v   -> atomically (setExit rts (exitCodeOf v))  -- program over
      EffPanic v  -> do
        hookPanic (rtsHooks rts) (renderVal v)
        atomically (setExit rts (ExitFailure 1))
      EffBytesBind h cps -> do
        -- §11.8 (provisionally resolved): create/destroy route through
        -- the shared effect-runner. The completion tuple lands in
        -- @Global@ (the front door) so consumers can join on it.
        bytesBindEffect rts h cps >> go es
      EffBytesNew cps -> do
        -- §9 (issue #18 part 3): the handle is picked HERE — effect
        -- time — so the skip in 'freshBytesSTM' sees every
        -- earlier-landed bind (FIFO: an earlier same-bundle bytesBind
        -- has already landed). Same landing as a bind: side-table
        -- write + the @(Bytes, H)@ gate.
        h <- atomically (freshBytesSTM rts)
        bytesBindEffect rts h cps >> go es
      EffBytesDestroy h ->
        atomically (modifyTVar' (rtsBytes rts) (Map.delete h)) >> go es
      EffImport nh sh hidden sfx -> do
        -- §13.13: settle the pending-import slot (claimed when the
        -- action was interpreted) and load. Everything fallible is
        -- contained here: a failed import is a runner-safe fatal
        -- (panic hook + exit 1) rather than a silent runner death —
        -- the program would otherwise deadlock with no one to say so.
        ex <- readTVarIO (rtsExit rts)
        if isJust ex
          then atomically (modifyTVar' (rtsLive rts) (subtract 1))
          else do
            r <- try (importOnce rts nh sh hidden sfx)
            case r of
              Right (Right ()) -> pure ()
              Right (Left err) -> importFailed rts err
              Left exc         -> importFailed rts (show (exc :: SomeException))
        go es
      EffFopen h path mode -> do
        -- §13.17: fallible FD effects are runner-safe fatals (§13.13
        -- import precedent): panic hook + exit 1, never a silent
        -- runner death. Last fopen on a handle wins — and the
        -- superseded OS handle is CLOSED first (not merely replaced):
        -- a silent leak would keep the file locked (GHC's per-Handle
        -- locking) and un-reopenable. Provisional, flip-worthy:
        -- "second fopen fails loudly" is the obvious alternative.
        old <- Map.lookup h <$> readTVarIO (rtsFds rts)
        case old of
          Just fd -> do
            _ <- try (hClose (fdHandle fd)) :: IO (Either SomeException ())
            pure ()
          Nothing -> pure ()
        r <- try (do hh <- openFile path (fdIOMode mode)
                     hSetBinaryMode hh True
                     pure hh)
        case r of
          Right hh -> do
            atomically $ do
              modifyTVar' (rtsFds rts) (Map.insert h (FdState hh mode False False))
              b <- bagForSTM rts globalBag
              outSTM b (VTuple [VAtom "Fopen", VAtom h])
            go es
          Left exc -> fdFailed rts ("fopen " ++ h ++ " " ++ show path ++ ": "
                                    ++ show (exc :: SomeException))
      EffFclose h -> do
        -- Idempotent close (the bytesDestroy precedent): an unknown
        -- handle is a no-op, later operations are the user's to guard
        -- (they'll fatal via the missing-handle checks below).
        fds <- readTVarIO (rtsFds rts)
        case Map.lookup h fds of
          Nothing -> go es
          Just fd -> do
            _ <- try (hClose (fdHandle fd)) :: IO (Either SomeException ())
            atomically (modifyTVar' (rtsFds rts) (Map.delete h)) >> go es
      EffFread h -> do
        fds <- readTVarIO (rtsFds rts)
        -- The gate-tuple emit, shared by every read flavor: clobber
        -- the side-table entry and emit @(Fread, H)@ into @Global@
        -- (the deterministic gate), then continue the bundle.
        let emitGate bs = do
              atomically $ do
                modifyTVar' (rtsBytes rts) (Map.insert h bs)
                b <- bagForSTM rts globalBag
                outSTM b (VTuple [VAtom "Fread", VAtom h])
              go es
        case Map.lookup h fds of
          Nothing ->
            fdFailed rts ("fread: unknown fd handle " ++ h)
          Just fd
            | fdMode fd /= FdRead ->
              fdFailed rts ("fread: handle " ++ h
                            ++ " is not open for reading")
            | fdSpent fd ->
              -- Spent read fd: the empty remainder. Still clobber the
              -- side-table entry and emit the gate tuple — the content
              -- really is "" now.
              emitGate BS.empty
            | fdLine fd -> do
              -- §13.18 (issue #18 part 2): line-mode read fd — Stdin.
              -- fread BLOCKS for one line (the carried §13.17 open
              -- question, resolved toward blocking-available): the
              -- cost is that the (§11.7, global) effect runner parks
              -- until a line arrives — every other queued effect
              -- waits behind it. Documented, not guarded. EOF reads
              -- as the honest empty remainder (the spent-fd shape):
              -- clobber "" and emit the gate tuple; the fd is NOT
              -- spent — lines keep coming until EOF, and it stays EOF
              -- after.
              r <- try (BS.hGetLine (fdHandle fd))
              case r of
                Right ln -> emitGate ln
                Left exc
                  | isEOFError exc -> emitGate BS.empty
                  | otherwise ->
                    fdFailed rts ("fread " ++ h ++ ": "
                                  ++ show (exc :: IOError))
            | otherwise -> do
              r <- try (BS.hGetContents (fdHandle fd))
              case r of
                Right bs -> do
                  -- Content lands in the bytestring side-table under
                  -- the SAME handle (clobbering): `say %b H` reads it
                  -- back, and (Fread, H) is the deterministic gate.
                  -- The fd is now spent ('BS.hGetContents' closed it);
                  -- see 'FdState'.
                  atomically $ do
                    modifyTVar' (rtsBytes rts) (Map.insert h bs)
                    modifyTVar' (rtsFds rts)
                                (Map.insert h fd { fdSpent = True })
                    b <- bagForSTM rts globalBag
                    outSTM b (VTuple [VAtom "Fread", VAtom h])
                  go es
                Left exc -> fdFailed rts ("fread " ++ h ++ ": "
                                          ++ show (exc :: SomeException))
      EffFwrite h src -> do
        fds <- readTVarIO (rtsFds rts)
        bytes <- readTVarIO (rtsBytes rts)
        case (,) <$> Map.lookup h fds <*> Map.lookup src bytes of
          Nothing ->
            fdFailed rts ("fwrite: unknown " ++
              (case Map.lookup h fds of
                 Nothing -> "fd handle " ++ h
                 Just _  -> "bytestring handle " ++ src))
          Just (fd, bs)
            | fdMode fd /= FdWrite ->
                fdFailed rts ("fwrite: handle " ++ h ++ " is not open for writing")
            | otherwise -> do
                r <- try (BS.hPut (fdHandle fd) bs >> hFlush (fdHandle fd))
                case r of
                  Right () -> do
                    atomically $ do
                      b <- bagForSTM rts globalBag
                      outSTM b (VTuple [VAtom "Fwrote", VAtom h])
                    go es
                  Left exc -> fdFailed rts ("fwrite " ++ h ++ ": "
                                            ++ show (exc :: SomeException))

-- | §13.13, the @import@ effect's load path. Left = failure message
-- (turned into a fatal @panic@ by 'runBundle'). Reads the name and
-- suffix handles' /contents/ from the side-table at effect time,
-- consults the loaded-modules registry (singleton per
-- @(name, effective suffix)@ — also what makes import cycles
-- terminate), and on a fresh pair parses, hides, mangles, lowers,
-- outs the module's initial tuples, emits the @(Imported, H, suffix)@
-- completion tuple into @Global@, and spawns the module's machines
-- mid-run.
importOnce :: RTS -> Name -> Name -> [Name] -> String
           -> IO (Either String ())
importOnce rts nh sh hidden sfx = do
  em <- readTVarIO (rtsBytes rts)
  case (decodeName =<< Map.lookup nh em,
        decodeName =<< Map.lookup sh em) of
    (Just nm, Just sfxW) -> do
      let eff = sfx ++ sfxW
          key = (nm, eff)
      fresh <- atomically $ do
        seen <- readTVar (rtsMods rts)
        if Map.member key seen
          then pure False
          else writeTVar (rtsMods rts) (Map.insert key () seen) >> pure True
      if not fresh
        -- Repeat import: module singletons (first import wins —
        -- a later hide list has no effect; documented hazard).
        -- Still emit the completion tuple: consumers gate on it
        -- regardless of whether the load was fresh. The pending slot
        -- claimed in-transaction must still be settled (−1) — the
        -- §13.13 contract says "−1 on skip or failure", and a leaked
        -- slot would make the run-alive check never fire (found by
        -- the §13.15 prelude tests: the default import + an explicit
        -- repeat would hang every non-exit program forever).
        then do
          atomically (modifyTVar' (rtsLive rts) (subtract 1))
          emitImported rts nh eff >> pure (Right ())
        else do
          ep <- case Map.lookup nm builtinModules of
            -- §13.15: builtin modules (the prelude) are parsed from
            -- the registry, shadowing disk — the search then never
            -- touches @hookModDir@ (a user file named Prelude.lind is
            -- shadowed; documented, flip-worthy).
            Just src -> pure (parseModuleSource ("builtin module " ++ nm) src)
            Nothing  -> parseModuleFile (hookModDir (rtsHooks rts)) nm
          case ep of
            Left err   -> pure (Left err)
            Right prog -> case lowerModule hidden eff prog of
              Left err   -> pure (Left err)
              Right (ms, ini) -> do
                installModule rts ms ini
                emitImported rts nh eff
                pure (Right ())
    _ -> pure (Left
      ("unknown bytestring handle(s) for name/suffix: " ++ nh ++ ", " ++ sh))
  where
    decodeName bs = case decodeUtf8' bs of
      Right t -> Just (T.unpack t)
      Left _  -> Nothing    -- provisional: invalid UTF-8 = missing handle

-- | §13.13: install a freshly loaded module — initial tuples out'd
-- (one transaction, so module machines wake to a fully-populated
-- bag), live count credited with the new machines (minus the pending
-- slot this effect settles), machine threads spawned and recorded
-- for shutdown cancellation.
installModule :: RTS -> [MachineDef] -> Map Name [Expr] -> IO ()
installModule rts ms ini = do
  atomically $ do
    mapM_ (\(n, es) ->
              mapM_ (\e -> do
                       v <- evalR rts Map.empty e
                       b <- bagForSTM rts n
                       outSTM b v)
                 es)
          (Map.toList ini)
    -- Credit only non-idle machines (§11.12): a module's default
    -- Error machine never terminates, and a leaked live count would
    -- make the run-alive check never fire (the §13.15 prelude-slot
    -- shape). The −1 still settles the pending-import slot.
    modifyTVar' (rtsLive rts)
                (+ (length (filter (not . machIdle) ms) - 1))
  mbags <- mapM (\m -> (,) m <$> atomically (bagForSTM rts (machBag m))) ms
  as <- mapM (\(m, b) -> async (machineThread rts b m)) mbags
  atomically (modifyTVar' (rtsExtra rts) (++ as))

-- | §13.13: the @(Imported, H, suffix)@ completion tuple lands in
-- @Global@ — the same deterministic-gate idiom as @(Bytes, H)@. @H@
-- is the name handle /as written in the import action/; two imports
-- through the same handle at different times are indistinguishable
-- in the gate (documented hazard).
emitImported :: RTS -> Name -> String -> IO ()
emitImported rts nh eff = atomically $ do
  b <- bagForSTM rts globalBag
  outSTM b (VTuple [VAtom "Imported", VAtom nh, stringVal eff])

-- | §13.13: a failed import is fatal, but /runner-safe/: the message
-- goes to the panic hook and the program exits 1, instead of the
-- exception killing the effect-runner thread silently (the §13.12
-- debugging tale — every later effect, including @exit@, would then
-- never run).
importFailed :: RTS -> String -> IO ()
importFailed rts err = do
  hookPanic (rtsHooks rts) ("import failed: " ++ err)
  atomically $ do
    modifyTVar' (rtsLive rts) (subtract 1)
    writeTVar (rtsExit rts) (Just (ExitFailure 1))

-- | §13.17: a failed FD effect is fatal but /runner-safe/ — same
-- shape as 'importFailed', minus the pending slot (FD effects spawn
-- no machines, and the graceful effect-runner drain already runs
-- every queued bundle before a run returns, so no live-count slot is
-- needed).
fdFailed :: RTS -> String -> IO ()
fdFailed rts err = do
  hookPanic (rtsHooks rts) err
  atomically (writeTVar (rtsExit rts) (Just (ExitFailure 1)))

-- | §13.17: the 'FdMode' → 'IOMode' mapping. @W@ truncates; append
-- mode is the obvious flip-worthy extension (messageboard).
fdIOMode :: FdMode -> IOMode
fdIOMode FdRead  = ReadMode
fdIOMode FdWrite = WriteMode

setExit :: RTS -> ExitCode -> STM ()
setExit rts c = writeTVar (rtsExit rts) (Just c)

-- | The shared landing of a bytestring registration (§9): the
-- side-table write and the @(Bytes, H)@ completion tuple into @Global@
-- — the gate @bytesBind@ and @bytesNew@ both emit ('EffBytesNew' picks
-- its handle just before calling this).
bytesBindEffect :: RTS -> Name -> [Int] -> IO ()
bytesBindEffect rts h cps = atomically $ do
  modifyTVar' (rtsBytes rts) (Map.insert h (encodeUtf8 (T.pack (map chr cps))))
  b <- bagForSTM rts globalBag
  outSTM b (VTuple [VAtom "Bytes", VAtom h])

-- | @say@ formatting: @%i@ int, @%s@ casual string (a codepoint
-- cons-list, decoded — §9), @%a@ render-any, @%b@ bytestring handle
-- (decoded, §9), @%%@ a literal @%@. Mismatched arg counts are
-- provisional Haskell errors (pending unified @error@ routing, §3.3).
formatSay :: Map Name ByteString -> String -> [Val] -> String
formatSay bytes fmt = go fmt
  where
    go ('%' : 'i' : cs) (VInt n : as)   = show n ++ go cs as
    go ('%' : 's' : cs) (v : as)        = casualString v ++ go cs as
    go ('%' : 'a' : cs) (v : as)        = renderVal v ++ go cs as
    go ('%' : 'b' : cs) (VAtom h : as) =
      case Map.lookup h bytes of
        Nothing -> error ("say: unknown bytestring handle " ++ h)
        Just bs -> case decodeUtf8' bs of
          Right t -> T.unpack t ++ go cs as
          Left _  -> error ("say: bytestring " ++ h ++ " is not valid UTF-8")
    go ('%' : 'b' : _)  _               = error "say: %b needs an atom bytestring handle"
    go ('%' : '%' : cs) as              = '%' : go cs as
    go ('%' : _ : _) []                 = error "say: too few arguments"
    go ('%' : _) _                      = error "say: bad directive or dangling %"
    go (c : cs) as                      = c : go cs as
    go [] []                            = []
    go [] (_ : _)                       = error "say: too many arguments"

-- | Crude value rendering (panic messages, @%a@).
renderVal :: Val -> String
renderVal (VAtom n)   = n
renderVal (VInt n)    = show n
renderVal (VDouble d) = show d
renderVal (VTuple vs) = "(" ++ intercalate ", " (map renderVal vs) ++ ")"

exitCodeOf :: Val -> ExitCode
exitCodeOf (VInt n)
  | n == 0    = ExitSuccess
  | otherwise = ExitFailure (fromInteger (n `mod` 256))
exitCodeOf _ = ExitFailure 1

--------------------------------------------------------------------------------
-- Running a program
--------------------------------------------------------------------------------

data RunResult = RunResult
  { rrExit :: ExitCode        -- ^ program exit status (@exit@\/@panic@)
  , rrBag  :: [Val]           -- ^ final contents of @Global@
  , rrBags :: Map Name [Val]  -- ^ final contents of every other named
                              --   bag (§6): machineless accumulators
                              --   and live bags alike
  , rrBytes :: Map Name ByteString  -- ^ final §9 side-table state
                                    --   (surviving bytestring handles)
  } deriving (Eq, Show)

-- | Run a @Global@-only program: initial tuples land in @Global@ in
-- one transaction, then one thread per machine. Convenience for tests
-- and callers that have not crossed into named bags (§6); the loader
-- ('Lindana.Loader.loadProgram') produces the general shape.
-- Returns when every machine has terminated (die, one-shot, or
-- exception) or the program has exited. A machine blocked on a match
-- that will never arrive keeps the count up — that is the §1 loop
-- doing its job, not a bug; such programs need @exit@ or @die@ paths
-- (or an external watchdog) to finish.
runProgram :: [MachineDef] -> [Expr] -> IO RunResult
runProgram machines initial =
  runProgramWith defaultHooks machines (Map.singleton globalBag initial)

runProgramWith :: Hooks -> [MachineDef] -> Map Name [Expr] -> IO RunResult
runProgramWith hooks machines initial =
  runLoaded hooks machines initial

-- | Run a loaded program (§6): one thread per machine, each matching
-- the bag its 'MachineDef' names; initial tuples land per bag. Bags
-- are resolved (and created on demand) through 'bagForSTM', so a
-- machine's bag and any @lob@ target with the same name are the same
-- structure.
runLoaded :: Hooks -> [MachineDef] -> Map Name [Expr] -> IO RunResult
runLoaded hooks machines initial = do
  rts <- newRTSWith hooks
  atomically $ do
    mapM_ (\(n, es) ->
              mapM_ (\e -> do
                       v <- evalR rts Map.empty e
                       b <- bagForSTM rts n
                       outSTM b v)
                 es)
          (Map.toList initial)
    -- Idle-exempt machines (§11.12) are not counted: they never
    -- terminate, and must not keep the run alive.
    writeTVar (rtsLive rts) (length (filter (not . machIdle) machines))
  -- Resolve each machine's bag up front: the bag is fixed for the
  -- machine's lifetime (its declaration site named it), and resolving
  -- once keeps the loop from re-reading the bag map on every re-arm.
  mbags <- mapM (\m -> do
                    b <- atomically (bagForSTM rts (machBag m))
                    pure (m, b))
                machines
  runner <- async (effectRunner rts)
  mths   <- mapM (\(m, b) -> async (machineThread rts b m)) mbags
  atomically $ do
    live <- readTVar (rtsLive rts)
    ex   <- readTVar (rtsExit rts)
    check (live <= (0 :: Int) || isJust ex)
  -- Shutdown (§11.12): machines first (no new bundles after this) —
  -- both the startup threads and any the @import@ effect spawned
  -- mid-run (§13.13) — then ask the runner to stop; it finishes the
  -- current bundle and drains the queue, so every queued bundle is
  -- fully executed before runProgram returns.
  --
  -- The run-alive check above counts only non-idle machines (§11.12):
  -- the default Error machine never terminates and must not keep the
  -- run alive. But cancellation must not race its final grab: if an
  -- error tuple is sitting in an idle machine's bag, we wait here
  -- until the bag drains (the parked machine's grab is already woken
  -- — it removes the tuple and queues its panic bundle; the runner
  -- sets @rtsExit@ when it drains that bundle, which passes the
  -- check). Only once every idle bag is empty is cancellation honest:
  -- there is nothing left for an idle machine to process.
  let idleBags = map machBag (filter machIdle machines)
  atomically $ do
    live <- readTVar (rtsLive rts)
    ex   <- readTVar (rtsExit rts)
    idleEmpty <- and <$> mapM (\n -> do
                                 b <- bagForSTM rts n
                                 null <$> readTVar (bagTVar b))
                              idleBags
    check (live <= (0 :: Int) && idleEmpty || isJust ex)
  mapM_ cancel mths
  extras <- readTVarIO (rtsExtra rts)
  mapM_ cancel extras
  atomically (writeTVar (rtsStop rts) True)
  wait runner
  bag   <- bagContents (rtsBag rts)
  bags  <- traverse bagContents =<< readTVarIO (rtsBags rts)
  bytes <- readTVarIO (rtsBytes rts)
  ex    <- readTVarIO (rtsExit rts)
  pure (RunResult (fromMaybe ExitSuccess ex) bag bags bytes)
