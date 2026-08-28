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
  meta.description = "propnix per-app launcher: GTK4 splash + single-instance + env-seal + in-process mount-table prefix orchestration (links propnix-mount + propnix-prefetch)";
  meta.mainProgram = "propnix-launcher";
}
