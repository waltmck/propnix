# box64 pinned to the latest UPSTREAM release (v0.4.3-2, May 2026) — ahead of nixpkgs' 0.4.2 — per
# propnix's latest-and-greatest emulator policy (memory: latest-and-greatest-emulators). Overrides
# nixpkgs box64's src to the newer tag; the cmake build is otherwise unchanged. Verified to compile
# and run before adoption. The box64 packages (poc/, future makeAppBox64) consume this.
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs { system = "aarch64-linux"; },
}:
pkgs.box64.overrideAttrs (o: {
  version = "0.4.3-2";
  src = pkgs.fetchFromGitHub {
    owner = "ptitSeb";
    repo = "box64";
    rev = "v0.4.3-2";
    hash = "sha256-Lp8+FfVp/bRTtwzwtv1tgDBzU/hwRMrXZcnBxh9q5gk=";
  };
})
