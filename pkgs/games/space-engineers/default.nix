# Space Engineers (Steam, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on
# x86_64 natively. Keen Software House's VRage 2 engine: a MANAGED .NET Framework game (Sandbox.*/VRage.*
# assemblies, Steamworks.NET, EmptyKeys UI, Roslyn for in-game scripting) driving native D3D11 through
# SharpDX, with Havok and RecastDetour as native DLLs beside it. ARCH-AGNOSTIC: this spec is identical on
# both hosts; mkApp + the scope pick the arch-appropriate emulator set and the SAME Windows payload (a
# content-addressed FOD) is shared across arches.
#
# Steam-only, Windows-only: app 244850 has one content depot pinned here (244851), so the fetch matrix has
# exactly that pair and any other selection is a legible mkApp error. Requires an account that owns the
# title: `propnix cred add steam`.
#
# ── THE CLR THIS TITLE NEEDS NOW SHIPS IN THE PREFIX (was: OPEN BLOCKER) ───────────────────────────────
# `Bin64/SpaceEngineers.exe` is a PURE MANAGED assembly — 2 sections (.text + .rsrc), NO import table at
# all, `file` reports "Mono/.Net assembly", and its CLR header names runtime v4.0.30319; the sidecar
# `SpaceEngineers.exe.config` pins `<supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.6.1"/>`.
# Starting it therefore requires a CLR, and this tree used to ship NONE — neither `share/wine/mono` in
# emulators/wine-hangover nor `drive_c/windows/mono` in the realised wine-prefix-lower — so the process
# was expected to exit at CLR startup before reaching the renderer.
#
# That gap is closed one level down, where it belongs (every managed title benefits, not just this one):
# emulators/wine-mono.nix pins Wine Mono 11.2.0 — the exact `WINE_MONO_VERSION` the pinned wine 11.15
# hardcodes — and emulators/wine-prefix-lower.nix drops it at `C:\windows\mono\mono-2.0`, the first path
# `mscoree`'s `get_mono_path()` probes, plus the .NET 4.x NDP version-detection keys that satisfy this
# exe's v4.6.1 `supportedRuntime`. Verified in the built prefix by compiling and RUNNING a managed exe
# under it (Environment.Version = 4.0.30319.42000). The tree-wide `mscoree = "b"` is unchanged and
# correct: the builtin mscoree IS the CLR host, and it is now backed by a real runtime.
#
# The CLR works: the game's own log opens with `Environment.Version: Mono 6.13.0 (tarball)` and
# `Environment.CommandLine: C:\game\Bin64\SpaceEngineers.exe`, i.e. managed `Main` is executing.
# kerbal-space-program remains the precedent for the OTHER managed shape (Unity's BUNDLED Mono, which
# needs no prefix runtime — only a writable, non-overlay `Managed` dir).
#
# ── LAUNCHED. RENDERS. (x86_64-linux) ──────────────────────────────────────────────────────────────────
# Run on 2026-09-03 against a headless sway (`WLR_BACKENDS=headless` + `swaymsg create_output`) on an
# AMD RX 7900 XTX, with `iron-lung` as the known-good control in the same harness. Space Engineers
# reaches its MAIN MENU and keeps drawing: the game log shows `MyGuiScreenMainMenu MyGuiScreenBase
# .LoadContent` ~36 s after launch and then `GUI Stats: Update … Draw …` for as long as it is left alone;
# `nix run` returns 137 (still alive when the timeout kills it), never a crash. A `grim` capture of the
# compositor output is a fully rendered 1920x1080 VRage GUI frame. DXVK reports the adapter to the engine
# correctly — the log's `AdapterInfo` reads `AMD Radeon RX 7900 XTX (RADV NAVI31) + DISPLAY1`,
# `feature_level 11.1: True`, `Multithreaded rendering supported = True`.
#
# What is on screen at that point is SE's own first-run stack — `MyGuiScreenGDPR` and
# `MyGuiScreenWelcomeScreen` sit ON TOP of the loaded main menu — and they were not dismissed, because
# the harness has no real input devices: a headless sway seat reports `capabilities: 0, devices: []`, and
# while a transient `wlr_virtual_pointer` is enough for VRage to show the OK button's hover state and its
# "Proceed" tooltip, no synthetic button press or keystroke ever activated a control. That is a property
# of the test rig, not of the title — the same rig drives the control's menu fine, and a real session has
# real devices. Getting PAST those two dialogs is therefore the one step still unobserved here.
#
# THREE THINGS HAD TO BE FIXED TO GET THIS FAR, all verified by running:
#   1. `lib/backends/wine/defaults.nix`: `dosdevices` was a READ-ONLY bind, which turns wine mountmgr's
#      drive-letter retry loop into an infinite one and wedges every mountmgr IOCTL in the prefix. This
#      title hung there — main thread in `NtQueryVolumeInformationFile` — before drawing anything. Not a
#      Space Engineers bug; see the long comment on that mount row.
#   2. `dllOverrides.d3dcompiler_47 = "n,b"` below: wine's builtin HLSL compiler cannot compile this
#      game's shaders at all.
#   3. `exeArgs = [ "-skipintro" ]` below: the intro video cannot be decoded and never ends.
#
# LOAD MATTERS. One launch under a load average of ~20 (many concurrent wine prefixes) died during
# cold-start; the identical build at load ~3 reached the menu. Re-run before reading a single failure as
# a regression.
#
# Everything below this line that is NOT marked as measured is derived from the pinned payload (directory
# layout, PE headers and resources, the assemblies' string tables) and from the framework's documented
# mechanisms.
#
#   nix run .#space-engineers --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
}:
mkApp (
  { config, ... }:
  {
    pname = "space-engineers";
    appid = "space-engineers";
    name = "Space Engineers";

    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;

    # The ONLY executable in Bin64 (verified: `Bin64/*.exe` is exactly this one file — there is no separate
    # launcher stub and no dedicated-server exe in this depot; `Tools/` holds two unrelated audio-converter
    # exes). Steam's own `Bin64/install_script_SpaceEngineersGame_244851.vdf` names the same path for its
    # one-time cold-start task: `%INSTALLDIR%\Bin64\SpaceEngineers.exe -coldstart`.
    exe = "Bin64/SpaceEngineers.exe";

    # cwd = the exe's own directory, NOT the game root (propnix's default). Evidence: the engine's asset
    # literals in SpaceEngineers.Game.dll are written relative to `Bin64`, e.g.
    # `..\Content\Textures\Logo\splashscreen.png` — and `Content/` sits at the game ROOT, one level above
    # `Bin64/`, so those `..\` paths only resolve with the base inside `Bin64`. Also matches how Steam
    # starts it (the install script's `%INSTALLDIR%\Bin64\` process path).
    # MEASURED: the running game logs `Environment.CurrentDirectory: C:\game\Bin64` and then loads all of
    # `C:\game\Content\…` through it. `.apply { workingDir = null; }` reverts to the game root.
    workingDir = "Bin64";

    # WITHOUT THIS THE GAME IS A BLACK SCREEN FOREVER. `MyGuiScreenIntroVideo` is pushed before the main
    # menu and plays `Content/Videos/*.wmv` — WMV3/VC-1 in an ASF container — through DirectShow. Under
    # this wine that graph cannot be built: the run prints
    #     -2147220985  Can't connect WM ASF Reader and WMVideo Decoder DMO
    # (0x80040217 = VFW_E_CANNOT_CONNECT), and the screen then never completes. MEASURED (x86_64-linux,
    # headless sway, RX 7900 XTX): a 300 s run sat on a black 1920x1080 window the whole time — the engine
    # was healthy underneath (`GUI Stats: Update … Draw …` every 30 s, DXVK swapchain up), it simply waits
    # on a video that will never finish. With `-skipintro` the same build reaches `MyGuiScreenMainMenu
    # MyGuiScreenBase.LoadContent` about 35 s in and renders.
    # `-skipintro` is the game's OWN switch (a literal in Sandbox.Game.dll alongside -coldstart/-nosplash),
    # so this is asking the title for a supported path, not defeating it. Drop this line the day the video
    # decodes — the flag only skips the intro, so it is also the right thing to keep if a user prefers no
    # intro. NOT `-nosplash`: the WinForms splash works fine here.
    exeArgs = [ "-skipintro" ];

    # Full-colour icon auto-extracted from the exe's PE resources (the `icon.auto` default): the resource
    # directory of SpaceEngineers.exe carries RT_ICON (0x3) + RT_GROUP_ICON (0xe) in a ~52 KB .rsrc, which
    # matches the 48 KB `Bin64/SpaceEngineers.ico` shipped beside it, so extraction has something to find.
    icon.auto = true;

    # NOT `online = false`. Space Engineers is a multiplayer game and the depot ships the whole online
    # stack: Steamworks.NET.dll + steam_api64.dll, VRage.EOS.dll + EOSSDK-Shipping.dll (Epic Online
    # Services — the exe's string table even carries https://retail.epicgames.com/), VRage.Mod.Io.dll and a
    # workshop browser. Unsharing the network namespace would break all of it, which is the case the
    # option's default is written for. A single-player-only user can opt in: `.apply { online = false; }`.

    # The game's shipped Steamworks copy sits beside the exe at `Bin64/steam_api64.dll`, and the managed
    # side reaches it by P/Invoke through Steamworks.NET.dll — which resolves the library by NAME through
    # the ordinary PE loader, i.e. the exe's own directory first, exactly like a static import. On wine the
    # mechanism is UNION-REPLACEMENT: steam.emu mirrors the gbe_fork PE shim at this relative path inside
    # its settings tree, which ranks above the payload in the game-dir overlay, so the dll the loader maps
    # IS the shim with its settings beside it. Declaring the path is also mandatory — mkApp refuses
    # steam.emu on wine with no `.dll` path rather than ship a silently-inert shim.
    # MEASURED: the shim is the copy that gets loaded and the game accepts it —
    # `Service.IsActive: True`, `Service.OwnsGame: True`, `Service.IsOnline: False` in the game log.
    #
    # No `dlc.available`: only the base content depot is pinned, so the entitlement list is emitted empty
    # with an explicit `unlock_all=0` — "own nothing", never the upstream default of "own everything".
    steam.emu.libPaths = [ "Bin64/steam_api64.dll" ];

    # Save/state: VRage keeps the user's world under %AppData%\<GameNameSafe>. The name comes out of
    # SpaceEngineers.Game.dll's per-game settings block, where the literals sit adjacent in the metadata:
    # "Space Engineers" (the display name) immediately followed by "SpaceEngineers" (the filesystem-safe
    # one), alongside `SpaceEngineers.ico` and `SpaceEngineers-Dedicated.cfg`; the assemblies also carry
    # the expected subdirectory names as literals — Saves, Blueprints, Mods, Screenshots, Storage,
    # ShaderCache. On wine `dst` is joined onto the wine profile home (drive_c/users/propnix/), so
    # %AppData% is `AppData/Roaming`.
    # MEASURED — this is the right target. The game logs the exact path it opens
    # (`Path: C:\users\propnix\AppData\Roaming\SpaceEngineers\SpaceEngineers.cfg`) and a run to the main
    # menu fills the bound directory with `SpaceEngineers.cfg`, `Saves/`, `Blueprints/`-siblings
    # (`Mods/`, `Promo/`, `WorkshopBrowser/`), the per-run `SpaceEngineers_*.log` and
    # `VRageRender-DirectX11_*.log`, `Minidump.dmp` on a crash, and the shader/JIT scratch
    # (`ShaderCache2/`, `ProfileOptimization/`, `cache/`, `temp/`).
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "AppData/Roaming/SpaceEngineers";
      }
    ];

    wine = {
      # HLSL AT RUNTIME NEEDS MICROSOFT'S COMPILER, NOT WINE'S. VRage compiles shaders at startup through
      # `D3DCompile` (SharpDX.D3DCompiler → d3dcompiler_47), and its shaders `#include
      # "D3DX_DXGIFormatConvert.inl"` — Microsoft's header, which picks its HLSL body vs. its C++ body with
      #     #if HLSL_VERSION > 0   … HLSL typedefs …   #else   #ifndef __cplusplus
      #     #error C++ compilation required   #endif   #include <float.h>   #include <xnamath.h>
      # (Content/Shaders/D3DX_DXGIFormatConvert.inl:202/224). `HLSL_VERSION` is PREDEFINED BY THE COMPILER.
      # Wine's builtin d3dcompiler_47 is vkd3d-shader, which does not define it — grepped: the string
      # "HLSL_VERSION" appears 0 times in either builtin (lib/wine/{i386,x86_64}-windows/d3dcompiler_47.dll)
      # and once in the depot's own Bin64/d3dcompiler_47.dll. So under the builtin every shader takes the C++
      # branch and dies on the #error plus two host headers that do not exist.
      # MEASURED (x86_64-linux, sway headless, before this line): `Include not found:
      # C:\game\Content\Shaders\float.h` / `xnamath.h`, then
      # `D3DX_DXGIFormatConvert.inl:226:1: E4001: Error directive: C++ compilation required`,
      # `Failed to compile Primitives/Lines.hlsl @ profile vs_5_0` → `MyRender11.InitSubsystems` throws
      # `MyRenderException`, `CreateDevice failed: Disposing Device`, and VRage retries down to its
      # "Lowest res fallback" 640x480 device and fails there identically. The D3D11 device and the DXVK
      # swapchain themselves were fine — this is purely the shader front-end.
      #
      # The depot ships the real thing next to the exe (Bin64/d3dcompiler_47.dll, 4 173 928 bytes), which is
      # exactly where the loader looks first for the exe's own directory — but only once the load order says
      # native. "n,b" not "n": builtin stays as the fallback so a payload that ever lacks the file degrades
      # to today's behaviour instead of failing to start.
      dllOverrides.d3dcompiler_47 = {
        value = "n,b";
        reason = "native: the depot ships Microsoft's d3dcompiler_47 beside the exe, and only it predefines HLSL_VERSION — wine's vkd3d-shader builtin does not, so D3DX_DXGIFormatConvert.inl takes its C++ branch and every runtime shader compile fails (measured).";
      };

      # THE GAME WRITES INSIDE ITS OWN INSTALL DIRECTORY, which is a read-only store path here. `drive_c/game`
      # is bound read-only (and becomes a read-only multi-lower overlay once steam.emu contributes its
      # settings tree), so give the one subtree that needs it a PERSISTENT COW overlay instead: reads come
      # straight from the store payload, writes land in the app's cache dir. Same mechanism as KSP's
      # writable game dir, scoped to one child row so the rest of the tree stays immutable.
      #
      # WHY THIS SUBTREE. The depot ships `TempContent/` as a set of EMPTY scratch directories — cache/,
      # temp/, Mods/, ShaderCache/, ShaderCachePdb/, WorkshopBrowser/ — plus two files that are plainly
      # RUNTIME OUTPUT accidentally captured into the build: `ProfileOptimization/Startup.profile` (the
      # .NET startup JIT profile, written by ProfileOptimization.SetProfileRoot) and a stray
      # `VRageRender-DirectX11_20260811_175209248.log`. Empty directories in a content depot exist to be
      # written into. VRage.Platform.Windows.dll independently declares a `tempContent` path parameter
      # (visible in its metadata), so the engine has an explicit notion of this location.
      # $PROPNIX_CACHE (not state, not saves) because everything named there is DERIVED — shader caches, a
      # JIT profile, extracted workshop mods — regenerable from the payload, and the cache dir is the one a
      # user can point at a fast, un-snapshotted filesystem.
      #
      # MEASURED, AND THE ANSWER IS "NOT ON THE PATH TO THE MENU". The thing this row was written against —
      # the game resolving its temp-content root HERE rather than under %AppData% — did not happen: across
      # every run to the main menu the overlay's upper (`$PROPNIX_CACHE/tempcontent`) came back EMPTY, while
      # the save bind filled with the identically-named scratch (`cache/`, `temp/`, `Mods/`,
      # `WorkshopBrowser/`, `ProfileOptimization/`, plus `ShaderCache2/`). So VRage's scratch root is
      # %AppData%\SpaceEngineers, which the save bind already covers.
      # KEPT ANYWAY, deliberately: an empty upper costs one overlay mount and nothing else (a COW overlay
      # with no writes is just the lower), and the measurement only covers launch → main menu — loading a
      # world and subscribing to workshop mods are untested, and those are exactly the paths the depot's
      # empty `TempContent/Mods` and `TempContent/WorkshopBrowser` were shipped for. Delete the row the day
      # a trace of those paths also comes back empty.
      mounts."drive_c/game/TempContent" = {
        type = "overlay";
        lower = "${lib.head config.payloads}/TempContent";
        upper = "$PROPNIX_CACHE/tempcontent";
        createIfNotExist = true;
      };
    };

    # NO d3d / graphics override, deliberately. VRage renders D3D11 via SharpDX (SharpDX.Direct3D11 /
    # .DXGI / .D3DCompiler beside the exe, and the exe's own error string "The current version of the game
    # requires a Dx11 card"), which is exactly what the tree default d3d=dxvk is for. MEASURED: both
    # defaults hold up — DXVK gives the engine a working D3D11 feature-level-11.1 device and a 1920x1080
    # swapchain on the winewayland surface, and the game renders through it. Add an override only with a
    # measurement.
    #
    # KNOWN, NOT FIXED HERE — VIDEO PLAYBACK. The engine's .wmv assets (the intro, and the animated main-menu
    # backgrounds `Content/Videos/Background0*.wmv`) do not decode: DirectShow cannot connect the WM ASF
    # Reader to the WMVideo Decoder DMO (0x80040217). `exeArgs = [ "-skipintro" ]` above steps around the one
    # place where that is FATAL; the menu backgrounds are merely absent. Fixing it belongs in the wine layer
    # (a WMV3/VC-1 path for winegstreamer), not in this file, so no per-title workaround is invented here.
  }
)
