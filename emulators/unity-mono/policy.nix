# Defaults for a newly locked stream. Compilation and checkPhase must still pass. Maintained pins can
# override these choices when a stream needs its own port or an additional compatibility patch.
stream: {
  branch = "unity-${stream}-mbe";
  patchFamily = if builtins.compareVersions stream "6000.0" >= 0 then "6000" else stream;
  extraPatchFamilies = [ ];
  targets =
    (if builtins.compareVersions stream "2023.1" >= 0 then [ "aarch64-windows" ] else [ ])
    ++ [ "aarch64ec-windows" ];
}
