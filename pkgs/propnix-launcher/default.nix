# propnix-launcher — the per-app launcher (GTK4 splash + single-instance + env-seal + in-process mount-table
# prefix + orchestration). It LINKS propnix-mount + propnix-prefetch as library crates (path deps) rather
# than exec'ing them as separate binaries, so the build source is all three crate dirs and cargo builds the
# launcher crate (which pulls the two libs in). Built with rustPlatform.buildRustPackage; deps vendored
# offline from Cargo.lock (no cargoHash). GTK is wrapped at install by wrapGAppsHook4 (sets the GTK/GIO env in
# the LAUNCHER process only — the wine child's env is the sealed one this program builds; PLAN2 §5).
{
  lib,
  rustPlatform,
  pkg-config,
  wrapGAppsHook4,
  gtk4,
  glib,
  wayland,
}:
let
  # Build source = the three sibling crate dirs under pkgs/ (the launcher path-deps propnix-mount +
  # propnix-prefetch). Exclude local build state so the hash tracks the code.
  crates = [
    "propnix-launcher"
    "propnix-mount"
    "propnix-prefetch"
    "propnix-steam-cred" # stored-Steam-credential decoding (steamid.rs), shared with propnix-cli
  ];
  src = lib.cleanSourceWith {
    name = "propnix-rust";
    src = ../.; # pkgs/
    filter =
      path: _type:
      let
        rel = lib.removePrefix (toString ../. + "/") (toString path);
        top = lib.head (lib.splitString "/" rel);
      in
      builtins.elem top crates && !(builtins.elem (baseNameOf path) [ "target" ".cargo-home" ]);
  };
in
rustPlatform.buildRustPackage {
  pname = "propnix-launcher";
  version = "0.1.0";
  inherit src;
  # cargo builds the launcher crate; its path deps (../propnix-mount, ../propnix-prefetch) are siblings here.
  sourceRoot = "propnix-rust/propnix-launcher";
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [
    pkg-config
    wrapGAppsHook4
  ];
  buildInputs = [
    gtk4 # gtk4-rs links the system GTK4 (pulls pango/cairo/gdk-pixbuf/graphene/glib as propagated deps)
    glib
    wayland # wayland-sys links libwayland-client for the ext/wlr foreign-toplevel focus path (focus.rs)
  ];

  # The self-contained unit tests (steamid.rs's ini merge — the launch orchestration itself is still
  # validated by the end-to-end game runs, §9). Everything they touch is pure fs, so this stays sandbox-safe.
  doCheck = true;

  # KWin AUTHORIZATION for the focus paths (focus.rs). KDE hides `org_kde_plasma_window_management` — its
  # only window list/activate protocol; KWin implements no wlr foreign-toplevel-management and no ext
  # toplevel list — from every client except those whose INSTALLED desktop file (a) has an `Exec` whose
  # first token canonicalizes to the client's /proc/<pid>/exe and (b) declares the interface in
  # `X-KDE-Wayland-Interfaces` (KWin src/utils/serviceutils.h; xdg-desktop-portal-kde is granted its
  # screencast global the same way). Two subtleties both live in that sentence:
  #   * the CONNECTING exe is `.propnix-launcher-wrapped` — wrapGAppsHook4's wrapper execs it — so Exec
  #     must name the wrapped file, not the friendly `bin/propnix-launcher` (the paths never match
  #     otherwise). postFixup runs after the per-output fixup hooks have wrapped, so the wrapped name
  #     exists here; the plain name is the fallback if the hook ever stops wrapping.
  #   * NoDisplay keeps this out of menus; KWin's KApplicationTrader query still considers it.
  # mkLauncherPackage links this file into every game package (under a launcher-unique name), so
  # INSTALLING a game is what grants its launcher the global. Without the grant the plasma paths see no
  # manager and degrade to a graceful no-op — `nix run` without installation keeps working, just without
  # raise/window-watch on KDE.
  postFixup = ''
    exe="$out/bin/.propnix-launcher-wrapped"
    [ -e "$exe" ] || exe="$out/bin/propnix-launcher"
    mkdir -p "$out/share/applications"
    {
      echo "[Desktop Entry]"
      echo "Type=Application"
      echo "Name=propnix launcher"
      echo "Comment=Internal entry granting the propnix launcher KWin window management (X-KDE-Wayland-Interfaces); not a menu item"
      echo "Exec=$exe"
      echo "NoDisplay=true"
      echo "X-KDE-Wayland-Interfaces=org_kde_plasma_window_management"
    } > "$out/share/applications/org.propnix.launcher.desktop"
  '';

  meta.description = "propnix per-app launcher: GTK4 splash + single-instance + env-seal + in-process mount-table prefix orchestration (links propnix-mount + propnix-prefetch)";
  meta.mainProgram = "propnix-launcher";
}
