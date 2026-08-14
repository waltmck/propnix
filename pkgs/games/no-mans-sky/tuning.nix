# No Man's Sky — per-title tuning. Layered over lib/wine-defaults.nix (sealing.mergeTuning), so this
# states only what is SPECIFIC to No Man's Sky. Hello Games' custom engine; Vulkan-first (renders through
# winevulkan → host Vulkan directly), so the global default (d3d=dxvk, graphics=wayland) is left in place —
# only `save` is game-specific.
{
  # Save: NMS writes its local save + settings under AppData/Roaming/HelloGames/NMS (the GOG local-save
  # location; confirmed from the payload's goggame-*.script savePath). Bound to the app's host save dir
  # ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default $XDG_DATA_HOME/propnix-saves/no-mans-sky).
  mounts."drive_c/users/propnix/AppData/Roaming/HelloGames/NMS" = {
    source = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    createIfNotExist = true;
  };
}
