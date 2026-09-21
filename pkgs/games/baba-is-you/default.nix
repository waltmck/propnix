# Baba Is You (Steam, the NATIVE x86_64 LINUX build) — on aarch64 through box64, on x86_64 directly.
# Hempuli's rule-rewriting puzzle game. The Linux build is a CHOWDREN port: the game was authored in
# Multimedia Fusion and Chowdren transpiles that to C++, so what ships is an ordinary native ELF
# (`bin64/Chowdren`) with a statically linked SDL2 — no Mono, no Unity, no interpreter to emulate beyond
# the ELF itself. ARCH-AGNOSTIC: one spec for both hosts; the same payload (a content-addressed FOD) is
# shared, and mkApp + the scope pick box64 or a direct execve.
#
# Steam-only: Baba Is You is also sold on itch.io and GOG, but only the Steam depot is pinned here (the
# GOG build would need its own pin and has no advantage). Requires an account that owns the title.
#
#   nix run .#baba-is-you --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
#
# ── ONE DEPOT, AND WHY THE LINUX ONE ──────────────────────────────────────────────────────────────────
# App 736260 ships exactly three depots, one per OS, with no DLC at all (`listofdlc` is absent from its
# appinfo and `dlc.available` below is correspondingly empty):
#   736261  114 MB  windows
#   736262  111 MB  macos
#   736263  113 MB  linux   ← pinned
# The native build is the obvious choice on both hosts: it removes wine from the aarch64 path entirely
# (box64 emulates the ELF and bridges the host's real GL/audio libraries) and runs with nothing in the
# way at all on x86_64. Its payload is one flat tree — `bin64/`, `Data/`, `Assets.dat`, `icon.bmp`.
{
  lib,
  mkApp,
  fetchSteamDepot,
  runCommandLocal,
  imagemagick,
}:
mkApp (
  { config, ... }:
  {
    pname = "baba-is-you";
    maintainers = [ "waltmck" ];
    appid = "baba-is-you";
    name = "Baba Is You";

    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;

    # The shipped `run.sh` is two lines — `cd "$(dirname "$0")"; exec ./bin64/Chowdren "$@"` — so the
    # engine binary is run from the game ROOT, which is propnix's default cwd. That makes the script pure
    # overhead: name the ELF directly and skip a shell (`workingDir` stays null for the same reason).
    exe = "bin64/Chowdren";
    # Chowdren names its own window: WM_CLASS is the game's TITLE (measured: `xprop WM_CLASS` →
    # "Baba Is You", "Baba Is You"), not the exe basename the desktop entry would otherwise guess —
    # without this the taskbar ties the icon to the splash only and the game window falls back to the
    # generic one.
    wmClass = "Baba Is You";

    # ── ICON: THE GAME'S OWN CHARACTER SPRITE, NOT ITS KEY ART ──────────────────────────────────────────
    # The payload root carries `icon.bmp`, a 256² key-art card (logo lettering over a dark scene) — the
    # image the game and Steam use. It is legible at 256px and an unreadable smudge at 48px, which is the
    # size a launcher actually shows, so it makes a poor app icon.
    #
    # The better source is in the payload too. This title ships its art as LOOSE PNGs for modders
    # (`Data/Sprites/`, 3983 of them) rather than packed — `Assets.dat` turned out to be a table of
    # compressed blobs, and reversing it proved unnecessary once the loose tree was found. `baba_0_1.png`
    # is the title character's own 24² sprite, frame 1: a high-contrast silhouette that stays legible
    # down to 16px.
    #
    # IT NEEDS A BACKDROP. The sprite is pure white on transparency (the engine tints sprites through the
    # level palette at runtime), so on its own it is INVISIBLE on any light theme — only the two dark eye
    # pixels survive, which is exactly what a first attempt produced. So it is composited over the game's
    # own background colour, read out of `Data/Palettes/default.png` at build time (pixel 1,0 — the dark
    # navy every default level is drawn on) rather than hardcoded here, so the two always agree.
    #
    # TWO SHAPE DETAILS, both forced by the shared pipeline (lib/icons/pipeline.sh), which trims its
    # source and then smooth-resizes it to 460²:
    #   * ROUNDED tile, not a flat square. `-trim` crops a uniform border, so a flat backdrop is cropped
    #     back to the character's bounding box and the legs and ears then bleed off the dark area onto
    #     the theme. Transparent corners give the trim nothing to eat, so the tile keeps its shape.
    #   * POINT upscaling. A smooth 20x enlargement of pixel art is mush; enlarging by an integer factor
    #     with `-filter point` keeps the edges hard, and the pipeline's remaining fit-to-460 is then a
    #     small adjustment on an already-large image.
    icon.png = "${
      runCommandLocal "baba-is-you-icon-src"
        {
          nativeBuildInputs = [ imagemagick ];
          meta.description = "Baba Is You's own character sprite on its own palette colour, sized for the icon pipeline";
        }
        ''
          mkdir -p $out
          payload=${lib.head config.payloads}
          bg=$(magick "$payload/Data/Palettes/default.png" -format '%[pixel:p{1,0}]' info:)
          magick -size 1024x1024 xc:none -fill "$bg" \
            -draw 'roundrectangle 0,0 1023,1023 160,160' tile.png
          magick "$payload/Data/Sprites/baba_0_1.png" -filter point -resize 2600% sprite.png
          magick tile.png sprite.png -gravity center -composite $out/icon.png
        ''
    }/icon.png";
    # Monochrome variant for symbolic contexts (line art, CC BY-SA 4.0 — see the file's own header).
    icon.symbolic = ./baba-is-you-symbolic.svg;

    # OFFLINE, kernel-enforced: the launcher unshares a network namespace, so the guarantee does not rest
    # on trusting the title. Baba Is You is single-player and its Steamworks use is achievements, stats and
    # WORKSHOP (the exe references UGC) — the first two the offline shim answers locally, and the last
    # genuinely does not work offline: custom levelpacks cannot be browsed or downloaded. That is the same
    # trade every propnix title makes, and it costs nothing for the base game, whose ~200 levels and its
    # built-in editor are all local. `baba-is-you.apply { online = true; }` gives the netns back.
    online = false;

    # ── THE LIBRARY UNION ───────────────────────────────────────────────────────────────────────────────
    # Derived from the binary, not copied from a sibling: `readelf -d` gives the hard needs (libGL,
    # libuuid, libm, libpthread, libc, libdl) and the SDL2 statically linked inside it dlopens the rest by
    # soname — the X11 set below, the audio set, and libudev for controller hotplug. No Vulkan: the
    # renderer is GL. `zlib` is here because box64 says so: without it the launch logs "Error initializing
    # native libz.so.1" as it tries to wrap the soname something in the process (the Steam shim's curl)
    # pulls in.
    #
    # `bridgingLibs` = what box64 WRAPS, so it needs the native aarch64 copy to bridge AND the x86_64 one
    # for the guest; `guestLibs` = guest-only. On x86_64 both collapse to the host set.
    box64 = {
      bridgingLibs =
        p: with p; [
          libgcc
          libGL
          libglvnd
          libx11
          libxext
          libxcursor
          libxi
          libxrandr
          libxscrnsaver # SDL2's screensaver inhibition (libXss.so.1)
          libxcb # libX11-xcb.so.1 links it; listed so resolution never depends on RUNPATH
          libxkbcommon
          dbus.lib
          libpulseaudio
          alsa-lib
          libsamplerate # SDL2's audio resampler, dlopened when present
          udev # libudev.so.1: SDL2's controller hotplug
          libuuid # a HARD DT_NEEDED of the engine, not an SDL dlopen
          zlib # box64 wraps libz; absent, every launch logs an "Error initializing native libz.so.1"
        ];
      guestLibs =
        p: with p; [
          glibc
          stdenv.cc.cc.lib
        ];
    };

    # ── STEAMWORKS ──────────────────────────────────────────────────────────────────────────────────────
    # The engine links `bin64/libsteam_api.so` beside itself, so the shim is bound over that exact path.
    # The interface list is read out of the shipped library with `strings` (what upstream's own
    # `generate_interfaces_file` does), so it states what THIS build asks for rather than what the shim
    # happens to default to. It is a recent SDK — SteamClient020/SteamUser023 — and both SteamClient
    # revisions the library names are listed, since the engine may ask for either.
    steam.emu.libPaths = [ "bin64/libsteam_api.so" ];
    steam.emu.interfaces = [
      "SteamClient017"
      "SteamClient020"
      "SteamUser023"
      "SteamFriends017"
      "SteamUtils010"
      "SteamMatchMaking009"
      "SteamMatchMakingServers002"
      "SteamGameServer015"
      "SteamGameServerStats001"
      "SteamNetworking006"
      "SteamNetworkingMessages002"
      "SteamNetworkingSockets012"
      "SteamNetworkingUtils004"
      "SteamController008"
      "SteamInput006"
      "SteamParties002"
      "SteamMatchGameSearch001"
      "STEAMAPPS_INTERFACE_VERSION008"
      "STEAMAPPLIST_INTERFACE_VERSION001"
      "STEAMUSERSTATS_INTERFACE_VERSION012"
      "STEAMREMOTESTORAGE_INTERFACE_VERSION016"
      "STEAMSCREENSHOTS_INTERFACE_VERSION003"
      "STEAMHTTP_INTERFACE_VERSION003"
      "STEAMUGC_INTERFACE_VERSION018"
      "STEAMMUSIC_INTERFACE_VERSION001"
      "STEAMMUSICREMOTE_INTERFACE_VERSION001"
      "STEAMREMOTEPLAY_INTERFACE_VERSION002"
      "STEAMPARENTALSETTINGS_INTERFACE_VERSION001"
    ];

    # ── SDL'S VIDEO DRIVER: PINNED TO X11 ───────────────────────────────────────────────────────────────
    # Without this the game EXITS 1 before drawing anything, and the reason is inherited state rather than
    # anything about the title: a Wayland session commonly exports `SDL_VIDEODRIVER=wayland` (this host
    # does), the launcher's seal scrubs only WINE*/FEX_*/BOX64_*/LD_*, so the value reaches the guest and
    # SDL then reports
    #     SDL could not be initialized: wayland not available
    #     Could not open window: wayland not available
    # and the process gives up. The X11 sonames ARE the ones this build carries (libX11/Xext/Xcursor/Xi/
    # Xrandr/Xss, all dlopened by soname), so x11 is the backend it can actually use here — the same
    # setting hollow-knight pins for every thin backend, where the measured reason is that SDL's Wayland
    # path also trips box64's dynarec. Stating it in the game's `env` beats the inherited value, which is
    # exactly what makes the launch independent of whoever's session started it.
    env.SDL_VIDEODRIVER = "x11";

    # ── SAVES ───────────────────────────────────────────────────────────────────────────────────────────
    # The engine resolves its data directory as `$XDG_DATA_HOME/Baba_Is_You`, falling back to
    # `$HOME/.local/share` and then to `$HOME/.Baba_Is_You` — its own error string ("neither XDG_DATA_HOME
    # nor HOME environment is set") names the first two. The thin launcher points both $HOME and the XDG
    # roots at the ephemeral per-launch view, so binding the propnix save dir at the XDG-relative path is
    # what makes progress persist while the game tree stays read-only.
    #
    # SAVES AND SETTINGS ARE ROUTED APART, the papers-please/factorio shape. Everything the engine writes
    # lands in that one directory, but it is two kinds of thing (measured — this is the tree a first run
    # leaves behind):
    #   ba.ba, <slot>ba.ba   PROGRESS — `[baba] firsttime=1`, per-level `…_intro`, `Previous=<level>`
    #   SettingsC.txt        SETTINGS — an INI of keyboard/gamepad bindings, display and audio options,
    #                        plus a `[savegame] slot/world` pointer, which is "where was I last", i.e.
    #                        per-machine state rather than progress
    # A `type = "file"` row redirects the settings file out of the directory that is itself bound, which
    # no overlay can do (one upper cannot split writes by filename), and makes `create` TOUCH the source
    # rather than mkdir it. The engine rewrites the file wholesale, so an empty one on a first launch just
    # reads as "no settings yet".
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = ".local/share/Baba_Is_You";
      }
      {
        src = "$PROPNIX_STATE/SettingsC.txt";
        dst = ".local/share/Baba_Is_You/SettingsC.txt";
        type = "file";
      }
    ];
  }
)
