# mkWineReg — build a DECLARATIVE registry hive file (system.reg / userdef.reg / user.reg) as a per-game
# store path: start from the wine-generated base in `prefixLower` and apply a set of overrides on top via
# `wine reg add` (native aarch64, headless — the same mechanism wine-prefix-lower already uses). The result
# is bind-mounted read-only for the HKLM/HKU\.Default hives (system.reg/userdef.reg, from systemReg/userdefReg
# overrides). For user.reg (HKCU) makeAppWine calls this with NO overrides, using the verbatim base as the
# one-time SEED for the persistent root mount (all HKCU overrides are applied at runtime, not baked).
#
# With NO overrides it returns the base hive verbatim (`${prefixLower}/<regName>`) — no wine run, no new store
# path — so the common case is free and games that share a config share one build (content-addressed).
{
  lib,
  runCommand,
  wine,
  coreutils,
  gnused,
}:
{
  prefixLower,
  regName, # "system.reg" | "userdef.reg" | "user.reg"
  # Overrides for THIS hive: a list of { key; name; value; type ? "REG_SZ"; }, where `key` is the FULL
  # registry key including the hive (e.g. "HKCU\\Software\\Wine\\Drivers", "HKLM\\Software\\...").
  overrides ? [ ],
  name ? "wine-reg",
}:
if overrides == [ ] then
  "${prefixLower}/${regName}"
else
  runCommand "${name}-${regName}"
    {
      nativeBuildInputs = [
        wine
        coreutils
        gnused
      ];
    }
    ''
      export HOME="$TMPDIR/home" && mkdir -p "$HOME"
      export USER=propnix LOGNAME=propnix
      export WINEPREFIX="$TMPDIR/pfx"
      export WINEDEBUG=-all
      export WINEDLLOVERRIDES="mscoree=b;mshtml=;winemenubuilder.exe=d"
      mkdir -p "$WINEPREFIX"
      # Seed a MINIMAL prefix from the fully-provisioned lower: symlink the (read-only) system tree so wine
      # can run reg.exe, copy the base hives in WRITABLE, and disable wineboot (already provisioned) so no
      # ~22 s reprovision happens — just the reg edits.
      ln -s ${prefixLower}/drive_c "$WINEPREFIX/drive_c"
      ln -s ${prefixLower}/dosdevices "$WINEPREFIX/dosdevices"
      for r in system.reg userdef.reg user.reg; do
        cp "${prefixLower}/$r" "$WINEPREFIX/$r" && chmod u+w "$WINEPREFIX/$r"
      done
      echo disable > "$WINEPREFIX/.update-timestamp"

      # Apply the overrides.
      ${lib.concatMapStringsSep "\n" (
        o:
        "wine reg add ${lib.escapeShellArg o.key} /v ${lib.escapeShellArg o.name} "
        + "/t ${lib.escapeShellArg (o.type or "REG_SZ")} /d ${lib.escapeShellArg o.value} /f"
      ) overrides}

      # Flush the registry to disk, bounded so a lingering service can't hang the build.
      timeout 60 wineserver -w || wineserver -k || true

      # Extract ONLY the target hive, normalizing the wall-clock stamps wine writes (reproducibility — the
      # LastWrite times are metadata no game reads).
      sed -E '
        s/^(\[.*\]) [0-9]+$/\1 0/
        /^#time=/ s/=.*/=0/
      ' "$WINEPREFIX/${regName}" > "$out"
    ''
