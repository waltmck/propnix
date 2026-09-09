# Rust (Facepunch Studios, Steam app 252490) — a Unity/IL2CPP survival sandbox, Windows build under wine
# (aarch64 → FEX + ARM64EC DXVK, x86_64 → native wine). Two depots, both pinned:
#
#   252495  the Windows x64 client   859 MB   RustClient.exe, Rust.exe, GameAssembly.dll, EasyAntiCheat/
#   252494  OS-agnostic content       39 GB   Bundles/ (items, textures, maps, shared)
#
# (sizes measured on the realised store paths, not Steam's headline install figure)
#
# ── STATUS — REACHES THE MAIN MENU (2026-09-03, x86_64 host, headless sway + real RX 7900 XTX) ──────────
# Verified on the SHIPPED config, not inferred: `[Bootstrap] Done` / `[Bootstrap] completed in 16.17s` in
# its own `Player.log` (saveBinds lands it at `$PROPNIX_SAVE_DIR/rust/Player.log`), and a compositor
# screenshot of the live frontend — the store hero panel ("BREACH AND CLEAR"), the top nav bar, the bottom
# bar, and the first-run "TUTORIAL / Crashed Pilot" dialog on top of them. Engine init, D3D11-over-DXVK on
# the RX 7900 XTX, all twelve asset bundles, the menu prefabs, the menu UI and the menu scene all complete.
#
# GETTING THERE TOOK TWO FIXES AND LEAVES ONE UNSOLVED BUG. The first two are the SAME ROOT CAUSE —
# the game writes inside its own install dir and that dir is read-only — while the third is unrelated and
# only LOOKS like the first (both leave you staring at the loading screen). Do not conflate them:
#
#   1. FIXED — the loading overlay never cleared even after `[Bootstrap] Done`, because the menu's hero
#      video downloader writes to `C:\game\temp` and the game dir is read-only. See the `wine.mounts` block
#      further down; that row is what turned "Bootstrap finished, screen frozen" into an actual menu.
#   2. FIXED — the server browser threw `SqliteException: Could not open database file:
#      client.serverlist.1.db (error 14)` out of a static ctor, because Rust opens that DB by a RELATIVE
#      path against the launch cwd (C:\game). The `drive_c/game` row in the same block makes the game dir a
#      persistent CoW overlay; that also closes the `cfg/client.cfg` + `cfg/keys.cfg` persistence gap this
#      file used to carry as a KNOWN GAP.
#   3. NOT FIXED — an INTERMITTENT freeze EARLIER, during `[Bootstrap] Initializing Steam`, described next.
#      It is a lost wakeup inside wine, below anything this package controls.
#
# ── THE UNSOLVED ONE: AN INTERMITTENT FREEZE AT `Initializing Steam` ───────────────────────────────────
# What you see is the loading bar parked at `LOADING MENU PREFABS 99.0%` (the label lags one step — the
# bootstrap coroutine blocks before it can repaint), and `Player.log` ending at:
#
#     [Bootstrap] Loading Menu Prefabs done in 5.44s
#     [Bootstrap] Initializing Steam                  ← last line; no matching "done in"
#
# IT IS INTERMITTENT. On this host, default config, under the harness at the bottom of this block: THREE OF
# THE FIRST FOUR attempts froze, and the next EIGHT in a row reached the menu. The freezes all fell in a
# window when several other wine games were being launched concurrently on the box; the passes came when
# the runs were serialised — but load average was ~19-21/48 cores throughout, so "load" is a correlation
# nobody has turned into a cause. Treat this as a RACE, not a configuration error. The practical
# consequences: a single launch proves NOTHING here (five earlier attempts to explain this title from one
# log all reached wrong conclusions), and any change claimed as a fix has to be judged over many runs.
#
# WHERE IT FREEZES, to the frame. winedbg attached to the frozen process (`nsenter -t <pid> -m -U
# --preserve-credentials -- wine winedbg`, then `attach <win-pid>` + `bt all`) gives the SAME main-thread
# stack on two independent hangs:
#
#     ntdll!NtQueryVolumeInformationFile   ← never returns
#     kernelbase!GetFileInformationByHandle+0xd5
#     steam_api64 +0x778c97 / +0x778984    ← the shim's static C++ runtime: CreateFileW, then the query
#     steam_api64 +0x1c937                 ← common_helpers::file_exist (std::filesystem)
#     steam_api64 +0x50111 … +0xb36ac      ← Steam_Client() → create_localstorage_settings()
#     steam_api64!SteamAPI_InitFlat+0x17
#     gameassembly …  unityplayer …  rustclient        (Bootstrap+<Start>d__26.MoveNext)
#
# So the stall is INSIDE the gbe_fork shim's `SteamAPI_InitFlat`, in an ordinary `std::filesystem` "does
# this file exist" on its own global settings file — and specifically in what WINE does underneath it.
# `kernelbase!GetFileInformationByHandle` calls `NtQueryVolumeInformationFile(FileFsVolumeInformation)` to
# fill `dwVolumeSerialNumber` (verified by disassembling wine's own kernelbase.dll: the return address
# +0xd5 sits immediately after `call *__imp_NtQueryVolumeInformationFile`, with info class 1 in the frame).
# A full syscall trace of the main thread shows what that becomes: wine opens `\Device\MountPointManager`,
# issues `IOCTL_MOUNTMGR_QUERY_UNIX_DRIVE`, gets STATUS_PENDING, and blocks in `server_select` — the
# 16-byte `read(wait_fd, …, 16)` of a `struct wake_up_reply` — waiting for the completion APC. On a run
# that SUCCEEDS the trace shows that APC arriving with STATUS_NO_SUCH_DEVICE (0xC000000E, the expected
# answer for a path inside the prefix) and init carrying straight on. On a run that freezes it never
# arrives: the thread accrues ZERO cpu-time (utime/stime unchanged over 10 s of sampling) and sits there
# indefinitely. A LOST WAKEUP on an async device IOCTL, one layer below anything this package controls.
#
# WHAT THAT RULES OUT, each measured rather than assumed:
#
#   * NOT gbe_fork, and NOT its settings. The same wine build + the same shim DLL + an equivalent
#     `steam_settings/` in a PLAIN prefix outside propnix (`wine rundll32 steam_api64.dll,SteamAPI_Init`)
#     returns every time and writes its `GSE Saves/settings/configs.user.ini`. hollow-knight-silksong —
#     the same shim, on wine, under propnix — reaches its menu in the same harness.
#   * NOT `steam.emu.offline`, which this file used to set to `false` on the theory that the client was
#     refusing to finish a bootstrap it had been told was logged out. That setting is gone from here:
#     `Settings::is_offline()` has exactly three call sites in the pinned gbe_fork, all in
#     dll/steam_user.cpp, and all reachable only AFTER `SteamAPI_Init` RETURNS — the stack above proves the
#     freeze is inside that call, so no value of the key can move it. EVERY freeze recorded here happened
#     with `offline=0` already in effect. Careful with the family resemblance: pkgs/games/victoria-3 blocks
#     on the same wine PRIMITIVE (`server_select` collecting a 16-byte `wake_up_reply` that never arrives)
#     and IS cured by this key — but its wait is raised from a `RtlWakeAddressAll` spin inside the shim,
#     while this one is raised from `NtQueryVolumeInformationFile` under `GetFileInformationByHandle`. Same
#     syscall signature, different caller; only a PE-level backtrace tells them apart, which is why the one
#     above is quoted in full. The OPTION stays for victoria-3, whose need for it is measured.
#   * NOT the multi-depot game dir, and NOT the read-only game dir (fix 2 above; still true after it, and
#     the freeze predates and postdates that change). Making
#     `drive_c/users` a separate overlay mount in a bare prefix — the thing propnix does that a plain
#     prefix does not — reproduces nothing; `SteamAPI_Init` still returns.
#   * NOT a missing Steamworks interface — the specific failure modules/steam-emu.nix warns about. All 19
#     interface-version strings in the shipped `RustClient_Data/Plugins/x86_64/steam_api64.dll`
#     (`SteamClient021`, `SteamUser023`, `SteamUtils010`, `STEAMUGC_INTERFACE_VERSION020`,
#     `SteamNetworkingSockets012`, `STEAMREMOTESTORAGE_INTERFACE_VERSION016`, …) are implemented at this
#     gbe_fork pin. And an unimplemented one would THROW, not block.
#   * NOT the network, and NOT the sandbox. The three `Curl error 6: Could not resolve host` lines name
#     `config.uca.cloud.unity3d.com` and `cdp.cloud.unity3d.com` — neither resolves ON THE HOST either,
#     while `api.epicgames.dev` and `github.com` do. Dead Unity telemetry endpoints, not a sandbox fault.
#   * NOT EAC — see the next block; `RustClient.exe` is Facepunch's own EAC-free entry point.
#
# DO NOT "FIX" IT BY DISABLING THE SHIM. `.apply { steam.emu.enable = false; }` does make the freeze
# impossible, and it is still wrong: the genuine Valve `steam_api64.dll` then fails init with
# `Could not determine Steam client install directory`, Facepunch.Steamworks turns that into
# `System.Exception: SteamApi_Init failed with FailedGeneric`, and the exception escapes
# `Bootstrap+<Start>d__26.MoveNext` — so the coroutine dies and the loading screen freezes at the SAME
# 99% anyway, just with a stack trace above it. Rust has no working no-Steam path; the emu is required.
#
# TWO THINGS ARE KNOWN TO MAKE THE RACE COME OUT RIGHT, and both are timing perturbations rather than
# fixes, which is the strongest evidence that this is a lost wakeup: attaching `strace` to the main thread,
# and `.apply { online = false; }` (which adds nothing but CLONE_NEWNET — propnix-mount enter_and_mount).
# Neither is shippable: the first is a debugger and the second cuts off the only thing this game does.
# Until then: if the loading bar parks at 99%, kill it and launch again.
#
# THE NEXT LEVER TO PULL, untested here only because the freeze stopped reproducing before it could be:
# NTSYNC. `nixos/propnix.nix` loads the `ntsync` module deliberately, the hung process holds `/dev/ntsync`
# and dozens of `anon_inode:ntsync` handles, and "a wait that is never woken although the waited-for event
# happened" is precisely the failure class kernel-backed sync objects introduce. Reproduce the freeze
# first (several concurrent wine launches on the box is what did it here), then re-run with `/dev/ntsync`
# masked — a `unshare -Umr` wrapper that bind-mounts `/dev/null` over it before invoking the launcher is
# enough, since the launcher's own userns inherits the outer mount table — and see whether it survives.
# A clean result either way is what a wine bug report needs.
#
#   nix run .#rust --extra-sandbox-paths /propnix=/var/lib/propnix
#
# REPRODUCING IT HEADLESSLY — and a warning that cost a whole session. WESTON DOES NOT WORK for these
# titles: under `weston --backend=headless` (with EITHER renderer) the known-good control `iron-lung` dies
# with a 100-byte `Player.log`, because wine's explorer/display-driver bring-up fails there — i.e. weston
# MANUFACTURES a truncated-log symptom indistinguishable from the bug. Use a wlroots compositor, and run a
# known-good control FIRST every time:
#
#   R=/tmp/pnx-rust; mkdir -p $R; chmod 700 $R      # SHORT path: sun_path is 108 bytes
#   XDG_RUNTIME_DIR=$R WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 nix run nixpkgs#sway -- -c /dev/null &
#   XDG_RUNTIME_DIR=$R WAYLAND_DISPLAY=wayland-1 PROPNIX_DEBUG=1 nix run .#iron-lung   # control: must render
#   XDG_RUNTIME_DIR=$R WAYLAND_DISPLAY=wayland-1 PROPNIX_DEBUG=1 nix run .#rust
#   XDG_RUNTIME_DIR=$R WAYLAND_DISPLAY=wayland-1 nix run nixpkgs#grim -- shot.png      # the evidence
#
# To see wine's and the game's own output while reproducing (the seal pins `WINEDEBUG=-all` and scrubs
# inherited `WINE*`, so setting WINEDEBUG directly does nothing — propnix-launcher/src/settings.rs):
#
#   PROPNIX_DEBUG=1 nix run .#rust --extra-sandbox-paths /propnix=/var/lib/propnix
#   PROPNIX_WINEDEBUG=+loaddll,+seh nix run .#rust --extra-sandbox-paths /propnix=/var/lib/propnix
#
# `-logfile -` is a TRAP here: Unity's stdout goes through a pipe and is block-buffered, so the tail you
# see lags the process by kilobytes. Read `$PROPNIX_SAVE_DIR/rust/Player.log` instead — Unity flushes it.
#
# ── EAC, AND WHY EAC-FREE SERVERS ARE THE TARGET ───────────────────────────────────────────────────────
# Rust ships Easy Anti-Cheat (EOS flavour), and `Rust.exe` is not the game: `strings` shows it is EAC's
# bootstrapper — `AntiCheatLauncher@launcher@easyanticheat`, `EAC_ProtectedGameLaunchResult`, "Could not
# reach the Easy Anti-Cheat CDN!", and the module CDN template
# `https://modules-cdn.eac-prod.on.epicgames.com/modules/{{productid}}/{{deploymentid}}/{{system}}`.
# `EasyAntiCheat/Settings.json` names the game it wraps: `"executable": "RustClient.exe"`. The depot's own
# Steam install script (`win_installscript.vdf`) runs
# `EasyAntiCheat/EasyAntiCheat_EOS_Setup.exe install 429c2212ad284866aee071454c2125b5`, whose job on
# Windows is to register EAC's KERNEL-MODE service — propnix never runs a Steam install script, and wine
# has no NT kernel to install a driver into.
#
# NONE OF WHICH MATTERS HERE, because launching `RustClient.exe` directly IS the vendor-documented way to
# run Rust without EAC. Facepunch's own support article, "Launching Rust with EAC disabled
# (RustClient.exe)", says it in those words:
#
#     "RustClient.exe is the Rust game application without the EAC wrapper. Launching this will be the same
#      as Rust but without EAC, this means you will only be able to connect to unsecure servers."
#     — support.facepunchstudios.com/hc/en-us/articles/15041503601437 (retrieved 2026-09-03)
#
# So there is NO client-side flag to look for. The mechanism is which executable you start, and `exe`
# below already starts the right one. `exeArgs` stays empty deliberately: no launch argument, environment
# variable or config entry for this was found in the payload or in Facepunch's documentation, and guessing
# a spelling would be worse than the empty list.
#
# TWO CONSEQUENCES THE SAME ARTICLE STATES, both of which shape what "working" means for this package:
#
#   * "Launching Rust with EAC disabled means that you will only be able to connect to EAC-unsecure
#     servers. These servers will not display in the server browser." So the in-game browser being empty
#     of them is CORRECT BEHAVIOUR, not a propnix bug. Connection is by IP, from the F1 console:
#
#         connect <ip>:<port>
#
#     Facepunch run an unsecure server for exactly this purpose and print its address in that article:
#     `connect 79.137.98.20:28021`. That is the first thing to try once the loading screen is passed, and
#     an EAC-unsecure server is the only class this package can ever reach. Community servers join that
#     class by setting `server.secure 0` / `server.eac 0` server-side (widely documented by Rust hosting
#     providers; not something verifiable from this payload, and not something propnix controls).
#   * The client still CARRIES the anti-cheat: `RustClient_Data/Plugins/x86_64/EOSSDK-Win64-Shipping.dll`
#     ships, and `GameAssembly.dll` contains 50 `EOS_AntiCheat{Client,Server}_*` symbol names. NOTE what
#     that is and is not — those are runtime P/Invoke targets, NOT import-table entries: `objdump -x
#     GameAssembly.dll` lists only KERNEL32/USER32/ADVAPI32/ole32/OLEAUT32/SHELL32/WS2_32/IPHLPAPI, the
#     WinRT api-ms-win-* set, bcrypt, dbghelp and `baselib.dll`. (An earlier revision of this file called
#     them imports; they are not, and the difference is the whole point — nothing forces a session at load
#     time. Likewise `RustClient.exe` itself carries ZERO `EOS_AntiCheat` strings.) Whether the client ever
#     calls `EOS_AntiCheatClient_BeginSession` is a runtime decision the game makes per connection, and on
#     an unsecure server the vendor's own article says it does not need to.
#
# ── WHY `exe = RustClient.exe` AND NOT `Rust.exe` ──────────────────────────────────────────────────────
# `RustClient.exe` is the Unity player: PE32+, and its ONLY non-KERNEL32 import is `UnityPlayer.dll`'s
# `UnityMain2` (verified with `readpe -i`). It reads `RustClient_Data/` beside itself — the standard Unity
# layout — so it is a normal game binary of exactly the kind every other spec here launches directly.
#
# `Rust.exe` is the EAC bootstrapper described above. Launching it would (a) require network access to
# Epic's module CDN before the game starts, (b) try to load an anti-cheat module wine cannot host, and
# (c) hand propnix a LAUNCHER-STUB process: `EasyAntiCheat/Settings.json` sets
# `"wait_for_game_process_exit": "false"`, i.e. the bootstrapper is designed to exit while the game keeps
# running — the same primary-child teardown trap that makes skyrim-se launch `SkyrimSE.exe` instead of
# `SkyrimSELauncher.exe`. So `Rust.exe` is wrong on every axis, independent of whether EAC could work.
# `.apply { exe = "Rust.exe"; }` is there if someone wants to watch the bootstrapper fail on purpose.
{
  lib,
  mkApp,
}:
mkApp (
  { config, lib, ... }:
  {
    pname = "rust";
    maintainers = [ "waltmck" ];
    appid = "rust";
    name = "Rust";

    # ── THE `online` JUDGEMENT ──────────────────────────────────────────────────────────────────────────
    # `true` — STATED, not inherited. It is already the schema default (modules/app-options.nix), so this
    # line changes no behaviour; it is here because every other title in this tree that says anything about
    # `online` says `false`, and a silent default on a title like THIS one would read as an oversight.
    #
    # Rust is not a game with online features, it is a game that IS an online feature: there is no
    # single-player mode, no offline campaign, and no local server in the client depot — the entire product
    # is connecting to a Facepunch or community server. `online = false` unshares a network namespace, which
    # would leave the client loopback-only: the server browser would come up empty, every connect would fail,
    # and the menu fills with `ConnectFailure (Network is unreachable)` from the Discord friend provider and
    # `api.facepunch.com` — i.e. it manufactures failure modes and makes real diagnosis harder, exactly what
    # the option's own docs warn against ("silently cutting a game off ... is miserable to debug").
    #
    # RESIST ONE PARTICULAR TEMPTATION. `.apply { online = false; }` was measured to carry the bootstrap past
    # the freeze described at the top of this file — and it is NOT a fix, it is a coincidence of timing. The
    # only thing that flag changes is `CLONE_NEWNET` (propnix-mount `enter_and_mount`); it cannot touch the
    # `NtQueryVolumeInformationFile` wait the backtrace lands on, and attaching a debugger has exactly the
    # same effect. Turning it off here would trade an intermittent freeze for a client that can never do the
    # one thing it exists to do.
    #
    # BE CLEAR ABOUT WHAT THIS COSTS. propnix's usual guarantee — the kernel, not the app, enforces that a
    # game cannot phone home — DOES NOT APPLY to this package. With `online = true` the launch reaches the
    # network like any other process the user runs, and this payload will use it: EAC/EOS telemetry
    # (`api.epicgames.dev/telemeter/...` and `datarouter.ol.epicgames.com/datarouter/api/v1/public/data`,
    # both string-visible in `Rust.exe`), Facepunch's own analytics (`Facepunch.Rust.AnalyticsManager` in
    # `GameAssembly.dll`), and the Steam and Discord SDKs the client bundles. There is no honest way to
    # package an EAC-protected multiplayer shooter and keep the offline guarantee; the guarantee is what is
    # given up, and this comment is the place that says so.
    online = true;

    # Payload ORDER = overlay priority, and the head tree is load-bearing beyond that: builders/wine.nix
    # takes `head payloads` as C:\game's primary tree, the launch cwd, and the tree it extracts the PE icon
    # from. So the Windows depot (252495) goes FIRST even though 252494 is the numerically lower depot and
    # the far larger tree — `RustClient.exe` lives in 252495. The two do not overlap at all: 252494 is
    # exactly one top-level `Bundles/` directory, 252495 is everything else, so priority never actually
    # arbitrates anything here.
    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;

    exe = "RustClient.exe";

    # Full-colour icon from RustClient.exe's own PE resources — verified present with `wrestool -l`: a
    # group-icon (type 14, name 103) over nine raster sizes, the largest a 256px 270 KB entry.
    icon.auto = true;

    # De-store-integration: the client ships `RustClient_Data/Plugins/x86_64/steam_api64.dll`, and steam.emu
    # union-replaces it with the gbe_fork shim (the settings tree ranks above the payload in the wine game
    # overlay). REQUIRED, not optional: `steam.emu.enable` defaults to true for every Steam fetch, and
    # mk-app.nix refuses a wine build that enables the emu without naming a `.dll` path — a shim the game
    # never loads would be silently inert.
    #
    # NB what this does and does not buy. It answers OWNERSHIP questions offline, which is all propnix ever
    # asks of it. It does not give the client a real Steam session, and Rust's server auth is a Steam ticket
    # validated by the server against Valve — so this is not a route around the online requirement, only the
    # same de-store-integration every other Steam fetch in this tree gets. gbe_fork tracks SDK 1.64 at this
    # pin; the client's `GameAssembly.dll` carries Facepunch.Steamworks entry points including
    # `SteamAPI_ISteamNetworkingSockets_*`, which that SDK covers — but if init ever throws instead of
    # failing, re-check with the `nm -D` triage in modules/steam-emu.nix before blaming anything else.
    steam.emu.libPaths = [ "RustClient_Data/Plugins/x86_64/steam_api64.dll" ];

    # NB there is deliberately NO `steam.emu.*` tuning beyond the line above. `steam.emu.offline = false`
    # was set here, aimed at the 99% freeze; the backtrace in the header killed the theory — the freeze is
    # inside `SteamAPI_InitFlat` and `is_offline()` is only ever read after that returns — so the setting
    # was removed rather than left standing as a fix nobody had watched work. The option itself is still
    # right for a title that genuinely blocks on logon state (pkgs/games/victoria-3); it is just not this
    # title's problem, and leaving it set here would send the next reader down a dead branch.

    # Save/state: the Unity persistentDataPath. `RustClient_Data/app.info` gives the two components verbatim
    # — company "Facepunch Studios LTD", product "Rust" — which is what Unity joins under
    # %USERPROFILE%\AppData\LocalLow. This is where Player.log and the engine's own per-user state land.
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "AppData/LocalLow/Facepunch Studios LTD/Rust";
      }
    ];

    wine = {
      # ── C:\game\temp MUST BE WRITABLE, OR THE MAIN MENU NEVER APPEARS ───────────────────────────────────
      # OBSERVED, and it is the SECOND blocker this title has (the first is the intermittent freeze at the top
      # of this file — different failure, different cause, same-looking screen). With the bootstrap finished —
      # `[Bootstrap] Done`, the menu scene live, `Rust.UI.MainMenu.*` running — the loading overlay still would
      # not clear: 200 s of screenshots came back pixel-identical, and `Player.log` grew to 831,367 lines of
      # one repeating managed exception:
      #
      #     UnauthorizedAccessException: Access to the path 'C:\game\temp' is denied.
      #       … Rust.UI.MainMenu.<PlayVideoAsync>d__22:MoveNext()
      #          Rust.UI.MainMenu.UI_Hero_Store:…(Hero)
      #
      # The menu's hero/store panel downloads its background video into `temp/` BESIDE THE EXE, retries
      # forever when the write fails, and the overlay is gated on it. `temp/` is not in either depot, so the
      # game creates it — and the default `drive_c/game` row is a read-only bind of the payload.
      #
      # A FRESH PRIVATE TMPFS, not a persistent overlay: this is a scratch dir for a re-downloadable video, so
      # nothing here is worth keeping across launches, and an ephemeral row needs no skeleton and no state.
      # (`source = null` is what makes it a tmpfs — backends/wine/defaults.nix documents the row shapes.) The
      # mountpoint itself does not have to exist in the read-only game overlay: propnix-mount gives every
      # mount a CHILD SKELETON of the mountpoints its own content lacks, precisely so a nested row lands on a
      # read-only parent (pkgs/propnix-mount/src/lib.rs).
      #
      # THIS ROW STAYS even though the game dir below is now a WRITABLE overlay, which would make `temp/` land
      # in the persistent upper on its own. It is kept deliberately: `temp/` is scratch for a re-downloadable
      # video, and without this row every launch would accrete video files in `$PROPNIX_STATE/gamedir` forever.
      # The nesting is fine — MEASURED: with both rows in place the menu still comes up and the state dir's
      # `gamedir/` upper contains no `temp/` at all (the tmpfs shadows it).
      mounts."drive_c/game/temp" = {
        type = "mount";
        source = null;
      };

      # ── C:\game MUST BE WRITABLE, OR THE SERVER BROWSER THROWS ──────────────────────────────────────────
      # The THIRD blocker, and the one that closes the old "KNOWN GAP" note this file used to end with (see
      # below). Reported symptom: opening / refreshing the server browser throws
      #
      #     System.TypeInitializationException: The type initializer for '<obfuscated>' threw an exception.
      #      ---> Facepunch.Sqlite.SqliteException: Could not open database file: client.serverlist.1.db (error 14)
      #
      # SQLite error 14 is SQLITE_CANTOPEN — not corruption, a create that failed. WHERE it wanted the file is
      # MEASURED, not guessed (Rust encrypts its string literals — `client.serverlist.1.db` appears nowhere in
      # `global-metadata.dat`, so only a live trace can answer it). `PROPNIX_WINEDEBUG=+file` gives the whole
      # chain:
      #
      #     RtlGetFullPathName_U (L"client.serverlist.1.db" …)                    ← relative → resolved vs the cwd
      #     CreateFileW L"C:\game\client.serverlist.1.db" GENERIC_READ GENERIC_WRITE … creation 4
      #     warn:file:CreateFileW Unable to create file L"C:\game\client.serverlist.1.db" (status c0000022)
      #
      # c0000022 = STATUS_ACCESS_DENIED. So the DB is a file at the ROOT of C:\game — the launch cwd — and the
      # default game row is read-only. AND IT IS NOT A CLICK-ONLY FAILURE: the managed stack in `Player.log`
      # ends at `Rust.UI.MainMenu.UI_MainMenuManager.Awake()`, via `UI_ServerBrowserPage` →
      # `ServerBrowserList` → `<RunQueryAsync>d__19` → the `ServerCacheDatabase` cctor, i.e. it fires at MENU
      # LOAD, four times per launch, with no input at all. That is what makes it verifiable headlessly.
      #
      # A NARROW `type = "file"` ROW FOR THE DB IS NOT ENOUGH, and this was measured rather than reasoned
      # about. With `drive_c/game/client.serverlist.1.db` bound out to the state dir, the trace shows the DB
      # itself opening — and then:
      #
      #     CreateFileW L"C:\game\client.serverlist.1.db-journal" … creation 4
      #     warn:file:CreateFileW Unable to create file L"C:\game\client.serverlist.1.db-journal" (c0000022)
      #     → SqliteException: Could not reset SQL statement: unable to open database file (14)
      #
      # SQLite's ROLLBACK JOURNAL is a SIBLING of the DB, created and DELETED per transaction, so no bind of
      # the DB file alone can work — Facepunch only reaches `journal_mode=wal` (confirmed: `pragma
      # journal_mode` on the resulting file says `wal`) by first running the pragma inside an ordinary
      # journalled transaction. The DIRECTORY has to be writable. Hence a whole-game-dir CoW overlay.
      #
      # PERSISTENT ($PROPNIX_STATE), not ephemeral — a deliberate choice, and the DB is the least of it.
      # The same row is what finally lets the game write `cfg/client.cfg` and `cfg/keys.cfg`, which are
      # settings and keybinds and MUST survive a restart (the old note below called their loss "a persistence
      # bug, not a blocker"; it is fixed here, not merely worked around). The server-list DB itself is only a
      # cache, but it is a cache with `favorites.cfg` for company, and a state dir is exactly where
      # regenerable-but-worth-keeping per-app data belongs.
      #
      # `lower` IS BUILT HERE FROM `config`, not hardcoded, and the order matters: `extraLowers` (steam.emu's
      # offline-entitlement settings tree) must outrank the depots, then the payloads in declared order. That
      # reproduces exactly what builders/wine.nix's own `gameMount` computes — which this row REPLACES
      # wholesale, since `finalMounts` merges tuning rows over the derived game row with `//`, not per-field.
      # `skeleton` is deliberately NOT set: the wine builder then derives the default data-only skeleton over
      # the WHOLE colon-joined stack, which is the piece that had to be built for this (see the commit's
      # changes to lib/builders/store-skeleton.nix and pkgs/propnix-mount). Leaving it `null` "works" for the
      # DB and is a TRAP: without the skeleton the store lowers stay `dr-xr-xr-x nobody nogroup` inside the
      # launch's user namespace, so only the merged ROOT is writable — `touch cfg/client.cfg` fails EACCES
      # (measured directly with `unshare --user --map-root-user --mount` + a bare overlay).
      #
      # MEASURED ON THE SHIPPED ROW (x86_64, headless sway + RX 7900 XTX, four consecutive launches):
      # `Player.log` contains ZERO SqliteException/TypeInitializationException lines (was four per launch);
      # `[Bootstrap] Done` / `completed in 15.44s`; all twelve bundles still load through the metacopy
      # redirects out of the 39 GB content depot; and `$PROPNIX_STATE/gamedir` ends up holding
      # `client.serverlist.1.db` (+`-wal`), `cfg/client.cfg`, `cfg/keys.cfg` and `cfg/favorites.cfg`, all
      # written BY THE GAME. Persistence was checked both ways: editing `graphics.fov` to a marker value in
      # the persisted `client.cfg` and relaunching leaves the marker in place, so the game reads it back
      # rather than starting from defaults.
      #
      # THE ONE COST OF A PERSISTENT UPPER, shared with the KSP/no-mans-sky rows: a depot bump leaves whatever
      # was copied up shadowing the NEW payload. Nothing here is copied up in normal play (the game only
      # CREATES files), but if a future version misbehaves after a `versions.json` bump, clearing
      # `$PROPNIX_STATE/gamedir` is the first thing to try.
      mounts."drive_c/game" = {
        type = "overlay";
        lower = lib.concatStringsSep ":" (map (d: "${d}") (config.extraLowers ++ config.payloads));
        upper = "$PROPNIX_STATE/gamedir";
        createIfNotExist = true;
      };
    };

    # ── THE OLD "KNOWN GAP" (RUST WRITES INSIDE ITS OWN INSTALL DIR) IS CLOSED — WHAT IT COST ─────────────
    # This file used to end with a note saying the multi-depot game dir could not be made writable, so
    # `cfg/client.cfg`, `cfg/keys.cfg`, `screenshots/` and `demos/` were lost at exit. The `drive_c/game`
    # overlay above fixes all of them, and the note is kept — inverted — because the thing that BLOCKED it was
    # not what that note said, and the next reader should not re-derive the wrong obstacle.
    #
    # What the old note got right: the whole-game-dir CoW pattern (KSP / no-mans-sky) needs a skeleton, and
    # `mkStoreSkeleton` only took ONE tree. That is now a LIST (first tree wins, matching overlayfs' own
    # leftmost-wins order), and builders/wine.nix splits a colon-joined `lower` and derives one skeleton
    # spanning the whole stack. Rust's three lowers — the steam.emu entitlement tree, 252495, 252494 — produce
    # a 2.5 MB sparse tar of 3510 stubs, so "the payload is 39 GB" was never the problem either.
    #
    # WHAT ACTUALLY BLOCKED IT, and it is a kernel detail nothing in this tree had hit before: in an overlayfs
    # `lowerdir=`, `::` introduces ONE data-only layer AND MUST BE REPEATED PER LAYER. propnix-mount composed
    # `<skel>::<l1>:<l2>:<l3>`, which the kernel reads as "regular lowers after data lowers" and rejects —
    # `mount(2)` = EINVAL, `overlayfs: regular lower layers cannot follow data lower layers` in dmesg, and the
    # launcher's only visible symptom was `propnix-launcher: launch failed: Invalid argument (os error 22)`.
    # `<skel>::<l1>::<l2>::<l3>` mounts. (Two traps live here: `mount(8)` normalises the option string and the
    # per-layer form does NOT survive it, so this can only be reproduced through the syscall — propnix-mount
    # already calls `mount(2)` directly; and the single-tree case is a no-op for the fix, which is why every
    # other game in this tree worked without it.)
    #
    # WHAT IS STILL NOT DONE. `screenshots/` and `demos/` now WORK (verified creatable in the merged tree),
    # but they land in `$PROPNIX_STATE/gamedir` rather than anywhere a user would look. If someone actually
    # uses them, they want their own rows pointing at `$PROPNIX_SAVE_DIR` / `$XDG_PICTURES_DIR` — a
    # presentation choice, not a correctness one, and not worth guessing at before anyone has taken a
    # screenshot with this package.
  }
)
