# Factorio — per-title tuning. Layered over lib/wine-defaults.nix (sealing.mergeTuning), so this states only
# what is SPECIFIC to Factorio. Renderer/tuning verified below on the global defaults (d3d=dxvk, wayland).
{
  # Save: Factorio's user-data dir (saves + mods + config + player-data + log) is %APPDATA%\Factorio on
  # Windows — CONFIRMED by config-path.cfg (`use-system-read-write-data-directories=true`) + the goggame
  # savePath `{userappdata}/Factorio`, and verified: the running game wrote config/config.ini +
  # factorio-current.log + temp/ here. Bound out of the rebuildable prefix to the app's host save dir
  # ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default $XDG_DATA_HOME/propnix-saves/factorio).
  mounts."drive_c/users/propnix/AppData/Roaming/Factorio" = {
    source = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    createIfNotExist = true;
  };

  # Auto-update default is handled by the setupScript (setup.sh, wired in default.nix), NOT here. Factorio is
  # cross-platform and stores the update toggle in config.ini's `[other] check-updates` key (VERIFIED against
  # live state — it is NOT in the Windows registry, so a `userReg` entry has no effect). The setupScript sets
  # `check-updates=false` there (the updater is moot anyway: the payload is a read-only Nix store path it can
  # never update, and leaving it on pops an "automatic updates / log in" dialog at launch). It SEEDS a valid
  # minimal config.ini with the key already off on a fresh save dir (so the very first launch is covered) and
  # edits the key in place otherwise. See setup.sh for the exact key/section/path + the timing rationale.
}
