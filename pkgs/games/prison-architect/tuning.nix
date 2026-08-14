# Prison Architect — per-title tuning. Layered over lib/wine-defaults.nix (sealing.mergeTuning), so this
# states only what is SPECIFIC to Prison Architect. To change a default for PA alone, add the knob here.
{
  # Save dir: PA (Introversion custom engine) writes saves + config under
  # %LocalAppData%\Introversion\Prison Architect (saves live in the `saves/` subfolder). Bound to the app's
  # host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default …/propnix-saves/prison-architect).
  # Confirmed via Introversion/PCGamingWiki save-location docs.
  mounts."drive_c/users/propnix/AppData/Local/Introversion/Prison Architect" = {
    source = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    createIfNotExist = true;
  };

  # NOTE: no graphics/d3d override. PA is an OpenGL title (builtin OPENGL32.dll), so d3d=dxvk is a no-op
  # for it. The startup crash (below) reproduces IDENTICALLY on graphics=wayland and graphics=x11 — it is
  # NOT a rendering issue, so no graphics knob is set. See the BLOCKER note in the packaging report:
  # Prison Architect64.exe faults in rpcrt4 (write to null+0x10) during the GOG Galaxy SDK's network/RPC
  # init (Galaxy64.dll + pops_api.dll are STATIC imports, so they cannot be disabled via WINEDLLOVERRIDES).
  # A fix needs a shared change (stub/override the Galaxy SDK DLLs into the prefix, or a wine rpcrt4 fix).
}
