# builders/steam-offline-entitlement.nix — a SELF-LOCATING entitlement tree for a bundled Steam-API
# reimplementation: the LGPL gbe_fork shim (emulators/gbe-fork) COPIED beside a generated settings tree
# that tells it which DLC this account owns. One derivation is both the preload target and the config it
# reads.
#
# WHY THIS EXISTS. Steam pins content by (appId, depotId, manifestId) and releases it only to an account that
# owns it — `fetchSteamDepot` cannot produce a tree for a DLC the account lacks, because Steam refuses the
# depot decryption key (eresult 15) before a byte is downloaded. The payload IS the proof of purchase. Some
# engines nevertheless resolve ENTITLEMENT at runtime through `libsteam_api.so`, and Valve ships no Steam
# client for every platform propnix runs on (there is none for 16K-page aarch64). On such a host the owner's
# own, already-downloaded, already-decrypted DLC reads as unowned. This closes that gap — and nothing else:
#
#   * `dlc` is the set of trees ACTUALLY MOUNTED for this build, threaded from `config.dlc.enabled` rather
#     than authored by hand. By construction it can only contain depots Steam decrypted for this account,
#     so the emitted entitlement list cannot name content the account does not own.
#   * Upstream unlocks EVERY DLC by default (`[app::dlcs] unlock_all` defaults to 1 — and its ancestor
#     unlocked everything when the list file was missing). We therefore always emit `configs.app.ini` with
#     an EXPLICIT `unlock_all=0` + the owned list: an empty `dlc` set yields an empty list — "own nothing",
#     never "own everything". That inversion is the whole safety property, now stated as a key rather than
#     hinging on file presence.
#
# HOW THE SHIM FINDS IT — TWO PLACEMENTS, because the answer depends on the loader. Upstream looks for
# `steam_settings/` (and `steam_interfaces.txt`) beside the loaded library, by readlink()ing the
# /proc/self/map_files entry covering one of its own functions (dll/base.cpp `get_lib_path`), and falls back
# to "." — the CWD — when that finds nothing. Both cases occur:
#
#   * NATIVE x86_64 (and FEX's guest ld.so): the probe succeeds — and because the preloaded shim is the COPY
#     inside THIS tree, it resolves right here, where the settings already sit. Nothing has to be mounted
#     into the shim package's read-only store path.
#   * box64: guest libraries are not file-mapped at all — no `libsteam_api.so` appears in the emulated
#     process's maps, not even the game's own copy — so the probe returns "." and the lookup resolves
#     against the CWD, which propnix sets to the game dir. Union this tree in there via `extraLowers`.
#
# Preload the copy (`box64.guestPreload = [ "${settings}/libsteam_api.so" ]`) AND union the tree into the
# game dir, and no backend needs special-casing: whichever way the loader answers, the shim reads the same
# list. Getting it wrong is silent and INVERTED — a `steam_settings/` the shim cannot find means "unlock
# everything", so a caller that wires only one placement can over-claim on the other backend.
#
# No local identity (account_name.txt / user_steam_id.txt) is written: entitlement does not key on it,
# and a package shipped to other people must not carry a baked-in account name or SteamID — it would be
# one identity shared by every install, and a plausible-looking SteamID64 in the source invites the reader
# to assume it belongs to someone. Identity is instead a RUNTIME, per-host fact: the launcher (steamid.rs,
# gated by the baked `steamEmu` flag) reads the SteamID64 out of the host's stored Steam credential and
# seats it in gbe_fork's GLOBAL settings inside the per-launch view — the local tree here deliberately
# leaves `[user::general]` unset so that global value is what the shim resolves. No credential → upstream
# makes an identity up per launch, exactly as before.
{
  lib,
  runCommandLocal,
}:
{
  appId, # the BASE game's Steam appid
  # Owned + mounted DLC: name → { appId; title; }. `appId` here is the DLC's own store appid, which for a
  # DLC shipped as its own depot of the base app IS the depotId — see pkgs/games/stellaris/versions.json.
  dlc,
  # The PAYLOAD-ABI `libsteam_api.so` (the caller picks gbe_fork's matching per-ABI build), copied at $out
  # — the THIN preload target.
  # COPIED, not symlinked: the beside-the-library probe resolves the mapping's BACKING file, and a
  # symlink's backing file is the shim package's own store path — where no settings live. The copy costs
  # ~9 MiB per DLC selection (identical copies hardlink under auto-optimise) and is what lets the probe
  # land here.
  #
  # `null` for a backend with no preload at all (wine, served entirely by `mirror`): the root `.so` is
  # stray there, and emitting it anyway would pull a whole foreign-ABI shim — cross toolchain, static
  # protobuf and all — into a pure-wine game's closure to place a file nothing ever opens.
  shim ? null,
  # MIRRORS, for backends where the placement mechanism is UNION-REPLACEMENT rather than preload+binds
  # (wine: extraLowers outrank the payload, and the PE loader file-maps DLLs so the beside-the-library
  # probe just works): `{ "<game-dir-relative shipped lib path>" = <replacement lib>; }`. Each entry
  # materializes the replacement lib AT that path with `steam_settings/` + `steam_interfaces.txt` copied
  # beside it — so unioning this tree over the game replaces the lib and seats its settings in one move.
  mirror ? { },
  pname ? "steam-offline-entitlement",
}:
let
  # `<appid>=<name>` per line under `[app::dlcs]`, in attr-name order (Nix attrsets iterate name-sorted,
  # so the output is deterministic). `#` and `;` start INI comments upstream, so strip them from titles
  # rather than emit a line that silently parses as one.
  dlcLine = n: e: "${toString e.appId}=${lib.replaceStrings [ "#" ";" "\n" ] [ "" "" " " ] (e.title or n)}";
  # The DLC entitlement config (gbe_fork dialect). `unlock_all=0` is stated EXPLICITLY every time — the
  # upstream default is 1 — followed by the owned list; see the header for why this is always emitted.
  appIni = lib.concatMapStrings (l: "${l}\n") (
    [
      "[app::dlcs]"
      "unlock_all=0"
    ]
    ++ lib.mapAttrsToList dlcLine dlc
  );
  # Report the client as offline (the gbe_fork spelling of the ancestor's `offline.txt`) so nothing
  # reaches for the network or a lobby.
  mainIni = ''
    [main::connectivity]
    offline=1
  '';
  # Point the legacy global accessors at the same interface revisions the modern
  # `SteamInternal_FindOrCreateUserInterface` path resolves, so both routes agree if a game uses each.
  # Harmless when unused: dll/dll.cpp only consults this to seed its `old_*` version fallbacks.
  interfaces = [
    "STEAMAPPS_INTERFACE_VERSION008"
    "SteamUser020"
    "SteamFriends017"
    "SteamUtils009"
    "STEAMUGC_INTERFACE_VERSION013"
    "STEAMREMOTESTORAGE_INTERFACE_VERSION014"
    "STEAMUSERSTATS_INTERFACE_VERSION011"
    "SteamMatchMaking009"
    "SteamMatchMakingServers002"
    "SteamNetworking005"
    "STEAMHTTP_INTERFACE_VERSION003"
    "SteamGameServer012"
  ];
in
runCommandLocal "${pname}-${toString appId}"
  {
    inherit appIni mainIni;
    passAsFile = [
      "appIni"
      "mainIni"
    ];
    meta.description = "Offline Steam entitlement shim + settings for owned, already-decrypted DLC of app ${toString appId}";
  }
  ''
    set -euo pipefail
    install -d "$out/steam_settings"
    cd "$out"
    ${lib.optionalString (shim != null) "cp ${shim} libsteam_api.so"}
    # Both spots: inside steam_settings/ (gbe_fork's documented location) AND beside the lib (the
    # ancestor's spot; harmless, and the libPaths bind rows reference the root copy).
    printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep "\n" interfaces)} > steam_interfaces.txt
    cp steam_interfaces.txt steam_settings/steam_interfaces.txt

    cd steam_settings
    printf '%s' ${lib.escapeShellArg (toString appId)} > steam_appid.txt
    cp "$mainIniPath" configs.main.ini
    # The entitlement list (`unlock_all=0` + owned rows). Written unconditionally — see the header — and
    # also what GetDLCCount()/BGetDLCDataByIndex() enumerate.
    cp "$appIniPath" configs.app.ini
    cd ..

    # The union-replacement mirrors (see the `mirror` param): the replacement lib at the shipped path,
    # settings + interfaces beside it. A root-level entry ("." parent) needs only the lib — the root
    # settings/interfaces above already sit beside it.
    ${lib.concatStrings (
      lib.mapAttrsToList (
        p: replacement:
        let
          parent = builtins.dirOf p;
        in
        ''
          install -Dm444 ${replacement} ${lib.escapeShellArg p}
        ''
        + lib.optionalString (parent != ".") ''
          cp -r steam_settings ${lib.escapeShellArg "${parent}/steam_settings"}
          cp steam_interfaces.txt ${lib.escapeShellArg "${parent}/steam_interfaces.txt"}
        ''
      ) mirror
    )}
    echo "steam-offline-entitlement: app ${toString appId}, $(($(grep -c . steam_settings/configs.app.ini) - 2)) owned DLC, ${toString (lib.length (lib.attrNames mirror))} mirror(s)"
  ''
