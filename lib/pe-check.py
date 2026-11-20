#!/usr/bin/env python3
"""pe-check.py <machine-decimal> <chpe: 0|1> <file>... — refuse a PE whose COFF machine is not the one
requested, or whose CHPE metadata presence does not match. The one output check every Windows PE this
repo builds runs (lib/win-toolchain.nix hands each target's expectation to its packages), independent of
which toolchain produced the file: a plain x64 PE where an ARM64EC one was meant would be the emulated
code the build exists to replace, and an ARM64EC PE where plain ARM64 was meant loads in no native
process — both silent at build time without this."""
import struct
import sys

MACHINES = {0x8664: "x86-64", 0x14C: "i386", 0xAA64: "ARM64", 0xA641: "ARM64EC"}


def check(path, want_machine, want_chpe):
    data = open(path, "rb").read()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe : pe + 4] != b"PE\0\0":
        return f"{path}: not a PE image"
    machine = struct.unpack_from("<H", data, pe + 4)[0]
    if machine != want_machine:
        return (
            f"{path}: COFF machine is {MACHINES.get(machine, hex(machine))}, "
            f"wanted {MACHINES.get(want_machine, hex(want_machine))}"
        )
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    chpe = False
    if magic == 0x20B:  # PE32+: the load-config directory may carry a CHPEMetadataPointer
        rva, size = struct.unpack_from("<II", data, opt + 112 + 10 * 8)
        if rva and size:
            nsec = struct.unpack_from("<H", data, pe + 6)[0]
            sect = opt + struct.unpack_from("<H", data, pe + 20)[0]
            for i in range(nsec):
                vsz, va, rsz, raw = struct.unpack_from("<IIII", data, sect + i * 40 + 8)
                if va <= rva < va + max(vsz, rsz):
                    off = raw + rva - va
                    cfg_size = struct.unpack_from("<I", data, off)[0]
                    # IMAGE_LOAD_CONFIG_DIRECTORY64.CHPEMetadataPointer sits at +0xC8.
                    if cfg_size > 0xC8 + 8:
                        chpe = struct.unpack_from("<Q", data, off + 0xC8)[0] != 0
                    break
    if chpe != want_chpe:
        return f"{path}: {'has' if chpe else 'has no'} CHPE metadata, {'expected none' if chpe else 'expected some'}"
    return None


def main():
    want_machine, want_chpe, files = int(sys.argv[1]), sys.argv[2] == "1", sys.argv[3:]
    bad = [e for e in (check(f, want_machine, want_chpe) for f in files) if e]
    for e in bad:
        print(f"pe-check: {e}", file=sys.stderr)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
