# builders/launcher-package.nix — mkLauncherPackage: the shared packaging TAIL of every propnix app.
# Both builders (wine.nix, thin.nix) compute their launcher config JSON + icon tree, then delegate here for
# the parts that are backend-independent: the `bin/<pname>` wrapper (makeWrapper around propnix-launcher
# with the baked config path), the `.desktop` entry (+ symbolic icon), meta.broken gating, and the final
# symlinkJoin. The configFile IS the launcher↔wrapper interface (PLAN2 §4): Nix computes the intended
# state; the launcher enforces it.
{
  lib,
  stdenv,
  runCommand,
  makeWrapper,
  symlinkJoin,
  propnix-launcher,
  mkDesktopItem,
}:
{
  pname,
  appid,
  name,
  exe, # for startupWMClass (the window class ≈ exe basename, lowercased)
  configFile,
  iconTree ? null, # the hicolor theme + splash tree (built by the caller — icon SOURCE selection is per-builder)
  iconSymbolic ? null,
  # `{ systems; reason; }` — meta.broken on the listed systems. The derivation still EVALUATES there
  # (discoverable, reason inspectable via `nix eval`); only building is refused (without allowBroken).
  broken ? {
    systems = [ ];
    reason = null;
  },
  description,
  extraPassthru ? { },
}:
let
  wrapper = runCommand "${pname}-launcher-wrapper" { nativeBuildInputs = [ makeWrapper ]; } ''
    mkdir -p "$out/bin"
    makeWrapper ${propnix-launcher}/bin/propnix-launcher "$out/bin/${pname}" \
      --add-flags "--config ${configFile}"
  '';

  desktopItem = mkDesktopItem {
    inherit appid name iconSymbolic;
    exec = pname; # resolves from PATH once the package is installed
    hasIcon = iconTree != null; # set Icon=<id> only if the raster theme is actually installed
    startupWMClass = lib.toLower (baseNameOf exe);
  };

  isBroken = lib.elem stdenv.hostPlatform.system broken.systems;
in
symlinkJoin {
  name = pname;
  paths = [
    wrapper
    desktopItem
  ]
  ++ lib.optional (iconTree != null) iconTree; # the freedesktop hicolor raster theme
  passthru = {
    inherit configFile;
    launcher = propnix-launcher;
  }
  // extraPassthru;
  meta = {
    inherit description;
    mainProgram = pname;
    broken = isBroken;
  }
  // lib.optionalAttrs (broken.reason != null) { brokenReason = broken.reason; };
}
