# propnix-launcher — the per-app launcher (GTK4 splash + single-instance + env-seal + symlink-farm prefix
# + orchestration), the Rust port of winefex.nix's backend. Built with rustPlatform.buildRustPackage;
# deps vendored offline from Cargo.lock (no cargoHash to maintain, like propnix-prefetch). GTK is wrapped
# at install by wrapGAppsHook4 (sets the GTK/GIO env in the LAUNCHER process only — the wine child's env
# is the sealed one this program builds, so the two don't collide; PLAN2 §5).
{
  lib,
  rustPlatform,
  pkg-config,
  wrapGAppsHook4,
  gtk4,
  glib,
  wayland,
}:
rustPlatform.buildRustPackage {
  pname = "propnix-launcher";
  version = "0.1.0";
  # Only the crate inputs — exclude local build state and this file so the source hash tracks the code.
  src = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: _type:
      let
        base = baseNameOf (toString path);
      in
      !(base == "target" || base == ".cargo-home" || base == "default.nix");
  };
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [
    pkg-config
    wrapGAppsHook4
  ];
  buildInputs = [
    gtk4 # gtk4-rs links the system GTK4 (pulls pango/cairo/gdk-pixbuf/graphene/glib as propagated deps)
    glib
    wayland # wayland-sys links libwayland-client for the wlr-foreign-toplevel focus path (focus.rs)
  ];

  doCheck = false; # no tests; the launcher is validated by the end-to-end HK run (§9)
  meta.description = "propnix per-app launcher: GTK4 splash + single-instance + env-seal + symlink-farm prefix orchestration";
}
