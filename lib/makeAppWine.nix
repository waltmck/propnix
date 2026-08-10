# makeAppWine — turn a game spec into an installable package that invokes propnix-launcher (PLAN2 §4).
#
# ARCH-TRANSPARENT: the emulator set (wine/dxvk/vkd3d/prefixLower) is injected from the scope, which wires
# the arch-appropriate packages (aarch64 → Hangover wine + FEX + native ARM64EC DXVK/vkd3d; x86_64 →
# the SAME wine source built native + standard x86_64 DXVK/vkd3d, no FEX). The wrapper, launcher, config,
# game spec, and tuning are IDENTICAL across arches, and the EXTERNAL behaviour (every PROPNIX_* env var)
# is the same — the emulation is handled transparently below the launcher. (A future arg could select the
# aarch64 emulator between FEX and box64; for now aarch64 always uses FEX via the scope.)
#
# The produced package is a symlinkJoin of `bin/<pname>` (a makeWrapper around the launcher, with the
# baked config path added as a flag) + the `.desktop` entry (+ icon). The `configFile` — a writeText JSON
# with all store paths interpolated — IS the launcher↔wrapper interface (PLAN2 §4): Nix computes the
# intended state; the launcher enforces it. The config bakes DEFAULTS ONLY; every knob is overridable at
# runtime by the matching PROPNIX_* env var (§5), so a user or NixOS module can steer all games at once.
{
  lib,
  stdenv,
  runCommand,
  makeWrapper,
  writeText,
  symlinkJoin,
  wine,
  dxvk,
  vkd3d,
  prefixLower,
  propnix-prefetch,
  propnix-launcher,
  sealing,
  winefexDefaults,
  mkPropnixDesktopItem,
  extractPeIcon,
}:
{
  pname,
  appid,
  payload, # a derivation (e.g. fetchGogGalaxyBuild result); its store path is the game tree + launch cwd
  exe, # executable relative to payload, e.g. "Hollow Knight.exe"
  tuning, # per-game tuning; layered over winefexDefaults (only the game-specific bits, e.g. `save`)
  name ? pname, # human-visible name (desktop entry + splash)
  autoIcon ? true, # extract the app icon from the exe's PE resources into a freedesktop hicolor theme
  iconSymbolic ? null, # optional monochrome `-symbolic.svg` (currentColor) variant
}:
let
  # Layer the per-game tuning over the global defaults, then strip reasons.
  #   flat = { d3d; graphics; dllOverrides = { <dll> = <order>; … }; save; (dpi?; fps?) }
  flat = sealing.flattenTuning (sealing.mergeTuning winefexDefaults tuning);
  wineUser = prefixLower.wineUser; # single source of truth: the user the store prefix was built for

  # Icon: extract the exe's PE icon into a freedesktop hicolor theme (all sizes → share/icons/…), found
  # natively via $XDG_DATA_DIRS once installed. `${iconTree}/icon.png` (largest size) feeds the splash.
  iconName = "org.propnix.${appid}";
  iconTree = if autoIcon then extractPeIcon { inherit payload exe iconName; } else null;
  splashIcon = if iconTree != null then "${iconTree}/share/propnix/${iconName}.png" else null;

  # Informational: which emulation the scope wired for this host (aarch64 = wine+FEX/ARM64EC, x86_64 =
  # native wine). The launcher does NOT branch on this — its behaviour is arch-identical.
  backend = if stdenv.hostPlatform.isAarch64 then "winefex" else "wine";

  # The §7 seal: targeted scrub + the structured DLL-override map + the remaining meant vars. The launcher
  # joins dllOverrides into WINEDLLOVERRIDES (merging the DXVK/vkd3d entries) at launch; USER/LOGNAME pin
  # the wine profile to the store lower's user; WINEDEBUG's launch default is -all (PROPNIX_WINEDEBUG wins).
  seal = sealing.mkSeal {
    dllOverrides = flat.dllOverrides;
    setEnv = {
      WINEDEBUG = "-all";
      USER = wineUser;
      LOGNAME = wineUser;
    };
  };

  configFile = writeText "propnix-${appid}.json" (
    builtins.toJSON {
      schema = 1;
      inherit appid name exe backend;
      icon = splashIcon; # largest extracted PE icon (for the splash), or null
      payload = "${payload}";
      wineUser = wineUser;
      emulators = {
        wine = "${wine}";
        prefixLower = "${prefixLower}";
        dxvk = "${dxvk}";
        vkd3d = "${vkd3d}";
        prefetch = "${propnix-prefetch}/bin/propnix-prefetch";
      };
      defaults = {
        graphics = flat.graphics;
        d3d = flat.d3d;
        dpi = flat.dpi or null; # a title may add these to tuning; default null
        fps = flat.fps or null;
      };
      save = flat.save; # { guestRel; hostDefault; } passed through by flattenTuning
      # HKCU overrides re-applied every launch (list of { key; name; value; type; }); e.g. the black
      # pre-render window colors. From winefexDefaults.userReg, mergeable per-game.
      userReg = flat.userReg;
      inherit seal;
    }
  );

  wrapper = runCommand "${pname}-launcher-wrapper" { nativeBuildInputs = [ makeWrapper ]; } ''
    mkdir -p "$out/bin"
    makeWrapper ${propnix-launcher}/bin/propnix-launcher "$out/bin/${pname}" \
      --add-flags "--config ${configFile}"
  '';

  desktopItem = mkPropnixDesktopItem {
    inherit appid name iconSymbolic;
    exec = pname; # resolves from PATH once the package is installed
    hasIcon = iconTree != null; # set Icon=<id> only if the raster theme is actually installed
    # wine's top-level window class ≈ the exe basename (lowercased). Confirm at Tier-3 verification.
    startupWMClass = lib.toLower (baseNameOf exe);
  };
in
symlinkJoin {
  name = pname;
  paths = [
    wrapper
    desktopItem
  ]
  ++ lib.optional (iconTree != null) iconTree; # the freedesktop hicolor raster theme
  passthru = {
    inherit configFile payload backend;
    launcher = propnix-launcher;
  };
  meta = {
    description = "${name} — propnix wine app (${backend})";
    mainProgram = pname;
  };
}
