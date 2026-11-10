# Sid Meier's Civilization VI (Steam, x86_64 WINDOWS build) via wine — on aarch64 through FEX +
# ARM64EC, on x86_64 natively. Firaxis's in-house Civ6 engine (Havok Script/Lua gameplay layer,
# SQLite-backed databases, Bink video, SDL2 windowing), all shipped beside the exe as
# `*_FinalRelease.dll`.
#
# Steam-only, Windows-only: Civ VI is not sold on GOG, and the Aspyr Linux build is a separate,
# later-patched port whose depots are not pinned here. The fetch matrix has exactly that pair, so
# both axes resolve with no ranking to declare.
#
# Boots to the rendered front end on x86_64; not played past it
# (docs/verified/civilization-6-win.json).
#
#   nix run .#civilization-6 --extra-sandbox-paths /propnix=/var/lib/propnix
#
# Four depots of app 289070, pairwise disjoint at file level, so the game dir is a pure union:
#   289072   55 MB  Base/Binaries/Win64Steam/   exes, engine DLLs, the shipped steam_api64.dll
#   289071   11 GB  Base/{Assets,ArtDefs,Platforms}, Debug/, CTP/, DLC/<27 civ & mode packs>
#   289085  4.2 GB  DLC/Expansion1 (Rise and Fall), DLC/Expansion2 (Gathering Storm)
#   289089  142 MB  LaunchPad/                  the 2K launcher (Qt5 + QtWebEngine + Xsolla)
# The binaries depot leads because the PE icon is extracted from `head payloads` at build time.
# Depot 289089 (2K LaunchPad) is carried as the evidence for the exe choice; nothing runs it.
# Payload and launcher research: docs/research/multi-store-payloads.md and
# publisher-launcher-bypass.md.
{
  lib,
  mkApp,
  fetchSteamDepot,
}:
let
  versions = lib.importJSON ./versions.json;
in
mkApp {
  pname = "civilization-6";
  maintainers = [ "waltmck" ];
  appid = "civilization-6";
  name = "Sid Meier's Civilization VI";

  fetchInfo = versions.fetchInfo;

  # The DX11 exe, launched directly: LaunchPad's config.json offers only the DX11 and DX12 exes, so
  # the launcher contributes nothing but that pick. DX11 because DXVK is the tree's well-travelled
  # d3d path; the DX12 exe would land on vkd3d-proton. Shader blobs for both renderers ship, so
  #   .apply { exe = "Base/Binaries/Win64Steam/CivilizationVI_DX12.exe"; }
  # is the one-line switch.
  exe = "Base/Binaries/Win64Steam/CivilizationVI.exe";

  # The exe's asset paths are `../../../`-relative (`../../../Base/Assets/…`, `../../../DLC/`),
  # which reach the game root only from `Base/Binaries/Win64Steam`
  # (docs/research/engine-working-directory.md).
  workingDir = "Base/Binaries/Win64Steam";

  # Full-colour icon auto-extracted from CivilizationVI.exe's PE resources (icon.auto default).
  # Symbolic vendored (CC BY-SA 4.0): the series' roman-numeral "VI" in a rounded frame.
  icon.symbolic = ./civilization-6-symbolic.svg;

  # Stated rather than defaulted: Civ VI has real online features (multiplayer, cross-play, Play By
  # Cloud); Steam lobbies cannot work either way, since the shim reports offline. OPEN: whether the
  # front end comes up under `.apply { online = false; }`, a kernel-enforced offline single-player
  # run at the cost of the rest.
  online = true;

  # Offline Steam entitlement. The base depots ship every pack's data (a multiplayer client must
  # render a civ another player owns) and the engine unlocks packs from the Steam entitlement it
  # sees, so the shim is what makes owned content playable. The declared path is the copy
  # CivilizationVI.exe imports statically; LaunchPad's own copy is undeclared, as nothing runs it.
  steam.emu.libPaths = [ "Base/Binaries/Win64Steam/steam_api64.dll" ];

  # Both game exes are SteamStub v3.1-wrapped, and the wrapper asks its own embedded Steam API, so
  # the shim alone exits 53. This stages a proxy at the dll path whose DllMain loads gbe_fork's
  # in-memory patcher before the exe's entry point (docs/research/steam-drm.md).
  steam.emu.steamStub = true;

  # DLC: seven owned packs, each its own depot of 289070 holding one `DLC/<Pack>/` tree:
  #   aztec            512030   DLC/Aztec_Montezuma/Data/*.xml
  #   vikings          512032   DLC/VikingsScenario/
  #   poland           512033   DLC/PolandScenario/
  #   australia        512034   DLC/AustraliaScenario/
  #   persia-macedon   512035   DLC/AlexanderScenario/
  #   nubia            645400   DLC/NubiaScenario/
  #   khmer-indonesia  645401   DLC/Indonesia_KhmerScenario/
  # The base depot ships each pack's civilization half; the owner-only depot ships the scenario
  # half. `aztec` duplicates base files byte for byte (the pack is free to all owners) and is kept
  # for the entitlement it attests. depotId is the store appid for all seven, so no row needs
  # `dlcAppId`, and the titles are the exact store names because the engine's appid-to-pack mapping
  # is not visible and may match on them (docs/research/steam-dlc-appids.md).
  # OPEN: Rise and Fall and Gathering Storm ride in base depot 289085, so nothing attests them and
  # they are expected to read as unowned; the fix is to pin their own depots as `dlc` rows with
  # `dlcAppId` 645402 / 947510.
  dlc.available = lib.mapAttrs (_: fetchSteamDepot) versions.dlc;

  # Save: `Documents\My Games\Sid Meier's Civilization VI` holds the hall of fame, mods, mod user
  # data and `Saves\`. Options, input bindings, caches and dumps go to `%LOCALAPPDATA%\Firaxis
  # Games`, which nothing binds, so they persist in the profile overlay upper
  # (`$PROPNIX_STATE/wine/users`). OPEN: whether that options half deserves a save row of its own.
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "Documents/My Games/Sid Meier's Civilization VI";
    }
  ];

  # No wine tuning: the tree defaults (d3d = dxvk, graphics = wayland) reach the front end.
  # OPEN: whether Single Player starts a game and the DLC rulesets show as owned in the game's UI.
}
