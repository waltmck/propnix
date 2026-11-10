# The Elder Scrolls V: Skyrim Special Edition — via wine (aarch64 → FEX + native ARM64EC DXVK,
# x86_64 → native wine). Bethesda Creation Engine (the 64-bit "Special Edition" remaster), renders
# D3D11 → DXVK → Vulkan. ARCH-AGNOSTIC: this spec is identical on both hosts; mkApp + the scope pick
# the arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD) is
# shared across arches. Windows-only title, so `platformPreference` stays derived.
#
# GOG is the default (`preferredFetchers` order) and the played path; the three-depot Steam build
# has never been launched. The store-specific rows are `saveBinds` and `galaxyStubDlls`; the exe
# and the engine tuning are the same on both. setup.sh (`setupScript`) seeds SkyrimPrefs.ini before
# launch.
#
#   nix run .#skyrim-se --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64/x86_64-linux
#   nix run '.#skyrim-se.apply { fetcher = "steam"; }'                    # untested Steam payload
#
# Depot 489833 must be head in versions.json: it is the only depot with SkyrimSE.exe, and `exe`, the
# icon and PROPNIX_PAYLOAD all resolve against the head tree. setup.sh finds the quality presets in
# another depot with `payload_require` (see its header). Depot contents:
# docs/research/multi-store-payloads.md.
{
  lib,
  mkApp,
  mkSetupScript,
  presets,
}:
mkApp (
  { config, lib, ... }:
  let
    onGog = config.fetcher == "gog";
  in
  {
    pname = "skyrim-se";
    maintainers = [ "waltmck" ];
    appid = "skyrim-se";
    name = "Skyrim Special Edition";

    # Offline by construction: the launcher unshares a NETWORK NAMESPACE for the game, so propnix's
    # offline guarantee is enforced by the kernel rather than by trusting the title and its bundled
    # SDKs. Safe here because this game is single-player; the Creation Engine build has no
    # multiplayer, and the exe's lone `Matchmaking` string is Steam-SDK boilerplate.
    # Store-independent: the Steam build is the same engine, and its bundled Steamworks lib is
    # de-integrated by `steam.emu` below rather than relied on.
    online = false;
    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
    # Launch the actual x86_64 game exe DIRECTLY, NOT the isPrimary SkyrimSELauncher.exe (a 32-bit
    # settings stub that spawns SkyrimSE.exe and exits → trips the propnix launcher's primary-child
    # teardown). SkyrimSE.exe is the 64-bit Creation Engine binary; it resolves Data/, *.ini, and
    # the game root relative to its own location, so cwd = payload root is fine. Same name and same
    # behaviour in both stores' payloads. Its VC++ runtime (MSVCP140/VCRUNTIME140) loads on wine's
    # ARM64EC UCRT builtins under FEX, so no extraSystem32.
    exe = "SkyrimSE.exe";
    # Full-color icon auto-extracted from SkyrimSE.exe's PE resources (icon.auto default). Symbolic
    # vendored (CC BY-SA 4.0).
    icon.symbolic = ./skyrim-se-symbolic.svg;

    # The Steam build's one Steamworks copy, at the install root, gets the gbe_fork shim; inert on
    # GOG (`steam.emu.enable` follows `fetcher`). Required: mk-app.nix refuses a wine steam.emu that
    # names no `.dll` path.
    steam.emu.libPaths = [ "steam_api64.dll" ];

    # Save: the Creation Engine writes saves + Skyrim.ini/SkyrimPrefs.ini under
    # Documents\My Games\<folder>, and THE FOLDER NAME IS STORE-SPECIFIC — this is the one place
    # where getting the fetcher wrong loses data silently rather than loudly, so it is derived from
    # the axis, not hardcoded:
    #
    #   gog    "Skyrim Special Edition GOG"  — from a +file trace of SkyrimSE.exe.
    #   steam  "Skyrim Special Edition"      — the "Copy Folders" rule in its installscript.vdf.
    #
    # Both bind the same host dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID), which is deliberate: the save
    # format is identical, so a save made under one store's build opens under the other's. Bind the
    # whole folder (saves + .ini config together).
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "Documents/My Games/Skyrim Special Edition${lib.optionalString onGog " GOG"}";
      }
    ];

    # setup.sh seeds SkyrimPrefs.ini's iSize/fullscreen from PROPNIX_WIDTH/HEIGHT and merges the
    # PROPNIX_QUALITY preset: the engine renders its backbuffer at iSize even in fullscreen, and the
    # bypassed SkyrimSELauncher.exe is what normally writes both. Top-level, not a wine knob: the
    # hook runs in the OUTER phase before any prefix exists, and writes into the HOST save dir that
    # each store's `saveBinds` row then places.
    setupScript = mkSetupScript {
      name = "skyrim-se-setup";
      script = ./setup.sh;
      withIniLib = true;
    };

    wine = presets.mergeTuning [
      (import ./wine-tuning.nix)
      {
        # Galaxy64.dll (statically imported, at the root) gets the no-op stub as offline policy (see
        # emulators/galaxy-stub); gated on GOG because the Steam payload has no Galaxy SDK.
        galaxyStubDlls = lib.mkIf onGog [ "Galaxy64.dll" ];
      }
    ];
  }
)
