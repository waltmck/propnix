# Proton's extended Windows fallback fonts, built from the exact sources and recipes on its proton_11.0
# branch. These are open, metric/name-compatible replacements -- not redistributed Microsoft fonts.
#
# Keep this as its own architecture-independent derivation. Each host-specific lower prefix links the
# result into C:\windows\Fonts alongside Wine's built-in fonts, exactly as Proton's prefix setup does.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  bash,
  gnumake,
  patch,
  fontforge,
  python3Packages,
}: let
  protonRev = "db9e6ffbf24a95b104fb699dd62532c70a2f9a51";
  protonSrc = fetchFromGitHub {
    owner = "ValveSoftware";
    repo = "Proton";
    rev = protonRev;
    sha256 = "0z57p41wqh9zmdlhjq5p62wbi3m5mm7c9b4cbcav9dzfsqs4021f";
  };

  # Proton carries this as a git submodule, so fetch it independently rather than pulling Proton's many
  # unrelated emulator/graphics submodules into the font derivation.
  liberationSrc = fetchFromGitHub {
    owner = "liberationfonts";
    repo = "liberation-fonts";
    rev = "4b0192046158094654e865245832c66d2104219e";
    sha256 = "11472kifz1h9qbljxqzdyqxqmzd90yygpm55kxbazzx47nh6w3as";
  };
in
  stdenvNoCC.mkDerivation {
    pname = "proton-fallback-fonts";
    version = "11.0-${builtins.substring 0 12 protonRev}";
    src = protonSrc;

    nativeBuildInputs = [
      bash
      gnumake
      patch
      fontforge
      python3Packages.afdko
      python3Packages.fonttools
    ];

    postUnpack = ''
      chmod -R u+w "$sourceRoot"
      mkdir -p "$sourceRoot/fonts/liberation-fonts"
      cp -R ${liberationSrc}/. "$sourceRoot/fonts/liberation-fonts/"
    '';

    postPatch = ''
      # FontForge and fonttools honor SOURCE_DATE_EPOCH. Proton's all-in-one build deliberately unexports it
      # for its per-architecture binaries; this data-only build keeps a fixed epoch so the font tables are
      # reproducible too. AFDKO 5 renamed makeotfexe to makeotf; the replacement wrapper accepts the same
      # source/options used here and performs the now-separate CFF conversion internally.
      substituteInPlace Makefile.in \
        --replace-fail "SHELL := /bin/bash" "SHELL := ${bash}/bin/bash" \
        --replace-fail "afdko makeotfexe" "afdko makeotf" \
        --replace-fail "unexport SOURCE_DATE_EPOCH" "export SOURCE_DATE_EPOCH"
      patchShebangs fonts/scripts
    '';

    buildPhase = ''
      runHook preBuild
      export SOURCE_DATE_EPOCH=1
      make -j "$NIX_BUILD_CORES" -f Makefile.in fonts \
        CONTAINER=1 \
        SRCDIR="$PWD" \
        FONTS_OBJ="$PWD/obj-fonts"
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/fonts/truetype/proton" "$out/share/fonts/truetype/proton/alt"

      # The default set installed by Proton. The alternate Arial is retained for the two title-specific
      # Proton workarounds, but is intentionally not linked into propnix prefixes by default.
      install -m444 obj-fonts/{arial,arialbd,georgia,times,cour,courbd,micross,nirmala}.ttf \
        "$out/share/fonts/truetype/proton/"
      install -m444 obj-fonts/source-han/{msyh.ttf,simsun.ttc,malgun.ttf} \
        "$out/share/fonts/truetype/proton/"
      install -m444 obj-fonts/ume-gothic/msgothic.ttc \
        "$out/share/fonts/truetype/proton/"
      install -m444 obj-fonts/alt/arial.ttf \
        "$out/share/fonts/truetype/proton/alt/"
      runHook postInstall
    '';

    meta = {
      description = "Proton's open metric-compatible Windows fallback fonts";
      homepage = "https://github.com/ValveSoftware/Proton";
      license = [
        lib.licenses.ofl
        {
          fullName = "UmeFont License";
          free = true;
          redistributable = true;
        }
      ];
      platforms = lib.platforms.all;
    };
  }
