# The Witcher 3: Wild Hunt — Complete Edition (GOG, Windows build) via wine — on aarch64 through FEX +
# native ARM64EC DXVK, on x86_64 natively. CD Projekt Red's REDengine 3, in its 4.0x "next-gen" form, which
# ships TWO complete renderers as two separate binaries (D3D11 and D3D12); we run the D3D11 one, so D3D goes
# game → DXVK → Vulkan. ARCH-AGNOSTIC: this spec is identical on both hosts; mkApp + the scope pick the
# arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across
# arches. Windows-only title (CDPR ships no Linux build), so the payload is the pinned GOG Galaxy build
# fetched by fetchGogGalaxyBuild (D15) — the game tree directly, no InnoSetup.
#
#   nix run .#witcher-3 --extra-sandbox-paths /propnix=/var/lib/propnix
#
# ── NO DLC ROWS, AND THAT IS THE POINT OF "COMPLETE EDITION" ───────────────────────────────────────────
# Unlike cyberpunk-2077, this title needs no `dlc` block: every expansion is ALREADY in the base build.
# `launcher-configuration.json` declares one edition, `completeEdition`, listing 21 DLC → path pairs
# (EP1→dlc/ep1, EP2→dlc/bob, DLC 01…20→dlc/dlcNN), and all 21 directories are present in the fetched tree
# (`dlc/` is 13 GB of the payload's 52 GB; `content/` is the other 38 GB as content0…content12). So Hearts
# of Stone and Blood and Wine come with the base pin — there is no second dlcId depot to fetch, and
# `.withDlc` has nothing to offer here.
#
# The pinned `version` string is GOG's own build label, `4.04a_REDkit_Update_2` — the base-game build that
# shipped alongside a REDkit toolkit release. The payload contains NO REDkit binaries (REDkit is a separate
# GOG product); the label is provenance, and the download is determined by buildId regardless. NB also that
# `goggame-1495134320.info` still calls itself "Game of the Year Edition" while the store product is now
# "Complete Edition" — GOG renamed the SKU, the .info was not rewritten. Same content either way.
#
# ── WHICH EXECUTABLE, AND WHY THE D3D11 ONE ────────────────────────────────────────────────────────────
# `goggame-1495134320.info` lists four launchable tasks:
#   isPrimary=true            REDprelauncher.exe                              category=launcher
#                             REDprelauncher.exe --launcher-fallback="DirectX 11"  category=launcher
#   isHidden                  bin/x64_dx12/witcher3.exe  workingDir=bin/x64_dx12   category=game   91 MB
#   isHidden                  bin/x64/witcher3.exe       workingDir=bin/x64        category=game   86 MB
# and `launcher-configuration.json` shows what the launcher's renderer setting actually IS:
#   executables: [ { "DirectX 12": bin\x64_dx12\witcher3.exe }, { "DirectX 11": bin\x64\witcher3.exe } ],
#   "fallback": "DirectX 12"
# — i.e. an exe pick and nothing more, exactly like baldurs-gate-3's launcher.cfg. So choosing `exe` here IS
# the launcher's renderer setting, and launching a game binary directly loses no setup.
#
# NOT the launcher: REDprelauncher.exe is a 1.8 MB Qt5/Poco/sqlite BOOTSTRAPPER that installs
# `setup_redlauncher.exe` (642 MB, right beside it at the payload root) into
# `%LOCALAPPDATA%\Programs\CD Projekt Red\REDlauncher` — the exact `additionalPaths` filesystemPath the
# play tasks declare — and runs THAT, which then spawns witcher3.exe and exits. Under propnix that is an
# installer run per prefix, a 642 MB launcher app, and a parent that spawns-and-exits into the launcher's
# primary-child teardown (skyrim-se / baldurs-gate-3 hit the same wall).
#
# THE TWO BINARIES ARE GENUINELY DIFFERENT RENDERERS, confirmed from their PE import tables:
#   bin/x64/witcher3.exe       imports d3d11.dll, dxgi.dll, D3DCOMPILER_47.dll, GFSDK_SSAO_D3D11.win64.dll
#   bin/x64_dx12/witcher3.exe  imports NEITHER d3d11 nor d3d12 (it loads D3D12 dynamically — its dir ships
#                              D3D12/D3D12Core.dll, the Agility SDK) and instead pulls
#                              GFSDK_SSAO_D3D12.win64.dll, dxcompiler.dll (DXC), libxess.dll,
#                              sl.interposer.dll (NVIDIA Streamline) and GFSDK_Aftermath_Lib.x64.dll.
#
# WE PICK D3D12 — an OWNER DECISION (2026-09-03) after a first run on the D3D11 binary, taken for ray
# tracing and to chase HDR. The DX11 spec below is preserved because its analysis is still the honest
# account of the trade; only the conclusion changed. What is now MEASURED, and what is not:
#   * MEASURED: the D3D11 binary RUNS here (owner ran it: renders and plays) but WITHOUT HDR. So the
#     `env.DXVK_HDR` argument below — that DXVK's dxgi carries the gate for either renderer — did NOT by
#     itself produce an HDR swapchain on the D3D11 path. Whether that is the engine's own HDR toggle being
#     off in `user.settings` (the in-game Video menu writes it; a fresh prefix starts from defaults) or
#     something in the DXVK-dxgi path is UNRESOLVED — do not read this switch as a diagnosis of it.
#   * NOT MEASURED: that D3D12 fixes HDR, or that it runs at all here. vkd3d-proton has never been the
#     primary renderer for a packaged title in this tree. If D3D12 regresses, the DX11 pick is one
#     `.apply` away (see the switch line below, and note the settings files differ per renderer).
#   * The engine keeps SEPARATE graphics settings per renderer (`user.settings` vs `dx12user.settings`),
#     so the DX12 path starts from ITS OWN defaults — expect to set resolution/quality AND the HDR toggle
#     in the in-game Video menu on first run, rather than inheriting anything from the DX11 session.
#
# THE ORIGINAL D3D11 ARGUMENT, kept for the record:
#   * HDR IS NOT THE DIFFERENTIATOR HERE, and this is the interesting difference from baldurs-gate-3.
#     BOTH exes carry the identical display-HDR gate (`GetHDRSupported`, `IsHdrSupported`,
#     `SetHDRMenuActive`, `OnHDRChangedEvent`, `hdr\hdr_calibration_screen.dds` — same set in both string
#     tables), and BOTH present through DXVK's dxgi.dll either way: for D3D11 directly, and for D3D12
#     because vkd3d-proton ships only d3d12.dll + d3d12core.dll and exports `IDXGIVkSwapChainFactory`,
#     handing presentation to DXVK. So `env.DXVK_HDR` below is the same knob for either binary, and the
#     renderer choice is free to be made on other grounds. (bg3 was the opposite case: there the choice was
#     Vulkan-native vs D3D11 and HDR decided it.)
#   * FEWEST LAYERS ON THE BEST-TRODDEN PATH. D3D11 → DXVK → Vulkan is the chain every wine title in this
#     tree already runs, and native ARM64EC DXVK is what the `wine.d3d` default was measured on (60 fps vs
#     wined3d's ~12 — see backends/wine/defaults.nix). The D3D12 exe would put vkd3d-proton in the primary
#     role, which no packaged title here does yet.
#   * LESS BOUND SURFACE. The D3D12 build hard-imports the NVIDIA stack (Streamline interposer, Aftermath)
#     and runs DXC for shader compilation at load; on a Mesa target the DLSS/Streamline paths are inert
#     anyway, and under FEX all of it is emulated CPU work on the critical path.
#   * THE TRADE-OFF, STATED: RAY TRACING IS D3D12-ONLY. Picking D3D11 forgoes RT (and DLSS). This is the
#     reason the default is now D3D12. To go BACK to D3D11 it needs BOTH fields, because the engine is
#     cwd-sensitive:
#         witcher-3.apply { exe = "bin/x64/witcher3.exe"; workingDir = "bin/x64"; }
#     The two renderers keep SEPARATE graphics settings (`user.settings` vs `dx12user.settings`, both read
#     off the respective exes' strings) but share one `gamesaves` directory, so switching costs a
#     re-configure, not a savegame.
# NONE OF THIS IS MEASURED. It is an argument from the import tables plus this repo's existing DXVK
# results; nobody has run either binary here. Treat the pick as a reviewable default.
#
# CWD = THE EXE'S OWN DIRECTORY, and unlike cyberpunk-2077 that is not a guess: BOTH game play tasks in the
# .info declare an explicit `workingDir` equal to the exe's directory. (Cyberpunk's task in the same file
# format declares none — the presence here is the statement, and it is the same cwd sensitivity that
# baldurs-gate-3 had to discover the hard way.)
{
  lib,
  mkApp,
}:
mkApp {
  pname = "witcher-3";
  maintainers = [ "waltmck" ];
  appid = "witcher-3";
  name = "The Witcher 3: Wild Hunt";

  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;

  exe = "bin/x64_dx12/witcher3.exe";
  workingDir = "bin/x64_dx12";

  # Offline by construction: the launcher unshares a NETWORK NAMESPACE, so the guarantee is enforced by the
  # kernel rather than by trusting the title's bundled SDKs. Single-player title — there is no multiplayer
  # mode in The Witcher 3 at all — and the payload's two network consumers are exactly what should be held
  # to loopback: `RedTelemetryLib.dll` sits beside the exe in both bin dirs (and the exe's RTTI carries a
  # whole `telemetry::parameters` type tree — Hardware, Build, Location, Progress, Debug), and witcher3.exe
  # statically imports WININET.dll and `REDGalaxy64.dll` (CDPR's rebuild of the GOG Galaxy SDK). Nothing
  # here needs the network to play.
  online = false;

  # DXVK's stand-in for the Windows "HDR on" display toggle. Needed because wine writes no EDID into the
  # registry under winewayland, so DXVK's dxgi has nothing to auto-detect from and never reports HDR by
  # itself (baldurs-gate-3 / no-mans-sky carry the measured version of this). The engine has a real
  # display-HDR gate to unlock — `GetHDRSupported` / `SetHDRMenuActive` / `hdr\hdr_calibration_screen.dds`
  # in the exe — and it degrades safely on an SDR session, because the actual Vulkan surface offers no
  # HDR10 colorspace there and the swapchain stays sRGB rather than getting PQ rendered into it.
  # NOT VERIFIED on this title: the mechanism is established, that Witcher's HDR menu unlocks from it is not.
  env.DXVK_HDR = "1";

  # Full-colour icon auto-extracted from witcher3.exe's PE resources (icon.auto default). Checked rather
  # than assumed: the exe's resource directory carries types [1, 3, 5, 12, 14, 16, 24] — 14 is
  # RT_GROUP_ICON, which is what lib/icons/from-pe.nix pulls with `wrestool -t 14`. Both binaries carry the
  # same .rsrc, so the icon does not change if you switch to the D3D12 exe. No symbolic icon vendored yet.

  # Save: REDengine 3 writes everything under the Documents known folder, `Documents\The Witcher 3\`, with
  # savegames in the `gamesaves` subdirectory and settings as siblings (`user.settings` for this D3D11
  # binary, `dx12user.settings` for the D3D12 one, plus `input.settings`). Evidence from the exes' own
  # UTF-16 string tables: `\The Witcher 3\`, `gamesaves`, `\user.settings` in bin/x64/witcher3.exe and
  # `\dx12user.settings` in bin/x64_dx12/witcher3.exe — and, as a nice cross-check that this is the
  # Documents-rooted series convention, a legacy `\Witcher 2\gamesaves\` path for save import. One
  # whole-folder bind (saves + settings together), the skyrim-se shape.
  #
  # UNVERIFIED: read off the binaries, not off a `+file` trace of a running game. If saves go missing,
  # trace the real CreateFileW path and correct this row rather than adding a speculative second one.
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "Documents/The Witcher 3";
    }
  ];

  # THE STUB COVERS `Galaxy64.dll` ONLY — `REDGalaxy64.dll` is NOT stubbable, and that half is a finding
  # rather than an omission. Checked the whole import graph of this payload:
  #   * witcher3.exe (BOTH binaries) statically imports `REDGalaxy64.dll`, CDPR's own rebuild of the Galaxy
  #     SDK, which is self-contained (it imports WS2_32/WININET/CRYPT32/bcrypt directly — no Galaxy64.dll).
  #     emulators/galaxy-stub CANNOT stand in for it: its 28 exports are in the `redgalaxy` namespace
  #     (`?Init@api@redgalaxy@@YAXAEBUInitOptions@12@@Z`, …) while the stub exports the `galaxy` namespace
  #     (src/symbols64.txt: 34 symbols, zero `redgalaxy`), so a bound stub would leave 28 imports
  #     unresolved and the exe would not load. It could not even be bound: galaxyMounts sources
  #     `${galaxyStub}/${baseNameOf rel}` and the stub package emits only Galaxy64.dll / Galaxy.dll /
  #     pops_api.dll. Adding a `redgalaxy` variant to symbols64.txt (+ a REDGalaxy64.dll output) is what it
  #     would take.
  #   * The real `Galaxy64.dll` IS present in BOTH bin dirs, and no DLL in either dir STATICALLY imports it
  #     (checked one by one). It is stubbed anyway, as policy: a static-import scan cannot prove nothing
  #     loads it, because the GOG store plugin is loaded BY NAME at runtime — that is exactly how
  #     cyberpunk-2077 reaches `Galaxy64.dll` (its `GameServicesGOG.dll` is absent from every import table
  #     in that payload and dlopens it), and this payload ships `bin/config/platform/pc/GalaxyPeer.json`
  #     beside `REDGalaxyPeer.json`, which is a Galaxy peer config for something. If nothing loads it the
  #     rows are inert; if something does, it is neutralized. Both dirs are listed because the payload
  #     carries both binaries and `exe` selects between them.
  # What enforces the offline guarantee regardless is `online = false` above: a loopback-only netns fails
  # connect(2) with ENETUNREACH immediately, so the SDK takes its offline path instead of hanging.
  wine.galaxyStubDlls = [
    "bin/x64/Galaxy64.dll"
    "bin/x64_dx12/Galaxy64.dll"
  ];
  #
  # NB also no `extraSystem32`: neither witcher3.exe imports MSVCP140/VCRUNTIME140 at all (static CRT), so
  # there is nothing to stage over wine's builtins.

  # OPEN: REDengine 3 keeps a shader cache and crash-reporter output next to the binaries, and
  # `drive_c/game` is a read-only bind here, so any in-place write fails with STATUS_ACCESS_DENIED — the
  # baldurs-gate-3 situation, where the only cost turned out to be "no log sink". Whether Witcher merely
  # loses its logs or actually needs a writable game dir has NOT been established. If it does, the fix is
  # the no-mans-sky row (a persistent CoW overlay on `drive_c/game` with a $PROPNIX_STATE upper) — but
  # weigh it first: the data-only skeleton is built per FILE, and this payload is 2546 files / 52 GB, far
  # bigger than the 160-file case that made it cheap for no-mans-sky.
}
