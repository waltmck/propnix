# Kerbal Space Program — per-title tuning. Layered over the base wine tuning (lib/backends/wine/
# defaults.nix) by the module merge, so this states only what is SPECIFIC to KSP. A FUNCTION of `payload`
# (default.nix applies it) because KSP's game-dir overlay references the payload's store path directly.
{ payload }:
{
  # KSP writes settings.cfg, PartDatabase, the ModuleManager cache, AND saves THROUGHOUT its own game
  # directory. Override the default read-only `drive_c/game` bind with a PERSISTENT COW overlay: reads come
  # straight from the store payload (fast, no copy), every write persists to app state.
  mounts."drive_c/game" = {
    type = "overlay";
    lower = "${payload}";
    upper = "$PROPNIX_STATE/gamedir";
    createIfNotExist = true;
  };

  # KSP_x64_Data/Managed — the .NET managed assemblies, as a per-launch EPHEMERAL, WRITABLE tmpfs SEEDED
  # from the store payload: a source-less `type = "mount"` (→ ns-private tmpfs) plus `seed` (→ copy the real
  # assemblies into it each launch). This player's Mono fails at startup ("mscorlib.dll could not be loaded")
  # when Managed is served from the game-dir overlay or a read-only bind; only real files in a writable
  # directory load (docs/research/unity-player-facts.md). ~28 MB, RAM-backed, re-seeded from the pinned
  # payload every launch, no persistent state.
  mounts."drive_c/game/KSP_x64_Data/Managed" = {
    seed = "${payload}/KSP_x64_Data/Managed";
  };

  # Saves live in <gamedir>/saves, which also SHIPS the training + scenario saves. Redirect them to the host
  # save dir with a nested persistent overlay — shipped scenarios read from the store lower, the user's own
  # saves persist to $PROPNIX_SAVE_DIR (only deltas on disk, no startup copy). Nested inside (and shadowing
  # the saves/ of) the whole-gamedir overlay above. THE DELIBERATE `saveBinds` EXCEPTION: this save
  # persistence is an overlay UPPER (store lower underneath), not expressible as a bind, so it stays a
  # hand-written mounts row.
  mounts."drive_c/game/saves" = {
    type = "overlay";
    lower = "${payload}/saves";
    upper = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    createIfNotExist = true;
  };

  # Runs on aarch64 (wine+FEX) with the Managed tmpfs above. A main thread dying at the main-menu canvas
  # build (a frozen loading screen) is the signature of an emulator page-size regression, not of this spec.
}
