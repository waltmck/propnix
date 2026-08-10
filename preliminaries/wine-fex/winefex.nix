# winefex — run a Windows PE (x86_64, x86, or aarch64) on aarch64 Linux via the hybrid wine + FEX
# emulators. The wine prefix is a SYMLINK FARM (§7.2): a persistent per-app directory whose read-only
# content is symlinked into the read-only store, while its writable content is real and persists there.
# No overlay, no mount, no namespace — so the game runs as the real user with every host supplementary
# group (video, kvm, pipewire, …) intact.
#
#   winefex some_app.exe [args...]
#   PROPNIX_APPID=hollow-knight winefex "Hollow Knight.exe"
#
# Prefix layout ($XDG_STATE_HOME/propnix/<appid>/prefix), assembled each launch:
#   * READ-ONLY, symlinked -> the store lower (wine-prefix-lower.nix): drive_c/windows/* except temp
#     (system32/syswow64, the FEX DLLs, Fonts, …), drive_c/Program Files*, system.reg (HKLM),
#     userdef.reg (HKU\.Default), .update-timestamp. These symlinks are removed + recreated every launch,
#     so a wine/FEX bump (new store path) is picked up automatically, and any RO file wine tried to
#     rewrite last run (it can't — the store is 0444 — so it drops a real file over the symlink) is
#     restored to the symlink.
#   * WRITABLE, real, persistent — the Windows non-elevated write set (matches what a standard Windows
#     user may write; everything else is read-only, as on Windows): user.reg (HKCU — wine regenerates it
#     on first run and writes it in place thereafter), drive_c/users (the user profile / AppData),
#     drive_c/ProgramData, drive_c/windows/temp, dosdevices.
#   * Saves are bound OUT of the prefix separately (PROPNIX_WINE_BIND / §6.1).
#   * The store lower's DLL closure is prefetched into cache in the background at the very start (§ prefetch).
#
# appid = PROPNIX_APPID (else exe basename). PROPNIX_BENCH=1 → performance samples to
# ${PROPNIX_BENCH_DIR:-/tmp/propnix-bench}/<appid>/ AND, on the dxvk backend, an on-screen DXVK HUD
# (upper-left: fps, frametime, GPU load, GPU name, DXVK version, D3D level). PROPNIX_WINEDEBUG overrides -all.
# PROPNIX_WINE_D3D=wined3d|dxvk selects the D3D→GPU translation (default dxvk = native ARM64EC DXVK, fast Vulkan).
# PROPNIX_WINE_GRAPHICS=wayland|x11 selects the wine display driver. PROPNIX_FPS caps the framerate
# (→ DXVK_FRAME_RATE on the dxvk backend). All PROPNIX_* are launch-time env, globally settable.
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs {
    system = "aarch64-linux";
    config.allowUnfree = true;
  },
}:
let
  wine = import ./wine-hangover.nix { inherit nixpkgs pkgs; };
  # FEX emulator DLLs, built FROM SOURCE at FEX-2607 (fex-dlls.nix): libarm64ecfex.dll (x86_64 guests,
  # 0xA641) + libwow64fex.dll (i386 guests, native ARM64 0xAA64) + wowbox64.dll. RESEARCH §22.
  fexdlls = import ./fex-dlls.nix { inherit nixpkgs pkgs; };

  # Native ARM64EC DXVK (D3D9/10/11 → Vulkan) + vkd3d-proton (D3D12 → Vulkan). Installed into the prefix's
  # system32 as native overrides when PROPNIX_WINE_D3D=dxvk — the fast Vulkan path (wined3d's Vulkan renderer
  # stalls to ~12 fps; RESEARCH §22). vkd3d-proton ships only d3d12/d3d12core and reuses DXVK's dxgi, so the
  # two are installed together. Each store-path hash keys a bump the same way the lower does.
  dxvk = import ./dxvk-arm64ec.nix { inherit nixpkgs pkgs; };
  vkd3d = import ./vkd3d-proton-arm64ec.nix { inherit nixpkgs pkgs; };

  # The read-only system tree, provisioned at BUILD TIME into the store (wine-prefix-lower.nix): wineboot
  # + FEX DLLs + Wow64 keys + system hives, minus user.reg. Symlinked into each prefix; its store-path
  # hash keys a wine/FEX bump (new path → the next launch relinks to it). No first-launch provisioning; §7.2.
  wineUser = "propnix";
  prefixLower = import ./wine-prefix-lower.nix { inherit nixpkgs pkgs wine fexdlls wineUser; };

  # Cold-launch prefetcher (self-contained Rust/Cargo package in ./propnix-prefetch): per file, chunked
  # posix_fadvise(WILLNEED) across a tokio blocking pool — async ZFS dmu_prefetch that yields to wine's
  # synchronous faults (degrades to readahead off ZFS). winefex's sole prefetcher (RESEARCH §19).
  prefetchTool = import ./propnix-prefetch { inherit nixpkgs pkgs; };

  # Benchmarking runner (opt-in). Kept as a writeShellScript so the fiddly sampler is isolated from
  # the wrapper. Launches wine in the background, samples the game's /proc tree until it exits, and
  # (best-effort) lets MangoHud log the render path. Env in: PROPNIX_APPID, PROPNIX_BENCH_DIR.
  benchRunner = pkgs.writeShellScript "winefex-bench-run" ''
    set -u
    exe="$1"; shift || true
    exebase="$(basename "$exe")"
    appid="''${PROPNIX_APPID:-''${exebase%.exe}}"
    benchdir="''${PROPNIX_BENCH_DIR:-/tmp/propnix-bench}/$appid"
    mkdir -p "$benchdir"
    run="$(date +%Y%m%d-%H%M%S)-$$"
    meta="$benchdir/$run.meta"
    csv="$benchdir/$run.samples.csv"
    {
      echo "app=$appid"
      echo "backend=winefex"
      echo "exe=$exebase"
      echo "start_epoch=$(date +%s)"
      echo "clk_tck=$(getconf CLK_TCK 2>/dev/null || echo 100)"
      echo "pagesize=$(getconf PAGE_SIZE 2>/dev/null || echo '?')"
      echo "nproc=$(nproc 2>/dev/null || echo '?')"
    } > "$meta"

    # FPS/frametime/CPU/GPU/RAM/VRAM via MangoHud when available (best-effort; unverified on the wine
    # path — /proc RSS/CPU below is the guaranteed floor, RESEARCH §19).
    if command -v mangohud >/dev/null 2>&1; then
      export MANGOHUD=1
      export MANGOHUD_CONFIG="fps,frametime,cpu_load,gpu_load,ram,vram,cpu_stats,output_folder=$benchdir,log_interval=250,autostart_log=1"
      echo "mangohud=1" >> "$meta"
    else
      echo "mangohud=absent" >> "$meta"
    fi

    printf 'epoch,rss_kb,threads,cpu_jiffies\n' > "$csv"
    wine "$exe" "$@" &
    launcher=$!
    trap 'kill "$launcher" 2>/dev/null || true' INT TERM

    # The game's processes match exebase in their cmdline; exclude THIS script (its argv also holds
    # exebase) so the loop terminates when the game exits.
    list_pids() { pgrep -f "$exebase" 2>/dev/null | grep -vx "$$" || true; }

    # Brief grace for the launcher/game to appear.
    i=0; while [ "$i" -lt 20 ] && [ -z "$(list_pids)" ]; do sleep 1; i=$((i + 1)); done

    while [ -n "$(list_pids)" ]; do
      now="$(date +%s)"; rss=0; thr=0; jif=0
      while read -r p; do
        [ -r "/proc/$p/status" ] || continue
        vr="$(awk '/^VmRSS:/{print $2; exit}' "/proc/$p/status" 2>/dev/null)"; vr="''${vr:-0}"
        nt="$(awk '/^Threads:/{print $2; exit}' "/proc/$p/status" 2>/dev/null)"; nt="''${nt:-0}"
        cj="$(sed 's/^.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $12 + $13}')"; cj="''${cj:-0}"
        rss=$((rss + vr)); thr=$((thr + nt)); jif=$((jif + cj))
      done < <(list_pids)
      printf '%s,%s,%s,%s\n' "$now" "$rss" "$thr" "$jif" >> "$csv"
      sleep 2
    done

    rc=0; wait "$launcher" 2>/dev/null || rc=$?
    { echo "end_epoch=$(date +%s)"; echo "exit_code=$rc"; } >> "$meta"
    echo "propnix: bench samples -> $benchdir" >&2
    exit "$rc"
  '';
in
pkgs.writeShellApplication {
  name = "winefex";
  runtimeInputs = [
    wine
    pkgs.coreutils
    pkgs.procps # pgrep (bench sampler), ps (teardown backstop)
    pkgs.gnused # bench sampler
    pkgs.gawk # bench sampler + teardown backstop
    pkgs.findutils # find/xargs — profile-skeleton seed + clearing stale windows symlinks
    prefetchTool # propnix-prefetch — cold-launch DLL prefetch (posix_fadvise WILLNEED)
  ];
  text = ''
    _appid="''${PROPNIX_APPID:-$(basename "''${1:-winefex}" .exe)}"
    _state="''${XDG_STATE_HOME:-$HOME/.local/state}/propnix/$_appid"
    _cache="''${XDG_CACHE_HOME:-$HOME/.cache}/propnix/$_appid"   # regenerable caches (DXVK shaders): cache, not state
    lower="${prefixLower}"   # store-built read-only system tree (§7.2)
    pfx="$_state/prefix"     # persistent per-app WINEPREFIX (the symlink farm)

    # Cold-launch prefetch (RESEARCH §19): warm the wine LOWER's DLL closure in the background via
    # propnix-prefetch (chunked posix_fadvise(WILLNEED) — async, yields to wine's demand faults). No-op on
    # a warm cache; disable with PROPNIX_NO_PREFETCH=1.
    if [ -z "''${PROPNIX_NO_PREFETCH:-}" ]; then
      propnix-prefetch "$lower" &
    fi

    # First-run popups off (mscoree=b suppresses the wine-mono prompt without breaking .NET; mshtml= drops
    # gecko; winemenubuilder=d drops icon dialogs); quiet logs; pin the wine username to the store lower's
    # profile so drive_c/users/${wineUser} is found as-is.
    export WINEDLLOVERRIDES="''${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}mscoree=b;mshtml=;winemenubuilder.exe=d"
    export WINEDEBUG="''${PROPNIX_WINEDEBUG:--all}"
    export USER="${wineUser}" LOGNAME="${wineUser}"

    # Target framerate (PROPNIX_FPS): a global, backend-agnostic knob (a user or NixOS module can set it
    # once for all games). On winefex it maps to DXVK's limiter (DXVK_FRAME_RATE); wined3d has no frame
    # cap (games self-limit), so it only takes effect on the DXVK backend below.
    if [ -n "''${PROPNIX_FPS:-}" ]; then export DXVK_FRAME_RATE="''${PROPNIX_FPS}"; fi

    # ===== Assemble the prefix (symlink farm) in the persistent per-app dir. =====
    # Read-only content is symlinked into the store; writable content is real + persists here. Rebuilt
    # every launch: cheap (a few dozen symlinks), needs no bump-detection, and restores anything wine
    # clobbered last run (§7.2).
    mkdir -p "$pfx/drive_c/windows/temp" "$pfx/drive_c/users" "$pfx/drive_c/ProgramData" "$pfx/dosdevices"
    # Writable profile skeleton (real dirs; wine + apps fill AppData etc. here — persists). Idempotent, so
    # re-running each launch only ensures the standard dirs exist; user data is never touched.
    ( cd "$lower/drive_c/users"       && find . -type d -print0 ) | ( cd "$pfx/drive_c/users"       && xargs -0 mkdir -p )
    ( cd "$lower/drive_c/ProgramData" && find . -type d -print0 ) | ( cd "$pfx/drive_c/ProgramData" && xargs -0 mkdir -p )
    ln -sfn ../drive_c "$pfx/dosdevices/c:"
    ln -sfn /          "$pfx/dosdevices/z:"
    # Read-only -> store: drop the old links/clobbered files and recreate them against the CURRENT lower.
    #   * system.reg (HKLM) + userdef.reg (HKU\.Default): Admin-only hives games never write. wine can't
    #     write the 0444 store target, so its save drops a real file over the symlink — discarded + relinked
    #     here next launch, so the store copy is authoritative every launch (no drift, no import).
    #   * user.reg (HKCU) is deliberately NOT symlinked: wine's save would clobber a file symlink. It is a
    #     REAL file in this prefix (wine regenerates it on first run — built-in defaults + font list, ~+0.1 s,
    #     not a wineboot) and persists.
    rm -f "$pfx/system.reg" "$pfx/userdef.reg" "$pfx/.update-timestamp"
    ln -s "$lower/system.reg"       "$pfx/system.reg"
    ln -s "$lower/userdef.reg"      "$pfx/userdef.reg"
    ln -s "$lower/.update-timestamp" "$pfx/.update-timestamp"
    find "$pfx/drive_c/windows" -maxdepth 1 -type l -delete   # clear stale symlinks (e.g. entries dropped across a bump)
    for _e in "$lower"/drive_c/windows/*; do
      _b="$(basename "$_e")"; [ "$_b" = temp ] && continue    # temp is real + writable (C:\Windows\Temp)
      rm -rf "$pfx/drive_c/windows/$_b"                        # robust: also clear a leftover real file/dir at this name (never `ln -s` onto an existing name → set -e abort → wedge)
      ln -s "$_e" "$pfx/drive_c/windows/$_b"
    done
    for _d in "Program Files" "Program Files (x86)"; do
      rm -rf "$pfx/drive_c/$_d"                                # -rf (not -f): may be a real dir if an installer wrote here
      [ -e "$lower/drive_c/$_d" ] && ln -s "$lower/drive_c/$_d" "$pfx/drive_c/$_d"
    done
    export WINEPREFIX="$pfx"

    # D3D→GPU backend (PROPNIX_WINE_D3D=wined3d|dxvk; default DXVK). DXVK is the fast Vulkan path —
    # wine's builtin wined3d Vulkan renderer serializes present on the render thread and stalls to ~12 fps
    # here, while native ARM64EC DXVK reaches 60 (RESEARCH §22). DXVK needs REAL files in system32, so
    # rebuild system32 as a real dir of per-file store symlinks with the DXVK DLLs dropped over the D3D
    # ones (the whole-dir symlink the loop above made is replaced). A wined3d launch relinks system32 to
    # the store whole-dir symlink, so switching backends is clean either way.
    if [ "''${PROPNIX_WINE_D3D:-dxvk}" = dxvk ]; then
      _sys="$pfx/drive_c/windows/system32"
      rm -rf "$_sys"; mkdir -p "$_sys"
      for _f in "$lower"/drive_c/windows/system32/*; do ln -s "$_f" "$_sys/$(basename "$_f")"; done
      for _d in d3d11 d3d10core dxgi d3d9; do rm -f "$_sys/$_d.dll"; ln -s "${dxvk}/$_d.dll" "$_sys/$_d.dll"; done
      # vkd3d-proton (D3D12): ships only d3d12/d3d12core and reuses DXVK's dxgi (installed just above).
      for _d in d3d12 d3d12core; do rm -f "$_sys/$_d.dll"; ln -s "${vkd3d}/$_d.dll" "$_sys/$_d.dll"; done
      export WINEDLLOVERRIDES="d3d11,d3d10core,dxgi,d3d9,d3d12,d3d12core=n;$WINEDLLOVERRIDES"
      # Persist DXVK's pipeline/shader cache so cold-start compile happens once (a fresh cache reads as a
      # low-fps first run, not steady state). It lives under XDG_CACHE_HOME (regenerable → cache, not state,
      # and never inside the read-only store / rebuildable prefix, where DXVK's default next-to-exe cache
      # would silently no-op).
      export DXVK_STATE_CACHE_PATH="$_cache/dxvk"; mkdir -p "$DXVK_STATE_CACHE_PATH"
      export DXVK_LOG_PATH="$DXVK_STATE_CACHE_PATH"
      export DXVK_LOG_LEVEL="''${PROPNIX_WINEDEBUG:+info}"; : "''${DXVK_LOG_LEVEL:=none}"
      # PROPNIX_BENCH → DXVK's built-in on-screen HUD (upper-left): fps + frametime graph, GPU load, GPU
      # name/driver (devinfo), DXVK version, and the D3D feature level (api). Free (no MangoHud needed) on
      # the DXVK backend. User-overridable via DXVK_HUD. (The benchRunner also logs /proc RSS/CPU + MangoHud
      # if present; this is the visible indicator.)
      if [ -n "''${PROPNIX_BENCH:-}" ]; then
        export DXVK_HUD="''${DXVK_HUD:-fps,frametimes,gpuload,devinfo,version,api}"
      fi
    fi

    # Per-app wine display driver (PROPNIX_WINE_GRAPHICS=wayland|x11|…) → HKCU\…\Drivers\Graphics, stamped
    # so the reg-add (which spins a wineserver) only runs on first launch / on change. Per-title choice
    # (§6.2 / RESEARCH §12): winewayland = native fractional scaling (no PROPNIX_DPI) but undersized cursor;
    # winex11/Xwayland = correct cursor, needs PROPNIX_DPI.
    if [ -n "''${PROPNIX_WINE_GRAPHICS:-}" ]; then
      gstamp="$pfx/.propnix-graphics"
      if [ "$(cat "$gstamp" 2>/dev/null)" != "''${PROPNIX_WINE_GRAPHICS}" ]; then
        wine reg add 'HKCU\Software\Wine\Drivers' /v Graphics /t REG_SZ /d "''${PROPNIX_WINE_GRAPHICS}" /f >/dev/null 2>&1 || true
        printf '%s' "''${PROPNIX_WINE_GRAPHICS}" > "$gstamp"
      fi
    fi

    # Persistent data binds (PROPNIX_WINE_BIND: ';'-separated "GUESTREL|HOSTPATH"): each guest path under
    # drive_c/users/<user> becomes a symlink to HOSTPATH, so saves live OUTSIDE the prefix and can be
    # shared with a native build. Applied every run (idempotent).
    if [ -n "''${PROPNIX_WINE_BIND:-}" ]; then
      userdir="$WINEPREFIX/drive_c/users/${wineUser}"
      while IFS= read -r -d ';' pair || [ -n "$pair" ]; do
        [ -z "$pair" ] && continue
        guestrel="''${pair%%|*}"; hostpath="''${pair#*|}"
        [ -z "$guestrel" ] || [ "$guestrel" = "$pair" ] && continue
        mkdir -p "$hostpath" "$(dirname "$userdir/$guestrel")"
        # If the guest path already holds real data (not a symlink), migrate it out once — but only
        # delete the source if the copy SUCCEEDS (this is the one path touching irreplaceable saves; a
        # swallowed cp failure followed by an unconditional rm would lose them). `-n` keeps host copies
        # authoritative.
        if [ -d "$userdir/$guestrel" ] && [ ! -L "$userdir/$guestrel" ]; then
          if cp -an "$userdir/$guestrel/." "$hostpath/"; then
            rm -rf "''${userdir:?}/''${guestrel:?}"
          else
            echo "propnix: save migration to $hostpath failed — leaving data in the prefix" >&2
          fi
        fi
        ln -sfn "$hostpath" "$userdir/$guestrel"
      done <<< "$PROPNIX_WINE_BIND;"
    fi

    # Teardown: `wineserver -k` is PREFIX-SCOPED — it reaps this prefix's whole wine tree (game +
    # wineserver + services) on exit/signal, and touches nothing else. There is no mount or namespace to
    # unwind, so this can never strand anything. Do NOT add a global process-name kill: `wineserver`,
    # `services.exe`, `explorer`, etc. are shared by EVERY wine app, so it would SIGKILL a concurrent
    # Slack/Zoom/other-title wineserver (same user), losing their unsaved state. wine runs BACKGROUNDED +
    # `wait`ed (not exec/foreground) so an INT/TERM interrupts the wait and fires the trap promptly;
    # normal exit falls through to the EXIT trap.
    # shellcheck disable=SC2329  # invoked via the traps below
    cleanup() {
      trap - EXIT INT TERM
      WINEPREFIX="$pfx" wineserver -k >/dev/null 2>&1 || true
    }
    trap 'cleanup; exit 130' INT TERM
    trap cleanup EXIT

    rc=0
    if [ -n "''${PROPNIX_BENCH:-}" ]; then
      ${benchRunner} "$@" &
    else
      wine "$@" &
    fi
    _child=$!
    wait "$_child" || rc=$?
    exit "$rc"
  '';
}
