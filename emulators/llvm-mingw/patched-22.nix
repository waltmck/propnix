# llvm-mingw 20260616 (clang 22.1.8) with llvm/llvm-project#190933 backported — the ARM64EC variadic
# exit-thunk fix, and the whole reason this exists.
#
# WHY BACKPORT INSTEAD OF PINNING LLVM 23. The fix landed in main, so the only released toolchain carrying
# it is llvm-mingw 20260812 = clang 23.1.0-rc3. Tracking a release CANDIDATE turned out to cost far more
# than the one fix is worth: libc++ 23 dropped a batch of transitive includes, which breaks pinned
# third-party sources one file at a time (DXVK, vkd3d-proton's dxil-spirv, two files in FEX's CRT), and it
# hard-blocks fex-dlls outright — libc++ 23's locale_win32.cpp calls kernel32's GetACP/GetLocaleInfoEx,
# while libarm64ecfex.dll is freestanding because wine's ntdll loads it before kernel32 exists. That is an
# open-ended patch treadmill against a moving target, in exchange for one 2-file codegen fix.
#
# So: take the STABLE 22.1.8 that everything already builds against, and apply the 2-file patch. One
# toolchain, no third-party patches, no skew. The build is a one-time cost that lives in the store.
#
# WHAT IS AND ISN'T REBUILT. The patch touches only llvm/lib/Target/AArch64/{AArch64Arm64ECCallLowering,
# AArch64ISelLowering}.cpp and NO public headers, so in principle only libLLVM needs rebuilding. We build
# clang and lld too, because grafting a libstdc++-built libLLVM under mstorsjo's prebuilt libclang-cpp
# mixes two C++ ABIs — that fails subtly rather than loudly, and subtle is not worth saving an hour on.
# Everything on the WINDOWS side is kept from the prebuilt tarball and is exactly what we want unchanged:
# the mingw-w64 sysroots, libc++ 22, and lib/clang/22/lib/windows compiler-rt (including the ARM64EC
# builtins the reindex fix repairs).
#
# The graft works because `bin/<triple>-w64-mingw32-clang` is a symlink to `clang-target-wrapper.sh`,
# which execs a SIBLING `clang` — so replacing bin/clang redirects every target driver at our build.
{
  lib,
  stdenv,
  fetchzip,
  runCommand,
  cmake,
  ninja,
  python3,
  zlib,
  zstd,
  libxml2,
  ncurses,
  libffi,

  # The prebuilt llvm-mingw whose Windows-side artifacts we keep. MUST be the release built from the same
  # llvm commit as `llvmRev` below, or the grafted clang and the kept libc++/compiler-rt disagree.
  prebuilt,
}:
let
  # The exact commit llvm-mingw 20260616 was built from (`clang --version` on the prebuilt tree). Matching
  # it is what makes the graft safe: same sources, plus the patch.
  llvmRev = "ca7933e47d3a3451d81e72ac174dcb5aa28b59d1";
  llvmVersion = "22.1.8";

  # ./patches/0001-arm64ec-varargs-exit-thunk.patch — upstream e6a12781bcc2 ("[AArch64] Copy x4/x5
  # vararg payload into the x64 stack in Arm64EC exit thunks", merged 2026-05-17), REBASED onto 22.1.8.
  #
  # It has to be rebased, and the reason is worth knowing because the failure mode is silent. Five of the
  # six AArch64ISelLowering hunks apply verbatim; the big one does not:
  #   * Its leading context in main is `});` / `}` / blank — which `patch` happily fuzz-matches ~50 lines
  #     too early in 22.1.8 (just before `SDValue ZTFrameIdx;`), inserting the block in the WRONG PLACE
  #     and reporting success.
  #   * Upstream HOISTS `MachineFrameInfo &MFI` to function scope and deletes the in-loop copy, but 22.1.8
  #     already declares MFI at function scope — so re-adding it is `error: redeclaration of MFI`.
  # The rebased patch anchors that block on `// Adjust the stack pointer for the new arguments` and omits
  # the MFI line. `PtrVT` still needs hoisting (22.1.8 declares it after the insertion point), so that
  # addition and its matching deletion are both kept, exactly as upstream does.
  #
  # Regenerate with scratchpad/gen-backport.py, which performs each edit against a UNIQUE anchor and
  # aborts unless it matches exactly once. Upstream's two codegen tests (arm64ec-exit-thunks.ll,
  # arm64ec-hybrid-patchable.ll) are deliberately not carried: running them needs the whole lit suite
  # built, and the graft below asserts the emitted thunk directly, which is cheaper and more specific.
  varargsExitThunkPatch = ./patches/0001-arm64ec-varargs-exit-thunk.patch;

  compiler = stdenv.mkDerivation {
    pname = "llvm-arm64ec-varargs-backport";
    version = llvmVersion;

    src = fetchzip {
      url = "https://github.com/llvm/llvm-project/archive/${llvmRev}.tar.gz";
      hash = "sha256-SF7wFuh4kXZTytpdgX7vUZItKtRobnVICm+ixze4iG0=";
    };

    patches = [ varargsExitThunkPatch ];

    # --fuzz=0: a rebased backport MUST NOT be allowed to land at an approximate location. With the
    # default fuzz, upstream's version of this patch applies at `offset -189 lines` and silently produces
    # a duplicate declaration instead of the intended hoist; with fuzz 0 it fails loudly. Verified: the
    # rebased patch applies with no offsets at all.
    patchFlags = [
      "-p1"
      "--fuzz=0"
    ];

    nativeBuildInputs = [
      cmake
      ninja
      python3
    ];
    buildInputs = [
      zlib
      zstd
      libxml2
      ncurses
      libffi
    ];

    # llvm-project's CMakeLists lives in llvm/, not the archive root.
    cmakeDir = "../llvm";

    # mstorsjo's build-llvm.sh flags verbatim, minus lldb/clang-tools-extra (we keep the prebuilt lldb —
    # it is ABI-compatible with this libLLVM, being the same commit — and never use clang-tools-extra).
    # LLVM_TOOLCHAIN_TOOLS matches upstream so LLVM_INSTALL_TOOLCHAIN_ONLY installs the same tool set.
    cmakeFlags = [
      "-DCMAKE_BUILD_TYPE=Release"
      "-DLLVM_ENABLE_ASSERTIONS=OFF"
      "-DLLVM_ENABLE_BINDINGS=OFF"
      "-DLLVM_ENABLE_PROJECTS=clang;lld"
      "-DLLVM_TARGETS_TO_BUILD=ARM;AArch64;X86;NVPTX"
      "-DLLVM_LINK_LLVM_DYLIB=ON"
      "-DLLVM_INSTALL_TOOLCHAIN_ONLY=ON"
      "-DLLVM_INCLUDE_BENCHMARKS=OFF"
      "-DLLVM_INCLUDE_EXAMPLES=OFF"
      ("-DLLVM_TOOLCHAIN_TOOLS=" + lib.concatStringsSep ";" [
        "llvm-ar" "llvm-ranlib" "llvm-objdump" "llvm-rc" "llvm-cvtres" "llvm-nm"
        "llvm-strings" "llvm-readobj" "llvm-dlltool" "llvm-pdbutil" "llvm-objcopy"
        "llvm-strip" "llvm-cov" "llvm-profdata" "llvm-addr2line" "llvm-symbolizer"
        "llvm-windres" "llvm-ml" "llvm-readelf" "llvm-size" "llvm-cxxfilt" "llvm-lib"
      ])
    ];

    # Linking libLLVM.so and libclang-cpp.so takes several GB each; on this 8-core aarch64 box two
    # concurrent links OOM. Compile wide, link one at a time.
    ninjaFlags = [ "-l" "8" ];
    LLVM_PARALLEL_LINK_JOBS = 1;

    # Not our binaries to shrink, and stripping buys nothing here — the grafted tree deliberately does not
    # strip (see default.nix: strip corrupts the ARM64EC builtins archives).
    dontStrip = true;

    doCheck = false;

    meta.description = "clang/lld ${llvmVersion} with the ARM64EC variadic exit-thunk fix (llvm#190933) backported";
  };
in
runCommand "llvm-mingw-arm64ec-${prebuilt.version}-patched"
  {
    inherit (prebuilt) version;
    passthru = (prebuilt.passthru or { }) // {
      inherit compiler;
      llvmPatch = varargsExitThunkPatch;
    };
    # Same rule as the unpatched package: never strip, or the ARM64EC builtins archives lose their symbol
    # index and every EC link fails on `#__chkstk_arm64ec`.
    dontStrip = true;
    meta.description =
      "llvm-mingw ${prebuilt.version} (clang ${llvmVersion}) with the ARM64EC variadic exit-thunk fix backported";
  }
  ''
    mkdir -p "$out"
    # --no-preserve=ownership on every copy: `cp -a` implies -p, and the build user cannot chown
    # root-owned store files. Store paths are also read-only, hence the chmod before we overlay.
    cp -a --no-preserve=ownership ${prebuilt}/. "$out/"
    chmod -R u+w "$out"

    # Overlay the patched compiler. `cp -a` MERGES directories, which is what we want:
    #   * bin/  — replaces clang/clang++/lld/llvm-* and leaves the mingw target wrappers, widl, gendef and
    #             clang-target-wrapper.sh in place (our build has no such names).
    #   * lib/  — replaces libLLVM/libclang-cpp, and merges lib/clang/22/include (our builtin headers,
    #             byte-identical sources) WITHOUT disturbing lib/clang/22/lib/windows, which holds the
    #             Windows compiler-rt we must keep.
    cp -a --no-preserve=ownership ${compiler}/bin/. "$out/bin/"
    cp -a --no-preserve=ownership ${compiler}/lib/. "$out/lib/"

    # Fail loudly here rather than at some game's link step months from now.
    have=$("$out/bin/clang" --version | head -1)
    echo "grafted: $have"
    case "$have" in
      *${llvmVersion}*) ;;
      *) echo "FATAL: grafted clang is not ${llvmVersion}: $have" >&2; exit 1 ;;
    esac
    for t in aarch64 arm64ec x86_64 i686; do
      "$out/bin/$t-w64-mingw32-clang" --version >/dev/null \
        || { echo "FATAL: $t target driver broken after graft" >&2; exit 1; }
    done
    # THE ACTUAL FIX. Calling a variadic import from EC code emits `$iexit_thunk$cdecl$i8$varargs`, and
    # that thunk must MEMCPY the payload x4 (pointer) / x5 (length) onto the x64 stack. Unpatched, it does
    # `stp x4, x5, [sp, #0x20]` — passing the DESCRIPTOR as x64 arguments 5 and 6, which is precisely the
    # defect (a `[out]` handle then receives x5; "0x10" was the varargs size). Measured on the unpatched
    # 20260616 compiler, so this probe is a known-good discriminator, not a guess.
    printf 'int printf(const char *, ...);\nvoid f(void) { printf("%%d %%d\\n", 1, 2); }\n' > thunk.c
    "$out/bin/arm64ec-w64-mingw32-clang" -O2 -c -o thunk.obj thunk.c

    # Assert the symbol is PRESENT first. Without this the check is vacuous: plain `objdump -d` does not
    # label the .wowthk$aa symbol, so a grep for it finds nothing and "no thunk" would read as success.
    "$out/bin/llvm-nm" thunk.obj | grep -q 'iexit_thunk\$cdecl\$i8\$varargs' \
      || { echo "FATAL: probe emitted no variadic exit thunk — the assertion below would be vacuous" >&2
           "$out/bin/llvm-nm" thunk.obj >&2; exit 1; }

    "$out/bin/llvm-objdump" -d --disassemble-symbols='$iexit_thunk$cdecl$i8$varargs' thunk.obj > thunk.txt
    # Read the call targets from the RELOCATIONS, not the disassembly. In an unlinked object llvm-objdump
    # renders a branch as `bl 0x54 <.wowthk$aa+0x54>` — the callee name appears only in the reloc table, so
    # grepping the disassembly for "bl .*memcpy" can never match and silently fails a correct compiler.
    "$out/bin/llvm-objdump" -r thunk.obj > relocs.txt
    if grep -q '#memcpy' relocs.txt && ! grep -qE 'stp[[:space:]]+x4, x5' thunk.txt; then
      echo "verified: variadic exit thunk copies its payload via memcpy (llvm#190933 active)"
      grep -E '#memcpy|#__chkstk_arm64ec' relocs.txt | sed 's/^/  reloc: /'
    else
      echo "FATAL: variadic exit thunk does not copy its payload — the patch did not take" >&2
      echo "--- disassembly ---" >&2; cat thunk.txt >&2
      echo "--- relocations ---" >&2; cat relocs.txt >&2
      exit 1
    fi
    rm -f thunk.c thunk.obj thunk.txt relocs.txt
  ''
