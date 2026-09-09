# gen-def.py — emit a .def whose every entry is a PE FORWARDER to the same name in another module.
#
# Used by emulators/gbe-fork/steamstub-proxy.nix to make the proxy's Steamworks surface identical to the
# gbe_fork shim it is staged in front of, WITHOUT a checked-in symbol list that could silently drift from
# the pinned release (galaxy-stub can carry `symbols64.txt` because those symbols are the GAMES' imports,
# fixed by the SDK; here the surface is whatever the pinned shim exports).
#
# The export table is read straight out of the PE rather than shelled out to objdump/llvm-readobj: the
# parse is ~40 lines, and it keeps this derivation independent of which mingw toolchain the host leg picked
# (llvm-mingw on aarch64, nixpkgs' cross-GCC on x86_64 — see the .nix).
#
#   usage: gen-def.py <shim.dll> <forward-target-module-basename-without-.dll> <out.def>
import struct
import sys


def pe_export_names(path):
    d = open(path, "rb").read()
    if d[:2] != b"MZ":
        raise SystemExit(f"{path}: not a PE image (no MZ)")
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    if d[pe : pe + 4] != b"PE\0\0":
        raise SystemExit(f"{path}: not a PE image (no PE signature at e_lfanew)")
    coff = pe + 4
    nsec = struct.unpack_from("<H", d, coff + 2)[0]
    optsz = struct.unpack_from("<H", d, coff + 16)[0]
    opt = coff + 20
    magic = struct.unpack_from("<H", d, opt)[0]
    if magic not in (0x10B, 0x20B):
        raise SystemExit(f"{path}: unexpected optional-header magic {magic:#x}")
    # Data directory 0 = export table; it sits after the (differently sized) PE32/PE32+ optional header.
    ddir = opt + (0x70 if magic == 0x20B else 0x60)
    edir_rva, edir_size = struct.unpack_from("<II", d, ddir)
    if edir_rva == 0 or edir_size == 0:
        raise SystemExit(f"{path}: image has no export directory")

    sections = []
    sec0 = opt + optsz
    for i in range(nsec):
        b = sec0 + 40 * i
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", d, b + 8)
        # A section's mapped size is its virtual size, but an image whose VirtualSize is 0 (some linkers)
        # maps SizeOfRawData instead — take the larger so no RVA in range is missed.
        sections.append((vaddr, max(vsize, rawsize), rawptr))

    def off(rva):
        for vaddr, size, rawptr in sections:
            if vaddr <= rva < vaddr + size:
                return rawptr + (rva - vaddr)
        raise SystemExit(f"{path}: RVA {rva:#x} is outside every section")

    eo = off(edir_rva)
    n_names = struct.unpack_from("<I", d, eo + 24)[0]
    names_rva = struct.unpack_from("<I", d, eo + 32)[0]
    no = off(names_rva)
    out = []
    for i in range(n_names):
        p = off(struct.unpack_from("<I", d, no + 4 * i)[0])
        out.append(d[p : d.index(b"\0", p)].decode("ascii"))
    return out


def main():
    shim, target, outp = sys.argv[1], sys.argv[2], sys.argv[3]
    names = sorted(set(pe_export_names(shim)))
    # A shim with no exports would build a proxy that satisfies no import — a silent, load-time failure in
    # the game. Fail the build instead.
    if not names:
        raise SystemExit(f"{shim}: export table is empty")
    with open(outp, "w") as f:
        f.write("EXPORTS\n")
        for n in names:
            # MS .def forwarder syntax: `entry=module.entry`, module named WITHOUT the .dll suffix.
            f.write(f"  {n}={target}.{n}\n")
    print(f"steamstub-proxy: {len(names)} forwarders -> {target}.dll")


main()
