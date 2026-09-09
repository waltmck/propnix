# modules/steam-emu.nix — the framework's OFFLINE STEAM ENTITLEMENT module (the `steam.*` namespace):
# wires lib/builders/steam-offline-entitlement.nix (the LGPL gbe_fork shim, emulators/gbe-fork, copied
# beside a generated settings tree) into every Steam-fetched THIN game, so an engine that asks the
# (absent) Steam client whether the owner's already-decrypted DLC is owned gets the answer automatically.
# Imported by mk-app.nix alongside app-options; a game normally sets NOTHING here — `steam.appId` derives
# from its Steam fetch rows and `steam.emu.enable` follows the fetcher/platform axes.
#
# WHAT IT WIRES (the builder's header carries the placement rationale):
#   * `box64.guestPreload` — the shim copy inside the settings tree, contributed ONLY off the native
#     backend. Under box64/FEX the guest loader's spelling (BOX64_LD_PRELOAD / guest LD_PRELOAD) confines
#     the preload to emulated code, and it interposes the shipped steam lib for engines that LINK
#     libsteam_api without a declared path (Stellaris under box64). On NATIVE there is no preload at all:
#     plain LD_PRELOAD is inherited by every child the game spawns, and games shell out to HOST binaries
#     (Factorio execs `sh -c lsb_release` to stamp its log) — on a non-NixOS host the shim's nix-store
#     RUNPATH then drags a second glibc into a foreign-distro process, which dies with SIGBUS (observed:
#     every Factorio launch on Fedora coredumped its lsb_release child). Native is served entirely by the
#     bind-over rows below, the same replace-the-file story as wine: the real ld.so resolves both
#     DT_NEEDED and dlopen through the path, and the file AT the path is the shim.
#   * `extraLowers` — the same tree unioned into the game dir, ABOVE every game tree (box64's CWD-fallback
#     discovery; box64 never file-maps guest libraries, so the beside-the-library probe cannot work there).
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
#     points/interface strings exist in gbe_fork's .so; if not, bump emulators/gbe-fork first.
#
# steam.emu SUPERSEDES `maskFiles` for the steam lib: the mask's whiteout re-overlays the file's parent,
# which EINVALs once this module's `extraLowers` makes the game dir multi-lower — and with the shim bound
# over / mirrored over / interposed ahead of the shipped copy, absence is no longer the goal anyway. A
# steam game keeps a mask only where the emu is deliberately disabled.
{
  lib,
  knobTypes,
  mkSteamOfflineEntitlement,
  # The shim package (emulators/gbe-fork): one derivation carrying a build PER ABI — the Linux shims
  # compiled from source (the host's own arch natively, the other by cross-compilation), the Windows PE
  # shims from upstream's release of the same tag. Each is self-contained: nix's cc-wrapper records a
  # RUNPATH covering every dependency, so the thin backends inject nothing on its behalf.
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
  # The Linux shim is loaded INTO the game's own process, so it must be the PAYLOAD's ABI: the x86_64 build
  # for anything running x86_64 code (native or under box64), the aarch64 build for a native aarch64
  # payload. emulators/gbe-fork builds one per ABI from a single source description.
  #
  # Indexed through `gbeFork.linuxShims` — the PER-ABI derivations — never through the assembled
  # `${gbeFork}` tree. The tree is a symlinkJoin over every ABI, so referencing it would make ANY
  # steam.emu game (which is every Steam fetch by default) force all of them: on this host that means a
  # full pkgsCross bootstrap — a two-stage cross-GCC plus static protobuf/abseil/curl/mbedtls/opus/
  # portaudio, ~1300 derivations, none of them substitutable — to build an x86_64 library that an aarch64
  # payload will never load. `null` for the wine platforms, which have no preload and are served entirely
  # by the `.dll` mirrors below: the root `.so` is stray there (see the header), so emitting it would drag
  # a foreign-ABI shim into a pure-wine game's closure for a file nothing opens.
  linuxShim =
    {
      "aarch64-linux" = "${gbeFork.linuxShims.aarch64}/lib/libsteam_api.so";
      "x86_64-linux" = "${gbeFork.linuxShims.x64}/lib/libsteam_api.so";
      "x86_64-windows" = null;
      "i386-windows" = null;
    }
    .${cfg.emulatedPlatform}
      or (throw "propnix (${cfg.pname}): steam.emu has no gbe_fork shim for emulatedPlatform '${cfg.emulatedPlatform}' — add that ABI to emulators/gbe-fork, or set `steam.emu.enable = false` for this platform.");
  # The PE shims are upstream prebuilt bytes in their own derivation — again by passthru, so a wine game
  # pulls the two DLLs and nothing else.
  winShimFor =
    p:
    {
      "steam_api64.dll" = "${gbeFork.winPrebuilt}/share/gbe_fork/win/x64/steam_api64.dll";
      "steam_api.dll" = "${gbeFork.winPrebuilt}/share/gbe_fork/win/x86/steam_api.dll";
    }
    .${baseNameOf p}
    or (throw "propnix (${cfg.pname}): steam.emu.libPaths entry '${p}' has an unrecognized basename — expected steam_api.dll / steam_api64.dll / *.so.");
  # The SteamStub arm of the same placement (`steam.emu.steamStub`), one entry per declared `.dll` path.
  # gbe_fork's in-memory wrapper patcher is architecture-matched to the shim it rides with; the proxy is
  # built per (arch, shipped name) because its forwarder table is generated from THAT shim's exports.
  # `<base>_gbe.dll` is the name the real shim moves to — it only has to be a name the payload does not
  # already use, and it keeps the pair legible in a `ls` of the game dir.
  winStubFor =
    p:
    let
      dllName = baseNameOf p;
      arch = if dllName == "steam_api64.dll" then "x64" else "x86";
      extraName = "steamclient_extra_${arch}.dll";
      realName = "${lib.removeSuffix ".dll" dllName}_gbe.dll";
    in
    {
      inherit dllName realName extraName;
      extra = "${gbeFork.winPrebuilt}/share/gbe_fork/win/${arch}/${extraName}";
      proxy = gbeFork.steamStubProxy {
        inherit
          dllName
          realName
          extraName
          arch
          ;
        shim = winShimFor p;
      };
    };
  unknownPaths = lib.subtractLists (soPaths ++ dllPaths) cfg.steam.emu.libPaths;
  # "Name (Steam)" → "Name"; "Name (linux, Steam)" → "Name"; anything else is returned untouched.
  stripProvenance =
    s:
    let
      m = builtins.match "(.*) \\([^()]*Steam\\)" s;
    in
    if m == null then s else lib.head m;
  # One entitlement row per ENABLED DLC, read off the depot derivation's own identity — never authored by
  # hand. The `or` throws mirror mkApp's own legibility (this projection can be forced before its check).
  entitlement =
    name:
    let
      d =
        cfg.dlc.available.${name}
          or (throw "propnix (${cfg.pname}): DLC '${name}' is not available (available: ${lib.concatStringsSep ", " (lib.attrNames cfg.dlc.available)}).");
    in
    {
      appId =
        if (d.dlcAppId or null) != null then
          d.dlcAppId
        else
          d.depotId
            or (throw "propnix (${cfg.pname}): DLC '${name}' is not a Steam depot fetch (no depotId/dlcAppId on the derivation) — steam.emu cannot project its entitlement.");
      # Row titles carry a human PROVENANCE suffix, and it is not always the bare " (Steam)": a game that
      # pins the same DLC once per platform distinguishes the rows — "Factorio: Space Age (linux, Steam)".
      # The emitted list is a DISPLAY NAME the engine shows in its own DLC/Additional-Content UI, so strip
      # any trailing parenthesised tag that names the store rather than only the exact bare suffix, which
      # would leak "(linux, Steam)" straight into the game's UI.
      title = stripProvenance (d.title or name);
    };
  settings = mkSteamOfflineEntitlement {
    appId =
      if cfg.steam.appId != null then
        cfg.steam.appId
      else
        throw "propnix (${cfg.pname}): steam.emu is enabled but steam.appId is null — it only derives from a Steam fetch matrix; set `steam.appId` explicitly.";
    pname = "${cfg.pname}-entitlement";
    # PER-PLATFORM (see `linuxShim`): the .so is loaded into the game's OWN process, so it has to be that
    # process's arch. This makes the settings tree platform-specific, which is correct — a game's aarch64
    # and x86_64 builds cannot share one shim — and costs nothing, since the tree is a few KB of generated
    # config beside a copy of the library.
    shim = linuxShim;
    # Wine's union-replacement mirrors, one per declared .dll path. Built into the ONE shared tree (a
    # game's every backend uses the same settings drv): stray on thin — nothing there loads a PE — exactly
    # as the root .so is omitted entirely on wine, which has no preload to point at it.
    mirror =
      lib.throwIfNot (unknownPaths == [ ])
        "propnix (${cfg.pname}): steam.emu.libPaths entries with unrecognized suffix (need .so or .dll): ${toString unknownPaths}"
        (lib.genAttrs dllPaths winShimFor);
    # OPT-IN, per title: a proxy in front of every mirrored dll is only correct for a payload whose exe is
    # actually SteamStub-wrapped, and it is one more moving part everywhere else.
    stubProxies = lib.optionalAttrs cfg.steam.emu.steamStub (lib.genAttrs dllPaths winStubFor);
    steamOffline = cfg.steam.emu.offline;
    interfaces = cfg.steam.emu.interfaces;
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
    emu.offline = lib.mkOption {
      type = knobTypes.lastWins;
      default = true;
      description = ''
        Whether the shim reports the Steam client as being in OFFLINE MODE
        (`[main::connectivity] offline` in the generated `configs.main.ini`).

        This is a statement about LOGON STATE, not a network switch. Measured in the pinned gbe_fork
        source, the key is read once into `Settings::offline` and consulted at exactly three call sites,
        all in `dll/steam_user.cpp` — `BLoggedOn()` and `BConnected()` return `!is_offline()`, and
        `GetLogonState()` returns `k_ELogonStateNotLoggedOn` instead of `k_ELogonStateLoggedOn`. What the
        shim does on the wire is governed by the separate `disable_networking` / `disable_lan_only` keys,
        which propnix leaves at their upstream defaults regardless of this option.

        `true` (the default) is the honest answer for everything this module normally serves: there is no
        Steam session behind the shim, so a game that asks "am I logged on?" is told no, and an engine
        that has an offline path takes it. Set it `false` ONLY for a title that is online-only by nature
        (`online = true`, no single-player mode), where a client can read "not logged on" as "the Steam
        client is coming back" and block on a logon that will never arrive. Flipping it does not give the
        game a real Steam session and does not help it authenticate to any server that validates tickets
        with Valve — it only stops the shim from volunteering a "no".
      '';
    };
    emu.interfaces = lib.mkOption {
      type = knobTypes.lastWins;
      default = null;
      description = ''
        The contents of the shim's `steam_interfaces.txt` (one interface-version string per line), or
        `null` for the modern default in builders/steam-offline-entitlement.nix.

        This is NOT cosmetic and it is NOT only about the "old" flat accessors: the version named here is
        the VTABLE LAYOUT the shim's global accessors hand out. gbe_fork keeps one `old_<itf>` string per
        interface, initialised to the revision it was compiled against and overwritten from this file;
        `SteamClient()` returns `SteamInternal_CreateInterface(old_client)`, which casts the one
        implementation object to that version's class — `ISteamClient001` … `ISteamClient017` … are
        distinct, differently-shaped vtables. A game built against an older SDK walks that pointer with ITS
        header's slot numbering, so the two layouts must agree.

        SET THIS whenever the game's OWN shipped `steam_api(64).dll` advertises an older SDK than the
        default list. Read the revisions straight out of that dll (`strings`; upstream's
        `generate_interfaces_file` tool does exactly this) — that file is the ground truth for what the
        engine beside it will call. pkgs/games/cities-skylines is the worked example, and the measured
        failure of getting it wrong: modern `ISteamClient` dropped `GetISteamUnifiedMessages`, so
        `SteamClient017`'s slot 25 landed on the shim's `GetISteamController`, which does not recognise
        `STEAMUNIFIEDMESSAGES_INTERFACE_VERSION001` and answers with a MODAL "Missing interface" MessageBox
        and `std::exit()`.
      '';
    };
    emu.steamStub = lib.mkOption {
      type = knobTypes.lastWins;
      default = false;
      description = ''
        Set this when the game's own exe is wrapped in Valve's SteamStub DRM. It changes what the wine
        mirror stages at each declared `.dll` `libPaths` entry: instead of gbe_fork's shim alone, a small
        propnix-built PROXY takes the shipped name, the shim moves one name over
        (`steam_api64_gbe.dll`) behind the proxy's forwarders, and gbe_fork's `steamclient_extra_*.dll`
        joins them. The proxy's only added behaviour is to load that patcher from its DllMain.

        WHY IT IS A SEPARATE KNOB AND NOT AUTOMATIC. A SteamStub'd exe carries the wrapper in a `.bind`
        section with the PE entry point inside it, decrypts itself, then MANUALLY MAPS an embedded copy of
        Valve's Steam API and asks that for the ownership answer. Replacing the on-disk `steam_api64.dll` —
        everything `steam.emu` otherwise does — cannot reach it, so a wrapped title fails with Valve's
        "Application load error 3:…" (or an immediate exit) no matter how correct the shim is; and an
        UNWRAPPED title gains nothing from the extra two files. Which one a payload is, is a fact about its
        bytes: a 10th section named `.bind` whose range contains `AddressOfEntryPoint`.

        The mechanism, the measurements behind it (a wine `+relay` trace placing the wrapper's Steam calls
        in an anonymous mapping rather than any module), and the two alternatives that were tried and
        MEASURED not to work, are in emulators/gbe-fork/steamstub-proxy.nix. VERIFIED on
        pkgs/games/civilization-6 (x86_64-linux, 2026-09-03): without it the process exits 53 having
        written nothing; with it the game reaches its rendered front end.
      '';
    };
    emu.libPaths = lib.mkOption {
      type = knobTypes.dedupList lib.types.str;
      default = [ ];
      description = ''
        Game-dir-relative paths of the game's own bundled Steam-API library copies, declared for EVERY
        payload unconditionally (each backend consumes only the flavor its loader can mean):

          * `*.so` (Steam Linux build) — the shim is BOUND OVER it with `steam_settings/` +
            `steam_interfaces.txt` bound beside it, so the file at the path the engine opens IS the shim.
            On the NATIVE backend this is the ONLY mechanism (there is no preload — see the header), and
            it serves both loading styles: the real ld.so resolves a linked DT_NEEDED and an
            explicit-path dlopen (Unity native plugins: "<exe>_Data/Plugins/libsteam_api.so") through the
            same file. Under box64/FEX the guest preload additionally interposes for an engine that LINKS
            the lib without a declared path (Stellaris) — but declare the path anyway: mk-app.nix
            requires it wherever the native backend is reachable, and the bind is inode-identical to the
            preload so the two never fight.
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
    # Guest-loader backends only (see the header): native gets NO preload — plain LD_PRELOAD leaks into
    # every spawned host process, and the bind-over rows below already replace the file the real ld.so
    # resolves. mk-app.nix enforces that a native build declares its `.so` path, mirroring the wine rule.
    box64.guestPreload = lib.optionals (cfg.backend != "native") [ "${settings}/libsteam_api.so" ];
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
