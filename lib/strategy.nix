# strategy.nix — `resolveStrategy`, the ONE pure function that picks the execution backend for an
# ALREADY-CHOSEN payload platform on a host (DESIGN.md D4). It selects the *backend*, never which store or
# build to fetch — that is the game's `fetcher`/`emulatedPlatform` axes + `fetchInfo` matrix (a per-title
# judgment, not a derivable fact). `mkApp` uses it only as the DEFAULT of the `backend` option, so a user's
# `.apply { backend = "fex"; }` still wins; the selection logic stays a pure, unit-testable function
# outside the module fixpoint (D16 keeps this pure).
{ lib }:
rec {
  # need   = { os = "windows" | "linux"; arch = "x86_64" | "i386"; }   (the payload's ABI, from its recipe)
  # system = "aarch64-linux" | "x86_64-linux"                          (stdenv.hostPlatform.system)
  # → "wine" | "box64" | "fex" | "native" | "unsupported"
  resolveStrategy =
    need: system:
    let
      isAarch = lib.hasPrefix "aarch64" system;
    in
    if need.os == "windows" then
      # wine handles both hosts; it picks native vs ARM64EC-Hangover+HODLL and the 32-bit backend DLL INTERNALLY
      # (host/bits-derived, not a surface choice).
      "wine"
    else if need.os == "linux" then
      (
        if !isAarch then
          "native" # x86_64 Linux on an x86_64 host: run the ELF directly, no emulator
        else
          "box64"
      ) # x86_64 OR i386 Linux on aarch64: box64 by default (fex is opt-in via `.apply`; box86 is dead on 16K)
    else
      "unsupported";
}
