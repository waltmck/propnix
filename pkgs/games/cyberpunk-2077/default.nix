# Cyberpunk 2077 (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK/vkd3d, on
# x86_64 natively. CD Projekt Red's REDengine 4, a D3D12-ONLY renderer (see below), so D3D goes
# game → vkd3d-proton (d3d12) → DXVK's dxgi (presentation) → Vulkan. ARCH-AGNOSTIC: this spec is identical
# on both hosts; mkApp + the scope pick the arch-appropriate emulator set, and the SAME Windows payload (a
# content-addressed FOD) is shared across arches. Windows-only title (CDPR ships no Linux build), so the
# payload is the pinned GOG Galaxy build fetched by fetchGogGalaxyBuild (D15) — the game tree directly, no
# InnoSetup.
#
#   nix run .#cyberpunk-2077 --extra-sandbox-paths /propnix=/var/lib/propnix          # base game
#   nix run '.#cyberpunk-2077.withDlc [ "phantom-liberty" ]'                          # + the expansion
#
# ── WHICH EXECUTABLE, AND WHY NOT THE LAUNCHER ─────────────────────────────────────────────────────────
# `goggame-1423049311.info` lists exactly two play tasks:
#   isPrimary=true              REDprelauncher.exe        category=launcher   1.6 MB
#   isPrimary=false isHidden    bin\x64\Cyberpunk2077.exe category=game      60   MB
# and `launcher-configuration.json` at the payload root says the same thing in one line:
#   { "platform": "gog", "executablePath": "bin\\x64\\Cyberpunk2077.exe", "gameId": "cyberpunk2077" }
#
# We launch the game binary DIRECTLY. REDprelauncher.exe is not the launcher, it is the launcher's
# BOOTSTRAPPER: it is a 1.6 MB Qt5/Poco/sqlite stub (PE imports: Qt5Core, Qt5Network, PocoData,
# PocoDataSQLite, sqlite3) whose whole job is to install `REDlauncher-4.2.0.4.msi` — 687 MB, sitting right
# next to it at the payload root — into `%LOCALAPPDATA%\Programs\CD Projekt Red\REDlauncher` (the path the
# .info play task declares as an `additionalPaths` filesystemPath) and then run THAT, which in turn spawns
# Cyberpunk2077.exe. Going through it would mean running an MSI install inside every wine prefix, carrying a
# 687 MB Electron-class launcher app, and then handing propnix a parent that spawns the game and exits —
# which trips the launcher's primary-child teardown (the same reason skyrim-se bypasses
# SkyrimSELauncher.exe and baldurs-gate-3 bypasses LariLauncher.exe). It buys nothing: the launcher's only
# hand-off to the engine is the exe path already spelled out in launcher-configuration.json.
#
# ONE GAME BINARY ONLY — there is no DX11/DX12 fork to choose between, unlike witcher-3. The whole payload
# holds five .exe files: bin/x64/Cyberpunk2077.exe, bin/x64/REDEngineErrorReporter.exe,
# bin/x64/CrashReporter/{CrashReporter,7za}.exe, and REDprelauncher.exe. Cyberpunk2077.exe imports NEITHER
# d3d11.dll NOR d3d12.dll statically (PE import table) — it loads D3D12 dynamically, which is what lets it
# fall back to the bundled `bin/x64/d3d12on7/` (d3d12.dll + d3d11on12.dll, the Windows-7 D3D12-on-11
# shim) — and it ships `bin/x64/D3D12/D3D12Core.dll`, the D3D12 Agility SDK redistributable. So: D3D12 is
# the only renderer, and on this stack that means vkd3d-proton. Nothing to pick, nothing to justify beyond
# naming the right file.
#
# CWD = THE PAYLOAD ROOT (propnix's default, `workingDir = null`), and that is deliberate rather than
# accidental: the GOG play task for this exe declares NO `workingDir`, so Galaxy runs it from the install
# root — whereas the witcher-3 tasks in the same .info format DO declare one (`bin/x64_dx12`). The absence
# is the statement. REDengine resolves `archive/pc/`, `r6/`, `engine/` relative to the game root.
{
  lib,
  mkApp,
  fetchGogGalaxyBuild,
}:
let
  versions = lib.importJSON ./versions.json;
in
mkApp {
  pname = "cyberpunk-2077";
  maintainers = [ "waltmck" ];
  appid = "cyberpunk-2077";
  name = "Cyberpunk 2077";

  fetchInfo = versions.fetchInfo;
  exe = "bin/x64/Cyberpunk2077.exe";

  # Offline by construction: the launcher unshares a NETWORK NAMESPACE, so the guarantee is enforced by the
  # kernel rather than by trusting the title's bundled SDKs. Single-player title — and the two things in
  # this payload that WOULD talk to a network are exactly what we want held to loopback:
  #   * `https://marketing.live.cdpred.services` — a marketing/telemetry endpoint string in the exe, sitting
  #     next to `https://regulations.cdprojektred.com/privacy_policy` and a "third-party" consent token.
  #   * the GOG Galaxy SDK — the exe statically imports `bin/x64/REDGalaxy64.dll` and dispatches to
  #     `GameServicesGOG.dll` by name at runtime (the exe carries the sibling strings "GameServicesGOG.dll",
  #     "GameServicesEpic.dll", "GameServicesSteam.dll" — one store plugin per platform).
  # The exe DOES carry multiplayer-shaped symbols (`gsmMenuState_Multiplayer`, `GetMultiplayerWorlds`,
  # `DisableActionInMultiplayer`, ~66 `Multiplayer` strings in all). READ THEM AS SCAFFOLDING, not as a
  # feature: the shipped game has no multiplayer mode to reach — these are REDengine leftovers of the
  # cancelled multiplayer project, the same shape as the lone `Matchmaking` string in skyrim-se's exe.
  # That reading is INFERENCE from the strings plus the shipped game's menus, not something measured here.
  online = false;

  # DXVK's stand-in for the Windows "HDR on" display toggle — and it applies to a D3D12 title, which is
  # not obvious. vkd3d-proton ships ONLY d3d12.dll + d3d12core.dll; it has no dxgi of its own and exports
  # `IDXGIVkSwapChainFactory` (verified in the DLL's string table), i.e. it hands PRESENTATION to DXVK's
  # dxgi.dll, which is the DLL that reads `DXVK_HDR` (its strings: `DXVK_HDR`, `dxgi.enableHDR`,
  # `DxgiFactory::GlobalHDRState`, `VK_COLOR_SPACE_HDR10_ST2084_EXT`, `vkSetHdrMetadataEXT`). Both DLLs are
  # installed on this backend whenever `wine.d3d = dxvk` (the x86_64 default; propnix-launcher overlays
  # d3d9/10/11 + dxgi from DXVK and d3d12/d3d12core from vkd3d), so the D3D11 knob is the D3D12 knob.
  # WHY it is needed at all: wine writes no EDID into the registry under winewayland, so DXVK's dxgi has
  # nothing to auto-detect from and NEVER reports HDR on its own (see baldurs-gate-3 / no-mans-sky). Made
  # concrete, because the two `err:` lines in every run are this and nothing worse: the prefix's monitor key
  # `HKLM\System\ControlSet001\Enum\DISPLAY\Default_Monitor\0000&0000\Device Parameters` holds
  # `"BAD_EDID"=hex:` — EMPTY, which is wine's marker for "the display driver gave me no EDID", and it is
  # structural under Wayland (no protocol exposes EDID to clients). DXVK wants a value named `EDID` and
  # parses HDR capability out of it with a statically linked libdisplay-info (`di_edid_cta_*`,
  # `di_cta_data_block_get_hdr_static_metadata`, `di_cta_data_block_get_colorimetry` are all in dxgi.dll),
  # so it logs `readMonitorEdidFromKey: Failed to get EDID reg key size` then
  # `DXGI: Failed to parse display metadata + colorimetry info, using blank.`
  # TRIED AND IT DOES NOT WORK, so nobody re-runs it: seeding the HOST's real EDID into that exact key via
  # `wine.systemReg."System\\CurrentControlSet\\Enum\\DISPLAY\\Default_Monitor\\0000&0000\\Device Parameters".EDID`
  # (type REG_BINARY). The value lands correctly — it is visible as `"EDID"=hex:00,ff,ff,…` beside the
  # BAD_EDID in the baked `<appid>-system.reg` — and DXVK STILL logs the same failure, because wine's win32u
  # re-enumerates the display devices at runtime and DXVK reaches them through SetupAPI
  # (GUID_DEVCLASS_MONITOR → SetupDiOpenDevRegKey DIREG_DEV), not through the baked instance. A baked hive
  # cannot win that race, and `system.reg` is a READ-ONLY bind so nothing can rewrite it at runtime either.
  # Safe on an SDR session: the real Vulkan surface offers no HDR10 colorspace, so the swapchain degrades
  # to sRGB rather than rendering PQ into it.
  # WHAT IS AND IS NOT VERIFIED (x86_64, 2026-09-03, Hyprland session on an Odyssey G80SD in HDR —
  # `hyprctl monitors` reports currentFormat XRGB2101010, colorManagementPreset hdredid):
  #   * the presentation path this row targets IS the live one. The rendering run logs
  #     `vkd3d-proton:dxgi_vk_swap_chain_init: Creating swapchain (3840 x 2160), BufferCount = 3` and then
  #     `dxgi_vk_swap_chain_recreate_swapchain_in_present_task: Got 4 swapchain images` — i.e. vkd3d's
  #     IDXGIVkSwapChainFactory swapchain driving DXVK's dxgi, exactly the DLL that reads DXVK_HDR.
  #   * the var reaches the process: it is baked into the config's `seal.setEnv` (DXVK's scrub list is
  #     WINE*/FEX_*/BOX64_*/LD_* only), and DXVK's `DXGI: Failed to parse display metadata + colorimetry
  #     info, using blank.` is logged — the expected benign line when there is no EDID in the registry.
  #   * WHICH DLL DOES WHAT, from the shipped binaries (`strings` on both, 2026-09-03) — vkd3d NEVER READS
  #     THIS VAR, the row works through DXVK's dxgi and the interface between them:
  #       dxgi.dll (DXVK 2.7.1)      `DXVK_HDR`, `dxgi.enableHDR`, `dxvk::s_globalHDRState`,
  #                                  `DxgiVkFactory::{Get,Set}GlobalHDRState`, `DxgiFactory::GlobalHDRState`,
  #                                  `DxgiSwapChain::UpdateGlobalHDRState`, `DxgiSwapChain::SetColorSpace1`,
  #                                  `DxgiSwapChainDispatcher::SetColorSpace1` (the pass-through wrapper for a
  #                                  swapchain DXVK does not own), and the IDXGIVkSwapChainFactory UUID.
  #       d3d12core.dll (vkd3d 2.14.1)  ZERO hits for DXVK_HDR/enableHDR. It is the OTHER side:
  #                                  `IID_IDXGIVkSwapChainFactory`, `impl_from_IDXGIVkSwapChainFactory`,
  #                                  `dxgi_vk_swap_chain_{SetColorSpace,CheckColorSpaceSupport,
  #                                  supports_color_space,SetHDRMetaData}`, `VK_EXT_hdr_metadata`,
  #                                  `vkSetHdrMetadataEXT`, `Unhandled color space %#x. Falling back to sRGB.`
  #     So DXVK's dxgi holds the HDR POLICY and vkd3d holds the Vulkan swapchain that the colorspace is set
  #     on; SetColorSpace1 crosses from the first to the second over IDXGIVkSwapChainFactory.
  #   * STILL UNMEASURED, and do not assume either way: WHO initiates that SetColorSpace1 on this path.
  #     DXVK's state is explicitly GLOBAL (`s_globalHDRState`, `UpdateGlobalHDRState`, and a distinct
  #     `DXGI: Unsupported HDR metadata type (global): ` message), which is consistent with DXVK pushing
  #     HDR10 onto a new swapchain by itself — but it is equally consistent with DXVK_HDR only making
  #     IDXGIOutput6::GetDesc1 report an HDR display, leaving the game to opt in via its own HDR Mode row
  #     (Settings → Video, persisted in UserSettings.json under the saveBinds folder, off by default).
  #     Nothing here distinguishes them: vkd3d logs no colorspace at info, and DXVK's `Presenter: Actual
  #     swapchain properties` block never appears on this path because vkd3d owns the swapchain.
  #     TO SETTLE IT: `VKD3D_DEBUG=trace` and grep for `dxgi_vk_swap_chain_SetColorSpace` — whether it is
  #     called, and with what, is the whole answer. (Voluminous; filter as you go.)
  #     Menu-driven confirmation could NOT be automated: `wtype`'s zwp_virtual_keyboard input does not reach
  #     winewayland — the title screen ignored space/Return while the game kept animating — so the in-game
  #     toggle needs a human at the keyboard.
  env.DXVK_HDR = "1";

  # Full-colour icon auto-extracted from Cyberpunk2077.exe's PE resources (icon.auto default). Checked
  # rather than assumed: the exe's resource directory carries types [3, 6, 14, 16] — 14 is RT_GROUP_ICON,
  # which is what lib/icons/from-pe.nix pulls with `wrestool -t 14`. No symbolic icon vendored yet.

  # Save: REDengine writes savegames + UserSettings.json under the SAVED GAMES known folder,
  # `%USERPROFILE%\Saved Games\CD Projekt Red\Cyberpunk 2077` — NOT under Documents. Evidence from the exe's
  # own string table: a `Saved Games` literal sits in the file-IO region (beside the seek/read/write error
  # formats), and the two path components `CD Projekt Red` + `Cyberpunk 2077` are stored ADJACENT as
  # separate literals, which is the two-level join. The save-slot prefixes live in the same block
  # (`ManualSave-`, `AutoSave-`, `QuickSave-`, `EndGameSave-`, `PointOfNoReturnSave-`), as does
  # `UserSettings.json`. Wine's prefix already provides `Saved Games` in the profile (prefixLower ships it
  # for user `propnix`), and `drive_c/users` is a writable CoW overlay, so the bind lands on a real known
  # folder. Settings and saves share one directory here, so this is a single whole-folder bind (skyrim-se
  # shape), not the split baldurs-gate-3 needs.
  #
  # VERIFIED BY THE RUNNING GAME (x86_64, 2026-09-03): a boot to the title screen leaves a 171-byte
  # `user.gls` (the engine's `SLGR` settings blob) in `$PROPNIX_SAVE_DIR/cyberpunk-2077`, so this bind IS
  # the folder REDengine writes. Savegames and `UserSettings.json` are written later — `UserSettings.json`
  # only once settings are changed in-game — so their absence from a short boot means nothing.
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "Saved Games/CD Projekt Red/Cyberpunk 2077";
    }
  ];

  # ── DLC ── GOG carries DLC as SEPARATE dlcId depots INSIDE the base build (same productId, same buildId),
  # not as sibling apps the way Steam does — so each row here is another fetchGogGalaxyBuild against the
  # same pin with `dlcId` set, and the fetcher's own "a windows build must contain a .exe" sanity check is
  # skipped for it because a DLC tree is an OVERLAY, not a game. Enabled DLC union ABOVE the base payload at
  # mount time (builders/wine.nix `extraGameLowers` → a read-only multi-lower overlay), so an enabled DLC
  # costs no second copy of the 62 GB base.
  #
  # PURE UNIONS, VERIFIED against the realised trees: base ∩ phantom-liberty = 0 files, base ∩ redmod = 0,
  # phantom-liberty ∩ redmod = 0. Nothing here shadows a base file.
  #   * phantom-liberty (dlcId 1256837418) — the expansion, 24 GB in 29 files: `archive/pc/ep1/*.archive`
  #     plus `r6/cache/tweakdb_ep1.bin`. The base exe already knows about it (`ep1\quest\ep1.gamedef` sits
  #     beside `base\quest\cyberpunk2077.gamedef` in the exe's strings), which is consistent with
  #     presence-gated content — though whether the engine ALSO wants a Galaxy entitlement for it is NOT
  #     established here. If Phantom Liberty content stays locked with the tree mounted, that is the first
  #     thing to check, and it is the one place where neutralizing the store SDK could matter.
  #   * redmod (dlcId 1597316373) — NOT content: it is the modding TOOLKIT, 79 MB of
  #     `tools/redmod/bin/{redMod.exe,scc.exe}` + its libs, plus an empty `mods/.stub`. Staging the tree is
  #     necessary but NOT sufficient to actually mod: REDmod is normally activated by REDlauncher passing
  #     the engine a modded flag, and `redMod deploy` writes its output to `r6/cache/modded/mods.json`
  #     (both the `modded` and `modded/mods.json` tokens are in the exe) — which is INSIDE the game dir,
  #     read-only here. Making modding work would need the no-mans-sky treatment (a `wine.mounts`
  #     `drive_c/game` CoW overlay with a $PROPNIX_STATE upper) plus the flag in `exeArgs`; deliberately
  #     NOT done in this baseline, since neither the flag's exact spelling nor the deploy step has been run.
  #
  # Not part of the base package: `cyberpunk-2077` ships vanilla, so the default derivation does not depend
  # on the packager's entitlements. `.withDlc [ "phantom-liberty" ]` / `.withAllDlc` select.
  dlc.available = lib.mapAttrs (_: fetchGogGalaxyBuild) versions.dlc;

  wine = {
    # De-Galaxy, PARTIAL and deliberately so. Read the import graph before changing this:
    #   * Cyberpunk2077.exe statically imports `REDGalaxy64.dll` (14 MB, beside it in bin/x64) — CDPR's OWN
    #     rebuild of the Galaxy SDK. It is NOT stubable with emulators/galaxy-stub: its 28 exports are in
    #     the `redgalaxy` namespace (`?Init@api@redgalaxy@@YAXAEBUInitOptions@12@@Z`, …) while the stub
    #     exports the `galaxy` namespace (src/symbols64.txt: 34 symbols, zero `redgalaxy`), so binding the
    #     stub over it would leave 28 imports unresolved and the exe would not load at all. It also could
    #     not be bound: galaxyMounts sources `${galaxyStub}/${baseNameOf rel}`, and the stub package emits
    #     only Galaxy64.dll / Galaxy.dll / pops_api.dll. Adding a `redgalaxy` variant to symbols64.txt +
    #     a REDGalaxy64.dll output would be the fix, if it is ever wanted.
    #   * `bin/x64/Galaxy64.dll` (the real GOG SDK) is imported by exactly ONE thing in this payload —
    #     `GameServicesGOG.dll`, the store plugin the exe loads BY NAME at runtime — and it imports only 10
    #     symbols from it (Init, Shutdown, ProcessData, User, Friends, Apps, Stats, Utils,
    #     ListenerRegistrar, GetError, all `galaxy::api::`). ALL TEN are already in the stub's
    #     symbols64.txt, so the stub is a genuine drop-in here. Wired.
    # So the GOG plugin path is neutralized and CDPR's own SDK copy is not; what actually enforces the
    # offline guarantee for both is `online = false` above. That netns does NOT hang the SDK's probes:
    # measured under this exact wine inside `unshare -rn` (lo up), InternetGetConnectedState, IcmpCreateFile
    # + IcmpSendEcho, getaddrinfo and connect(2) all return in under 5 ms (connect fails, and note DNS still
    # RESOLVES — glibc reaches the host resolver over a unix socket, which the netns does not cut; the
    # guarantee is enforced at connect, not at name lookup).
    #
    # THIS ROW IS A NO-OP ON x86_64: backends/wine/defaults.nix takes `galaxyStub ? null` and drops EVERY
    # derived row when it is null, which is the case on the native-wine (x86_64) path. Confirmed in a
    # minidump's module list: `C:\game\bin\x64\Galaxy64.dll` loads at SizeOfImage 14,299,136 — the REAL 14 MB
    # SDK (payload file 14,208,648), not the stub. So on x86_64 the GOG stack runs for real, with no network,
    # AND THAT IS FINE — the game renders that way (see the render note below). Do NOT reach for `maskFiles`
    # here: masking `bin/x64/GameServicesGOG.dll` was tried, and MEASURED not to be the answer. It does what
    # it says (the dump then shows neither GameServicesGOG.dll nor Galaxy64.dll loaded — Galaxy64 has exactly
    # one importer and it is that plugin), but the game hung identically with it gone, and `+winsock` shows
    # GameThread still resolving `galaxy-log.gog.com` afterwards: the statically-imported REDGalaxy64.dll is
    # CDPR's own SDK copy and carries that path itself. Masking the plugin removes a DLL, not the GOG stack.
    # THIS ROW WAS A SILENT NO-OP ON x86_64 until 2026-09-03 — backends/wine/defaults.nix dropped every
    # derived row while `galaxyStub` was null there, so the REAL 14 MB SDK loaded and the de-Galaxy claim
    # above was fiction (confirmed in a minidump's module list: `C:\game\bin\x64\Galaxy64.dll` at
    # SizeOfImage 14,299,136). Closing that gap made the row bind for real, and it immediately HUNG the game
    # before `dxgi_vk_swap_chain_init` was ever reached — which is how the two defects in
    # emulators/galaxy-stub were found and fixed (see src/galaxy_stub.c; the big one is that the SDK's
    # sign-in is an ASYNC OPERATION the stub has to COMPLETE, by delivering IAuthListener::OnAuthFailure
    # from ProcessData, not merely answer "not signed in"). This title is the one that found them, because
    # its GameServicesGOG.dll is the strictest consumer in the repo.
    # VERIFIED END-TO-END WITH THE STUB ACTUALLY LOADED (x86_64, 2026-09-03) — and "actually" is checked,
    # not assumed, because a no-op row looks identical to a working one from outside: the Galaxy64.dll mapped
    # in the running game (read through `/proc/<pid>/root` into its mount namespace) is md5-identical to
    # `${galaxy-stub}/Galaxy64.dll`, 33,869 bytes, versus the payload's real 14,208,648-byte SDK. With that
    # bound the game creates its swapchain at 3840x2160, raises no unhandled exception, keeps GameThread out
    # of its parked `read()`, stops retrying `User()->SignInGalaxy` once OnAuthFailure is delivered, and
    # boots THROUGH the title screen's "PRESS ␣ TO CONTINUE" gate to the CD Projekt Red user agreement and
    # the main menu — i.e. the sign-in gate this stub used to hang on now clears on the stub alone.
    # If it ever hangs at the GOG init again, instrument a COPY of the stub (one logging thunk per export
    # and per vtable slot, per-interface identity) and run with `PROPNIX_WINEDEBUG=-all,+debugstr` — that is
    # what produced every finding above.
    galaxyStubDlls = [ "bin/x64/Galaxy64.dll" ];

    # NB no `extraSystem32`: neither Cyberpunk2077.exe nor REDGalaxy64.dll imports MSVCP140/VCRUNTIME140 at
    # all (they static-link the CRT). GameServicesGOG.dll does, and wine's ARM64EC UCRT/VC140 builtins load
    # cleanly under FEX (the skyrim-se / no-mans-sky finding), so nothing needs staging.
  };

  # ── WHERE THE DIAGNOSTICS ACTUALLY ARE ─────────────────────────────────────────────────────────────────
  # No `drive_c/game` CoW overlay is needed to get this engine to talk, which is the opposite of what a
  # read-only install dir suggests. Three sinks, all already writable or already redirected:
  #   1. `OutputDebugString` IS ROUTED BUT NEARLY EMPTY. The exe imports OutputDebugStringA/W (4 and 2 call
  #      sites) and carries `LogChannel` / `LogChannelError` / `LogChannelWarning`; wine routes that to the
  #      `debugstr` channel, which propnix's pinned `WINEDEBUG=-all` suppresses, so it is one env var away:
  #        PROPNIX_WINEDEBUG=-all,+debugstr nix run .#cyberpunk-2077 …
  #      (PROPNIX_WINEDEBUG also forwards the child's pipe to the console — settings.rs `console`.)
  #      MEASURED YIELD, so nobody plans around it: a whole boot printed FOUR lines — one Streamline
  #      (`sl.interposer` skipping its IDXGIFactory proxy), three Intel XeSS/XeLL — plus, on a hung boot, the
  #      engine's assert text (`Assert: : Watchdog timeout! (120 seconds) - …\engineWatchdog.cpp(198)`). The
  #      release build does NOT push its LogChannel traffic here. `+winsock` is far more informative (below).
  #   2. HANG/CRASH REPORTS ALREADY LAND: `%LOCALAPPDATA%\REDEngine\ReportQueue\Cyberpunk2077-<date>-<pid>-<tid>\
  #      Cyberpunk2077.dmp`, which sits on the `drive_c/users` CoW overlay and is written for real. The
  #      trailing `-<pid>-<tid>` names the thread that RAISED the report — on a hang that is tid 468
  #      `WatchdogThread`, the engine's own hang detector, and the dump carries no ExceptionStream: it hung, it
  #      did not crash. The dump has no MemoryListStream, so there are no call stacks — but the ThreadList
  #      still carries every thread's CONTEXT, and resolving each RIP against the module list plus wine's own
  #      ntdll.dll export table (`lib/wine/x86_64-windows/ntdll.dll`) names the blocked syscall per thread.
  #      That is how `GameThread → ntdll.dll+0xece4 → ZwDeviceIoControlFile+0x14` was pinned down.
  #   3. vkd3d's pipeline cache is NOT written into the game dir: the launcher pins VKD3D_SHADER_CACHE_PATH to
  #      $XDG_CACHE_HOME/propnix/<appid>/vkd3d (env.rs) precisely because vkd3d otherwise defaults to the cwd.
  #      A 264 KB `vkd3d-proton.Cyberpunk2077.exe.cache.write` is there, so D3D12 pipeline compilation ran and
  #      persisted — the read-only payload costs nothing here.
  # What the read-only game dir still costs is `r6/logs/` (unused by the vanilla engine — the `.log` literals
  # in the exe are a gpu-crash name and a font-shaper name, no engine log path) and `r6/cache/modded/`, i.e.
  # REDmod only. If REDmod is ever wired, THAT is when the no-mans-sky row (a persistent CoW overlay on
  # `drive_c/game` with a $PROPNIX_STATE upper) is needed — cheap here, the payload is 160 files. NB that row
  # and the DLC lowers must be reconciled: `extraGameLowers` already turns `drive_c/game` into a multi-lower
  # overlay when DLC are enabled, so an overriding row has to carry the DLC lowers too.
  #
  # ── RENDERS (x86_64, 2026-09-03) — AND WHAT THE EARLIER HANG ACTUALLY WAS ──────────────────────────────
  # VERIFIED: this spec, unmodified, boots to the attract-mode cinematics and the title screen at the
  # monitor's native 3840x2160, presenting continuously (compositor screenshots of the "WELCOME TO NIGHT
  # CITY" splash and of a Bink cutscene with live subtitles, taken seconds apart, plus a walk through the
  # legal screen to "PRESS ▯ TO CONTINUE"). It stayed alive to a `timeout -s KILL` (exit 137) with NO
  # ReportQueue minidump and no `Watchdog timeout!` assert. Run on the real Hyprland session — a headless
  # weston is NOT a valid harness for this stack (a known-good title fails there too).
  #
  # THE HANG THAT USED TO HAPPEN WAS NOT THIS TITLE'S BUG — it was the shared `dosdevices` row in
  # backends/wine/defaults.nix being a READ-ONLY bind, since changed to an ephemeral overlay. Same-day A/B
  # on this game, that row the only difference:
  #   dosdevices = ro mount  → hang; watchdog fires at 120 s; `GameThread` parked in ZwDeviceIoControlFile+0x14.
  #   dosdevices = overlay   → the render above; 126 of the same ioctls complete; no dump, no watchdog.
  # The mechanism, and why the blocked call looked like a socket wait: on a read-only dosdevices,
  # mountmgr.sys's `add_drive` retries its `symlink()` forever on EROFS. All of wine's kernel drivers are
  # serviced by ONE `IOCTL_WINE_GET_NEXT_DEVICE_REQUEST` loop per winedevice.exe, so a dispatch routine that
  # never returns starves EVERY other driver in that host — including nsiproxy. `PROPNIX_WINEDEBUG=-all,+winsock`
  # caught it exactly: GameThread's last call on a hung boot is
  #   `sock_ioctl handle 0x1a4, code 0x121000` = IOCTL_NSIPROXY_WINE_ENUMERATE_ALL (CTL_CODE(FILE_DEVICE_NETWORK,
  #   0x400, METHOD_BUFFERED)), the third round of a GetAdaptersAddresses-shaped 0x121000/0x121008 sequence
  # whose first two rounds had just completed. An iphlpapi call, starved by mountmgr, in the same
  # NtDeviceIoControlFile stub that AFD_POLL uses — which is precisely what made it look like GOG sign-in.
  #
  # DEAD ENDS, so they are not re-run. The GOG sign-in theory (`BaseEngine/Initialization/GameServicesAsync`,
  # `GameServicesUserSignInComplete`, `NotSignedInGalaxy`/`NotSignedInLauncher`, and the three
  # `[GameServicesGalaxy::SignInGalaxy]` modes) is WRONG for this hang: it was inferred from an absent log
  # line, and `.apply { maskFiles = [ "bin/x64/GameServicesGOG.dll" ]; }` disproved it — that ablation does
  # load the game with neither GameServicesGOG.dll nor Galaxy64.dll mapped, and it hung IDENTICALLY, same
  # watchdog, same ZwDeviceIoControlFile+0x14. (See the `galaxyStubDlls` note: REDGalaxy64.dll is the GOG
  # stack that actually runs, and `+winsock` shows GameThread resolving `galaxy-log.gog.com` even with the
  # plugin masked. DNS resolves inside the netns; connect(2) is what the kernel refuses.) Also not the
  # cause: the exe's SSD probe (IOCTL_STORAGE_GET_DEVICE_NUMBER 0x2D1080 / IOCTL_STORAGE_QUERY_PROPERTY
  # 0x2D1400 over `\\.\PhysicalDrive%d`, ~1 ms each), and hidraw (root-only 0600 here, wine never opens it).
  #
  # IF IT EVER HANGS AGAIN, this is the order that worked — `+winsock` is the cheap one and names the last
  # ioctl per thread; the dump then confirms which thread is parked where:
  #   PROPNIX_WINEDEBUG=-all,+winsock nix run .#cyberpunk-2077 …
  #   PROPNIX_WINEDEBUG=-all,+loaddll …    # builtin-vs-native per module, if a shipped DLL looks shadowed
  #   cyberpunk-2077.apply { online = true; }   # DIAGNOSTIC ONLY, not a fix
  # (`maskFiles` whiteouts are refused over a multi-lower game dir — run those with NO DLC enabled. Both
  # overrides are function calls, so they need the `--impure … getFlake … .apply` build form, not `nix run`.)
}
