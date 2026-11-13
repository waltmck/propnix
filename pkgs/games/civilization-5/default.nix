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
# The Windows depot's exes are CEG-stripped templates: Valve generates the runnable exe per user at
# install time, so the depot copy exits 173 at its entry point and `fetchSteamDepot` can never
# obtain a runnable one (docs/research/steam-drm.md). The Linux ELF has no CEG and runs.
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
# On Linux the deluxe soundtrack rides in the Digital Deluxe DLC depot (282309), not a base depot,
# and each pack below is exactly one depot (the expansions' gameplay cores ship in 282301).
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
  # The Linux depots ship no usable icon (only a 320x240 wordmark LCD bitmap), so the gold "V"
  # emblem, 256x256 frame included, is lifted from the PE resources of the 45 MB Windows-exe depot;
  # the shared raster pipeline picks the largest `.ico` frame (lib/icons/pipeline.sh). (`icon.auto`
  # on a thin backend reads Unity's UnityPlayer.png, so it cannot serve this engine.) The pin lives
  # in versions.json's `extra` section, which `propnix pin` advances with the rest, because a
  # `fetchInfo` row would declare the CEG-stripped Windows build (above) runnable.
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

    # ── THE RUNNING RECIPE ──────────────────────────────────────────────────────────────────────────────
    # Two environment variables, both load-bearing (docs/research/fex-i386-linux-guests.md):
    #
    #   * SDL_VIDEODRIVER=x11 — this 2014 SDL2's Wayland backend fails (and the launcher defaults
    #     SDL to Wayland in a Wayland session), after which `ASL::SDL::Init()` calls `ASL::ErrorDie`
    #     and the game exits 0 in silence: no log, no window. X11 means Xwayland; FEX thunks
    #     GL/EGL/Wayland but NOT X11, so libX11 below has to be a real guest library.
    #   * ALSOFT_DRIVERS=pulse,alsa — the bundled OpenAL Soft otherwise picks OSS and plays nothing.
    #     Pulse FIRST: ALSA's `default` routes through PipeWire's aarch64
    #     libasound_module_pcm_pipewire.so, which a 32-bit guest cannot load (and FEX has no 32-bit
    #     asound thunk); the i686 libpulse in `guestLibs` talks to pipewire-pulse over a socket. Do
    #     NOT "fix" ALSA by pointing it at hw:0: card 0 on Asahi is `macaudio`, whose speakers rely
    #     on PipeWire's DSP chain for excursion limiting.
    #
    # The rest (FEX_ROOTFS=/, the guest ld.so stamped into a patched Civ5XP, the GL thunk, the
    # LD_PRELOAD scrub) is the FEX backend's job.
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
        alsa-lib # backs the `,alsa` fallback in ALSOFT_DRIVERS
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

    # The engine links `libsteam_api.so` from the game root (i386; gbe_fork's ABI follows the
    # resolved platform); on a thin backend steam-emu binds its shim copy over that exact path.
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
    # Civ V asks the Steam client about each pack before loading it; steam.emu (on for every Steam
    # fetch) answers from these SAME rows (real store appids and titles, `unlock_all=0`).
    dlc.available = lib.mapAttrs (_: fetchSteamDepot) versions.dlc;

    # ── THE ENGINE ASKS ABOUT DIFFERENT APPIDS THAN THE STORE SELLS ─────────────────────────────────────
    # Civ V's ContentManager asks `ISteamApps` about the `<SteamApp>` written INSIDE each
    # `steamassets/assets/dlc/*/*.civ5pkg` descriptor, not the store appid of the pack's depot
    # (mongol.civ5pkg says 34495; depot 282303's dlcappid is 16865), and a pack it gets "no" for
    # stays silently inactive. So each id below, read from the pack's own descriptor, is claimed
    # IN ADDITION to the store id (docs/research/steam-dlc-appids.md). The four `cradle-*` packs
    # ship no descriptor (nothing to gate); `digital-deluxe` ships Babylon's; each expansion carries
    # two ids (the expansion and its scenario set). Rows are GATED ON `dlc.enabled`, so the engine
    # is never invited to load content that is not mounted. The one ungated row is the base's own
    # `dlc/shared` (`upgrade1.civ5pkg`), whose sentinel `99999` is no real Steam app; answering "no"
    # there would deny the base game its own content.
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
    # The whole `Aspyr` directory, because the port writes state at BOTH levels:
    #   .local/share/Aspyr/com.aspyr.civ5xp.json        the shim's per-GPU GL-capability cache
    #                                                   and the fullscreen flag
    #   .local/share/Aspyr/Sid Meier's Civilization 5/  Saves/ MODS/ Replays/ ScreenShots/ Logs/,
    #                                                   the settings .ini files, and cache/ (the
    #                                                   SQLite databases built from the XML on
    #                                                   first run)
    # The folder name uses the numeral "5". Aspyr's shim resolves its home via getpwuid, not $HOME;
    # the launcher sets XDG_DATA_HOME, which redirects the game folder into the view (thin.rs).
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = ".local/share/Aspyr";
      }
      # THE SAME DIR, ALSO AT THE REAL HOME PATH: only `com.aspyr.civ5xp.json` (where
      # `DisplayFullScreen` lives) ignores XDG_DATA_HOME and goes to `pw_dir/.local/share/Aspyr`.
      # Without this row it escapes the sandbox, or is not written at all and fullscreen never
      # persists. An absolute `dst` binds outside the view (thin.rs); `$HOME` expands to the real
      # home.
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "$HOME/.local/share/Aspyr";
      }
    ];

    # ── BROKEN ON x86_64: NOTHING THERE SUPPLIES A 32-BIT libGL ──────────────────────────────────────────
    # `libGL.so.1` is in Civ5XP's DT_NEEDED, so ld.so refuses to start without it. On aarch64
    # FEX's i386 GL guest thunk answers it; the x86_64 host runs the payload with no emulator, so
    # no thunk. `guestLibs` above deliberately lists no GL (on aarch64 the thunk owns the soname),
    # and the launcher's fallback stack is host-arch only (`mkFallbackGl`; `glstack.rs` probes
    # `/run/opengl-driver`, never `/run/opengl-driver-32`). The fix is framework work: a
    # payload-ABI-aware fallback GL stack (32-bit glvnd + Mesa + DRI drivers, the `-32` probe),
    # tested on a real x86_64 machine. The rest of that path already resolves (`native`, the i686
    # loader and 32-bit sonames).
    broken.systems = [ "x86_64-linux" ];
    broken.reason = "the x86_64 host runs this i386 payload natively, with no FEX GL thunk — and libGL.so.1 is in Civ5XP's DT_NEEDED, while propnix's fallback GL stack (mkFallbackGl + glstack.rs) is host-arch only and knows nothing of a 32-bit /run/opengl-driver-32. The process would fail to load. Needs an ABI-aware GL fallback stack, then testing on an x86_64 machine; aarch64 (backend \"fex\") is verified and unaffected.";
  }
)
