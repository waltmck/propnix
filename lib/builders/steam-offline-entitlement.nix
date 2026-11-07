# builders/steam-offline-entitlement.nix — a SELF-LOCATING entitlement tree for a bundled Steam-API
# reimplementation: the LGPL gbe_fork shim (emulators/gbe-fork) COPIED beside a generated settings tree
# that tells it which DLC this account owns. One derivation is both the preload target and the config it
# reads.
#
# WHY THIS EXISTS. Steam pins content by (appId, depotId, manifestId) and releases it only to an account that
# owns it — `fetchSteamDepot` cannot produce a tree for a DLC the account lacks, because Steam refuses the
# depot decryption key (eresult 15) before a byte is downloaded. The payload IS the proof of purchase. Some
# engines nevertheless resolve ENTITLEMENT at runtime through `libsteam_api.so`, and Valve ships no Steam
# client for every platform propnix runs on (there is none for 16K-page aarch64). On such a host the owner's
# own, already-downloaded, already-decrypted DLC reads as unowned. This closes that gap — and nothing else:
#
#   * `dlc` is the set of trees ACTUALLY MOUNTED for this build, threaded from `config.dlc.enabled` rather
#     than authored by hand. By construction it can only contain depots Steam decrypted for this account,
#     so the emitted entitlement list cannot name content the account does not own.
#   * Upstream unlocks EVERY DLC by default (`[app::dlcs] unlock_all` defaults to 1 — and its ancestor
#     unlocked everything when the list file was missing). We therefore always emit `configs.app.ini` with
#     an EXPLICIT `unlock_all=0` + the owned list: an empty `dlc` set yields an empty list — "own nothing",
#     never "own everything". That inversion is the whole safety property, now stated as a key rather than
#     hinging on file presence.
#
# HOW THE SHIM FINDS IT — TWO PLACEMENTS, because the answer depends on the loader. Upstream looks for
# `steam_settings/` (and `steam_interfaces.txt`) beside the loaded library, by readlink()ing the
# /proc/self/map_files entry covering one of its own functions (dll/base.cpp `get_lib_path`), and falls back
# to "." — the CWD — when that finds nothing. Both cases occur:
#
#   * NATIVE x86_64 (and FEX's guest ld.so): the probe succeeds — and because the preloaded shim is the COPY
#     inside THIS tree, it resolves right here, where the settings already sit. Nothing has to be mounted
#     into the shim package's read-only store path.
#   * box64: guest libraries are not file-mapped at all — no `libsteam_api.so` appears in the emulated
#     process's maps, not even the game's own copy — so the probe returns "." and the lookup resolves
#     against the CWD, which propnix sets to the game dir. Union this tree in there via `extraLowers`.
#
# Preload the copy (`box64.guestPreload = [ "${settings}/libsteam_api.so" ]`) AND union the tree into the
# game dir, and no backend needs special-casing: whichever way the loader answers, the shim reads the same
# list. Getting it wrong is silent and INVERTED — a `steam_settings/` the shim cannot find means "unlock
# everything", so a caller that wires only one placement can over-claim on the other backend.
#
# No local identity (account_name.txt / user_steam_id.txt) is written: entitlement does not key on it,
# and a package shipped to other people must not carry a baked-in account name or SteamID — it would be
# one identity shared by every install, and a plausible-looking SteamID64 in the source invites the reader
# to assume it belongs to someone. Identity is left entirely to gbe_fork: it generates one and saves it in
# its GLOBAL settings — persistent on wine (the users overlay), per-launch on thin (the ephemeral view).
# The local tree here deliberately leaves `[user::general]` unset so that global value is what the shim
# resolves. (The launcher used to seat the stored Steam account's SteamID64 there; that seeding was
# removed — it read the credential store as the launching human, which the group-ownership contract does
# not permit on declarative/shared hosts, and it never delivered the stable identity it was added for.)
{
  lib,
  runCommandLocal,
}:
{
  appId, # the BASE game's Steam appid
  # Owned + mounted DLC: name → { appId; title; }. `appId` here is the DLC's own store appid, which for a
  # DLC shipped as its own depot of the base app IS the depotId — see pkgs/games/stellaris/versions.json.
  dlc,
  # The PAYLOAD-ABI `libsteam_api.so` (the caller picks gbe_fork's matching per-ABI build), copied at $out
  # — the THIN preload target.
  # COPIED, not symlinked: the beside-the-library probe resolves the mapping's BACKING file, and a
  # symlink's backing file is the shim package's own store path — where no settings live. The copy costs
  # ~9 MiB per DLC selection (identical copies hardlink under auto-optimise) and is what lets the probe
  # land here.
  #
  # `null` for a backend with no preload at all (wine, served entirely by `mirror`): the root `.so` is
  # stray there, and emitting it anyway would pull a whole foreign-ABI shim — cross toolchain, static
  # protobuf and all — into a pure-wine game's closure to place a file nothing ever opens.
  shim ? null,
  # MIRRORS, for backends where the placement mechanism is UNION-REPLACEMENT rather than preload+binds
  # (wine: extraLowers outrank the payload, and the PE loader file-maps DLLs so the beside-the-library
  # probe just works): `{ "<game-dir-relative shipped lib path>" = <replacement lib>; }`. Each entry
  # materializes the replacement lib AT that path with `steam_settings/` + `steam_interfaces.txt` copied
  # beside it — so unioning this tree over the game replaces the lib and seats its settings in one move.
  mirror ? { },
  # The STEAMSTUB arm of the same placement, keyed by the SAME paths as `mirror`:
  # `{ "<path>" = { proxy; realName; extra; extraName; }; }`. A path that appears here gets THREE files in
  # its directory instead of one — the proxy AT the shipped path, the gbe_fork lib under `realName` (the
  # proxy's forwarder target), and `extra` under `extraName` (gbe_fork's in-memory SteamStub patcher) —
  # because a SteamStub-wrapped exe never asks the on-disk steam lib anything. The whole argument, with the
  # relay measurements behind it, is in emulators/gbe-fork/steamstub-proxy.nix; this builder only places
  # the files. Unset (the default) leaves every mirror as the plain one-file replacement.
  stubProxies ? { },
  # Whether the shim should PRETEND THE STEAM CLIENT IS IN OFFLINE MODE (`[main::connectivity] offline`).
  # `true` matches the module default; see `mainIni` below for what the key actually reaches.
  steamOffline ? true,
  scanner,
  scanJobs,
  # gbeFork.interfaceOracle: asks the pinned shim, by running it, whether it serves a revision. The
  # compat gate below is its verdict, not a grep over the source — see the oracle's own header.
  oracle,
  # Revisions the shipped libraries NAME but this game is known never to REQUEST (steam.emu.neverRequested):
  # the oracle's "not served" for these is tolerated rather than fatal. The claim is the game module's.
  neverRequested ? [ ],
  # Whether the ROOT list — the tree-root `steam_settings/steam_interfaces.txt` — is the one list EVERY
  # guest process reads. True for the guest-loader thin backends, where the lookup never reaches a declared
  # path's directory: FEX's guest ld.so resolves the preloaded root copy (the bind at the declared path is
  # that same inode, so it dedups to the preload), and box64 resolves the CWD, the game root. There every
  # required-flavour lib must name the same revisions, since one file serves them all. False where the
  # loader reads the list beside the library it actually loaded (wine's mirrors, native's binds): then only
  # libs SHARING a directory must agree, and libs in different directories may differ — Baldur's Gate 3
  # ships `bin/steam_api64.dll` and `Launcher/steam_api64.dll` from different SDK releases.
  preloadRoot ? false,
  pname ? "steam-offline-entitlement",
}:
let
  # `<appid>=<name>` per line under `[app::dlcs]`, in attr-name order (Nix attrsets iterate name-sorted,
  # so the output is deterministic). `#` and `;` start INI comments upstream, so strip them from titles
  # rather than emit a line that silently parses as one.
  dlcLine =
    n: e: "${toString e.appId}=${lib.replaceStrings [ "#" ";" "\n" ] [ "" "" " " ] (e.title or n)}";
  # The DLC entitlement config (gbe_fork dialect). `unlock_all=0` is stated EXPLICITLY every time — the
  # upstream default is 1 — followed by the owned list; see the header for why this is always emitted.
  appIni = lib.concatMapStrings (l: "${l}\n") (
    [
      "[app::dlcs]"
      "unlock_all=0"
    ]
    ++ lib.mapAttrsToList dlcLine dlc
  );
  # Report the client as offline (the gbe_fork spelling of the ancestor's `offline.txt`).
  #
  # WHAT THIS KEY ACTUALLY REACHES — measured in the pinned source, because the name overpromises and an
  # earlier revision of this comment claimed it meant "nothing reaches for the network or a lobby". It does
  # not. `[main::connectivity] offline` is read once (dll/settings_parser.cpp: `steam_offline_mode`) into
  # `Settings::offline`, and `Settings::is_offline()` has exactly THREE call sites in the whole tree, all in
  # dll/steam_user.cpp:
  #
  #     BLoggedOn()      → `return !settings->is_offline();`            → false
  #     BConnected()     → `return !settings->is_offline();`            → false
  #     GetLogonState()  → k_ELogonStateNotLoggedOn instead of …LoggedOn
  #
  # Nothing else consults it. The shim's actual network behaviour is governed by the separate
  # `disable_networking` / `disable_lan_only` keys, which we leave at their defaults either way — so this
  # key is a pure STATEMENT ABOUT LOGON STATE, not a network switch. Upstream's own documentation of it
  # (post_build/steam_settings.EXAMPLE/configs.main.EXAMPLE.ini) says the same and cuts both ways:
  # "1=pretend steam is running in offline mode, mainly affects the function `ISteamUser::BLoggedOn()` /
  # Some games that connect to online servers might only work if the steam emu behaves like steam is in
  # offline mode".
  #
  # `1` stays the default because it is the honest answer for the offline-by-construction case this module
  # exists to serve: there IS no Steam session here, so a game that asks "am I logged on?" should be told
  # no. But a title whose boot links Steam to a second account system can read that "no" as "wait for the
  # client to come back" and sit there forever, which is why it is now a knob (`steam.emu.offline`) rather
  # than a constant — see pkgs/games/victoria-3, where flipping it alone turns "no log at all" into the
  # engine's full log set and a D3D11 device. (It is NOT a general cure for a title that stops at Steam
  # init, and the two cases look alike from the syscall side — both are wine's `server_select` waiting on a
  # `wake_up_reply` that never comes. pkgs/games/rust stops INSIDE `SteamAPI_Init`, before this key is ever
  # consulted, and flipping it there changes nothing; only a PE-level backtrace separates them.)
  mainIni = ''
    [main::connectivity]
    offline=${if steamOffline then "1" else "0"}
  '';
  # ── `steam_interfaces.txt` — WHICH INTERFACE REVISION THE LEGACY ACCESSORS HAND OUT ──────────────────
  # Point the legacy global accessors at the same interface revisions the modern
  # `SteamInternal_FindOrCreateUserInterface` path resolves, so both routes agree if a game uses each.
  #
  # NOT "harmless when unused" — an earlier revision of this comment said so, and pkgs/games/cities-skylines
  # is the measured counter-example. dll/dll.cpp holds one `old_<itf>[128]` string per interface, each
  # initialised to the version the shim was COMPILED against (`static char old_client[128] =
  # STEAMCLIENT_INTERFACE_VERSION;`), and dll/settings_parser.cpp's `try_parse_old_steam_interfaces_file()`
  # overwrites them from THIS FILE — matching a line to a slot by substring (`SteamClient` → CLIENT, …), so
  # a slot with no line here KEEPS the modern revision. `SteamClient()` then returns
  # `SteamInternal_CreateInterface(old_client)`, and dll/dll.cpp casts that to the REQUESTED version's class
  # (`ISteamClient001` … `ISteamClient017` … each a real, differently-shaped vtable).
  #
  # So the version named here IS the vtable layout the game gets. A game built against an older SDK walks
  # that pointer with ITS header's layout, and the two must agree slot-for-slot. Cities: Skylines (SDK 1.34,
  # `SteamClient017`) does not survive the disagreement: modern `ISteamClient` dropped
  # `GetISteamUnifiedMessages`, so 017's slot 25 lands on the shim's `GetISteamController`, which does not
  # recognise `STEAMUNIFIEDMESSAGES_INTERFACE_VERSION001` and calls
  # `report_missing_impl_and_exit()` — a MODAL "Missing interface" MessageBox followed by
  # `std::exit(0x4155149)`. OBSERVED, screenshotted, x86_64-linux 2026-09-03.
  #
  # The revisions are READ OUT OF THE GAME'S OWN SHIPPED LIBRARIES at build
  # time, which is the ground truth the paragraph above demands — upstream's generate_interfaces tool,
  # compiled from the pinned shim's source so its emission quirks (notably: several SteamClient revisions
  # collapse to 017, because modern steam_api's versionless SteamClient() still returns the 017 shape)
  # can never drift from the parser that reads the file. One scan per libPath; the results are placed
  # per-DIRECTORY — beside each lib AND inside that directory's own `steam_settings/`, because gbe_fork
  # reads `<module dir>/steam_settings/steam_interfaces.txt` FIRST and the beside-the-library copy only
  # when that is absent (dll/settings_parser.cpp parse_old_steam_interfaces). A per-directory list placed
  # beside the lib alone would be shadowed by the root list in the directory's settings copy.
  #
  # Two deliberate hard failures, both at BUILD time, both naming their remedy:
  #   * a REQUIRED-flavour lib that is missing, or two same-flavour scans that disagree where one file
  #     must stand for both: two libs sharing a directory, or — under `preloadRoot` — any two, since the
  #     root list is then the one every guest process reads. Otherwise libs in different directories may
  #     differ, each directory carrying its own list;
  #   * a scanned revision the pinned shim does NOT SERVE — asked of the shim itself through
  #     `oracle` — because at runtime that is a SILENT exit 73 (report_missing_impl_and_exit:
  #     0x4155149 & 0xFF) or a NULL vtable the moment the game asks for it, which is how factorio's
  #     2.1.2x SDK bump presented. Bump emulators/gbe-fork, or — when the game provably never asks
  #     (a library naming a family the game does not use) — declare it in `steam.emu.neverRequested`.
  scanned = runCommandLocal "${pname}-${toString appId}-interfaces" { } (
    ''
      set -euo pipefail
      mkdir -p "$out/by-dir" scans
    ''
    + lib.concatStrings (
      lib.imap0 (idx: job: ''
        # ── ${job.path} ──
        found=
        for c in ${lib.escapeShellArgs job.candidates}; do
          if [ -e "$c" ]; then found="$c"; break; fi
        done
        if [ -n "$found" ]; then
          d=$(mktemp -d)
          # Upstream exits 1 ("No interfaces were found") on a library naming NO revision — a stub, a
          # packed image, an empty placeholder. Name the file and the remedy rather than die on its
          # one-liner; a required-flavour lib the shim cannot be told about is the same wall as a
          # missing one.
          if ! (cd "$d" && ${scanner}/bin/generate_interfaces "$found" >/dev/null 2>"$d/err"); then
            echo "steam-offline-entitlement(${pname}): ${job.path} names no Steamworks interface revision (generate_interfaces: $(cat "$d/err"))." >&2
            ${
              if job.required then
                ''
                  echo "It is the flavour this backend loads, so the shim cannot be told which revisions to serve. If the file is not a real steam_api library, drop it from steam.emu.libPaths." >&2
                  exit 1
                ''
              else
                ''
                  echo "Not the flavour this backend loads; its directory gets the root list." >&2
                  : > "$d/steam_interfaces.txt"
                ''
            }
          fi
          awk '!seen[$0]++' "$d/steam_interfaces.txt" > "scans/${toString idx}"
          echo "${job.path}: $(grep -c . "scans/${toString idx}") revisions (from $found)"
        ${
          if job.required then
            ''
                            else
                              echo "steam-offline-entitlement(${pname}): no payload of this build carries ${job.path}," >&2
                              echo "so its interface revisions cannot be scanned. Candidates probed:" >&2
                              printf '  %s
              ' ${lib.escapeShellArgs job.candidates} >&2
                              echo "Fix the steam.emu.libPaths entry (the declared path must exist in the payloads of its own flavour)." >&2
                              exit 1
                            fi
            ''
          else
            ''
              fi
            ''
        }
      '') scanJobs
    )
    + ''
              # The ROOT list — what the tree-root `steam_settings/steam_interfaces.txt` carries. It is read by a
              # lib loaded FROM the root: a declared root-level path, and under `preloadRoot` every guest process
              # (see that argument). So the scans that must agree here are the root directory's own required
              # group, or under `preloadRoot` every required scan. With nothing loaded from the root the file is
              # unread; it then carries the first required scan (else any scan, else nothing) so it is never absent.
              # Agreement is of SETS: the scanner lists revisions in the order the strings sit in each
              # image, and a 32- and a 64-bit build of one SDK can differ there without differing at all.
              same_set() { cmp -s <(sort -u "$1") <(sort -u "$2"); }
              root=
              for i in ${lib.escapeShellArgs (map (j: toString j.i) rootAgreeIdx)}; do
                [ -e "scans/$i" ] || continue
                if [ -z "$root" ]; then
                  root="scans/$i"
                elif ! same_set "$root" "scans/$i"; then
                  echo "steam-offline-entitlement(${pname}): the shipped steam_api libraries of this build's own flavour disagree about their SDK revisions:" >&2
                  diff "$root" "scans/$i" >&2 || true
                  ${
                    if preloadRoot then
                      ''
                        echo "This backend preloads ONE shim copy into every guest process, which reads ONE list (the root steam_settings/steam_interfaces.txt), so it cannot serve both. Declare in steam.emu.libPaths only the library the game process itself loads — a launcher's or tool's copy from another SDK must not be listed for a guest-loader backend." >&2
                      ''
                    else
                      ''
                        echo "Both sit at the game root, where one steam_interfaces.txt stands for every lib (gbe_fork reads one file per directory, with no override); such a payload cannot be served as laid out." >&2
                      ''
                  }
                  exit 1
                fi
              done
              if [ -z "$root" ]; then
                for i in ${lib.escapeShellArgs (map (j: toString j.i) (requiredIdx ++ indexed))}; do
                  [ -e "scans/$i" ] && { root="scans/$i"; break; }
                done
              fi
              if [ -n "$root" ]; then
                cp "$root" "$out/root.txt"
              else
                echo "steam-offline-entitlement(${pname}): no steam_api library was scanned; the root interface list is empty (gbe_fork's built-in defaults apply)"
                : > "$out/root.txt"
              fi

              # Per-DIRECTORY placement. gbe_fork reads ONE steam_interfaces.txt per directory and offers no
              # other location — the lookup is hard-wired to beside-the-loaded-library (+ its steam_settings/),
              # settings_parser.cpp parse_old_steam_interfaces; no environment override exists (local_storage's
              # only getenv calls are XDG_DATA_HOME/HOME, for saves). So when a .so and a .dll share a
              # directory, the file is resolved BY FLAVOUR AT EVAL TIME instead: this entitlement is built per
              # resolved config, so the flavour this backend actually loads (`required`) wins the directory —
              # the other flavour's lib is never loaded by this backend, and on thin the per-path BIND rows
              # override the merged view besides. Agreement is enforced only WITHIN the consumed flavour
              # (steam_api.dll + steam_api64.dll sharing a dir must agree); a directory holding only the other
              # flavour gets that flavour's own scan, or the root list when these payloads do not carry it.
              ${lib.concatStrings (
                lib.mapAttrsToList (dir: grp: ''
                  best=
                  for i in ${lib.escapeShellArgs grp.req}; do
                    [ -e "scans/$i" ] || continue
                    if [ -z "$best" ]; then
                      best="scans/$i"
                    elif ! same_set "$best" "scans/$i"; then
                      echo "steam-offline-entitlement(${pname}): two shipped steam_api libraries of this build's own flavour share the directory '${dir}' but disagree about their SDK revisions; gbe_fork reads ONE steam_interfaces.txt per directory, with no override — such a payload cannot be served as laid out." >&2
                      exit 1
                    fi
                  done
                  if [ -z "$best" ]; then
                    for i in ${lib.escapeShellArgs grp.other}; do
                      [ -e "scans/$i" ] && { best="scans/$i"; break; }
                    done
                  fi
                  install -Dm444 "''${best:-$out/root.txt}" "$out/by-dir/${dir}/steam_interfaces.txt"
                '') jobDirs
              )}

              # The compat gate: every scanned revision must be SERVED by the pinned shim — asked of the shim
              # itself (the oracle runs it; "exit73" is report_missing_impl_and_exit, "null" a NULL vtable —
              # either kills the game the moment it asks). Tolerated only when the game declares it never asks.
              revs=$(cat scans/* | sort -u | grep . || true)
              unknown=
              if [ -n "$revs" ]; then
                # shellcheck disable=SC2086
                verdicts=$(${oracle}/bin/gbe-interface-oracle $revs) || [ $? -eq 1 ] || { echo "steam-offline-entitlement(${pname}): the interface oracle failed to run (see above)" >&2; exit 1; }
                while IFS=$'\t' read -r v verdict; do
                  [ "$verdict" = served ] && continue
                  case " ${lib.concatStringsSep " " neverRequested} " in
                    *" $v "*) echo "$v: not served by the pinned gbe_fork ($verdict) — tolerated, steam.emu.neverRequested says the game never asks" ;;
                    *) unknown="$unknown $v($verdict)" ;;
                  esac
                done <<<"$verdicts"
              fi
              if [ -n "$unknown" ]; then
                echo "steam-offline-entitlement(${pname}): this game's Steamworks SDK names interface revisions the pinned gbe_fork (${scanner.version or "?"}) does not serve:" >&2
                printf '  %s
      ' $unknown >&2
                echo "At runtime that is a silent exit 73 (or a NULL vtable) the moment the game asks for one. Bump emulators/gbe-fork — or, if the game provably never asks (a family it does not use), declare it in steam.emu.neverRequested with the evidence." >&2
                exit 1
              fi
    ''
  );
  # The scan jobs by index; the required-flavour ones; the ones whose agreement the root list demands (see
  # `preloadRoot`); and the per-directory index groups.
  indexed = lib.imap0 (i: job: {
    inherit i;
    inherit (job) path required;
  }) scanJobs;
  requiredIdx = lib.filter (j: j.required) indexed;
  rootAgreeIdx =
    if preloadRoot then requiredIdx else lib.filter (j: builtins.dirOf j.path == ".") requiredIdx;
  jobDirs = lib.foldl' (
    acc: j:
    let
      parent = builtins.dirOf j.path;
      slot = if j.required then "req" else "other";
      cur =
        acc.${parent} or {
          req = [ ];
          other = [ ];
        };
    in
    if parent == "." then
      acc
    else
      acc
      // {
        ${parent} = cur // {
          ${slot} = cur.${slot} ++ [ (toString j.i) ];
        };
      }
  ) { } indexed;

in
runCommandLocal "${pname}-${toString appId}"
  {
    inherit appIni mainIni;
    passAsFile = [
      "appIni"
      "mainIni"
    ];
    meta.description = "Offline Steam entitlement shim + settings for owned, already-decrypted DLC of app ${toString appId}";
  }
  ''
    set -euo pipefail
    install -d "$out/steam_settings"
    cd "$out"
    ${lib.optionalString (shim != null) "cp ${shim} libsteam_api.so"}
    # Both spots: inside steam_settings/ (gbe_fork's documented location) AND beside the lib (the
    # ancestor's spot; the root-level placements and the CWD-probe fallback read this copy).
    cp ${scanned}/root.txt steam_interfaces.txt
    cp steam_interfaces.txt steam_settings/steam_interfaces.txt
    # PER-DIRECTORY interface lists, one beside every declared libPath (gbe_fork reads the file beside
    # the library it was loaded as — each flavour gets the list scanned from ITS OWN lib, see `scanned`).
    cp -r --no-preserve=mode ${scanned}/by-dir/. .

    cd steam_settings
    printf '%s' ${lib.escapeShellArg (toString appId)} > steam_appid.txt
    cp "$mainIniPath" configs.main.ini
    # The entitlement list (`unlock_all=0` + owned rows). Written unconditionally — see the header — and
    # also what GetDLCCount()/BGetDLCDataByIndex() enumerate.
    cp "$appIniPath" configs.app.ini
    cd ..

    # PER-DIRECTORY settings: every directory holding a declared lib gets its own `steam_settings/` — the
    # root settings (appid, inis) with THAT directory's scanned list in place of the root one. This is the
    # copy gbe_fork reads first (`<module dir>/steam_settings/steam_interfaces.txt`, see `scanned`), so it
    # is what makes the per-directory lists real; wine's mirrors and the thin bind rows both resolve
    # `<dir>/steam_settings` here.
    ${lib.concatMapStrings (dir: ''
      install -d ${lib.escapeShellArg "${dir}/steam_settings"}
      cp --no-preserve=mode steam_settings/* ${lib.escapeShellArg "${dir}/steam_settings/"}
      cp --no-preserve=mode ${lib.escapeShellArg "${dir}/steam_interfaces.txt"} ${lib.escapeShellArg "${dir}/steam_settings/steam_interfaces.txt"}
    '') (lib.attrNames jobDirs)}


    # The union-replacement mirrors (see the `mirror` param): the replacement lib at the shipped path. Its
    # settings + interfaces were placed beside it above (the root ones for a root-level entry, the
    # directory's own otherwise).
    ${lib.concatStrings (
      lib.mapAttrsToList (
        p: replacement:
        let
          parent = builtins.dirOf p;
          # "" for a root-level entry, "<dir>/" otherwise — so the siblings below land beside the lib
          # whichever shape the declared path has.
          dir = if parent == "." then "" else "${parent}/";
          sp = stubProxies.${p} or null;
        in
        (
          if sp == null then
            ''
              install -Dm444 ${replacement} ${lib.escapeShellArg p}
            ''
          else
            # SteamStub: the PROXY takes the shipped name, the real shim moves one name over (the proxy's
            # forwarders name it), and the patcher joins them. All three must share a directory — the
            # proxy resolves its patcher off its OWN module path, and gbe_fork's beside-the-library probe
            # resolves `steam_settings/` off the shim's.
            ''
              install -Dm444 ${sp.proxy}/${sp.dllName} ${lib.escapeShellArg p}
              install -Dm444 ${replacement} ${lib.escapeShellArg "${dir}${sp.realName}"}
              install -Dm444 ${sp.extra} ${lib.escapeShellArg "${dir}${sp.extraName}"}
            ''
        )
      ) mirror
    )}
    echo "steam-offline-entitlement: app ${toString appId}, $(($(grep -c . steam_settings/configs.app.ini) - 2)) owned DLC, ${toString (lib.length (lib.attrNames mirror))} mirror(s)"
  ''
