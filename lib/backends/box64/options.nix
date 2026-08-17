# backends/box64/options.nix — the `box64.*` option namespace (the box64 sibling of `wine.*`): the
# LIBRARY UNION a Linux-build game declares, each a function `p: [ drv ]` over a nixpkgs instance. box64
# splits them (native aarch64 bridge ∪ x86_64 guest, resolved twice so the two can't drift — D7); the FEX
# backend reuses the SAME declarations as a pure x86_64 guest union, so one declaration serves both thin
# emulators. Games usually set the whole namespace from a file: `box64 = import ./box64-tuning.nix;`.
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
      description = "Guest-only x86_64 libraries (glibc, libstdc++, …): `p: [ drv ]` resolved from pkgsX86.";
    };
  };
}
