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

  # KSP_x64_Data/Managed — the .NET managed assemblies. Presented as a per-launch EPHEMERAL, WRITABLE tmpfs
  # SEEDED from the store payload: a source-less `type = "mount"` (→ ns-private tmpfs) plus `seed` (→ copy the
  # real assemblies into it each launch). WHY: Mono's mono_image_open MAP_SHARED-maps each assembly, which the
  # kernel does NOT handle for an overlay LOWER-layer file (overlayfs "Non-standard behavior" #2), and Mono
  # also needs the containing directory WRITABLE — so serving Managed via the data-only `drive_c/game` overlay
  # (or a ro-bind, or a plain overlay) fails "mscorlib.dll could not be loaded"; only real assemblies in a
  # writable dir load (verified). ~28 MB, RAM-backed, always current (re-seeded from the pinned payload), no
  # persistent state. (propnix-mount implements source-less-tmpfs + seed; see lib/builders/wine.nix / mount docs.)
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

  # BROKEN on aarch64 (see default.nix `broken.systems`): with the writable Managed tmpfs above, KSP passes
  # mscorlib and RENDERS the loading screen, but ~90% of launches the main thread dies at the main-menu canvas
  # build via a FEX-2607 CODEGEN bug — a wild WRITE to a fixed address from FEX-translated guest code →
  # recursive access-violation → main-thread zombie (frozen last frame reads as a "stuck" loading screen).
  # Intermittent + pervasive (the ~1/10 that clears the menu crashes again in asset loading). NOT fixable at
  # the propnix/wine/FEX-config layer — every lever was exhausted; needs an upstream FEX fix. Native x86_64
  # wine (no FEX) is unaffected. See the ksp-fex-blockers memory.
}
