# Factorio (GOG, Windows x86_64 build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. Wube Software's factory-automation sim on its own engine (D3D/OpenGL). ARCH-AGNOSTIC: the same
# spec runs on both hosts; mkApp + the scope pick the arch-appropriate emulator set, and the SAME Windows
# payload (a content-addressed FOD) is shared across arches. GOG's Galaxy content-system has NO Linux build
# for Factorio (Windows + Mac only), so like the other titles we package the Windows build via wine.
# Payload = the pinned GOG Galaxy build fetched by fetchGogGalaxyBuild (D15), delivered as the game tree directly.
#
#   nix run .#factorio --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
  mkSetupScript,
  fetchGogGalaxyBuild,
}:
let
  versions = lib.importJSON ./versions.json;
in
mkApp (
  { config, lib, ... }:
  {
    pname = "factorio";
    appid = "factorio";
    name = "Factorio";
    # GOG-Windows only (GOG's Galaxy content-system has no Linux Factorio build).
    fetchInfo = versions.fetchInfo;

    # The 64-bit game binary (goggame-*.info isPrimary FileTask, PE32+ x86-64). Factorio resolves read-data +
    # its %APPDATA%\Factorio write dir from the EXECUTABLE location (via GetModuleFileName → bin/x64/../..),
    # NOT the cwd, so no `workingDir` is needed. No Galaxy SDK in the tree (no galaxyStubDlls), and the modern
    # VC++/UCRT runtime loads on wine's ARM64EC builtins under FEX (no extraSystem32).
    exe = "bin/x64/factorio.exe";

    # Full-color icon: factorio.exe's PE resources top out at 48px (pixelated upscaled) AND the high-res game
    # asset is off-centre in its canvas, so use the 1024px icon Wube ships in the game data via `icon.png` —
    # autocropped + recentred into a crisp, centred hicolor theme + splash png (lib/icons/from-png.nix). The
    # symbolic variant is a vendored gear (Font Awesome 6 Solid, CC BY 4.0 — attribution in the .svg header).
    icon.png = "${lib.head config.payloads}/data/core/graphics/factorio.icon/Assets/factorio.png";
    icon.symbolic = ./factorio-symbolic.svg;

    # Save: Factorio's user-data dir (saves + mods + config + player-data + log) is %APPDATA%\Factorio on
    # Windows — CONFIRMED by config-path.cfg (`use-system-read-write-data-directories=true`) + the goggame
    # savePath `{userappdata}/Factorio`, and verified: the running game wrote config/config.ini +
    # factorio-current.log + temp/ here. Bound out of the rebuildable prefix to the app's host save dir
    # ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default $XDG_DATA_HOME/propnix-saves/factorio).
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "AppData/Roaming/Factorio";
      }
    ];

    # DLC — each versions.json `dlc` entry is a DLC-only FOD: the SAME base build fetched with a `dlcId`,
    # yielding just that DLC's game-relative overlay tree (e.g. `data/space-age/…`), no base exe. It is NOT
    # part of the base package: `factorio` ships vanilla; `factorio.withDlc [ "space-age" ]` (or
    # `factorio.withAllDlc` / `.apply { dlc.enabled = [ … ]; }`) flips the game mount to a read-only overlay
    # unioning base + selected DLC at runtime — so an enabled DLC costs no second copy of the base payload in
    # the store. Space Age (GOG DLC 1831417704) is Wube's 2.0 expansion (space platforms, new planets,
    # quality/elevated-rails); requires the base game.
    dlc.available = lib.mapAttrs (_: fetchGogGalaxyBuild) versions.dlc;

    # Run setup.sh before wine: assert `[other] check-updates=false` in config.ini so Factorio's in-game
    # auto-update check is off by default (moot for a read-only store payload — see setup.sh). Factorio keeps
    # this in config.ini, NOT the registry, so a `userReg` entry cannot express it. setup.sh uses the shared
    # `ini_set` (withIniLib) tuned to Factorio's CRLF `key=value` format.
    wine.setupScript = mkSetupScript {
      name = "factorio-setup";
      script = ./setup.sh;
      withIniLib = true;
    };
  }
)
