# propnix proof of concept #2 — Slack for Windows, ARM64 build, under wine on aarch64.
#
# Deliberately unabstracted, like poc/flake.nix. This one exercises a completely
# different axis from Hollow Knight:
#
#   * Windows payload, not Linux            -> the wine path
#   * ARM64 PE, not x86_64                  -> NO emulation at all; wine runs it natively
#   * freely downloadable, no credentials   -> plain fetchurl, not the credentialed FOD
#   * MSIX, not an installer                -> extract-and-run; wine cannot install MSIX
#
# It is the first test of PLAN2 §2's route table, third row, which was marked (unverified).
#
# Build:  nix-build slack-arm64.nix
# Run:    ./result/bin/slack
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; },
}:

let
  inherit (pkgs) lib;

  version = "4.51.180";

  # Freely downloadable — no account, no token, so no sandbox-path grant needed.
  # nixpkgs' own slack package keeps these in a generated sources.nix with
  # `version` + `src` per system; a real propnix package would use versions.json
  # the same way (PLAN2 §3.5).
  payload = pkgs.fetchurl {
    url = "https://downloads.slack-edge.com/desktop-releases/windows/arm64/${version}/Slack.msix";
    hash = "sha256-gDOWfdqgNdDZicK4R+2wouzHslY8ZiO5io8icFnBDao=";
  };

  # MSIX is a plain ZIP (compression method=store), so extract rather than install.
  # wine has no AppX/MSIX deployment stack, and an Electron app does not need one:
  # it wants a directory with Slack.exe and its DLLs, which is exactly what is inside.
  unpacked = pkgs.runCommand "slack-arm64-unpacked-${version}"
    {
      nativeBuildInputs = [ pkgs.libarchive ];
      allowSubstitutes = false; # proprietary, non-redistributable
    }
    ''
      mkdir -p $out
      bsdtar -xf ${payload} -C $out
      test -e "$out/app/Slack.exe" || { echo "Slack.exe missing" >&2; exit 1; }

      # Assert the payload really is ARM64 (PE machine 0xaa64) rather than x86_64.
      # If this ever flips, the whole no-emulation premise is void and we want a
      # loud build failure, not a silent fallback into emulation.
      mach=$(od -An -tx2 -j "$(( $(od -An -tu4 -j60 -N4 "$out/app/Slack.exe" | tr -d ' ') + 4 ))" \
                -N2 "$out/app/Slack.exe" | tr -d ' ')
      if [ "$mach" != "aa64" ]; then
        echo "expected ARM64 PE (aa64), got $mach — refusing" >&2
        exit 1
      fi
      echo "verified: app/Slack.exe is an ARM64 PE"
    '';

  # PLAN2 §2: an ARM64 Windows PE needs plain wine on aarch64 — no box64, no FEX,
  # no muvm. pkgs.wine THROWS on aarch64, so wineWow64Packages is mandatory.
  wine = pkgs.wineWow64Packages.stable;

in
pkgs.writeShellApplication {
  name = "slack";
  runtimeInputs = [ wine pkgs.coreutils ];
  text = ''
    # --- D13 seal (PLAN2 §7) ---
    # Scrub the backend's whole namespace plus LD_*, then set only what we mean, so
    # the run does not depend on the user's ambient wine configuration.
    while IFS='=' read -r k _; do
      case "$k" in WINE*|LD_*|DXVK_*) unset "$k" ;; esac
    done < <(env)

    export WINEDEBUG=-all
    export WINEARCH=win64          # never win32: deprecated in wine 11
    export WINEDLLOVERRIDES="mscoree,mshtml="   # no .NET / no Gecko prompts

    # --- PLAN2 §7.2 state layout, keyed by app, three lifetimes as siblings ---
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/propnix/slack"
    runtime="''${XDG_RUNTIME_DIR:-/tmp}/propnix/slack"
    mkdir -p "$state" "$runtime"
    export WINEPREFIX="$state/prefix"

    # NO flock guard here, deliberately — and this is a correction to a first attempt.
    # The lock fd is inherited by children, and `wineserver` lingers by design after the
    # app exits, so it kept holding the lock and refused the *next* launch. Electron
    # already implements single-instance itself (app.requestSingleInstanceLock), so the
    # guard is redundant as well as harmful. The flock pattern belongs to the box64/Unity
    # case, where Unity cannot write unity.lock into a read-only store dir — it is not a
    # universal wrapper feature.

    # Reconcile the prefix only when it is new or the wine build changed. Running
    # wineboot -u on every launch pops up wine's "configuration is being updated"
    # dialog each time, which is what the user sees flash past. The stamp is the wine
    # store path, so it already encodes the version (PLAN2 §7.2's staleness rule).
    stamp="$state/.wine-stamp"
    want=${wine}
    if [ ! -e "$WINEPREFIX/system.reg" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
      if [ ! -e "$WINEPREFIX/system.reg" ]; then
        echo "slack: creating wine prefix at $WINEPREFIX (first run)" >&2
      else
        echo "slack: wine changed, running wineboot -u to migrate the prefix" >&2
      fi

      # Run prefix setup with NO display, so wine physically cannot pop up its
      # "the wine configuration is being updated, please wait" dialog. Without this
      # the user gets a flashing notification on every reconcile.
      (
        unset DISPLAY WAYLAND_DISPLAY

        # wineboot -u is wine's own in-place upgrade path and is idempotent: it rewrites
        # system.reg (wine's hive) while preserving user.reg and drive_c/users (yours).
        # Verified across 11.0 -> 11.12.
        wineboot -u >/dev/null 2>&1 || true

        # Prefer the Wayland driver, falling back to X11. wineWow64 ships
        # winewayland.drv for aarch64-windows; selection is a runtime registry setting,
        # not a package choice. This is "declared" state and so belongs in prefix setup.
        wine reg add 'HKCU\Software\Wine\Drivers' /v Graphics /d 'wayland,x11' /f >/dev/null 2>&1 || true

        wineserver -w 2>/dev/null || true
      )
      printf '%s' "$want" > "$stamp"
    fi

    # Electron's GPU *child process* cannot launch under wine: it dies with
    #   GPU process launch failed: error_code=40  /  GPU process isn't usable. Goodbye.
    # --in-process-gpu folds it into the main process and fixes that. Measured
    # alternatives: --disable-gpu-sandbox alone still failed; --disable-gpu traded it for
    # DCompositionCreateDevice3 "Not implemented" and exit 5, so keeping GPU acceleration
    # ON and merely avoiding the child process is the better fix, not the blunter one.
    # These flags are per-package tuning data (PLAN2 §7.1) — nothing derives them.
    # PROPNIX_SLACK_ARGS overrides them for iteration without a rebuild.
    args=''${PROPNIX_SLACK_ARGS---no-sandbox --in-process-gpu}

    # shellcheck disable=SC2086  # deliberate word-splitting of the flag list
    exec wine ${unpacked}/app/Slack.exe $args "$@"
  '';
}
