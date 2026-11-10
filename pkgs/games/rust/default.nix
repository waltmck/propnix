# Rust (Facepunch Studios, Steam app 252490) — a Unity/IL2CPP survival sandbox, Windows build
# under wine (aarch64 → FEX + ARM64EC DXVK, x86_64 → native wine). Two depots, both pinned:
#
#   252495  Windows x64 client   859 MB  RustClient.exe, Rust.exe, GameAssembly.dll, EasyAntiCheat/
#   252494  OS-agnostic content   39 GB  Bundles/ (items, textures, maps, shared)
#
# Reaches the main menu on x86_64; joining a server is untested. Research lives in
# docs/research/easy-anti-cheat.md, writable-game-dir.md and steam-entitlement.md.
#
# An intermittent freeze at `[Bootstrap] Initializing Steam` matches the signature of the
# dosdevices mountmgr hang (docs/research/wine-mountmgr-dosdevices.md); unconfirmed on this title.
#
#   nix run .#rust --extra-sandbox-paths /propnix=/var/lib/propnix
#
# Logs: `-logfile -` with PROPNIX_DEBUG=1 is the live view; `$PROPNIX_SAVE_DIR/rust/Player.log` is
# the post-mortem (docs/research/headless-test-harness.md).
{ mkApp }:
mkApp (
  { config, lib, ... }:
  {
    pname = "rust";
    maintainers = [ "waltmck" ];
    appid = "rust";
    name = "Rust";

    # Stated rather than inherited from the schema default. Rust is multiplayer-only with no local
    # server in the client depot, so the offline guarantee is given up on purpose: the client and
    # its bundled EAC/EOS, Steam and Discord SDKs reach the network
    # (docs/research/easy-anti-cheat.md).
    online = true;

    # Depot 252495 holds RustClient.exe, so it leads: the head payload is C:\game's primary tree,
    # the launch cwd and the icon source. 252494 is only `Bundles/`, so the two never overlap.
    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;

    # RustClient.exe is the Unity player and Facepunch's documented EAC-free entry point (support
    # article 15041503601437). Rust.exe is EAC's bootstrapper: it needs Epic's CDN and a kernel
    # driver wine cannot host, and exits while the game keeps running. So only EAC-unsecure servers
    # are reachable, and the server browser hides them: join by IP from the F1 console with
    # `connect <ip>:<port>`.
    exe = "RustClient.exe";

    # Full-colour icon auto-extracted from RustClient.exe's PE resources (icon.auto default).
    # Symbolic vendored (CC BY-SA 4.0).
    icon.symbolic = ./rust-symbolic.svg;

    # The gbe_fork shim replaces the shipped steam_api64.dll and is required: with Valve's dll and
    # no Steam client, `SteamAPI_Init` fails and the bootstrap stops at 99%. It answers ownership
    # only; Rust's server auth is a Steam ticket it cannot issue.
    steam.emu.libPaths = [ "RustClient_Data/Plugins/x86_64/steam_api64.dll" ];

    # Save/state: the Unity persistentDataPath. `RustClient_Data/app.info` gives the two components
    # verbatim — company "Facepunch Studios LTD", product "Rust" — which is what Unity joins under
    # %USERPROFILE%\AppData\LocalLow. Player.log and the engine's own per-user state land here.
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "AppData/LocalLow/Facepunch Studios LTD/Rust";
      }
    ];

    wine = {
      # The menu's hero-video downloader writes `C:\game\temp`, retries forever when it cannot,
      # and holds the loading screen until it succeeds. A private tmpfs (`source = null`) because
      # the video is re-downloadable scratch that would otherwise accrete in the gamedir upper
      # below; the row nests on that overlay through propnix-mount's child skeleton.
      mounts."drive_c/game/temp" = {
        type = "mount";
        source = null;
      };

      # Rust opens its server-list SQLite db by a cwd-relative path (C:\game) and writes
      # `cfg/*.cfg` (settings, keybinds, favorites). SQLite's journal is a sibling of the db, so
      # the whole directory must be writable: a persistent CoW overlay in `$PROPNIX_STATE/gamedir`.
      # This row replaces the derived game row wholesale (lib/builders/wine.nix `finalMounts`), so
      # `lower` is rebuilt from config: `extraLowers` (the steam.emu tree) first, then the payloads
      # in order. `skeleton` is unset so the builder derives one over the whole stack.
      # `screenshots/` and `demos/` land in the same upper. A depot bump leaves copied-up files
      # shadowing the new payload: if anything misbehaves after one, clear the gamedir first.
      mounts."drive_c/game" = {
        type = "overlay";
        lower = lib.concatStringsSep ":" (map (d: "${d}") (config.extraLowers ++ config.payloads));
        upper = "$PROPNIX_STATE/gamedir";
        createIfNotExist = true;
      };
    };
  }
)
