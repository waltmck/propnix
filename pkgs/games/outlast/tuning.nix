# Outlast — per-title tuning. Layered over lib/wine-defaults.nix (sealing.mergeTuning), so this states
# only what is SPECIFIC to Outlast. Unreal Engine 3 (D3D9 SM3 path → DXVK).
#
# ── msvcp100.dll DLL-init crash — FIXED (the `extraSystem32` tuning field) ───────────────────────────────
# On aarch64 the game aborted at startup: `err:module:loader_init "MSVCP100.dll" failed to initialize`
# (c0000005 in the DLL's DllMain). Root cause: OLGame.exe (x86_64) bundles its own msvcr100.dll beside the
# exe but NOT msvcp100.dll, so wine supplied msvcp100 from system32 — where prefixLower maps wine's ARM64EC
# builtin, whose DllMain access-violates under FEX. Only the GENUINE MS x64 runtime loads (verified: neither
# `n`/`b` DLL overrides nor wine's builtin work). default.nix extracts the real VC++ 2010 SP1 x64
# msvcp100.dll from the game's OWN bundled redist (UE3Redist.exe → vcredist_x64_vs2010sp1.exe → vc_red.cab →
# F_CENTRAL_msvcp100_x64) and stages it over system32 via the `extraSystem32` tuning field. With it, OLGame.exe
# clears DLL init, initializes DXVK D3D9, and opens its window (`-nosteam` NOT needed).
{
  # Save: CONFIRMED from the GOG install script (goggame-1207660064.script → savePath
  # "{userdocs}/My Games/Outlast"). UE3 (shipping) redirects user config + saves + logs to
  # Documents\My Games\Outlast. Binding the whole folder captures saves + settings together, out to the
  # app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default …/propnix-saves/outlast).
  mounts."drive_c/users/propnix/Documents/My Games/Outlast" = {
    source = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    createIfNotExist = true;
  };
}
