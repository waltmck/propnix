#!/usr/bin/env python3
"""Emit a minimal STATIC Linux ELF for i386 or x86_64: write(1, msg, len) then exit(42).

Hand-assembled so the test depends on no toolchain, no libc, no loader and no rootfs — one PT_LOAD and
two syscalls. That matters for emulator bring-up: if a guest this small fails, the emulator is at fault,
with nothing else in the frame to blame. Exit status 42 is the signal, since 0 can arrive by accident.

Usage: mk_hello.py {i386|x86_64} <out>
"""
import struct, sys

arch, out = sys.argv[1], sys.argv[2]
MSG = f"fex-portable: {arch} guest alive\n".encode()

if arch == "i386":
    BASE, EHDR, PHDR = 0x08048000, 52, 32
    CODE_OFF = EHDR + PHDR

    def code(msg_addr, msg_len):
        return b"".join([
            b"\xb8" + struct.pack("<I", 4),          # mov $4,%eax     __NR_write
            b"\xbb" + struct.pack("<I", 1),          # mov $1,%ebx     fd
            b"\xb9" + struct.pack("<I", msg_addr),   # mov $msg,%ecx
            b"\xba" + struct.pack("<I", msg_len),    # mov $len,%edx
            b"\xcd\x80",                             # int $0x80
            b"\xb8" + struct.pack("<I", 1),          # mov $1,%eax     __NR_exit
            b"\xbb" + struct.pack("<I", 42),         # mov $42,%ebx
            b"\xcd\x80",                             # int $0x80
        ])

    msg_off = CODE_OFF + len(code(0, 0))
    body = code(BASE + msg_off, len(MSG)) + MSG
    total = CODE_OFF + len(body)
    ehdr = struct.pack("<16sHHIIIIIHHHHHH",
                       b"\x7fELF\x01\x01\x01" + b"\x00" * 9, 2, 3, 1,
                       BASE + CODE_OFF, EHDR, 0, 0, EHDR, PHDR, 1, 0, 0, 0)
    phdr = struct.pack("<IIIIIIII", 1, 0, BASE, BASE, total, total, 5, 0x1000)

elif arch == "x86_64":
    BASE, EHDR, PHDR = 0x400000, 64, 56
    CODE_OFF = EHDR + PHDR

    def code(msg_addr, msg_len):
        return b"".join([
            b"\x48\xc7\xc0" + struct.pack("<I", 1),   # mov $1,%rax     __NR_write
            b"\x48\xc7\xc7" + struct.pack("<I", 1),   # mov $1,%rdi     fd
            b"\x48\xbe" + struct.pack("<Q", msg_addr),# movabs $msg,%rsi
            b"\x48\xc7\xc2" + struct.pack("<I", msg_len),  # mov $len,%rdx
            b"\x0f\x05",                              # syscall
            b"\x48\xc7\xc0" + struct.pack("<I", 60),  # mov $60,%rax    __NR_exit
            b"\x48\xc7\xc7" + struct.pack("<I", 42),  # mov $42,%rdi
            b"\x0f\x05",                              # syscall
        ])

    msg_off = CODE_OFF + len(code(0, 0))
    body = code(BASE + msg_off, len(MSG)) + MSG
    total = CODE_OFF + len(body)
    ehdr = struct.pack("<16sHHIQQQIHHHHHH",
                       b"\x7fELF\x02\x01\x01" + b"\x00" * 9, 2, 62, 1,
                       BASE + CODE_OFF, EHDR, 0, 0, EHDR, PHDR, 1, 0, 0, 0)
    phdr = struct.pack("<IIQQQQQQ", 1, 5, 0, BASE, BASE, total, total, 0x1000)

else:
    raise SystemExit(f"unknown arch {arch!r}")

assert len(ehdr) == EHDR and len(phdr) == PHDR, (len(ehdr), len(phdr))
open(out, "wb").write(ehdr + phdr + body)
print(f"{out}: {arch}, {total} bytes, entry 0x{BASE + CODE_OFF:x}")
