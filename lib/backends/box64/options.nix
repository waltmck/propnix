# backends/box64/options.nix — the `box64.*` option namespace (the box64 sibling of `wine.*`): the
# LIBRARY UNION a Linux-build game declares, each a function `p: [ drv ]` over a nixpkgs instance. box64
# splits them (native aarch64 bridge ∪ x86_64 guest, resolved twice so the two can't drift — D7); the FEX
# backend reuses the SAME declarations as a pure guest union, so one declaration serves both thin
# emulators. Games usually set the whole namespace from a file: `box64 = import ./box64-tuning.nix;`.
#
# WHICH nixpkgs INSTANCE `p` is depends on the resolved backend and the PAYLOAD's ABI, never on the host
# alone: `pkgs` for a host-ABI native run, `pkgsX86` for an x86_64 guest (box64, or FEX on an x86_64-linux
# payload), and `pkgsGuest32` for an i386-linux payload — cross-built i686 on aarch64, pkgsi686Linux on an
# x86_64 host, where a 32-bit payload runs on the native face. So name SONAMES, and expect the same
# declaration to be resolved in whichever ABI the payload turns out to need.
{ lib, knobTypes }:
{
  options.box64 = {
    bridgingLibs = lib.mkOption {
      type = knobTypes.lastWins;
      default = _p: [ ];
      defaultText = lib.literalExpression "_p: [ ]";
      description = ''
        Sonames box64 WRAPS: needed as NATIVE aarch64 libraries (the bridge) AND as x86_64 guest copies.
        A function `p: [ drv ]` resolved against both nixpkgs instances on aarch64.
      '';
    };
    guestLibs = lib.mkOption {
      type = knobTypes.lastWins;
      default = _p: [ ];
      defaultText = lib.literalExpression "_p: [ ]";
      description = ''
        Libraries the payload needs only in the GUEST's ABI (glibc, libstdc++, …): `p: [ drv ]` resolved
        from the guest set — pkgsX86 for an x86_64 payload, pkgsGuest32 for an i386 one. Under FEX this is
        where a game's whole library set belongs: FEX bridges nothing, so `bridgingLibs`' native/guest
        distinction has no meaning for a payload that only ever runs there.
      '';
    };
    guestPreload = lib.mkOption {
      type = knobTypes.dedupList lib.types.str;
      default = [ ];
      description = ''
        GUEST-arch libraries (store paths to x86_64 .so files) force-loaded into the emulated process ahead
        of every other resolution — the interposition hatch (Stellaris under box64: the offline Steam
        entitlement shim, which must win over the libsteam_api.so shipped beside the exe). Each thin
        backend translates it to its loader's spelling: BOX64_LD_PRELOAD under box64 (whose guest loader
        ignores LD_PRELOAD and prepends the exe's own directory to its search list, so nothing weaker
        interposes), plain LD_PRELOAD on native and under FEX (both run the real ld.so).

        CAUTION on native: plain LD_PRELOAD is inherited by EVERY child the game spawns, including host
        binaries (games shell out — Factorio execs `sh -c lsb_release`), and on a non-NixOS host a
        store-closure preload drags a second glibc into a foreign-distro process, which dies with SIGBUS.
        Prefer an `extraBinds` bind-over of the file the engine resolves (how steam-emu serves native);
        reserve this hatch for the guest-loader backends, whose spelling host children never read.
      '';
    };
  };
}
