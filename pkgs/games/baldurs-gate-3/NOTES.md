# Baldur's Gate 3 — investigation notes

Two independent bugs stood between this title and working; both are fixed. Neither was a packaging problem in
the usual sense, and the second turned out to be a wine defect that affects any x64 application.

## 1. Every script path resolved to the drive root (`workingDir = "bin"`)

**Symptom.** The game died at the end of the loading screen — engine state `LoadModule`, ~95 % of the progress
bar, exit code 3 (the MSVC CRT's `abort()`).

**Diagnosis.** The engine derives its khonsu path roots as `<cwd>/../Data/...`. Dumped live out of its own
base-path global while running:

    workingDir = <game root>    ->  "C:/game/../Data/Scripts"   == C:\Data\Scripts   (drive root, wrong)
    workingDir = "bin"          ->  "C:/game/bin/../Data/Scripts" == C:\game\Data\Scripts   (correct)

A normal install runs the game from its own `bin` directory, so `bin/../Data` lands correctly. propnix's
default cwd (the game root) collapsed *every* root to `C:\`. Consequence: the VFS key built from that root
never matched a pak entry, so the engine read the pak's entire file list and then issued **zero** reads for any
`Scripts/**` entry — verified by instrumenting `ReadFile` to log byte ranges. The Lua definitions were
therefore missing, and script code failed at runtime (khonsu error `0x10D`).

**Fix.** `workingDir = "bin";` — one line, and it repairs all the roots at once (`Data`, `Public`, `Mods`,
`Projects`, `Localization`, `Scripts`).

**Dead end worth recording:** materialising the script trees as loose files on disk *appears* to work, because
it puts files exactly where the mis-computed root points. That route cost 831 extracted files across two
derivations before the real cause was found, and it merely moved the failure (`LoadModule` → `LoadLevel` →
savegame load) as each newly reachable subsystem hit the same broken root. If script content looks
unreachable, check the roots before extracting anything.

Also falsified along the way: position of the entries inside the archive (script entries span 10 %–99 % of
`Shared.pak`), memory mapping (the engine never maps paks — plain `ReadFile` only), file-list truncation (the
full list is read), uncompressed entries, and `crc32`/AES hash divergence (the binary contains none of those
instructions).

## 2. wine destroyed a rethrown exception object mid-flight

**Symptom.** With the roots fixed, Anubis behaviour scripts finally loaded — and the game then faulted during
`LoadLevel` on both a new game and a save load: `Unhandled page fault on read access to 0000000000000018 at
address 00000001410B4966`.

**Diagnosis — this is what the guest unwinder was built for.** winedbg cannot unwind x86_64 guest frames from
the ARM64 side (`dwarf2_virtual_unwind mismatch in cpu`), and heuristic stack scanning produced false frames
that led to two wrong conclusions. `tools/unwind-guest-stack.py` walks the real Microsoft x64 unwind data
(`.pdata` + `UNWIND_INFO`) from a captured guest register file and stack slice, giving exact frames:

    #0  0x1410b4966   container grow          <- faults, rbx = NULL
    #1  0x1410b3abe   thunk
    #2  0x1410aac79   noreturn error-report
    #3  0x1450153fa   ls.anubis.game.Entity
    #-- 0x6ffff51741dc  [outside the image]   <- vcruntime140_1: wine's C++ EH

Frame #3 being called *by wine* identified it as a catch funclet, which reframed the whole problem from "game
bug" to "exception handling". Logging wine's own EH then proved use-after-destroy by address identity — the
object at throw, the object wine destroyed, and the object the funclet dereferenced were all the same pointer,
with `[obj+0x18]` cleared by the destructor:

    _CxxThrowException  thrown_obj=0x…E030
    call_catch_handler  0x14502E4E0            <- inner catch runs, rethrows
    cxx_rethrow_filter  bare_rethrow=1         <- rethrow IS detected
    cxx_catch_cleanup   rethrow=0              <- but the flag is not set yet: destroys the object
    __DestructExceptionObject obj=0x…E030
    call_catch_handler  0x1450153C0            <- outer catch dispatched on freed memory -> fault

**Fix.** `emulators/wine-hangover/patches/0005-msvcrt-mark-rethrow-in-filter.patch`. `cxx_rethrow_filter`
recognises a bare `throw;` and returns `EXCEPTION_EXECUTE_HANDLER`, but `ctx->rethrow` was only set in the
`__EXCEPT` body — which runs after the unwind, by which point `cxx_catch_cleanup` has already destroyed the
exception. Filters run before unwinding, so the patch sets the flag there. Not arch-specific in principle: any
x64 application that rethrows from a nested catch can hit it, so it is worth sending upstream.

## Verified working

Menu, new game, intro cinematic, gameplay, autosave, and a savegame round-trip (save then load). Clean exits,
no page faults. `graphics` deliberately stays on the tree default (winewayland): an A/B measured 18 min clean
on wayland vs 17 min clean on x11, with zero swapchain recreations, so the Skyrim SE-style x11 override is
**not** needed here.

## Open / not investigated

* `--logPath` is load-bearing for diagnosis and is kept in the spec: the engine writes `gold.<timestamp>.log`
  into the game directory, which is read-only here, so without it `CreateFileW` fails with
  `STATUS_ACCESS_DENIED` and the engine runs with no log sink at all.
* Performance under FEX has not been measured.
* A Steam row could be pinned for comparison (the title is owned on both stores).
* Unrelated latent wine bug found en route, not needed for this game: `_FindAndUnlinkFrame` dereferences
  `cur->next` before its NULL check, so an empty frame list crashes where the author intended a "frame not
  found" ERR.
