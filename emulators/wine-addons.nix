# Wine's redistributable high-level runtime payloads. Keep these separate from the Wine derivation: changing
# an MSI must rebuild the provisioned prefix, not the hour-long Wine compile. The versions and hashes match
# the constants in the pinned Hangover Wine tree (11.15, commit 1c9ef214): Mono 11.2.0 and Gecko 2.47.4.
#
# Gecko is provided for BOTH Windows guest architectures. Every propnix Wine build is WoW64-capable on both
# host systems: x86_64 programs use the x86_64 engine, while i386 programs use the x86 engine. The lower
# prefix that consumes these MSIs is still host-specific (aarch64-linux gets ARM64X/FEX Wine; x86_64-linux
# gets native Wine).
{fetchurl}: {
  mono = fetchurl {
    name = "wine-mono-11.2.0-x86.msi";
    url = "https://dl.winehq.org/wine/wine-mono/11.2.0/wine-mono-11.2.0-x86.msi";
    hash = "sha256-tFJWeefaMNRljOuFc5y8VcdxeRBUq7tLMVL+lt7QuJc=";
  };

  gecko = {
    x86 = fetchurl {
      name = "wine-gecko-2.47.4-x86.msi";
      url = "https://dl.winehq.org/wine/wine-gecko/2.47.4/wine-gecko-2.47.4-x86.msi";
      hash = "sha256-Js7MR3BrCRkI9/gUvdsHTGG+uAYzGOnvxaf3iYV3k9Y=";
    };
    x86_64 = fetchurl {
      name = "wine-gecko-2.47.4-x86_64.msi";
      url = "https://dl.winehq.org/wine/wine-gecko/2.47.4/wine-gecko-2.47.4-x86_64.msi";
      hash = "sha256-5ZC32YijLWqkzx2Ko6o9M3Zv3Uz0yJwtzCCV7LKNBm8=";
    };
  };
}
