# Baldur's Gate 3

Larian's Baldur's Gate 3 (Divinity 4.0 engine) runs from its GOG Windows build under wine: FEX +
ARM64EC on aarch64, native wine on x86_64. Two independent defects stand between the title and a
working run, neither a packaging problem in the usual sense: the engine's data roots collapse to the
drive root unless the cwd is `bin`, and wine's C++ exception handling destroys a rethrown exception
object (a wine defect that can hit any x64 application). This doc records the evidence for both,
what verified play covers, the logging setup, and what remains open. HDR and the D3D11-exe choice
are in docs/research/dxvk-hdr-under-winewayland.md, the store payloads in
docs/research/multi-store-payloads.md.

## 1. Script paths resolve to the drive root unless cwd = `bin`

**Symptom.** The game dies at the end of the loading screen: engine state `LoadModule`, ~95 % of the
progress bar, exit code 3 (the MSVC CRT's `abort()`). Script code fails at runtime with khonsu error
`0x10D`.

**Mechanism.** The engine derives its khonsu path roots as `<cwd>/../Data/...`. Dumped live out of
the game's own base-path global while it runs:

    workingDir = <game root>  ->  "C:/game/../Data/Scripts"      == C:\Data\Scripts
                                                                   (drive root, wrong)
    workingDir = "bin"        ->  "C:/game/bin/../Data/Scripts"  == C:\game\Data\Scripts
                                                                   (correct)

A normal install runs the game from its own `bin` directory, so `bin/../Data` lands correctly.
propnix's default cwd (the game root) collapses every root (`Data`, `Public`, `Mods`, `Projects`,
`Localization`, `Scripts`) to `C:\`. The VFS key built from that root then never matches a pak
entry: the engine reads the pak's entire file list and issues zero reads for any `Scripts/**` entry
(measured by instrumenting `ReadFile` to log byte ranges). The Lua definitions are therefore missing
and script code fails.

**Fix.** `workingDir = "bin";` repairs all the roots at once.

**Trap: extracting loose files.** Materialising the script trees as loose files on disk appears to
work, because it puts files exactly where the mis-computed root points. It only moves the failure
(`LoadModule` → `LoadLevel` → savegame load) as each newly reachable subsystem hits the same broken
root; 831 extracted files across two derivations do not get past it. If script content looks
unreachable, check the roots before extracting anything.

**Not the cause:** the position of the entries inside the archive (script entries span 10 %–99 % of
`Shared.pak`); memory mapping (the engine never maps paks, it uses plain `ReadFile`); file-list
truncation (the full list is read); uncompressed entries; and `crc32`/AES hash divergence (the
binary contains none of those instructions).

## 2. wine destroys a rethrown exception object mid-flight

**Symptom.** With the roots fixed, the Anubis behaviour scripts load, and the game then faults
during `LoadLevel`, on a new game and on a save load alike:

    Unhandled page fault on read access to 0000000000000018 at address 00000001410B4966

The cause and the fix are in
emulators/wine-hangover/patches/0005-msvcrt-mark-rethrow-in-filter.patch (it sets `ctx->rethrow` in
`cxx_rethrow_filter`, which runs before the unwind). What follows is how the fault is attributed to
wine.

**Exact guest frames.** winedbg cannot unwind x86_64 guest frames from the ARM64 side
(`dwarf2_virtual_unwind mismatch in cpu`), and heuristic stack scanning produces false frames that
point at wrong conclusions. `tools/unwind-guest-stack.py` walks the real Microsoft x64 unwind data
(`.pdata` + `UNWIND_INFO`) from a captured guest register file and stack slice:

    #0  0x1410b4966   container grow          <- faults, rbx = NULL
    #1  0x1410b3abe   thunk
    #2  0x1410aac79   noreturn error-report
    #3  0x1450153fa   ls.anubis.game.Entity
    #-- 0x6ffff51741dc  [outside the image]   <- vcruntime140_1: wine's C++ EH

Frame #3 being called by wine identifies it as a catch funclet, which makes this an
exception-handling fault rather than a game bug.

**Use-after-destroy by address identity.** Logging wine's own EH shows the object at throw, the
object wine destroys and the object the funclet dereferences are the same pointer, with `[obj+0x18]`
cleared by the destructor:

    _CxxThrowException  thrown_obj=0x…E030
    call_catch_handler  0x14502E4E0            <- inner catch runs, rethrows
    cxx_rethrow_filter  bare_rethrow=1         <- rethrow IS detected
    cxx_catch_cleanup   rethrow=0              <- but the flag is not set yet: destroys the object
    __DestructExceptionObject obj=0x…E030
    call_catch_handler  0x1450153C0            <- outer catch dispatched on freed memory -> fault

A related latent wine bug, not needed for this game: `_FindAndUnlinkFrame` dereferences `cur->next`
before its NULL check, so an empty frame list crashes where the author intended a "frame not found"
ERR.

## Verified play

All on the GOG payload.

- `bin/bg3.exe` (native Vulkan): main menu, new game, intro cinematic, gameplay, autosave (the
  engine state machine reaches Running/Save) and a savegame round-trip (save, then load). Two
  ~18-minute sessions exit cleanly with no page faults. The FEX/ARM64EC soak tests are all on this
  exe.
- `bin/bg3_dx11.exe` (D3D11 → DXVK, the default exe): verified on x86_64 on 2026-09-01; it launches
  and plays, and with `DXVK_HDR=1` the swapchain presents HDR10_ST2084 on an HDR Wayland session
  (Hyprland 0.56, Mesa 26.1, RADV). DXVK is already the aarch64 d3d default, but this exe has no
  long session recorded on aarch64; re-verify there before trusting one.

## `graphics`: winewayland stays

The tree default (winewayland) is correct for this title, and there is no x11 override. A/B on
`bg3.exe`:

    wayland   18 min, clean exit, 0 faults, 0 swapchain recreations
    x11       17 min, clean exit, 0 faults

The fullscreen-Vulkan swapchain-recreation NULL-deref that forces x11 for Skyrim Special Edition
does not reproduce here.

## Logging: `--logPath`

The engine writes its log as `gold.<timestamp>.log` into the game directory, which is read-only
under propnix, so `CreateFileW` fails with `STATUS_ACCESS_DENIED` and the engine runs with no log
sink at all. `--logPath <dir>` redirects it, as two separate argv entries (the option parser does
not accept `=`):

    exeArgs = [
      "--logPath"
      "C:\\users\\propnix\\AppData\\Local\\Larian Studios\\Baldur's Gate 3"
    ];

That directory is already bound writable (to `$PROPNIX_STATE/larian`), so the log is host-visible.
It is load-bearing for diagnosis and stays in the package beyond debugging: a user reporting a bug
has a real log.

## Open

- Performance under FEX is not measured.
- The Steam build is pinned beside the GOG one for the same platform: four depots of app 1086940
  (1419652 `bin/`, 1419653 `Launcher/`, 1086941 `Data/`, 1086942 `Data/Localization/language.lsx`),
  reachable with `.apply { fetcher = "steam"; }`. It has never been launched; everything above is
  measured on the GOG tree.
- The Galaxy stub row targets `bin/Galaxy64.dll` on the GOG fetcher, a path not yet checked against
  the GOG tree.
