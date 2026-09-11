# R.E.P.O. (semiwork) — the Steam WINDOWS build via wine: on aarch64 through FEX + ARM64EC DXVK, on
# x86_64 natively. Unity **2022.3.67f2** (version string in UnityPlayer.dll), Mono scripting backend
# (`MonoBleedingEdge/` + a 143-assembly `REPO_Data/Managed/`, not IL2CPP), Addressables content in
# `REPO_Data/StreamingAssets/aa/StandaloneWindows64`.
#
# Steam-only, Windows-only, ONE depot: app 3241660 ships exactly `3241661` on the public branch, with no
# macOS or Linux depot and no DLC depot at all (Steam appinfo). So `platformPreference` derives itself,
# `dlc` is absent rather than empty-by-omission, and any other selection is a legible mkApp error.
#
#   nix run .#repo --extra-sandbox-paths /propnix=/var/lib/propnix
#
# ── WHICH EXECUTABLE ───────────────────────────────────────────────────────────────────────────────────
# `REPO.exe` — Steam's appinfo lists exactly one launch entry (`{"0": {"executable": "REPO.exe"}}`), and
# it is the stock Unity player stub: its ONLY imports are KERNEL32.dll and UnityPlayer.dll. The other two
# PEs in the tree are not launch targets — `UnityCrashHandler64.exe` is Unity's crash reporter (spawned
# by the player) and `UnityPlayer.dll` is the engine itself. Unity resolves `REPO_Data/` from the
# executable's directory, so `workingDir` stays null (the game dir).
#
# VERIFIED RENDERING on x86_64-linux — the main menu (title + PRIVATE/PUBLIC GAME, JOIN FRIEND,
# SINGLEPLAYER, TUTORIAL, CUSTOMIZE, SETTINGS, QUIT, over the animated truck scene), screenshotted twice
# from two independent launches on an otherwise busy machine (load ~7.6, five other wineservers alive).
# The game's own `Player.log` corroborates the pixels:
#
#     Initialize engine version: 2022.3.67f2 (6bedba8691df)
#     GfxDevice: creating device client; threaded=1; jobified=1
#     Direct3D: Version: Direct3D 11.0 [level 11.1]
#               Renderer: AMD Radeon RX 7900 XTX (RADV NAVI31) (ID=0x744c)
#     Begin MonoManager ReloadAssembly / - Loaded All Assemblies, in 0.220 seconds
#     VERSION: v0.4.4.3 / Steam - App ID: 3241660 / Steam - User ID: 765611…
#
# NO PER-TITLE ROW WAS NEEDED to get there. What had been hanging it was the PLATFORM-WIDE read-only
# `dosdevices` bug (mountmgr's `add_drive()` spins forever on EROFS holding `device_section`, so every
# other thread blocks in any mountmgr IOCTL) — see lib/backends/wine/defaults.nix. Unity's first act after
# Mono init is a volume-information IOCTL, which is why the pre-fix log always died exactly one line after
# `Mono config path = …`; that truncated log is a SYMPTOM OF THE HOST, not of this game.
#
# HARNESS NOTE for whoever re-verifies: headless **weston** is not a valid rig — it reproduces that same
# truncated-log signature on titles that work (iron-lung fails there and passes everywhere else). Headless
# **sway** (`WLR_BACKENDS=headless`) does work, and `nix run .#iron-lung` is the control to run first.
#
# Blocks below that are still STATIC ANALYSIS say so; each states the artefact its claim came from.
{
  lib,
  mkApp,
  presets,
}:
mkApp {
  pname = "repo";
  maintainers = [ "waltmck" ];
  appid = "repo";
  name = "R.E.P.O.";

  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;

  exe = "REPO.exe";

  # Full-colour icon from REPO.exe's own PE resources — VERIFIED extractable: `wrestool -l` lists a
  # group-icon with 256/192/128/96/64/48/32/24/16 px members at 32-bit depth, so the hicolor theme gets
  # every size and the splash gets a true 256px source. This is the default; stated because it is a fact
  # about the payload rather than a hope.
  icon.auto = true;

  # `online` is LEFT AT ITS DEFAULT (true), deliberately, and this is the one title in the tree where that
  # is not a shrug: R.E.P.O. is a co-op extraction game whose whole loop is multiplayer. The payload says
  # so three times over —
  #   * `REPO_Data/Managed/` carries the full Photon stack (Photon3Unity3D, PhotonRealtime,
  #     PhotonUnityNetworking(+.Utilities), PhotonChat) — a HOSTED cloud relay, so no shim can stand in
  #     for it,
  #   * plus Photon Voice (PhotonVoice{,.API,.PUN}) backed by the native `REPO_Data/Plugins/x86_64/`
  #     trio `webrtc-audio.dll` / `opus_egpv.dll` / `AudioIn.dll` — the proximity voice chat,
  #   * plus `Facepunch.Steamworks.Win64.dll` over the shipped `steam_api64.dll` for Steam lobbies, and
  #     `Discord.Sdk.dll` / `discord_partner_sdk.dll` for rich presence.
  # Unsharing a netns here would cut the game's reason to exist, so we do not. `.apply { online = false; }`
  # is the one-line switch for a strictly-singleplayer, kernel-enforced-offline run.
  #
  # WHAT THAT DOES *NOT* BUY YOU: the offline entitlement shim below reimplements the Steamworks surface
  # locally, so Steam LOBBIES (join-a-friend, the Steam friends list) do not reach Valve regardless of the
  # network namespace. Whether R.E.P.O.'s host/join flow degrades to Photon-only or refuses outright is
  # STILL UNVERIFIED — the verified run reached the menu, which OFFERS `PRIVATE GAME` / `PUBLIC GAME` /
  # `JOIN FRIEND` (none of them greyed out), but nobody has pressed them. That is the first thing to try
  # when someone actually plays this.

  # De-store-integration. The Steam library is a Unity native plugin at
  # `REPO_Data/Plugins/x86_64/steam_api64.dll` (the only steam_api copy in the tree), consumed by the
  # managed `Facepunch.Steamworks.Win64.dll` wrapper. steam.emu mirrors gbe_fork's PE shim at exactly that
  # path inside the settings tree and unions it ABOVE the payload, replacing the shipped dll in place; on
  # wine that union-replacement is the ONLY mechanism (PE has no preload), which is why mk-app.nix
  # requires this declaration rather than allowing a silently-inert shim.
  #
  # SDK COVERAGE CHECKED, because this is the failure mode that black-screened hollow-knight under the
  # predecessor emulator (the lib loads, init throws EntryPointNotFoundException — worse than absence).
  # Export-table diff of the shipped dll against the pinned gbe_fork x64 shim: 1086 exports shipped, 1257
  # in the shim, and the set difference is EMPTY — the shim is a strict superset. In particular the
  # modern-SDK init path is present: the shipped library no longer exports `SteamAPI_Init` at all (it is
  # inline since SDK 1.59) and routes through `SteamInternal_SteamAPI_Init` + `SteamInternal_ContextInit`,
  # both of which the shim exports. Every interface version the shipped dll advertises — SteamClient021,
  # SteamUser023, SteamUtils010, SteamFriends017, SteamInput006, SteamMatchMaking009,
  # SteamNetworkingSockets012, SteamNetworkingUtils004, STEAMAPPS_INTERFACE_VERSION008 — occurs in the
  # shim's string table too.
  #
  # CONFIRMED AT RUNTIME, so the symbol diff no longer stands alone: the boot log prints
  # `Steam - App ID: 3241660` / `Steam - User ID: 765611…` — i.e. Facepunch.Steamworks initialised over
  # the shim and read back an id — and `AppData/Roaming/GSE Saves/settings/configs.user.ini` appears in
  # the users overlay, which gbe_fork only writes once the game has actually called into it. No
  # EntryPointNotFoundException, no black screen: the game goes straight to its menu.
  steam.emu.libPaths = [ "REPO_Data/Plugins/x86_64/steam_api64.dll" ];

  # Save: Unity's Application.persistentDataPath =
  # %USERPROFILE%\AppData\LocalLow\<companyName>\<productName>, and this build's pair is
  # `semiwork` / `REPO` — read straight out of `REPO_Data/app.info` (the two lines Unity generates from
  # PlayerSettings) and corroborated by the same two literals in `REPO_Data/globalgamemanagers`. Neither
  # name needs path-sanitising, so the directory is verbatim. That is where the engine puts the save
  # files and `Player.log`. `dst` is HOME-relative; the wine builder joins it onto drive_c/users/<user>/.
  #
  # CASING SETTLED BY RUNNING — third-party guides for this title write the path as
  # `…\LocalLow\semiwork\Repo` (lowercase-o); the payload's own metadata says `REPO`, and `REPO` is what
  # the engine actually used. A launch through this bind left `MetaSave.es3`, `SettingsData.es3`,
  # `DefaultKeyBindings.es3`, `CurrentKeyBindings.es3`, `Cache/` and `Player.log` in
  # `$PROPNIX_SAVE_DIR/repo` — i.e. the bind caught every write, with no stray `…\semiwork\Repo` sibling
  # anywhere under the wine profile. (`[MetaSave] MetaSave.es3 not found - creating new` in Player.log is
  # the first-launch line; the file is there afterwards.)
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/LocalLow/semiwork/REPO";
    }
  ];

  # The Unity fullscreen PlayerPref (winewayland fractional-scale cursor confinement fix; see the preset).
  # APPLICABLE HERE — checked, not assumed: `Screenmanager Fullscreen mode` is a live pref name in this
  # build's UnityPlayer.dll (alongside `Screenmanager Resolution {Width,Height}` and
  # `Screenmanager Resolution Use Native`), so the preset's `…_h3630240806` value name is the one the
  # engine reads. The key is `Software\<companyName>\<productName>` = `Software\semiwork\REPO`, from the
  # same app.info pair as the save bind. A first-person game with mouse-look is exactly where a confined
  # cursor is unplayable, which is why it is set by default rather than left to the user — but it has NOT
  # been observed on this title; `.apply { wine.userReg = { }; }`-style removal is the revert if the
  # forced borderless-fullscreen is unwanted.
  #
  # `presets.unity.framePacing` is deliberately NOT merged in alongside: it writes `VidVSync_h382800143` /
  # `VidTFR_h3151569246`, and neither name occurs anywhere in UnityPlayer.dll, REPO.exe,
  # Assembly-CSharp.dll or globalgamemanagers — Unity 2022 dropped the legacy resolution-dialog prefs those
  # hashes belong to, so the rows would be inert registry noise.
  wine = presets.unity.fullscreen "Software\\semiwork\\REPO";

  # NOT NEEDED — recorded so the next reader does not re-derive it from iron-lung/KSP. Those two Unity-Mono
  # wine titles each serve `<Data>/Managed` from a per-launch seeded tmpfs because Mono could not load their
  # assemblies out of the game-dir mount. R.E.P.O. is also Unity Mono (MonoBleedingEdge/EmbedRuntime/
  # mono-2.0-bdwgc.dll + the 143-assembly Managed tree) behind a MULTI-LOWER read-only overlay (steam.emu's
  # entitlement tree above depot 3241661), so the same row looks obviously required here. It is not, and
  # the proof is now the strongest kind: with NO such row this game loads all 143 assemblies off the
  # two-lower read-only overlay and reaches its menu — `Begin MonoManager ReloadAssembly` /
  # `- Loaded All Assemblies, in 0.220 seconds` in Player.log, then Odin Serializer, then the scene. (The
  # earlier A/B that first argued this — the depot bound plain vs the real two-lower overlay, byte-identical
  # logs either way — was right about the overlay being irrelevant, but it was comparing two runs that were
  # BOTH hanging on the read-only-`dosdevices` platform bug; the render is what actually settles it.)
  # Seeding Managed would cost 21 MB of RAM plus a 143-file copy every launch and buy nothing, so it stays
  # out. iron-lung's finding is real for iron-lung (Unity 2021.1); it does not generalise to Unity 2022.3.
}
