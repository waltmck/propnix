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
  # Build-time ASSERTIONS the package must not be installable without: derivations that produce an empty
  # `$out` dir and fail loudly when their invariant does not hold (thin.nix checks that every declared
  # executable actually exists in one of the game trees). Joined in so `nix build` runs them; they
  # contribute no files.
  extraChecks ? [ ],
}:
let
  wrapper = runCommand "${pname}-launcher-wrapper" { nativeBuildInputs = [ makeWrapper ]; } ''
    mkdir -p "$out/bin"
    makeWrapper ${propnix-launcher}/bin/propnix-launcher "$out/bin/${pname}" \
      --add-flags "--config ${configFile}"
  '';

  # The launcher's KWin-authorization desktop entry (see propnix-launcher's postFixup: it is what grants
  # the launcher binary KDE's window-management global for the raise + window-watcher paths), linked into
  # the GAME package so installing a game installs the grant — a bare launcher package is never in a
  # profile. Named by the launcher's store hash: two games pinning DIFFERENT launcher builds then install
  # two entries (each authorizing its own binary) instead of colliding in the merged profile, while games
  # sharing one build dedupe to identical links.
  launcherHash = lib.substring 0 8 (lib.removePrefix "/nix/store/" "${propnix-launcher}");
  kwinGrant = runCommand "${pname}-kwin-grant" { } ''
    mkdir -p "$out/share/applications"
    ln -s ${propnix-launcher}/share/applications/org.propnix.launcher.desktop \
      "$out/share/applications/org.propnix.launcher-${launcherHash}.desktop"
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
    kwinGrant
  ]
  ++ lib.optional (iconTree != null) iconTree # the freedesktop hicolor raster theme
  ++ extraChecks; # empty dirs; here only so their assertions are forced by a build
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
