#!/usr/bin/env python3
"""Predict whether a Windows payload can run under a given wine build — before packaging it.

    ./wine-import-triage.py <app-dir> [--wine <wine-store-path>] [--variant stable|unstable|staging]

Cross-checks every static import in the payload against the exports wine actually ships, and
reports what is missing. This is cheap (seconds) and it answers the question that otherwise
costs an afternoon of packaging: *is this app reachable at all?*

Why this exists. The WhatsApp PoC burned four experiments on DOTNET_ThreadPool_* knobs trying
to work around an abort, on the assumption that the CLR was the caller. It was not — the
importer was the app's own bundled WinUI. One run of this script would have identified the
caller immediately and skipped all four. See docs/verified/whatsapp-arm64.json.

How to read the output:

  * A missing import in the MAIN executable, or in a DLL the main executable imports
    statically, is fatal and no environment variable can fix it. Wine binds a missing static
    import to an aborting stub, so the DLL loads and then dies on first call.
  * A missing import in a lazily-loaded plugin is usually survivable — that feature breaks,
    the app still starts. Zoom ships three such gaps (screen capture, assistant, looper) and
    runs anyway.
  * `ntdll.Nt*WaitCompletionPacket` specifically means WinUI 3, which does not run under any
    current wine: implementing it needs a new wineserver object type. Treat it as a reject.

Also flags the 16K-page hazard, which is not an import problem at all but shows up in the same
sweep: a PE section that is WRITABLE **and** SHARED and is not aligned to the host page size
cannot be mapped by wine. It refuses rather than silently downgrading sharing to a private
copy (dlls/ntdll/unix/virtual.c). Note NT's 64K allocation granularity does not save you: it
aligns image *bases*, while the offending section sits at some 4K-aligned offset *inside* the
image. Windows on ARM64 uses 4K pages, so such binaries are perfectly valid there and only
break on a large-page Linux host.
"""

import argparse
import collections
import glob
import os
import struct
import subprocess
import sys

try:
    import pefile
except ImportError:
    sys.exit("needs pefile:  nix-shell -p python3Packages.pefile --run './wine-import-triage.py ...'")

SHARED, WRITE = 0x10000000, 0x80000000

# Imports that mean "this will not run", with the reason.
KNOWN_BLOCKERS = {
    "NtCreateWaitCompletionPacket": "WinUI 3 dispatcher; needs a new wineserver object type",
    "NtAssociateWaitCompletionPacket": "WinUI 3 dispatcher; needs a new wineserver object type",
    "NtCancelWaitCompletionPacket": "WinUI 3 dispatcher; needs a new wineserver object type",
}


def wine_exports(winedir):
    """{dll name (lower) -> set of exported names} for one wine build."""
    out = {}
    for f in glob.glob(os.path.join(winedir, "*.dll")):
        try:
            pe = pefile.PE(f, fast_load=True)
            pe.parse_data_directories(
                directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_EXPORT"]]
            )
            syms = {
                e.name.decode()
                for e in getattr(pe.DIRECTORY_ENTRY_EXPORT, "symbols", [])
                if e.name
            }
            out[os.path.basename(f).lower()] = syms
            pe.close()
        except Exception:
            pass
    return out


def machine_of(path):
    with open(path, "rb") as f:
        d = f.read(0x400)
    if d[:2] != b"MZ":
        return None
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    if d[pe : pe + 4] != b"PE\0\0":
        return None
    return struct.unpack_from("<H", d, pe + 4)[0]


def resolve_wine(variant, explicit):
    if explicit:
        return explicit
    attr = f"wineWow64Packages.{variant}"
    p = subprocess.run(
        ["nix-build", "<nixpkgs>", "-A", attr, "--no-out-link"],
        capture_output=True, text=True,
    )
    if p.returncode:
        sys.exit(f"could not build {attr}:\n{p.stderr.strip()[:400]}")
    return p.stdout.strip().splitlines()[-1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("appdir")
    ap.add_argument("--wine", help="wine store path (skips nix-build)")
    ap.add_argument("--variant", default="staging", choices=["stable", "unstable", "staging"])
    ap.add_argument("--arch", default="aarch64-windows")
    args = ap.parse_args()

    wine = resolve_wine(args.variant, args.wine)
    winedir = os.path.join(wine, "lib", "wine", args.arch)
    if not os.path.isdir(winedir):
        sys.exit(f"no such wine dll dir: {winedir}")
    exports = wine_exports(winedir)
    print(f"wine    : {os.path.basename(wine)}  ({len(exports)} dlls, {args.arch})")

    binaries = sorted(
        glob.glob(os.path.join(args.appdir, "*.exe")) + glob.glob(os.path.join(args.appdir, "*.dll"))
    )
    if not binaries:
        sys.exit(f"no .exe/.dll directly under {args.appdir}")

    missing = collections.defaultdict(set)      # dll -> {symbol}
    needed_by = collections.defaultdict(set)    # symbol -> {binary}
    unshareable, machines, scanned = [], collections.Counter(), 0

    for path in binaries:
        m = machine_of(path)
        if m is None:
            continue
        machines[m] += 1
        try:
            pe = pefile.PE(path, fast_load=True)
        except Exception:
            continue
        scanned += 1

        for s in pe.sections:
            ch = s.Characteristics
            if (ch & SHARED) and (ch & WRITE):
                unshareable.append((os.path.basename(path), s.Name.rstrip(b"\0").decode(), s.VirtualAddress))

        try:
            pe.parse_data_directories(
                directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_IMPORT"]]
            )
        except Exception:
            pe.close()
            continue
        for entry in getattr(pe, "DIRECTORY_ENTRY_IMPORT", []) or []:
            dll = entry.dll.decode().lower()
            if dll not in exports:
                continue          # app-private or an apiset: not wine's to provide
            for imp in entry.imports:
                if not imp.name:
                    continue
                name = imp.name.decode()
                if name not in exports[dll]:
                    missing[dll].add(name)
                    needed_by[name].add(os.path.basename(path))
        pe.close()

    names = {0x8664: "x86_64", 0xAA64: "ARM64", 0x14C: "i386", 0x1C0: "ARM"}
    arches = ", ".join(f"{names.get(m, hex(m))}x{c}" for m, c in machines.most_common())
    print(f"payload : {scanned} binaries ({arches})\n")

    verdict = "LIKELY RUNS"

    if missing:
        print("MISSING IMPORTS (wine-provided dlls only)")
        for dll, syms in sorted(missing.items()):
            for s in sorted(syms):
                blocker = KNOWN_BLOCKERS.get(s)
                mark = "  !! " if blocker else "     "
                print(f"{mark}{dll}.{s}")
                print(f"        needed by: {', '.join(sorted(needed_by[s]))}")
                if blocker:
                    print(f"        REJECT: {blocker}")
                    verdict = "WILL NOT RUN"
        if verdict != "WILL NOT RUN":
            verdict = "RUNS WITH FEATURES BROKEN"
        print("\n  Fatal only if the importer is loaded during startup. Check whether the main")
        print("  executable imports it statically, directly or transitively; a lazily-loaded")
        print("  plugin just loses its feature.\n")
    else:
        print("MISSING IMPORTS: none\n")

    host_page = os.sysconf("SC_PAGE_SIZE")
    if unshareable:
        print(f"WRITABLE+SHARED SECTIONS (host page size {host_page})")
        for name, sec, va in unshareable:
            ok = va % host_page == 0
            print(f"     {name}:{sec} VA=0x{va:06x} host-aligned={ok}")
            if not ok:
                print("        wine cannot map this: err:virtual:map_file_into_view")
                print("        unaligned shared mapping not supported -> import_dll fails")
                if verdict == "LIKELY RUNS":
                    verdict = "NEEDS 16K-PAGE FIXUP"
        print("\n  Options: run on a 4K-page host (or a 4K-page VM), or clear")
        print("  IMAGE_SCN_MEM_SHARED on the section. Clearing it BREAKS the file's")
        print("  Authenticode signature, which apps that verify their own DLLs will notice")
        print("  (Zoom shows an 'unknown publisher' dialog).\n")
    else:
        print(f"WRITABLE+SHARED SECTIONS: none (host page size {host_page})\n")

    print(f"VERDICT: {verdict}")


if __name__ == "__main__":
    main()
