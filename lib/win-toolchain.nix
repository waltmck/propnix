# lib/win-toolchain.nix — the per-TARGET Windows PE toolchain descriptors behind `winPkgs.<target>`
# (lib/default.nix): one record per target platform a Windows process on this host can be, naming the
# cross compiler that produces PE code for it and the facts a build checks its output against.
#
# THE TARGET VOCABULARY. Every PE this repo builds — the Galaxy stub, DXVK/vkd3d, the Mono runtime, the
# Steam shim — must match the PROCESS it is loaded into, never the host: a game's x64 exe loads x64 DLLs
# whatever CPU wine runs on, and a native ARM64 player loads ARM64 ones. So the packages are instantiated
# once per target, the nixpkgs way (the same expression, a different toolchain), and a consumer indexes
# the set by the process platform it serves. `aarch64ec-windows` is not a name nixpkgs or Microsoft use
# (ARM64EC is x64's ABI on ARM64 silicon, the hybrid wine+FEX runs x64 games through); it is this repo's
# name for that target, chosen so the set reads uniformly.
#
# TWO COMPILER FAMILIES, by host. On aarch64 every target comes from this tree's llvm-mingw (emulators/
# llvm-mingw, the patched release wine, FEX, DXVK and Mono are built with — it drives all four triples).
# On x86_64 that toolchain does not exist (it is a prebuilt pinned to the aarch64-hosted release), and
# the two x86 targets come from nixpkgs' cached cross-mingw GCC instead; the two ARM targets are simply
# absent there — nothing an x86_64 host runs could load them. nixpkgs' Windows cross package SETS
# (`pkgsCross.mingwW64`, `.ucrtAarch64`) are deliberately not part of a record: a dependency a package
# needs for a Windows target is built from its nixpkgs-pinned source with the record's compiler
# (emulators/gbe-fork/win-deps.nix is the pattern), so one toolchain produces every byte of a target.
#
# The record (every field a package may read):
#   target      the key ("x86_64-windows" | "i386-windows" | "aarch64-windows" | "aarch64ec-windows")
#   triple      the mingw triple ("x86_64-w64-mingw32" …)
#   kind        "llvm" | "gcc"
#   cc, cxx     the C / C++ driver command, flags included, for a shell `${cc} …`
#   ar, strip, windres, dlltool, objdump, ld, ranlib   the binutils, as paths
#   root        the toolchain's store path (llvm: `<root>/bin/<triple>-*`), for configure-style builds that
#               take tool NAMES (`CC=<triple>-clang`) with `root` on PATH
#   machine     the PE COFF machine the output must carry (an ARM64EC IMAGE is an x64 image by that
#               field — IMAGE_FILE_MACHINE_AMD64 — distinguished only by its CHPE metadata, which is what
#               wine's loader tests too; the 0xA641 machine exists for ARM64EC OBJECT files, and
#               llvm-readobj labels an image ARM64EC by reading the CHPE pointer, not the field)
#   machineHex  the same as a number, for a tool-independent header check
#   chpe        whether the output carries CHPE metadata (ARM64EC only)
#   nativeBuildInputs   what a derivation lists to have the drivers on PATH
#   checkPe     a shell command prefix: `${checkPe} <file>...` refuses an output whose COFF machine or
#               CHPE metadata is not this target's (lib/pe-check.py; needs python3 on PATH)
#   cmakeToolchain   a CMake toolchain file naming these tools (CMAKE_SYSTEM_NAME Windows, the target's
#               processor, the compilers, ar/ranlib/windres), for a dependency whose build system is CMake:
#               `cmake -DCMAKE_TOOLCHAIN_FILE=${cmakeToolchain} …`. Programs are never searched for under
#               the target (FIND_ROOT_PATH_MODE_PROGRAM NEVER); libraries and headers are found through the
#               CMAKE_PREFIX_PATH a build names, which in the sandbox holds nothing but what it names.
{
  lib,
  pkgs,
  # emulators/llvm-mingw on aarch64 hosts; null elsewhere.
  llvmMingw ? null,
}:
let
  peCheck = builtins.path {
    path = ./pe-check.py;
    name = "pe-check.py";
  };
  checkPeFor = t: "python3 ${peCheck} ${toString t.machineHex} ${if t.chpe then "1" else "0"}";
  targets = {
    "x86_64-windows" = {
      triple = "x86_64-w64-mingw32";
      machine = "IMAGE_FILE_MACHINE_AMD64";
      machineHex = 34404; # 0x8664
      chpe = false;
      cmakeProcessor = "AMD64";
      cross = pkgs.pkgsCross.mingwW64;
      llvmOnly = false;
    };
    "i386-windows" = {
      triple = "i686-w64-mingw32";
      machine = "IMAGE_FILE_MACHINE_I386";
      machineHex = 332; # 0x14c
      chpe = false;
      cmakeProcessor = "X86";
      cross = pkgs.pkgsCross.mingw32;
      llvmOnly = false;
    };
    "aarch64-windows" = {
      triple = "aarch64-w64-mingw32";
      machine = "IMAGE_FILE_MACHINE_ARM64";
      machineHex = 43620; # 0xAA64
      chpe = false;
      cmakeProcessor = "ARM64";
      cross = null;
      llvmOnly = true;
    };
    "aarch64ec-windows" = {
      triple = "arm64ec-w64-mingw32";
      machine = "IMAGE_FILE_MACHINE_AMD64";
      machineHex = 34404; # 0x8664 — an EC image is an x64 image with CHPE metadata (see the record notes)
      chpe = true;
      cmakeProcessor = "ARM64EC";
      cross = null;
      llvmOnly = true;
    };
  };

  # The toolchain file. `linkerFlags` is what the driver command carries beyond the compiler path (CMake
  # takes a bare path for CMAKE_<LANG>_COMPILER, so flags travel as *_LINKER_FLAGS_INIT).
  cmakeToolchainFor =
    target: t:
    {
      cc,
      cxx,
      windres,
      ar,
      ranlib,
      linkerFlags ? "",
    }:
    pkgs.writeText "cmake-toolchain-${target}.cmake" ''
      set(CMAKE_SYSTEM_NAME Windows)
      set(CMAKE_SYSTEM_PROCESSOR ${t.cmakeProcessor})
      set(CMAKE_C_COMPILER "${cc}")
      set(CMAKE_CXX_COMPILER "${cxx}")
      set(CMAKE_RC_COMPILER "${windres}")
      set(CMAKE_AR "${ar}")
      set(CMAKE_RANLIB "${ranlib}")
      set(CMAKE_EXE_LINKER_FLAGS_INIT "${linkerFlags}")
      set(CMAKE_SHARED_LINKER_FLAGS_INIT "${linkerFlags}")
      set(CMAKE_MODULE_LINKER_FLAGS_INIT "${linkerFlags}")
      set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
    '';

  llvm =
    target: t:
    let
      bin = "${llvmMingw}/bin";
      tools = {
        cc = "${bin}/${t.triple}-clang";
        cxx = "${bin}/${t.triple}-clang++";
        windres = "${bin}/${t.triple}-windres";
        ar = "${bin}/llvm-ar";
        ranlib = "${bin}/${t.triple}-ranlib";
      };
    in
    {
      inherit target;
      inherit (t)
        triple
        machine
        machineHex
        chpe
        ;
      inherit (tools)
        cc
        cxx
        windres
        ar
        ranlib
        ;
      kind = "llvm";
      root = llvmMingw;
      checkPe = checkPeFor t;
      cmakeToolchain = cmakeToolchainFor target t tools;
      strip = "${bin}/${t.triple}-strip";
      dlltool = "${bin}/${t.triple}-dlltool";
      objdump = "${bin}/${t.triple}-objdump";
      ld = "${bin}/${t.triple}-ld";
      nativeBuildInputs = [ llvmMingw ];
    };

  # nixpkgs' cross-mingw GCC is configured with the mcfgthread threading model, so its driver adds a bare
  # `-lmcfgthread` that the bare cc wrapper cannot resolve on its own; the lib dir is handed to every
  # driver invocation.
  gcc =
    target: t:
    let
      cc = t.cross.stdenv.cc;
      bintools = "${cc.bintools}/bin/${t.triple}";
      threads = "-L${t.cross.windows.mcfgthreads}/lib";
      tools = {
        cc = "${cc}/bin/${t.triple}-gcc";
        cxx = "${cc}/bin/${t.triple}-g++";
        windres = "${bintools}-windres";
        ar = "${bintools}-ar";
        ranlib = "${bintools}-ranlib";
      };
    in
    {
      inherit target;
      inherit (t)
        triple
        machine
        machineHex
        chpe
        ;
      inherit (tools) windres ar ranlib;
      kind = "gcc";
      root = cc;
      checkPe = checkPeFor t;
      cmakeToolchain = cmakeToolchainFor target t (tools // { linkerFlags = threads; });
      cc = "${tools.cc} ${threads}";
      cxx = "${tools.cxx} ${threads}";
      strip = "${bintools}-strip";
      dlltool = "${bintools}-dlltool";
      objdump = "${bintools}-objdump";
      ld = "${bintools}-ld";
      nativeBuildInputs = [ cc ];
    };
in
lib.mapAttrs (
  target: t:
  if llvmMingw != null then
    llvm target t
  else if !t.llvmOnly then
    gcc target t
  else
    null
) targets
