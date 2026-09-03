# builders/patched-exes.nix — mkPatchedExes: a tiny overlay carrying EXECUTABLE copies of a thin game's
# declared executables, optionally with their ELF interpreter rewritten. Used by every thin backend whose
# launch is a real `execve` of the payload's ELF rather than an emulator reading it:
#
#   * the NATIVE face (backends/box64 with `backend == "native"`) — the host loader, so the launch does not
#     depend on `/lib/ld-linux-aarch64.so.1` or `/lib64/ld-linux-x86-64.so.2` existing, which on NixOS they
#     do not unless `programs.nix-ld` happens to be on;
#   * FEX (backends/fex) — the GUEST x86_64 loader's store path, which must resolve under FEX_ROOTFS.
#
# box64 needs none of this: it IS the loader, ignores PT_INTERP, and reads the ELF without the exec bit.
#
# WHY ONE BUILDER. Both backends previously carried their own copy of this, and they drifted: FEX's took
# the exe from `builtins.head cfg.payloads` — the BASE payload — while ranking the result above every game
# tree. For a store that ships an expansion as a COMPLETE build rather than an additive overlay (Factorio's
# Space Age, on both GOG and Steam, carries its own engine binary), that stacks the base engine on top of
# the expansion's and silently inverts the DLC-first ordering the union exists to express. Selecting the
# source tree is the whole subtlety here, so it lives in exactly one place.
#
# The tree choice is a shell loop at BUILD time, not a Nix conditional: deciding it in Nix would mean
# reading a payload at eval (IFD), which would turn every eval gate into a credentialed multi-GB fetch.
{
  lib,
  runCommandLocal,
  patchelf,
}:
{
  name,
  # Game trees in MOUNT PRIORITY order (DLC first, then payloads) — the same order the launcher stacks
  # them, so each executable is taken from whichever tree will actually supply it at that path.
  trees,
  # Game-dir-relative paths to make executable. Deduplicated; order is irrelevant.
  executables,
  # Store path of the ELF interpreter to stamp in, or null to only fix the exec bit.
  interpreter ? null,
}:
let
  paths = lib.unique (map (t: "${t}") trees);
  exes = lib.unique executables;
in
lib.throwIf (paths == [ ]) "propnix mkPatchedExes (${name}): no game trees given" (
  lib.throwIf (exes == [ ]) "propnix mkPatchedExes (${name}): no executables given" (
    runCommandLocal "propnix-exes-${name}" { nativeBuildInputs = [ patchelf ]; } ''
      ${lib.concatMapStringsSep "\n" (e: ''
        src=
        for tree in ${lib.escapeShellArgs paths}; do
          if [ -f "$tree"/${lib.escapeShellArg e} ]; then src="$tree"; break; fi
        done
        if [ -z "$src" ]; then
          echo "propnix (${name}): declared executable '${e}' is not a regular file in any game tree:" >&2
          printf '  %s\n' ${lib.escapeShellArgs paths} >&2
          exit 1
        fi
        dst="$out/${e}"
        mkdir -p "$(dirname "$dst")"
        cp --no-preserve=mode "$src/${e}" "$dst"
        chmod u+wx "$dst"
        ${lib.optionalString (interpreter != null) ''
          # Only a dynamically-linked ELF has an interpreter to set; anything else (a launcher script, a
          # static binary) just needs the exec bit, which it already got above.
          if patchelf --print-interpreter "$dst" >/dev/null 2>&1; then
            patchelf --set-interpreter ${lib.escapeShellArg interpreter} "$dst"
          fi
        ''}
        chmod a-w "$dst"
      '') exes}
    ''
  )
)
