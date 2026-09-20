# Sid Meier's Civilization V (Steam, Aspyr's i386 LINUX build) — on aarch64 through emulators/fex-linux.
# aarch64-ONLY for now: an x86_64 host would run this payload natively, but nothing there supplies the
# 32-bit libGL the binary hard-links (see the broken block at the bottom), so that host is refused.
#
# Firaxis's Civ5 engine: a 32-bit C++ core (`libCvGameCoreDLL.so`) with a Lua 5.1 gameplay layer over a
# SQLite gameplay database, Bink video and Miles audio, all shipped beside the binary. The spec itself is
# ARCH-AGNOSTIC — mkApp + the scope pick the runner, and the SAME i386 payload (content-addressed FODs)
# would serve both hosts.
#
# Steam-only: Civ V is not sold on GOG. Requires an account that owns the title (`propnix cred add steam`)
# — and, for the DLC below, one that owns each pack.
#
#   nix run .#civilization-5 --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux
#
# ── WHY THE LINUX BUILD AND NOT THE WINDOWS ONE ───────────────────────────────────────────────────────
# Because the Windows executable in the depot IS NOT A PROGRAM. It is CEG-stripped: Valve's Custom
# Executable Generation ships a template in the depot and generates the runnable, per-user exe at install
# time, so the runnable bytes are not depot content at all and `fetchSteamDepot` can never obtain them.
# Measured on the real payload, not inferred from CEG being a Windows mechanism:
#   * `AddressOfEntryPoint` of CivilizationV.exe is a three-instruction stub — `call <notify Steam>;
#     push $0x8000dead; call *KERNEL32!ExitProcess` — with no conditionals and no fall-through. All three
#     game exes (DX9, DX11, Tablet) have that same shape, and every launch exits 173 (0x8000dead & 0xff)
#     having drawn nothing and opened not one game asset.
#   * Each exe's export table names the original build: `Civ5Win32Final Release Steam CEG.exe`, and a
#     sibling of the stub is a guarded `MessageBoxA(NULL, "This file has been stripped", …)` — Valve's own
#     wording for this state.
# That is platform-independent: no emulator, renderer or Steam-API shim can reach code that exits at its
# entry point, and this is the general limitation of raw depot downloads for CEG titles. (The details of
# the stub's `STEAM_DRM_IPC` handshake were decoded along the way and are in the git history; answering it
# only shortened the refusal from ~33 s to ~13 s.)
#
# The Linux build carries none of that — again checked against the artifact:
#   * `Civ5XP` (36 MB i386 ELF) enters a textbook glibc `_start` whose `main` tail-calls
#     `ASL::Main(…)` — Aspyr's shim layer, taking the original WinMain as a function pointer. CEG replaced
#     the WINDOWS PE's entry point; this ELF was built separately and reaches the game's own code.
#   * none of the Windows build's DRM markers (STEAM_DRM_IPC, STEAM_DIPC_CONSUME, STEAM_START_ACK_EVENT,
#     .STEAMSTART, "has been stripped") appears in any of the depot's 37 files, none of its 821 imports
#     matches ceg/drm/secret/Steamworks_, `.text` entropy is 6.23 and it keeps 43706 dynamic symbols.
#   * and it RUNS (see THE RUNNING RECIPE below).
#
# ── THE THREE BASE DEPOTS ─────────────────────────────────────────────────────────────────────────────
# App 8930's English Linux install is three depots (the others — 282322-282325 — are french/german/
# italian/spanish text, none pinned, matching the English-only choice):
#   282301    87 MB  Civ5XP, the gameplay cores (libCvGameCoreDLL{,_Expansion1,_Expansion2}.so) and the
#                    bundled runtime .so's (libc++/libcxxrt, TBB, OpenAL, Miles, OpenSSL, libsteam_api)
#   282300   4.4 GB  `steamassets/` — every asset, the movies, the Miles data, the EULAs
#   282302   2.4 MB  `steamassets/assets/gameplay/xml` — the English gameplay text
# 282301 LEADS THE LIST because it holds the executable and the engine libraries; the trees union into one
# game dir, and the Linux layout is entirely lowercase with the assets under `steamassets/` (the Windows
# build's `Assets/`).
#
# Note what ISN'T a base depot here, unlike the Windows side: the deluxe soundtrack. On Linux it rides in
# the Digital Deluxe DLC depot (282309, `dlcappid` 16864) instead of a base depot of its own, so an owner
# who wants it enables that pack. And there is no Linux equivalent of the 2K LaunchPad (a Qt5 exe picker)
# or of the two `-gamecore` DLC depots: on Linux the expansions' gameplay cores are ELF .so's and ship in
# 282301 with the other binaries, so each pack below is exactly one depot.
{
  lib,
  mkApp,
  fetchSteamDepot,
  runCommandLocal,
  icoutils,
}:
let
  versions = lib.importJSON ./versions.json;

  # ── THE ICON SOURCE: 45 MB OF WINDOWS EXE, FETCHED FOR ITS PE RESOURCES AND NOTHING ELSE ────────────
  # The Linux depots ship NO icon — no .ico, no .icns, no app .png (a full extension census of all three
  # confirms it), and the only bitmap of the game's logo in them is a 320x240 Logitech-keyboard-LCD image
  # of the WORDMARK on an opaque black plate, which makes an illegible smudge at 48px. The game's real
  # icon is the gold "V" emblem, and it exists in the depots in exactly two places: `Civ5Icon.ico` in the
  # 3.1 GB Windows CONTENT depot, and — identical, right down to the 256x256 PNG frame — the PE
  # resources of the Windows exes, which are a 45 MB depot of their own. So this pins the cheap one.
  #
  # `icon.auto` cannot serve this: auto-extraction on a thin backend reads Unity's UnityPlayer.png, and
  # this is not a Unity game, so it would fail the build loudly (which is that option's design, and
  # correct). The `.ico` route reaches the shared raster pipeline instead, which picks the LARGEST frame
  # by area — documented in lib/icons/pipeline.sh with this very file as its example.
  #
  # THE PIN LIVES IN versions.json's `extra` SECTION, not in `fetchInfo`. A
  # `fetchInfo.steam."i386-windows"` row would declare the Windows build AVAILABLE — it is not, it is
  # CEG-stripped and cannot execute (see below) — and would add a pinned pair to the resolver, the CI
  # matrix and the README. `extra` is where a pin goes that is a BUILD-TIME INPUT rather than payload
  # content: `propnix pin` walks and ADVANCES it with everything else (pin/versions.rs `PinLoc::Extra`),
  # so this depot moves with the game as one unit instead of rotting at whatever manifest it was first
  # written with, while nothing in it is ever mounted.
  iconIco =
    runCommandLocal "civilization-5-icon-ico"
      {
        nativeBuildInputs = [ icoutils ];
        meta.description = "Civ V's icon group, extracted from the Windows exe's PE resources";
      }
      ''
        mkdir -p $out
        wrestool -x -t 14 ${fetchSteamDepot versions.extra.icon}/CivilizationV.exe -o $out/Civ5Icon.ico
      '';
in
mkApp (
  # `config` is read for exactly one thing: which DLC packs are mounted, so the engine-appid rows below
  # can be gated on them.
  { config, ... }:
  {
    pname = "civilization-5";
    maintainers = [ "waltmck" ];
    appid = "civilization-5";
    name = "Sid Meier's Civilization V";

    fetchInfo = versions.fetchInfo;

    # Aspyr's binary. One executable, no launcher and no renderer choice: the Linux port is GL-only (the
    # Windows build's DX9/DX11/Tablet split has no counterpart), and the DX9 name in the settings file it
    # writes (`GraphicsSettingsDX9.ini`) is just the port's inherited spelling for its GL renderer.
    # cwd = the game root, propnix's default, so no `workingDir`: the engine resolves `steamassets/`
    # relative to the install directory and the binary sits at that root.
    exe = "Civ5XP";

    # The game's own icon — the gold "V" emblem, whose 256² frame the shared pipeline autocrops and
    # recentres into the hicolor theme + splash. Source and its cost: see `iconIco` in the `let` above.
    icon.png = "${iconIco}/Civ5Icon.ico";
    # Monochrome variant for symbolic contexts. Vendored (MIT, Tabler Icons) rather than derived from the
    # emblem above: a symbolic icon has to be flat single-colour line art, which a shaded gold glyph is
    # not, and the game ships no such asset. See the file's own header for source + licence.
    icon.symbolic = ./civilization-5-symbolic.svg;

    # ── THE RUNNING RECIPE ──────────────────────────────────────────────────────────────────────────────
    # Two environment variables, both load-bearing and both measured on this host (aarch64, 16 KiB pages,
    # emulators/fex-linux):
    #
    #   * SDL_VIDEODRIVER=x11 — WITHOUT IT THE GAME EXITS 0 IN SILENCE. This is SDL2 as of 2014: it tries
    #     its Wayland backend first, that fails, and `ASL::SDL::Init()` then calls `ASL::ErrorDie` →
    #     `ASL::Exit` with nothing on stdout, nothing in the logs and no window. (Found with an i386
    #     LD_PRELOAD stub hooking `exit` for a symbolised guest backtrace, then `vsnprintf` to print the
    #     driver name SDL was formatting.) X11 here means Xwayland, which propnix assumes; FEX thunks
    #     GL/EGL/Wayland but NOT X11, which is why libX11 below has to be a real guest library.
    #   * ALSOFT_DRIVERS=pulse,alsa — the port's bundled OpenAL Soft otherwise picks OSS and plays nothing.
    #     Pulse FIRST: with alsa, `default` routes through PipeWire's AARCH64
    #     libasound_module_pcm_pipewire.so, which a 32-bit guest cannot load; the i686 libpulse client in
    #     `guestLibs` talks to pipewire-pulse over a socket and needs nothing loaded into the guest.
    #     VERIFIED objectively — `wpctl status` lists a live `Civ5XP` PipeWire stream within 5 s — not
    #     merely by an absence of errors. Do NOT "fix" ALSA by pointing it at hw:0: card 0 on this machine
    #     is Asahi `macaudio`, whose speakers rely on PipeWire's DSP chain for excursion limiting.
    #     FEX's own asound thunk is not available to a 32-bit guest: upstream's ThunkLibs CMake gates
    #     asound (and vulkan, and drm) behind `if (BITNESS EQUAL 64)`.
    #
    # Everything else the run needed is the FEX backend's job, not this file's: FEX_ROOTFS=/, the guest
    # ld.so stamped into a patched copy of Civ5XP at the game path, the GL thunk staged as libGL.so.1, and
    # the scrub of an inherited LD_PRELOAD (the host's aarch64 libmimalloc SIGSEGVs the guest ~5 s in).
    env = {
      SDL_VIDEODRIVER = "x11";
      ALSOFT_DRIVERS = "pulse,alsa";
    };

    # ── THE GUEST LIBRARY SET ───────────────────────────────────────────────────────────────────────────
    # All under `guestLibs`, none under `bridgingLibs`: FEX honours the guest's own libraries and bridges
    # nothing (that split is box64's, and box64 cannot serve a 32-bit payload at all), so for an i386
    # payload there is no native side to name. On aarch64 these resolve from `pkgsCross.gnu32` — every one
    # cross-built, never a native i686 instantiation; on an x86_64 host, from `pkgsi686Linux`.
    #
    # Derived from the payload, not guessed: `libx11` and the rest of the X set plus zlib are in
    # Civ5XP's DT_NEEDED, so ld.so refuses to start without them (libX11 included, Wayland desktop or
    # not); SDL dlopens the remaining X extensions by soname; libpulseaudio is for the audio route above.
    # glibc and gcc's libstdc++/libgcc_s are the floor. The game brings its own libc++, OpenAL, TBB and
    # Miles in 282301, and those win over anything here — the game trees lead the library path.
    box64.guestLibs =
      p: with p; [
        glibc
        stdenv.cc.cc.lib
        zlib
        libpulseaudio
        alsa-lib
        libx11
        libxext
        libxcursor
        libxinerama
        libxi
        libxrandr
        libxxf86vm
        libxrender
        libxfixes
      ];

    # ── STEAMWORKS ──────────────────────────────────────────────────────────────────────────────────────
    # ONLINE, deliberately (the default, stated because the reasoning is not obvious). Civ V's multiplayer
    # is pure Steamworks — Steam lobbies plus Steam networking, with no second account system anywhere in
    # the payload. That is exactly the shape gbe_fork's LAN protocol emulates, so with `steam.emu` below
    # two propnix instances on one network can in principle see each other's games — a capability
    # `online = false` would remove. Single-player users lose nothing by taking it away:
    # `civilization-5.apply { online = false; }`.

    # THE SHIM MUST HAND OUT THE VTABLES THIS BUILD ASKS FOR. Every string is read out of the payload's own
    # `libsteam_api.so` with `strings` — which is what upstream's `generate_interfaces_file` does, so this
    # is a fact about the binary rather than a guess. Left at the shim's own defaults, a game whose
    # requested version string the modern class doesn't recognise gets `report_missing_impl_and_exit()` — a
    # modal MessageBox and a dead process, which pkgs/games/cities-skylines documents from the other side.
    #
    # NOTE these are NOT the Windows build's numbers: Aspyr's port was built against a later SDK, and nine
    # of the sixteen differ (SteamUser017 vs 016, SteamFriends014 vs 011, SteamUtils006 vs 005,
    # REMOTESTORAGE 012 vs 006, USERSTATS 011 vs 010, APPS 006 vs 005, SCREENSHOTS/HTTP 002 vs 001, plus
    # UGC and UnifiedMessages, which the Windows build's dll doesn't mention at all). Copying the Windows
    # list over would have been a silent, hard-to-trace wrong answer.
    steam.emu.interfaces = [
      "SteamClient012"
      "SteamUser017"
      "SteamFriends014"
      "SteamUtils006"
      "SteamMatchMaking009"
      "SteamMatchMakingServers002"
      "SteamGameServer011"
      "SteamGameServerStats001"
      "SteamNetworking005"
      "STEAMAPPS_INTERFACE_VERSION006"
      "STEAMUSERSTATS_INTERFACE_VERSION011"
      "STEAMREMOTESTORAGE_INTERFACE_VERSION012"
      "STEAMSCREENSHOTS_INTERFACE_VERSION002"
      "STEAMHTTP_INTERFACE_VERSION002"
      "STEAMUGC_INTERFACE_VERSION001"
      "STEAMUNIFIEDMESSAGES_INTERFACE_VERSION001"
    ];

    # The engine links `libsteam_api.so` from the game root (the i386 build of it — the framework picks
    # gbe_fork's matching ABI from the resolved platform). On a thin backend the mechanism is a BIND-OVER:
    # steam-emu binds its own shim copy, with its settings beside it, onto this exact game-dir-relative
    # path, so the library the loader maps IS the shim. Declaring the path is mandatory — mkApp refuses
    # steam.emu with no path rather than ship a silently-inert shim.
    steam.emu.libPaths = [ "libsteam_api.so" ];

    # ── DLC ──────────────────────────────────────────────────────────────────────────────────────────────
    # Eighteen store packs, each shipped as its own Steam depot of the base app (8930) and each unpacking
    # to `steamassets/assets/dlc/<PackName>/` — siblings of the base's own `dlc/{shared,tablet}`, so the
    # trees union without shadowing anything.
    #
    # Every row states `dlcAppId` because on the Linux side the depot id is NEVER the store appid (the
    # Windows depots doubled as appids; 282303-282326 do not). The mapping is app 8930's own
    # `dlcappid` per depot from its appinfo — e.g. 282303 → 16865, the Mongols pack — so `steam.emu`'s
    # entitlement projection answers with the appid a user actually owns.
    #
    # This is the set the packaging account owns, which here is the whole catalogue. An unowned pack would
    # simply not be listed: Steam refuses the decryption key and there is nothing to pin.
    #
    # NOT part of the base package: `civilization-5` builds vanilla, so the default derivation does not
    # depend on the packager's entitlements. `civilization-5.withAllDlc` / `.withDlc [ "gods-and-kings" ]`
    # / `.apply { dlc.enabled = [ … ]; }` union the selected trees ABOVE the base at mount time, so an
    # enabled pack costs no second copy of the 4.5 GB base payload.
    #
    # STAGING THE TREES IS ONLY HALF THE JOB, exactly as for stellaris: Civ V asks the Steam client whether
    # the user owns a pack before it loads it, and there is no Steam client here. Declaring `dlc.available`
    # on a Steam-fetched build flips `steam.emu.enable` on (modules/steam-emu.nix), which wires the shim
    # above and projects the entitlement list from these SAME rows — real store appids, real store titles,
    # `unlock_all=0`.
    dlc.available = lib.mapAttrs (_: fetchSteamDepot) versions.dlc;

    # ── THE ENGINE ASKS ABOUT DIFFERENT APPIDS THAN THE STORE SELLS ─────────────────────────────────────
    # Mounting a pack's tree is necessary but NOT sufficient, and the gap is silent — no log line, no
    # error, the pack simply never appears. Civ V's ContentManager walks every
    # `steamassets/assets/dlc/*/*.civ5pkg` descriptor it finds and asks `ISteamApps` about the
    # `<SteamApp>` written INSIDE that file, which is NOT the id Steam's appinfo gives the depot:
    #
    #     assets/dlc/dlc_01/mongol.civ5pkg   <SteamApp>34495</SteamApp>     depot 282303, dlcappid 16865
    #
    # So the entitlement list projected from the pin rows (16865 …) answers a question the game never
    # asks, and `withAllDlc` yields a game with every pack mounted and none active. Every id below is
    # grepped out of the descriptor in the pack's own payload — a fact about those bytes, like the
    # interface list above — and is claimed IN ADDITION to the store id, which the packager does own.
    #
    # The four `cradle-*` packs are absent deliberately: they ship a single `.civ5map` and no descriptor
    # at all, so there is nothing to gate and the map just appears in the map list.
    #
    # `digital-deluxe` claims Babylon's pair because that is the descriptor its depot ships (Babylon was
    # the deluxe bonus civ); the two expansions each carry two ids (the expansion and its scenario set).
    #
    # GATED ON `dlc.enabled`, not stated flat: claiming a pack the user did not enable would invite the
    # engine to load content that is not mounted. The one ungated row is the base payload's own
    # `dlc/shared` (decals, buildings, strategic-view and UI art the packs draw from), whose
    # `upgrade1.civ5pkg` carries the sentinel `<SteamApp>99999` — not a real Steam app, so nothing is
    # claimed that could be bought, and answering "no" there would deny the base game its own content.
    steam.emu.extraDlc =
      let
        engineAppIds = {
          babylon = [
            34494
            34498
          ];
          brave-new-world = [
            235582
            235583
          ];
          conquest-of-the-new-world = [ 266721 ];
          denmark = [ 102001 ];
          digital-deluxe = [
            34494
            34498
          ];
          explorers-map-pack = [ 34496 ];
          gods-and-kings = [
            210450
            210451
          ];
          korea = [ 102002 ];
          mongols = [ 34495 ];
          polynesia = [ 102000 ];
          scrambled-continents = [ 235587 ];
          scrambled-nations = [ 235588 ];
          spain-and-inca = [ 34497 ];
          wonders-of-the-ancient-world = [ 102003 ];
        };
        # One row PER APPID, not per (pack × id): `digital-deluxe` ships Babylon's descriptor, so both
        # packs name 34494/34498 and keying by pack would emit each twice with different titles (gbe_fork
        # keys its own map by appid, so one would silently win anyway). Titled from the pack's pin row so
        # the name the shim reports matches the store's.
        rowsFor =
          name:
          map (
            id:
            lib.nameValuePair "engine-${toString id}" {
              appId = id;
              # The bare store name — the projection strips this suffix from its own rows, and a
              # title reading "… (Steam)" would leak the provenance tag into a game's content UI.
              title = lib.removeSuffix " (Steam)" versions.dlc.${name}.title;
            }
          ) (engineAppIds.${name} or [ ]);
      in
      {
        base-shared-content = {
          appId = 99999;
          title = "Sid Meier's Civilization V - shared DLC content";
        };
      }
      // lib.listToAttrs (lib.concatMap rowsFor config.dlc.enabled);

    # ── SAVES AND STATE ─────────────────────────────────────────────────────────────────────────────────
    # The whole `Aspyr` directory, not just the game's folder inside it, because the port writes state at
    # BOTH levels (measured — this is the tree a run leaves behind):
    #   .local/share/Aspyr/com.aspyr.civ5xp.json            the shim layer's GL-capability probe + the
    #                                                       fullscreen flag — a per-GPU cache, redone on
    #                                                       every launch if it is not kept
    #   .local/share/Aspyr/Sid Meier's Civilization 5/       Saves/ MODS/ Replays/ ScreenShots/ Logs/,
    #                                                       UserSettings.ini, GraphicsSettingsDX9.ini, and
    #                                                       cache/ — the SQLite gameplay databases the
    #                                                       engine BUILDS from the XML on first run, which
    #                                                       is most of what makes a cold start slow
    # The thin launcher points $HOME (and the XDG roots under it) at an ephemeral per-launch view, then
    # binds the persistent propnix save dir onto the path the game writes — so all of the above persists
    # while the game tree stays read-only. One bind covers both levels; the folder name uses the numeral
    # ("Civilization 5"), not the numeral-V of the display name.
    #
    # THIS TITLE IS WHY THE LAUNCHER STATES `XDG_DATA_HOME` RATHER THAN UNSETTING IT. Aspyr's shim layer
    # does not read $HOME at all — it resolves the home directory with `getpwuid(getuid())->pw_dir` (the
    # binary imports getpwuid and contains no "HOME" string, only "XDG_DATA_HOME"). With the XDG roots
    # merely unset, `$HOME/.local/share` was never consulted: the game wrote its saves, settings and
    # databases straight to the launching user's REAL ~/.local/share/Aspyr, escaping the view and making
    # this bind inert. Setting the root redirects it (thin.rs).
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = ".local/share/Aspyr";
      }
      # THE SAME DIR, ALSO AT THE REAL HOME PATH — because ONE of the shim's two path resolutions cannot
      # be redirected by any environment variable. Measured: the game FOLDER follows XDG_DATA_HOME into
      # the view (the row above), but `com.aspyr.civ5xp.json` — the GL-capability cache, which is also
      # where `DisplayFullScreen` lives — is written to `getpwuid(getuid())->pw_dir + /.local/share/Aspyr`.
      # That path is the launching user's real home whatever $HOME and XDG_DATA_HOME say, so without this
      # row the file either escapes the sandbox (persisting outside the save dir) or, if that directory
      # does not exist, is silently not written at all — which is what made the fullscreen setting fail to
      # survive a restart while every other setting persisted.
      #
      # An absolute `dst` binds outside the view (thin.rs); `$HOME` expands to the real home.
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "$HOME/.local/share/Aspyr";
      }
    ];

    # ── STATUS: RUNS ON aarch64 ──────────────────────────────────────────────────────────────────────────
    # Verified on this host (Asahi aarch64, 16 KiB pages, Wayland+Xwayland) with the recipe above.
    # Civ5XP starts, initialises every engine system and reaches the main menu's DLC/mods pass — from its
    # own logs: `Unit_System::Startup()`, `City_System`, `LandmarkSystem`, `TerrainSystem`,
    # `LeaderHead_System`, `Combat_System`, `AudioSimSystem` all complete, then
    # `Civilization 5: App Version: 403694 FINAL_RELEASE, GameCore: {478F7A6E-…}` and
    # `Changing active DLC and Mods`. Audio is live (a `Civ5XP` PipeWire stream). The first start is slow
    # (minutes) because the engine builds its SQLite databases from the XML; `saveBinds` keeps them.
    #
    # THE EMULATOR IS OURS AND HAD TO BE. Stock FEX assumes a 4 KiB kernel page and does not start at all
    # on a 16 KiB host; emulators/fex-linux carries the large-host-page work plus two 32-bit-guest fixes
    # this title forced out — a 4 KiB-granular MAP_FIXED address in `64BitAllocator.cpp` (which only
    # 32-bit guests reach, since that allocator exists to hand the low 4 GB to the guest) and sub-host-page
    # mmap emulation on the 32-bit syscall path. Neither box64 (x86_64-only) nor box86 (dead on 16 KiB
    # pages) can serve an i386 payload, which is why lib/strategy.nix routes i386-linux to FEX.
    #
    # x86_64 hosts run this payload with no emulator at all (backend "native", 32-bit loader and 32-bit
    # library set), and that path is INCOMPLETE — see the broken block below.
    #
    # KNOWN ROUGH EDGES, none fatal: the engine logs a benign upstream XML warning
    # (`columns StrategicViewType, TileType are not unique`) on database build, and DLC/entitlement answers
    # come from gbe_fork rather than a Steam client, so a pack must be enabled through `dlc.enabled` to be
    # visible — the game's own store page inside the menu does nothing offline, by design.

    # ── BROKEN ON x86_64: NOTHING THERE SUPPLIES A 32-BIT libGL ──────────────────────────────────────────
    # `libGL.so.1` is in Civ5XP's DT_NEEDED, so ld.so refuses to start the process without it — this is not
    # a rendering fallback that degrades, it is a load failure. On aarch64 the FEX backend answers it with
    # FEX's i386 GL guest thunk, which marshals to the host's native GL. The x86_64 host runs this payload
    # with no emulator and therefore no thunk, and nothing else in the stack covers it:
    #   * `guestLibs` below deliberately lists no GL. On aarch64 the thunk owns that soname, and a
    #     cross-built i686 Mesa there would be an enormous closure for a library that would never be used.
    #   * the launcher's baked fallback stack is HOST-ARCH ONLY — `mkFallbackGl` resolves the scope's own
    #     `mesa` (x86_64 on an x86_64 host), which a 32-bit process cannot load — and `glstack.rs` probes
    #     `/run/opengl-driver`, never NixOS's separate 32-bit `/run/opengl-driver-32`.
    # So the honest state is a BUILD REFUSAL on that host rather than a package that fails at execve. The
    # fix is framework work, not a line in this file: make the fallback GL stack payload-ABI-aware (32-bit
    # glvnd + Mesa vendor libraries + DRI drivers, and the matching discovery paths/`-32` probe), then test
    # it on a real x86_64 machine. Until then this is untested-and-known-incomplete, which is exactly what
    # `broken` is for. Everything else about the x86_64 path already resolves correctly: resolveStrategy
    # picks `native`, and the box64 entry's native face stamps the i686 loader and 32-bit sonames.
    broken.systems = [ "x86_64-linux" ];
    broken.reason = "the x86_64 host runs this i386 payload natively, with no FEX GL thunk — and libGL.so.1 is in Civ5XP's DT_NEEDED, while propnix's fallback GL stack (mkFallbackGl + glstack.rs) is host-arch only and knows nothing of a 32-bit /run/opengl-driver-32. The process would fail to load. Needs an ABI-aware GL fallback stack, then testing on an x86_64 machine; aarch64 (backend \"fex\") is verified and unaffected.";
  }
)
