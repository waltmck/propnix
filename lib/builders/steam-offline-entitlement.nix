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
# to assume it belongs to someone. Identity is left entirely to gbe_fork: it generates one and saves it in
# its GLOBAL settings — persistent on wine (the users overlay), per-launch on thin (the ephemeral view).
# The local tree here deliberately leaves `[user::general]` unset so that global value is what the shim
# resolves. (The launcher used to seat the stored Steam account's SteamID64 there; that seeding was
# removed — it read the credential store as the launching human, which the group-ownership contract does
# not permit on declarative/shared hosts, and it never delivered the stable identity it was added for.)
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
  # The STEAMSTUB arm of the same placement, keyed by the SAME paths as `mirror`:
  # `{ "<path>" = { proxy; realName; extra; extraName; }; }`. A path that appears here gets THREE files in
  # its directory instead of one — the proxy AT the shipped path, the gbe_fork lib under `realName` (the
  # proxy's forwarder target), and `extra` under `extraName` (gbe_fork's in-memory SteamStub patcher) —
  # because a SteamStub-wrapped exe never asks the on-disk steam lib anything. The whole argument, with the
  # relay measurements behind it, is in emulators/gbe-fork/steamstub-proxy.nix; this builder only places
  # the files. Unset (the default) leaves every mirror as the plain one-file replacement.
  stubProxies ? { },
  # Whether the shim should PRETEND THE STEAM CLIENT IS IN OFFLINE MODE (`[main::connectivity] offline`).
  # `true` matches the module default; see `mainIni` below for what the key actually reaches.
  steamOffline ? true,
  # The `steam_interfaces.txt` contents, or `null` for `defaultInterfaces` below (the modern revisions).
  # A game whose SHIPPED steam_api dll advertises an OLDER SDK must pass its own list — see the
  # `defaultInterfaces` comment for why that is a correctness requirement and not a nicety.
  interfaces ? null,
  pname ? "steam-offline-entitlement",
}:
let
  # `<appid>=<name>` per line under `[app::dlcs]`, in attr-name order (Nix attrsets iterate name-sorted,
  # so the output is deterministic). `#` and `;` start INI comments upstream, so strip them from titles
  # rather than emit a line that silently parses as one.
  dlcLine =
    n: e: "${toString e.appId}=${lib.replaceStrings [ "#" ";" "\n" ] [ "" "" " " ] (e.title or n)}";
  # The DLC entitlement config (gbe_fork dialect). `unlock_all=0` is stated EXPLICITLY every time — the
  # upstream default is 1 — followed by the owned list; see the header for why this is always emitted.
  appIni = lib.concatMapStrings (l: "${l}\n") (
    [
      "[app::dlcs]"
      "unlock_all=0"
    ]
    ++ lib.mapAttrsToList dlcLine dlc
  );
  # Report the client as offline (the gbe_fork spelling of the ancestor's `offline.txt`).
  #
  # WHAT THIS KEY ACTUALLY REACHES — measured in the pinned source, because the name overpromises and an
  # earlier revision of this comment claimed it meant "nothing reaches for the network or a lobby". It does
  # not. `[main::connectivity] offline` is read once (dll/settings_parser.cpp: `steam_offline_mode`) into
  # `Settings::offline`, and `Settings::is_offline()` has exactly THREE call sites in the whole tree, all in
  # dll/steam_user.cpp:
  #
  #     BLoggedOn()      → `return !settings->is_offline();`            → false
  #     BConnected()     → `return !settings->is_offline();`            → false
  #     GetLogonState()  → k_ELogonStateNotLoggedOn instead of …LoggedOn
  #
  # Nothing else consults it. The shim's actual network behaviour is governed by the separate
  # `disable_networking` / `disable_lan_only` keys, which we leave at their defaults either way — so this
  # key is a pure STATEMENT ABOUT LOGON STATE, not a network switch. Upstream's own documentation of it
  # (post_build/steam_settings.EXAMPLE/configs.main.EXAMPLE.ini) says the same and cuts both ways:
  # "1=pretend steam is running in offline mode, mainly affects the function `ISteamUser::BLoggedOn()` /
  # Some games that connect to online servers might only work if the steam emu behaves like steam is in
  # offline mode".
  #
  # `1` stays the default because it is the honest answer for the offline-by-construction case this module
  # exists to serve: there IS no Steam session here, so a game that asks "am I logged on?" should be told
  # no. But a title whose boot links Steam to a second account system can read that "no" as "wait for the
  # client to come back" and sit there forever, which is why it is now a knob (`steam.emu.offline`) rather
  # than a constant — see pkgs/games/victoria-3, where flipping it alone turns "no log at all" into the
  # engine's full log set and a D3D11 device. (It is NOT a general cure for a title that stops at Steam
  # init, and the two cases look alike from the syscall side — both are wine's `server_select` waiting on a
  # `wake_up_reply` that never comes. pkgs/games/rust stops INSIDE `SteamAPI_Init`, before this key is ever
  # consulted, and flipping it there changes nothing; only a PE-level backtrace separates them.)
  mainIni = ''
    [main::connectivity]
    offline=${if steamOffline then "1" else "0"}
  '';
  # ── `steam_interfaces.txt` — WHICH INTERFACE REVISION THE LEGACY ACCESSORS HAND OUT ──────────────────
  # Point the legacy global accessors at the same interface revisions the modern
  # `SteamInternal_FindOrCreateUserInterface` path resolves, so both routes agree if a game uses each.
  #
  # NOT "harmless when unused" — an earlier revision of this comment said so, and pkgs/games/cities-skylines
  # is the measured counter-example. dll/dll.cpp holds one `old_<itf>[128]` string per interface, each
  # initialised to the version the shim was COMPILED against (`static char old_client[128] =
  # STEAMCLIENT_INTERFACE_VERSION;`), and dll/settings_parser.cpp's `try_parse_old_steam_interfaces_file()`
  # overwrites them from THIS FILE — matching a line to a slot by substring (`SteamClient` → CLIENT, …), so
  # a slot with no line here KEEPS the modern revision. `SteamClient()` then returns
  # `SteamInternal_CreateInterface(old_client)`, and dll/dll.cpp casts that to the REQUESTED version's class
  # (`ISteamClient001` … `ISteamClient017` … each a real, differently-shaped vtable).
  #
  # So the version named here IS the vtable layout the game gets. A game built against an older SDK walks
  # that pointer with ITS header's layout, and the two must agree slot-for-slot. Cities: Skylines (SDK 1.34,
  # `SteamClient017`) does not survive the disagreement: modern `ISteamClient` dropped
  # `GetISteamUnifiedMessages`, so 017's slot 25 lands on the shim's `GetISteamController`, which does not
  # recognise `STEAMUNIFIEDMESSAGES_INTERFACE_VERSION001` and calls
  # `report_missing_impl_and_exit()` — a MODAL "Missing interface" MessageBox followed by
  # `std::exit(0x4155149)`. OBSERVED, screenshotted, x86_64-linux 2026-09-03.
  #
  # The list below is the MODERN default, which is right for every title packaged so far whose shipped
  # steam_api dll advertises the current SDK (pkgs/games/civilization-6 names it explicitly). A title on an
  # older SDK passes `interfaces` — read the revisions out of ITS OWN shipped `steam_api(64).dll`, which is
  # exactly what upstream's `generate_interfaces_file` tool does.
  defaultInterfaces = [
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
  itfs = if interfaces == null then defaultInterfaces else interfaces;
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
    printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep "\n" itfs)} > steam_interfaces.txt
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
          # "" for a root-level entry, "<dir>/" otherwise — so the siblings below land beside the lib
          # whichever shape the declared path has.
          dir = if parent == "." then "" else "${parent}/";
          sp = stubProxies.${p} or null;
        in
        (
          if sp == null then
            ''
              install -Dm444 ${replacement} ${lib.escapeShellArg p}
            ''
          else
            # SteamStub: the PROXY takes the shipped name, the real shim moves one name over (the proxy's
            # forwarders name it), and the patcher joins them. All three must share a directory — the
            # proxy resolves its patcher off its OWN module path, and gbe_fork's beside-the-library probe
            # resolves `steam_settings/` off the shim's.
            ''
              install -Dm444 ${sp.proxy}/${sp.dllName} ${lib.escapeShellArg p}
              install -Dm444 ${replacement} ${lib.escapeShellArg "${dir}${sp.realName}"}
              install -Dm444 ${sp.extra} ${lib.escapeShellArg "${dir}${sp.extraName}"}
            ''
        )
        + lib.optionalString (parent != ".") ''
          cp -r steam_settings ${lib.escapeShellArg "${parent}/steam_settings"}
          cp steam_interfaces.txt ${lib.escapeShellArg "${parent}/steam_interfaces.txt"}
        ''
      ) mirror
    )}
    echo "steam-offline-entitlement: app ${toString appId}, $(($(grep -c . steam_settings/configs.app.ini) - 2)) owned DLC, ${toString (lib.length (lib.attrNames mirror))} mirror(s)"
  ''
