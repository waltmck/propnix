# Middle-earth: Shadow of Mordor — Game of the Year Edition (Monolith / WB Games) via wine — on aarch64
# through FEX + native ARM64EC DXVK, on x86_64 natively. Monolith's LithTech-derived "Firebird" engine
# (the exe's own registry root is `SOFTWARE\WB Games\Firebird\1.00.0000`), renders D3D11 → DXVK → Vulkan:
# `ShadowOfMordor.exe` imports d3d11.dll + dxgi.dll and nothing else graphical, so the tree's DXVK default
# is exactly right and no `d3d` override belongs here. ARCH-AGNOSTIC: the spec is identical on both hosts;
# mkApp + the scope pick the arch-appropriate emulator set and the SAME Windows payload (a
# content-addressed FOD) is shared. Windows-only content — neither store ships a Linux build.
#
#   nix run .#shadow-of-mordor --extra-sandbox-paths /propnix=/var/lib/propnix       # gog/x86_64-windows
#   nix run '.#shadow-of-mordor.apply { fetcher = "steam"; }'                        # the Steam build
#   nix run '.#shadow-of-mordor.apply { fetcher = "steam"; }.withAllDlc'             # …+ its 20 DLC depots
#
# ── OWNED ON BOTH STORES: ONE PACKAGE, TWO FETCHER ROWS ────────────────────────────────────────────────
# The fetch matrix is `fetchInfo.<fetcher>.<platform>` — a full cross product — so nothing stops two
# fetchers from pinning the SAME platform, and that is what happens here: both stores ship an x86_64
# Windows build and there is no second platform anywhere. Three consequences fall out of the schema
# (modules/app-options.nix) rather than out of any choice made here:
#
#   * NO `platformPreference` IS DECLARED, and none may be. The ratchet that forces a game to state its
#     ranking counts PLATFORMS, not fetchers (`pinned = filter (p: any (f: fetchInfo.${f}.${p} != null))
#     platforms`); with one pinned platform the list derives itself. Declaring `[ "x86_64-windows" ]` here
#     would be noise that says nothing.
#   * THE STORE IS THE USER'S CHOICE, NOT THIS FILE'S. `fetcher` defaults to the first entry of
#     `preferredFetchers` that pins the selected platform, and `preferredFetchers` defaults to
#     `attrNames fetchers` — name-sorted, so "gog" precedes "steam". GOG therefore wins by default with NO
#     game-authored `fetcher = lib.mkDefault …`, which matters: lib/tests/resolution.nix holds
#     `fetcherExceptions = [ ]` and FAILS the flake check the moment a game defines that option. A
#     steam-first user (`config.preferredFetchers = [ "steam" "gog" ]`) gets the Steam build automatically;
#     `.apply { fetcher = …; }` overrides either way. Nothing here defeats the account preference.
#   * THE TWO ARMS DIVERGE ONLY IN STORE INTEGRATION — the `fetcher` axis's stated job. Everything below
#     that is unconditional (exe, workingDir, saveBinds, icon) is unconditional because it is genuinely
#     IDENTICAL: `x64/ShadowOfMordor.exe` is BYTE-IDENTICAL in the two payloads
#     (sha256 f5d72578f7e5fcf05e6d15d8bd231f763078620c8545f8464bb186e842279455 in both), as are
#     bink2w64.dll, d3dcompiler_46.dll and x64/default.archcfg. Only steam_api64.dll differs (see below).
#
# hollow-knight is the two-fetcher exemplar; the difference is that ITS fetchers pin different platforms,
# so it must rank them. This is the simpler shape the same machinery already covers.
#
# ── WHY GOG IS THE PRIMARY (and it is a content argument, not a taste one) ─────────────────────────────
# The GOG build is the WHOLE GOTY EDITION plus the free HD texture pack IN ONE TREE, and that is measured,
# not assumed. Every one of the 20 owned Steam DLC depots was fetched and compared file-by-file against the
# GOG payload root: all 20 are byte-identical SUBSETS of it.
#
#   * 19 depots ship exactly one tiny `layerNN_dlc_<name>.arch05` (68–232 bytes) — the entitlement/patch
#     layer for one skin, warband, rune or challenge mode. All 19 files are present at the GOG root with
#     identical sha256.
#   * depot 311670 ("HD Content", the free licence) ships 22 high-mip `*_0.arch05` archives, 11.8 GB. All
#     22 are present at the GOG root with identical sha256 (checked in full on the small ones, by size +
#     hash on the rest).
#   * The Steam BASE depot 241931 contains NONE of those 41 files — on Steam they are strictly DLC.
#
# So the GOG arm reaches full GOTY+HD content with ONE FOD and no entitlement machinery at all, while the
# Steam arm needs 21 FODs, the gbe_fork shim and a `withAllDlc` to reach the same bytes. Add that the two
# exes are the same file and there is nothing the Steam build does better. The Steam rows are kept anyway
# because the user owns the title there, because a second pin of the same content is a genuinely useful
# cross-check on the fetchers, and because the framework carries it at no cost to the default path — the
# `dlc.available` set and `steam.emu` wiring below are inert on the GOG arm by construction.
#
# ── THE EXECUTABLE, AND WHY `workingDir` IS LOAD-BEARING ──────────────────────────────────────────────
# `goggame-1213504814.info` lists exactly ONE play task of category `game`:
#     isPrimary=true   x64/ShadowOfMordor.exe   workingDir="x64"
# (the only other task is a `URLTask` to GOG's support page). There is no launcher binary to bypass and no
# renderer choice to make — the payload's ONLY executable is that one exe, in either store's tree.
#
# `workingDir = "x64"` is NOT cargo-culted from that .info; the engine's own manifest proves it is
# required. `x64/default.archcfg` — the archive search list Firebird reads at startup — names every asset
# pack RELATIVE, one directory up:
#     ..\Game            ..\global.arch05      ..\udun.arch05      ..\Layer71_DLC_BrightLord.Arch05   …
# With propnix's default cwd (the game dir = payload root) those `..\` paths resolve to the PARENT of
# C:\game — i.e. the drive root — and every archive, including the whole base game, silently fails to
# open. With cwd = `x64` they resolve to the payload root, where the archives actually are. Same class of
# bug as baldurs-gate-3's khonsu roots; same one-line fix.
#
# Two further facts read off that same archcfg, worth knowing before someone "fixes" a missing file:
#   * The list is a static SUPERSET. It names `Layer40_DLC_ForgottenRunes.Arch05`, `DLC2_0.arch05` and
#     `hotchunk_patch_0.arch05`, none of which exist in the GOG GOTY tree — which is the complete edition.
#     The engine therefore tolerates an absent archive, which is exactly why the Steam DLC depots can be a
#     pure additive union and why an un-owned layer costs nothing.
#   * It spells several entries in a case the files do not use (`..\ui_gfx.arch05` for `UI_GFX.arch05`,
#     `..\patch_1.arch05` for `Patch_1.arch05`). Harmless on wine, whose NT path layer resolves names
#     case-insensitively by directory scan. It would NOT be harmless on a thin/Linux backend — another
#     reason this title has no business anywhere but wine.
#
# ── TWO NOTES ON versions.json (which cannot hold comments of its own) ────────────────────────────────
#  1. TWO DEPOTS WERE DROPPED, NOT FORGOTTEN. App 241930 also publishes 241934 and 241935, and both were
#     fetched: 241934 is a 46 MB `Middle Earth Shadow of Mordor.app/` bundle (plus a .DS_Store) and 241935
#     is a 56 GB `ShadowOfMordorData/` tree — the macOS build, which `propnix pin` had labelled
#     "(macos, Steam)" while still filing under `x86_64-windows`. There is no honest row for them:
#     `lib/strategy.nix` has no macOS platform, and unioning a Mach-O app bundle into a wine game dir
#     would add ~102 GB of closure for nothing. The Steam Windows game is depot 241931 alone.
#  2. THE STEAM `pname`s ARE THE `propnix pin --new` PLACEHOLDERS, ON PURPOSE. House style would spell
#     them `shadow-of-mordor-<depotId>`, but an FOD's store path is `hash(name, outputHash)` — renaming
#     one REPOINTS it at a path that does not exist yet, and these 21 depots (43 GB base + 11.8 GB HD
#     content + 19 tiny layers) are already realised under the names as written. The rename is a free,
#     purely cosmetic edit for anyone willing to re-download ~55 GB; it is not free otherwise. The GOG
#     row needed no such compromise — `shadow-of-mordor-win` is already house style.
{
  lib,
  mkApp,
  fetchSteamDepot,
}:
let
  versions = lib.importJSON ./versions.json;
in
mkApp (
  { config, lib, ... }:
  let
    onSteam = config.fetcher == "steam";
  in
  {
    pname = "shadow-of-mordor";
    maintainers = [ "waltmck" ];
    appid = "shadow-of-mordor";
    name = "Middle-earth: Shadow of Mordor";

    fetchInfo = versions.fetchInfo;

    # ── aarch64 NEEDED A WINE PATCH, AND THIS FILE IS NOT WHERE THE FIX LIVES ──────────────────────────
    # PLAYS on both arches (aarch64 verified 2026-09-11). Recorded here because the failure looked like a
    # packaging problem and is not: on a host with 16k pages the loader refused the image outright —
    #
    #     err:virtual:map_file_into_view unaligned shared mapping 0x141b55000-0x141b56000 not supported
    #     err:module:map_image_into_view Could not map …ShadowOfMordor.exe shared section .SHARED
    #     wine: failed to start …: c000007b
    #
    # ShadowOfMordor.exe carries an EIGHT-BYTE `.SHARED` section (MEM_SHARED|MEM_WRITE) at 0x141b55000,
    # which is 0 mod 4096 and 4096 mod 16384. A writable shared section must be mmap'ed MAP_SHARED and
    # mmap only places shared mappings on whole host pages, so wine could not map it and rejected the
    # whole 54 GB game over one cross-instance variable. x86_64 never sees it: 4k pages make the address
    # aligned by construction. Fixed in emulators/wine-hangover/patches/0007 (host-page-aligned shared
    # sections, with a private-mapping fallback); this title takes the FALLBACK, because its 16k page also
    # holds the tail of `.pdata` and the head of an executable section. The fallback logs at ERR that
    # cross-process sharing of that range is lost, which for 8 bytes of multi-instance bookkeeping under a
    # single-instance launcher costs nothing — but note propnix defaults WINEDEBUG=-all, so seeing it
    # needs `PROPNIX_WINEDEBUG="err+all"`. Nothing about this belongs in a per-game knob.

    # See the header: the sole play task, and the sole executable, in either payload.
    exe = "x64/ShadowOfMordor.exe";
    # REQUIRED, not cosmetic — x64/default.archcfg addresses every asset archive as `..\<name>.arch05`.
    workingDir = "x64";

    # Full-colour icon auto-extracted from the exe's PE resources (`icon.auto` default), so no `icon.png`
    # hunt through the payload was needed. VERIFIED by running the extraction by hand: one RT_GROUP_ICON
    # (name=101) over 8 RT_ICON entries, and `icotool -l` reports genuine 256/128/96/72/64/48/32/16 px
    # images at 32-bit depth — the hicolor theme and the splash get real sizes at every step, nothing
    # upscaled. No symbolic variant is vendored yet; the .desktop falls back to the raster.

    # ── OFFLINE ── DELIBERATE, AND WEAKER EVIDENCE THAN hollow-knight's — read this before trusting it.
    # `false` makes the launcher unshare a network namespace for the game (loopback only), so the offline
    # guarantee is the kernel's rather than the SDK's. What was actually observed:
    #   * This exe DOES link a socket library — 32 static WS2_32.dll imports (the Winsock 1.1 set by
    #     ordinal, plus getaddrinfo/freeaddrinfo by name). So the hollow-knight argument ("links no socket
    #     library at all") is NOT available here and must not be repeated.
    #   * Its store SDK surface is a STATIC import of steam_api64.dll covering 22 entry points, among them
    #     SteamMatchmaking, SteamMatchmakingServers, SteamGameServer and SteamGameServer_Init — i.e. the
    #     online surface behind this title's leaderboards and its asynchronous friend-Vendetta feature.
    #   * BUT that surface is already dead on BOTH arms before the namespace is considered: on GOG the
    #     shipped steam_api64.dll is GOG's own Galaxy bridge, pointed at the no-op galaxy stub below; on
    #     Steam gbe_fork union-replaces it and reports `offline=1`. The netns is a second, independent
    #     guarantee behind an SDK that can no longer reach anything, not the only thing holding the line.
    #   * Cutting the network is also the LOW-LATENCY failure here: inside an empty netns connect(2) fails
    #     immediately with ENETUNREACH, whereas a reachable-but-dead-server host is what produces a boot
    #     hang. So `false` is the safer of the two guesses, not merely the more principled one.
    # NOT verified by running the game. If a launch ever stalls before the menu with the SDK retrying a
    # connect, `.apply { online = true; }` is the one-line revert and the first thing to try.
    online = false;

    # ── SAVES ── The GOG install script states the location outright: `goggame-1213504814.script` declares
    # `savePath = "{userdocs}/WB Games/Shadow of Mordor"` (type folder). The exe corroborates it — it
    # imports SHGetFolderPathA (the ANSI shell-folder API) and its string table holds `\WB Games\`
    # immediately followed by `Shadow of Mordor`. Bind the WHOLE folder, the skyrim-se pattern: the engine
    # keeps `GameData.sav`, `Game.ini` and its `errorlog.txt` there, so saves and config persist together
    # under one host directory a user can back up as a unit. `dst` is HOME-relative; the wine builder joins
    # it onto drive_c/users/<wineUser>/.
    #
    # UNRESOLVED — the ONE thing about persistence that string evidence could not settle. The exe also
    # carries `\USER\render.cfg` and `\USER\settings.cfg` (adjacent to `autoexec.cfg` in the string table,
    # i.e. the console/config subsystem, NOT next to the `\WB Games\` block). Whether that `USER\` hangs
    # off the save root above — in which case this bind already covers it — or off the GAME directory is
    # not determinable without a syscall trace. The game dir is a READ-ONLY bind (lib/builders/wine.nix),
    # so in the second case the two renderer/settings files would fail to write and in-game settings would
    # not survive a restart (a silent, non-fatal degradation — nothing else reads them). Diagnose with a
    # `+file` WINEDEBUG trace of one launch; the fix if it lands in the game dir is a `wine.mounts` row
    # over `drive_c/game/USER` in the KSP style (see pkgs/games/kerbal-space-program/wine-tuning.nix),
    # NOT a widening of this bind.
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "Documents/WB Games/Shadow of Mordor";
      }
    ];

    # ── DE-STORE-INTEGRATION ──────────────────────────────────────────────────────────────────────────
    # `maskFiles` IS IMPOSSIBLE FOR THIS TITLE, and it is worth stating why so nobody reaches for it: the
    # exe imports steam_api64.dll STATICALLY (it is in the PE import table, with 22 named thunks), so
    # erasing the file makes wine's loader refuse to start the process — nothing like the clean "no online
    # subsystem" degradation a dlopen-ing engine gives. The file must EXIST on both arms; what differs is
    # WHAT is behind it, and that is the whole content of the `fetcher` axis here.
    #
    # THE GOG ARM IS THE INTERESTING ONE. GOG did not patch the engine: the exe still imports
    # `steam_api64.dll`, and GOG SHIPS ITS OWN steam_api64.dll that re-implements exactly those 22 symbols
    # on top of Galaxy. Verified by dumping both PEs: the GOG file (427 008 B) exports precisely the 22
    # names the exe imports — no more — and its own import table names Galaxy64.dll for 11 `galaxy::api::`
    # free functions (Init, Shutdown, ProcessData, User, Friends, Apps, Stats, Networking, Matchmaking,
    # ListenerRegistrar, GameServerListenerRegistrar). Valve's genuine file in the Steam depot is a
    # different binary (121 256 B, 62 exports). So the chain to neutralize on GOG is
    # exe → GOG's steam_api64.dll → Galaxy64.dll, and the right cut is at the BOTTOM of it:
    wine.galaxyStubDlls = lib.mkIf (config.fetcher == "gog") [ "x64/Galaxy64.dll" ];
    # …bind the no-op stub over Galaxy64.dll. NB this row is now LIVE ON BOTH ARCHES: the stub used to be
    # built only by the aarch64 ARM64EC toolchain, so `galaxyStub` was null on x86_64 and this knob silently
    # did nothing there; it now builds with nixpkgs' cross-mingw on x86_64 too (emulators/galaxy-stub).
    # UNVERIFIED HERE: this title has NOT been run with the stub actually bound — only cyberpunk-2077 and
    # iron-lung have. If it misbehaves on the GOG arm, this row is the first thing to drop. All 11 symbols
    # GOG's bridge
    # imports are already in emulators/galaxy-stub/src/symbols64.txt — CHECKED one by one, no additions
    # were needed — and the stub's accessors return a non-null dummy whose every slot returns 0, so the
    # bridge's `User()->…` / `Apps()->…` chains answer "offline / not signed in / 0" instead of
    # null-dereferencing. Same de-Galaxy pattern as skyrim-se and factorio, one layer deeper.
    #
    # RESIDUAL RISK ON THE GOG ARM, stated because it is the one thing the static analysis cannot close:
    # if the bridge gates DLC content on a Galaxy ownership query, the stub's "0" answer is "unowned". The
    # GOTY layer archives are unconditionally listed in default.archcfg and physically present, and the
    # engine's own manifest tolerates absent layers (header), so content loading is not obviously
    # entitlement-gated — but this is INFERENCE, not a playthrough. The observable if it is wrong: the
    # GOTY skins/runes/warbands and the two story campaigns missing from an otherwise working game.

    # The shipped Steam-API library path, declared UNCONDITIONALLY (the house rule — each payload carries
    # its own copy and each backend consumes only the flavour its loader can mean). Only the Steam arm
    # actually uses it: `steam.emu.enable` defaults to `fetcher == "steam"`, and on wine union-replacement
    # at a declared `.dll` is the ONLY mechanism (PE has no preload), so mk-app.nix would refuse the build
    # outright if this were missing. gbe_fork's PE shim exports all 22 symbols this exe imports — verified
    # by diffing its export table against the exe's import list, the triage modules/steam-emu.nix
    # prescribes — so the pinned 1.64 shim is a drop-in and needs no bump for this title.
    steam.emu.libPaths = [ "x64/steam_api64.dll" ];

    # ── DLC (Steam arm only) ──────────────────────────────────────────────────────────────────────────
    # The 20 depots the packaging account owns: 19 single-file `layerNN_dlc_*.arch05` entitlement layers
    # (skins, warbands, runes, challenge modes, and the two story campaigns Lord of the Hunt / The Bright
    # Lord) plus 311670, the free HD Content texture pack. Each is a PURE ADDITION to the base depot —
    # verified: not one of the 41 files exists in depot 241931 — so enabling them is a directory union with
    # no base file shadowed and no store copy of the 43 GB base.
    #
    # `mkIf onSteam` is not defensive dressing: on the GOG arm this content is ALREADY IN THE BASE PAYLOAD
    # (header), so an empty available-set is the accurate statement. It also keeps `withAllDlc` honest —
    # on GOG there is nothing to enable because nothing is missing.
    #
    # Declaring these is the whole job on the Steam side: steam.emu is already on (Steam fetch), so the
    # entitlement list is PROJECTED from these same rows through each depot derivation's own identity
    # (`depotId`, since no row needs a `dlcAppId`) — no hand-written ownership list exists to drift.
    #
    # NAMING CAVEAT: the attr names and the `title` strings in versions.json are DERIVED FROM THE ARCHIVE
    # FILENAME each depot ships (`Layer53_DLC_BloodHunters.arch05` → `blood-hunters`), not copied from a
    # store listing — two of them are corrected to the engine's own spelling in default.archcfg
    # (`layer13_dlc_EndChallenge` is `Layer13_DLC_EndlessChallenge` there, and `Layer22_DLC_BlackHand` is
    # `Layer22_DLC_PowerOfShadow`). They are stable identifiers and plausible display names, but they are
    # not authoritative marketing names; the only place they surface is the game's own DLC list.
    dlc.available = lib.mkIf onSteam (lib.mapAttrs (_: fetchSteamDepot) versions.dlc);
  }
)
