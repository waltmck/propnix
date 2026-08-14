# Skyrim Special Edition — per-title tuning. Layered over lib/wine-defaults.nix (sealing.mergeTuning), so
# this states only what is SPECIFIC to Skyrim SE. Bethesda Creation Engine (D3D11 → DXVK → Vulkan).
{
  # Graphics driver: x11 (XWayland), NOT the default winewayland — winewayland's fractional-scale resize loop
  # NULL-derefs winevulkan's vkCreateSwapchainKHR (RESEARCH); x11 is the config the working build shipped.
  graphics = {
    value = "x11";
    reason = "winewayland fractional-scale surface resizes drive a DXVK swapchain-recreation loop that NULL-derefs winevulkan; x11 (the config the working build used) avoids it.";
  };

  # PROPNIX_DPI breaks Skyrim here (DIRECTLY verified): it stamps HKCU\…\LogPixels, and on this fractional
  # (160%) display LogPixels=154 makes wine DPI-scale the render to the LOGICAL size — the swapchain comes up
  # 1596x1037 instead of the physical 2560x1664 and the game self-exits ~10 s in. (With PROPNIX_DPI unset on a
  # clean prefix: 2560x1664, runs.) So unset it before launch even if the user exported it globally. NB:
  # PROPNIX_DPI=0 does NOT undo an already-written LogPixels — this stops it being written in the first place.
  # (PROPNIX_FPS is NOT listed: it's safe once the engine's vsync agrees — setup.sh sets iPresentInterval=0
  # when a cap is requested — verified rendering with PROPNIX_FPS=60.)
  brokenVariables = [ "PROPNIX_DPI" ];


  # Save: the Creation Engine writes saves + Skyrim.ini/SkyrimPrefs.ini under
  # Documents\My Games\Skyrim Special Edition GOG — this GOG build uses the " GOG"-suffixed folder (verified
  # via a +file trace: SkyrimSE.exe reads/writes exactly that path), NOT the Steam "Skyrim Special Edition".
  # The earlier (Steam) name silently dropped saves + hid config. Bind the whole folder (saves + .ini
  # config together) out to the app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID).
  mounts."drive_c/users/propnix/Documents/My Games/Skyrim Special Edition GOG" = {
    source = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    createIfNotExist = true;
  };

  # Display + quality seeding is done by the setupScript (setup.sh, wired in default.nix), NOT here — it needs
  # imperative logic (pick + merge a shipped quality preset by PROPNIX_QUALITY, plus assert iSize from the
  # compositor facts). That's the escape hatch for game-specific setup that doesn't belong in the launcher.
}
