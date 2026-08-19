# emulators/gbe-fork.nix — gbe_fork (Detanup01), the MAINTAINED successor of Mr_Goldberg's Goldberg
# emulator: the Steam-API reimplementation the steam-emu module preloads so a Steam engine resolves DLC
# entitlement offline. Chosen over nixpkgs' goldberg-emu 0.2.5 because 0.2.5 speaks only the pre-1.58
# Steamworks flat API — a game built against SDK 1.58+ initializes via `SteamInternal_SteamAPI_Init`,
# which 0.2.5 does not export (hollow-knight, SDK 1.60: the lib loads, init throws, black screen).
# gbe_fork tracks current SDKs (1.64 as of this pin), exports the new entry points, and covers every
# interface revision hollow-knight's genuine lib carries (verified by symbol/strings diff, 2026-08-19).
#
# STATUS: prebuilt RELEASE ARTIFACTS (Linux .so's + Windows .dll's of the same tag), pinned by tag + hash.
# The archives also carry "experimental" builds, a steamclient loader, lobby_connect, and a
# `generate_interfaces` tool (all left unpackaged).
# BACKLOG: package from source instead (premake5 + vendored deps — protobuf, ssq, …) — the same
# discipline the from-source emulators here follow; the prebuilt is fine for now because the .so is GUEST
# x86_64 content (loaded into the emulated process, never linked against host libs), statically carries
# its protobuf, and NEEDs only glibc ≥ 2.38 + libstdc++/libgcc_s — which the thin backends append to the
# guest lib union whenever steam-emu is enabled.
{
  lib,
  stdenvNoCC,
  fetchurl,
  p7zip,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "gbe-fork";
  version = "2026_07_19";

  src = fetchurl {
    url = "https://github.com/Detanup01/gbe_fork/releases/download/release-${finalAttrs.version}/emu-linux-release.tar.bz2";
    hash = "sha256-OCq+Kffp5P67L3PJ4qM3bmqv2ZMmaJDVGfJL7IlI1gQ=";
  };
  # The Windows release of the SAME tag: `regular/{x64,x86}/steam_api(64).dll`, the drop-in replacements a
  # wine game loads from its own tree (steam-emu's union-replacement). Import tables carry only
  # KERNEL32/USER32/WS2_32/IPHLPAPI (static CRT) — all wine builtins, nothing for the prefix to add.
  winSrc = fetchurl {
    url = "https://github.com/Detanup01/gbe_fork/releases/download/release-${finalAttrs.version}/emu-win-release.7z";
    hash = "sha256-O6hV75YiBRNqVPsyUZpGNi4MxbQvwrs2Z+TSEwfZcuU=";
  };

  nativeBuildInputs = [ p7zip ];

  # The payload is foreign-arch (x86_64 guest ELF / x86 PE) prebuilt code — keep the bytes verbatim: no
  # host strip, no RPATH shrink, no patchelf (the .so resolves via the launch's guest LD_LIBRARY_PATH,
  # the .dlls via wine; never the host loader).
  dontStrip = true;
  dontPatchELF = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm444 regular/x64/libsteam_api.so "$out/share/gbe_fork/x64/libsteam_api.so"
    install -Dm444 regular/x86/libsteam_api.so "$out/share/gbe_fork/x86/libsteam_api.so"
    7z x -y "$winSrc" 'release/regular/x64/steam_api64.dll' 'release/regular/x86/steam_api.dll' -owin > /dev/null
    install -Dm444 win/release/regular/x64/steam_api64.dll "$out/share/gbe_fork/win/x64/steam_api64.dll"
    install -Dm444 win/release/regular/x86/steam_api.dll "$out/share/gbe_fork/win/x86/steam_api.dll"
    install -Dm444 -t "$out/share/doc/gbe_fork" README.release.md CHANGELOG.md CREDITS.md
    runHook postInstall
  '';

  meta = {
    description = "Steam API reimplementation (Goldberg emulator fork) — offline entitlement shim, prebuilt guest-x86_64 .so + x86/x64 .dll release";
    homepage = "https://github.com/Detanup01/gbe_fork";
    license = lib.licenses.lgpl3Only;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
