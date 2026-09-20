# builders/launcher-package.nix — mkLauncherPackage: the shared packaging TAIL of every propnix app.
# Both builders (wine.nix, thin.nix) compute their launcher config JSON + icon tree, then delegate here for
# the parts that are backend-independent: the `bin/<pname>` wrapper (makeWrapper around propnix-launcher
# with the baked config path), the `.desktop` entry (+ symbolic icon), meta.broken gating, and the final
# symlinkJoin. The configFile IS the launcher↔wrapper interface (PLAN2 §4): Nix computes the intended
# state; the launcher enforces it.
{
  lib,
  stdenv,
  runCommandLocal,
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
  # `{ systems; reason; allow; }` — meta.broken on the listed systems. The derivation still EVALUATES
  # there (discoverable, reason inspectable via `nix eval`); only building is refused. `allow` is the
  # caller's escape hatch (the mkApp `allowBroken` option): it suppresses the refusal so a known wall can
  # be TESTED, while leaving `meta.brokenReason` in place and printing what is being ignored.
  broken ? {
    systems = [ ];
    reason = null;
    allow = false;
  },
  # Bare GitHub usernames (the mkApp `maintainers` option) → nixpkgs-shaped `meta.maintainers`. For
  # humans and stock tooling only: CI reads the option through `config` instead, because forcing `meta`
  # forces the derivation (see lib/tests/eval-matrix.nix).
  maintainers ? [ ],
  description,
  extraPassthru ? { },
  # Build-time ASSERTIONS the package must not be installable without: derivations that produce an empty
  # `$out` dir and fail loudly when their invariant does not hold (thin.nix checks that every declared
  # executable actually exists in one of the game trees). Joined in so `nix build` runs them; they
  # contribute no files.
  extraChecks ? [ ],
}:
let
  wrapper = runCommandLocal "${pname}-launcher-wrapper" { nativeBuildInputs = [ makeWrapper ]; } ''
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
  kwinGrant = runCommandLocal "${pname}-kwin-grant" { } ''
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

  # What this host's verdict WOULD be, and what it actually is: `allowBroken` is the only thing that
  # separates them. Keeping both means the warning below can name the wall it is overriding, and
  # `meta.brokenReason` stays truthful either way — a package built with the hatch is still a package
  # whose reason says why it should not work.
  knownBroken = lib.elem stdenv.hostPlatform.system broken.systems;
  isBroken = knownBroken && !(broken.allow or false);
in
# LOUD, because a silently-built broken config is how a stale `broken.systems` entry survives: the point
# of the hatch is to test the wall, so say which wall is being ignored.
lib.warnIf (knownBroken && (broken.allow or false))
  "propnix (${pname}): allowBroken — building a configuration known broken on ${stdenv.hostPlatform.system}${
    lib.optionalString (broken.reason != null) ": ${broken.reason}"
  }"
  (symlinkJoin {
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
      maintainers = map (github: { inherit github; }) maintainers;
    }
    // lib.optionalAttrs (broken.reason != null) { brokenReason = broken.reason; };
  })
