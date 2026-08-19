# modules/steam-emu.nix — the framework's OFFLINE STEAM ENTITLEMENT module (the `steam.*` namespace):
# wires lib/builders/steam-offline-entitlement.nix (the LGPL gbe_fork shim, emulators/gbe-fork.nix, copied
# beside a generated settings tree) into every Steam-fetched THIN game, so an engine that asks the
# (absent) Steam client whether the owner's already-decrypted DLC is owned gets the answer automatically.
# Imported by mk-app.nix alongside app-options; a game normally sets NOTHING here — `steam.appId` derives
# from its Steam fetch rows and `steam.emu.enable` follows the fetcher/platform axes.
#
# WHAT IT WIRES (the builder's header carries the placement rationale):
#   * `box64.guestPreload` — the shim copy inside the settings tree; each thin backend translates it
#     to its loader's spelling (BOX64_LD_PRELOAD / LD_PRELOAD). The shim's symbols interpose the shipped
#     steam lib on the game's PLT lookups (engines that LINK libsteam_api — Stellaris), and on native/FEX
#     the beside-the-library settings probe resolves right into the settings tree.
#   * `extraLowers` — the same tree unioned into the game dir (box64's CWD-fallback discovery; box64
#     never file-maps guest libraries, so the beside-the-library probe cannot work there).
#   * per `.so` entry of `steam.emu.libPaths`, three `extraBinds` rows — the SAME settings-tree shim bound
#     OVER the game's shipped copy, plus `steam_settings/` + `steam_interfaces.txt` bound beside it. This
#     serves engines that dlopen the lib by EXPLICIT PATH, which no preload can interpose (Unity native
#     plugins — hollow-knight): the file AT the path the engine opens IS the shim. Binding the settings
#     tree's own copy (not the shim package's store path) keeps it inode-identical to the preload, so
#     glibc's dev:ino dlopen dedup returns the one already-loaded instance rather than a second shim with
#     separate state — and the beside-the-library probe finds real settings whichever path the mapping is
#     recorded under.
#   * per `.dll` entry, a MIRROR inside the settings tree (builders/steam-offline-entitlement.nix): the
#     matching gbe_fork steam_api(64).dll at the shipped path, settings beside it. WINE is served entirely
#     by that + `extraLowers`: the wine game overlay ranks extra lowers ABOVE the payload, so the union
#     replaces the shipped dll in place, and the PE loader file-maps DLLs properly (GetModuleFileName), so
#     the beside-the-library probe just works — no preload (PE has none), no binds, no CWD fallback.
#
# The entitlement list is a PROJECTION of `dlc.enabled` through the depot derivations' own identity
# (fetchSteamDepot passthru): a row's `dlcAppId` when versions.json states one, else its `depotId` — the
# Paradox convention, where each DLC ships as its own depot of the base app and the depotId IS the DLC's
# store appid. There is no hand-maintained list that could name something unowned: a depot derivation only
# exists because Steam issued this account its decryption key (eresult 15 otherwise), and a missing
# settings tree fails INVERTED upstream ("unlock everything"), which is why the wiring is all-or-nothing.
#
# LIMITS:
#   * On WINE, a declared `.dll` libPath is the ONLY mechanism — an enabled emu with none would be a
#     silently-inert shim (the game loads its genuine dll, every DLC reads unowned), so mk-app.nix refuses
#     that combination legibly instead.
#   * The shim answers only the Steamworks surface its pin knows (gbe_fork tracks the current SDK — 1.64
#     at this pin, covering every interface hollow-knight's SDK-1.60 lib carries, verified by symbol
#     diff). A FUTURE game built against a newer SDK than the pin fails the same way the predecessor
#     goldberg-emu 0.2.5 failed hollow-knight: the lib loads, init throws EntryPointNotFoundException, black
#     screen — WORSE than absence. Triage: `nm -D <game's libsteam_api.so>` and check its newest entry
#     points/interface strings exist in gbe_fork's .so; if not, bump emulators/gbe-fork.nix first.
#
# steam.emu SUPERSEDES `maskFiles` for the steam lib: the mask's whiteout re-overlays the file's parent,
# which EINVALs once this module's `extraLowers` makes the game dir multi-lower — and with the shim bound
# over / mirrored over / interposed ahead of the shipped copy, absence is no longer the goal anyway. A
# steam game keeps a mask only where the emu is deliberately disabled.
{
  lib,
  knobTypes,
  mkSteamOfflineEntitlement,
  # The shim package (emulators/gbe-fork.nix): a prebuilt GUEST-x86_64 artifact, loaded INTO the emulated
  # process — inherently the guest arch on every host, so no pkgsGuest split arises. Its NEEDED set
  # (glibc/libstdc++/libgcc_s) is appended to the guest lib union by the thin backends whenever the emu is
  # enabled.
  gbeFork,
}:
{ config, ... }:
let
  cfg = config;
  # `libPaths` classified by FLAVOR — a game declares every shipped steam-lib path unconditionally (each
  # payload carries its own), and each backend consumes only the ones its loader can mean: `.so` entries →
  # the thin bind-over rows; `steam_api(64).dll` entries → wine union-replacement mirrors. Anything else
  # is a legible error (the mirror must pick a replacement flavor).
  soPaths = lib.filter (lib.hasSuffix ".so") cfg.steam.emu.libPaths;
  dllPaths = lib.filter (lib.hasSuffix ".dll") cfg.steam.emu.libPaths;
  winShimFor =
    p:
    {
      "steam_api64.dll" = "${gbeFork}/share/gbe_fork/win/x64/steam_api64.dll";
      "steam_api.dll" = "${gbeFork}/share/gbe_fork/win/x86/steam_api.dll";
    }
    .${baseNameOf p} or (throw
      "propnix (${cfg.pname}): steam.emu.libPaths entry '${p}' has an unrecognized basename — expected steam_api.dll / steam_api64.dll / *.so."
    );
  unknownPaths = lib.subtractLists (soPaths ++ dllPaths) cfg.steam.emu.libPaths;
  # One entitlement row per ENABLED DLC, read off the depot derivation's own identity — never authored by
  # hand. The `or` throws mirror mkApp's own legibility (this projection can be forced before its check).
  entitlement =
    name:
    let
      d =
        cfg.dlc.available.${name} or (throw
          "propnix (${cfg.pname}): DLC '${name}' is not available (available: ${lib.concatStringsSep ", " (lib.attrNames cfg.dlc.available)})."
        );
    in
    {
      appId =
        if (d.dlcAppId or null) != null then
          d.dlcAppId
        else
          d.depotId or (throw
            "propnix (${cfg.pname}): DLC '${name}' is not a Steam depot fetch (no depotId/dlcAppId on the derivation) — steam.emu cannot project its entitlement."
          );
      # Row titles carry a human " (Steam)" provenance suffix; the emitted list holds a display name — strip it.
      title = lib.removeSuffix " (Steam)" (d.title or name);
    };
  settings = mkSteamOfflineEntitlement {
    appId =
      if cfg.steam.appId != null then
        cfg.steam.appId
      else
        throw "propnix (${cfg.pname}): steam.emu is enabled but steam.appId is null — it only derives from a Steam fetch matrix; set `steam.appId` explicitly.";
    pname = "${cfg.pname}-entitlement";
    shim = "${gbeFork}/share/gbe_fork/x64/libsteam_api.so";
    # Wine's union-replacement mirrors, one per declared .dll path. Built into the ONE shared tree (a
    # game's every backend uses the same settings drv): stray on thin — the payload's own dll wins
    # through the exec-bit skeleton, and nothing loads it — exactly as the root .so is stray on wine.
    mirror = lib.throwIfNot (unknownPaths == [ ]) "propnix (${cfg.pname}): steam.emu.libPaths entries with unrecognized suffix (need .so or .dll): ${toString unknownPaths}" (
      lib.genAttrs dllPaths winShimFor
    );
    dlc = lib.genAttrs cfg.dlc.enabled entitlement;
  };
in
{
  options.steam = {
    appId = lib.mkOption {
      type = knobTypes.lastWins;
      default =
        let
          rows = if cfg.fetcher == "steam" then cfg.fetchInfo.steam.${cfg.emulatedPlatform} else null;
        in
        if rows == null || rows == [ ] then null else (lib.head rows).appId or null;
      defaultText = lib.literalExpression "the appId shared by the selected Steam fetch rows (null off steam)";
      description = ''
        The game's base Steam appid — what the entitlement settings tree is keyed on (steam_appid.txt).
        Derives from the selected Steam fetch matrix rows; only needs setting when a game's store appid
        differs from the app its depots belong to.
      '';
    };
    emu.enable = lib.mkOption {
      type = knobTypes.lastWins;
      default = cfg.fetcher == "steam";
      defaultText = lib.literalExpression ''fetcher == "steam"'';
      description = ''
        Wire the offline Steam entitlement shim (gbe_fork + generated settings) into the launch. On by
        default for EVERY Steam-fetched build — one Steam story to reason about, DLC or not, vanilla
        included: the entitlement list is always emitted with an explicit `unlock_all=0` (an empty
        selection = an empty owned list = "own nothing"; the upstream default is "unlock everything"), so
        a DLC-less game answers "own nothing" to questions it never asks, and a plumbing failure shows up
        on every package rather than hiding until someone enables DLC. On wine the mechanism is
        union-replacement at the declared `libPaths` — enabling it there with no `.dll` path declared is
        a legible eval error rather than a silently-inert shim.
      '';
    };
    emu.libPaths = lib.mkOption {
      type = knobTypes.dedupList lib.types.str;
      default = [ ];
      description = ''
        Game-dir-relative paths of the game's own bundled Steam-API library copies, declared for EVERY
        payload unconditionally (each backend consumes only the flavor its loader can mean):

          * `*.so` (Steam Linux build) — for an engine that dlopens the lib by EXPLICIT PATH (Unity
            native plugins: "<exe>_Data/Plugins/libsteam_api.so"), which no preload can interpose: the
            shim is BOUND OVER it with `steam_settings/` + `steam_interfaces.txt` bound beside it, so the
            file at the path the engine opens IS the shim. An engine that LINKS the lib (Stellaris) is
            served by the preload alone and declares no .so path.
          * `steam_api.dll` / `steam_api64.dll` (Steam Windows build) — the wine placement: the matching
            gbe_fork dll is MIRRORED at that path inside the settings tree with settings beside it, and
            the tree unions ABOVE the payload (wine extraLowers outrank it), replacing the shipped dll.
            PE has no preload, so on wine a declared .dll path is the ONLY mechanism — required there.

        Declaring a path also replaces any `maskFiles` entry for it (see the header: the two don't
        compose, and absence is no longer the goal).
      '';
    };
  };

  config = lib.mkIf cfg.steam.emu.enable {
    box64.guestPreload = [ "${settings}/libsteam_api.so" ];
    extraLowers = [ settings ];
    # The thin bind-over rows (`.so` libPaths; the .dll flavor travels INSIDE the tree as wine mirrors).
    # "game/" is the launcher's THIN_GAME_DIR contract (config.rs); a sibling target that does not exist
    # in the game tree is stubbed into the game overlay by propnix-mount's child-skeleton machinery, so
    # only the lib path itself must already exist. Gated off wine, whose backend refuses extraBinds.
    extraBinds = lib.optionals (cfg.backend != "wine") (
      lib.concatMap (
        p:
        let
          parent = builtins.dirOf p;
          dir = if parent == "." then "game" else "game/${parent}";
          row = src: dst: {
            src = "${settings}/${src}";
            inherit dst;
            ro = true;
            create = false;
          };
        in
        [
          (row "libsteam_api.so" "game/${p}")
          (row "steam_settings" "${dir}/steam_settings")
          (row "steam_interfaces.txt" "${dir}/steam_interfaces.txt")
        ]
      ) soPaths
    );
  };
}
