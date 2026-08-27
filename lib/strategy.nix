# strategy.nix — the PLATFORM AXIS and `resolveStrategy`, the ONE pure function that picks the execution
# backend for an ALREADY-CHOSEN payload platform on a host (DESIGN.md D4). It selects the *backend*, never
# which store or build to fetch — that is the game's `fetcher`/`emulatedPlatform` axes + `fetchInfo` matrix
# (a per-title judgment, not a derivable fact). `mkApp` uses it only as the DEFAULT of the `backend` option,
# so a user's `.apply { backend = "fex"; }` still wins; the selection logic stays a pure, unit-testable
# function outside the module fixpoint (D16 keeps this pure).
#
# The platform TABLE lives here too (`platforms` / `platformToNeed`), so the axis's vocabulary and the
# backend selection that reads it cannot drift: modules/app-options.nix builds its `emulatedPlatform` enum
# and its fetch matrix from this list. `runnable` has two consumers — that same resolver, which skips a
# platform this host cannot execute, and the thin backend, which turns one into a `meta.broken`
# contribution so an EXPLICITLY selected unrunnable pair still evaluates (the CI matrix forces every pinned
# pair on both systems) and is refused only at build time.
# Extending the platform axis is ONE edit: a `platforms` entry plus its `platformToNeed` row.
{ lib }:
rec {
  # The supported content platforms — the `emulatedPlatform` vocabulary.
  platforms = [
    "x86_64-windows"
    "i386-windows"
    "aarch64-linux"
    "x86_64-linux"
  ];

  # A platform → the { os; arch; } ABI pair `resolveStrategy` selects a backend from.
  platformToNeed =
    p:
    {
      "x86_64-windows" = {
        os = "windows";
        arch = "x86_64";
      };
      "i386-windows" = {
        os = "windows";
        arch = "i386";
      };
      "x86_64-linux" = {
        os = "linux";
        arch = "x86_64";
      };
      "aarch64-linux" = {
        os = "linux";
        arch = "aarch64";
      };
    }
    .${p};

  # An x86 guest (either width) is what box64 emulates; an x86_64 host runs both directly.
  isX86Guest = need: need.arch == "x86_64" || need.arch == "i386";
  hostArchOf = system: if lib.hasPrefix "aarch64" system then "aarch64" else "x86_64";

  # need   = { os = "windows" | "linux"; arch = "x86_64" | "i386" | "aarch64"; }   (the payload's ABI)
  # system = "aarch64-linux" | "x86_64-linux"                                      (stdenv.hostPlatform.system)
  # → "wine" | "box64" | "native"
  #
  # TOTAL over the registry, deliberately: it answers "which backend WOULD run this" for every pair,
  # including the pairs that cannot actually run here (aarch64 content on x86_64). Returning a sentinel
  # instead would leak "unsupported" into `backend`'s enum and turn a package that merely can't run on
  # THIS host into an eval error — which the CI matrix (one forced `.apply` per pinned pair, on BOTH
  # systems) would report as a red x86_64 leg. Unrunnability is a BUILD refusal (`meta.broken`, contributed
  # by the backend entry via `runnable` below), never an evaluation failure.
  resolveStrategy =
    need: system:
    if need.os == "windows" then
      # wine handles both hosts; it picks native vs ARM64EC-Hangover+HODLL and the 32-bit backend DLL INTERNALLY
      # (host/bits-derived, not a surface choice).
      "wine"
    else
      # Linux content. box64 is the ONE emulator here (fex is opt-in via `.apply`; box86 is dead on 16K),
      # and it only emulates x86 — so an aarch64 host runs an x86 payload under box64 and everything else
      # goes straight to `native`.
      (if isX86Guest need && hostArchOf system == "aarch64" then "box64" else "native");

  # Can `system` actually run this platform's content? The `emulatedPlatform` resolver filters the game's
  # own quality ranking through this (so a game may rank a host-specific native build first without
  # stranding the other host), and the thin backend turns a false here into `meta.broken` for the
  # explicit-override path. The one false case today: aarch64 Linux content on x86_64 — propnix ships no
  # ARM-on-x86 emulator, and running one would be strictly worse than the game's own x86_64 build.
  runnable =
    platform: system:
    let
      need = platformToNeed platform;
    in
    need.os == "windows" || isX86Guest need || need.arch == hostArchOf system;
}
