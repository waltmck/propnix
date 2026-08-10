# Hollow Knight (GOG, WINDOWS x86_64 build) on 16K aarch64-linux via wine + FEX — no muvm.
# This is the Windows counterpart to poc/hollow-knight-x86_64.nix (box64, Linux build). It
# validates the wine+FEX path end-to-end on a real game, and is the template for Windows-only
# titles (e.g. Baldur's Gate 3) that have no Linux build.
#
# Payload: the pinned GOG **Galaxy** build fetched with gogdl (D15) — delivered as the game tree
# directly, so there is NO InnoSetup/innoextract step (the old offline-installer path is gone).
#
#   nix-build wine-fex/hollow-knight-win.nix --option extra-sandbox-paths /propnix=/var/tmp/propnix
#   ./result/bin/hollow-knight-win
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs {
    system = "aarch64-linux";
    config.allowUnfree = true;
  },
}:
let
  winefex = import ./winefex.nix { inherit nixpkgs pkgs; };

  # Pinned GOG Galaxy Windows build (VERIFIED reproducible: two independent gogdl downloads +
  # a clean-sandbox FOD build all reproduced this recursive hash). gogdl takes the NUMERIC
  # productId, not the slug.
  galaxyTree = (import ./fetchGogGalaxyBuild-gogdl.nix { inherit nixpkgs pkgs; }) {
    productId = "1308320804";
    buildId = "59545516053866453";
    version = "1.5.12620";
    hash = "sha256-zNs+los9+7taVgCKmFrVrKGFHQMqJkB/Pau6nnE5EkU=";
    pname = "hollow-knight-win";
  };

  hollow-knight-win = pkgs.writeShellApplication {
    name = "hollow-knight-win";
    runtimeInputs = [ winefex pkgs.coreutils ];
    text = ''
      export PROPNIX_APPID=hollow-knight
      # HK renders correctly on wine's NATIVE Wayland driver (tested 2026-08-09: single native window,
      # stable, no err:) → native fractional scaling, no Xwayland. Per-title choice (RESEARCH §12); the
      # only rough edge is an undersized cursor on a scaled output. (SDL_VIDEODRIVER is irrelevant to the
      # Windows build — it uses wine's driver, not Linux SDL — so it is not set.)
      export PROPNIX_WINE_GRAPHICS=wayland
      # D3D backend: winefex defaults to DXVK (native ARM64EC) — measured 60 fps and lower CPU than the
      # box64 Linux build, vs wined3d-Vulkan's ~12 (RESEARCH §22). No per-title set needed; override to
      # wined3d-GL (also 60) with PROPNIX_WINE_D3D=wined3d.
      # WINEPREFIX is left unset: winefex defaults it to $XDG_STATE_HOME/propnix/hollow-knight/prefix
      # (§7.2 consolidated state), matching the box64 and native-ARM64 wine packages.

      # Save location. Default: share Unity's native persistentDataPath with the box64/Linux build:
      #   Linux:   ~/.config/unity3d/Team Cherry/Hollow Knight
      #   Windows: %USERPROFILE%\AppData\LocalLow\Team Cherry\Hollow Knight
      # userN.dat are engine-serialized + platform-independent, so the save is shared and persists
      # outside the rebuildable prefix. PlayerPrefs do NOT carry over (Windows: registry, Linux:
      # file), so keybinds/resolution reset — the actual save game is shared.
      # PROPNIX_SAVE_DIR overrides the root, NAMESPACED per app: $PROPNIX_SAVE_DIR/hollow-knight.
      if [ -n "''${PROPNIX_SAVE_DIR:-}" ]; then
        save_root="$PROPNIX_SAVE_DIR/$PROPNIX_APPID"
      else
        save_root="$HOME/.config/unity3d/Team Cherry/Hollow Knight"
      fi
      export PROPNIX_WINE_BIND="AppData/LocalLow/Team Cherry/Hollow Knight|$save_root"

      # winefex provisions the prefix (FEX emulators + Wow64 registry) + applies PROPNIX_WINE_BIND.
      cd "${galaxyTree}"
      exec winefex "${galaxyTree}/Hollow Knight.exe" "$@"
    '';
  };
in
hollow-knight-win
