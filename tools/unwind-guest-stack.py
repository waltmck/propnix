#!/usr/bin/env python3
"""Exact x86_64 stack unwinder for guest code running under FEX inside ARM64EC wine.

WHY THIS EXISTS: on aarch64-linux neither available debugger can produce a guest call stack. winedbg refuses
outright ("dwarf2_virtual_unwind mismatch in cpu") because it cannot unwind x86_64 guest frames from the
ARM64 side, and FEX's own documentation states you do not get clean backtraces and that recovery is expected
to happen offline in a reverse-engineering tool. The obvious workaround — scanning the stack for values that
look like code addresses — yields FALSE frames, because stale slots survive in dead frames; that produced two
wrong diagnoses before this tool existed. So this walks the real unwind data instead, exactly as Windows does.

    usage: unwind-guest-stack.py <pe-image> <log-with-capture>

INPUT comes from a capture hook in wine's UnhandledExceptionFilter (kernelbase) which prints:

    PROPNIX-CAP-REGS rip=.. rsp=.. rbp=.. rbx=.. rsi=.. rdi=.. r12=.. r13=.. r14=.. r15=..
    PROPNIX-CAP-STACK <absolute-addr> <hex bytes>          (repeated; any line width)

Note that wine hands the filter an ARM64 CONTEXT even for a guest x86_64 fault, so the hook must recover the
x64 register file through the ARM64EC mapping (Pc->RIP, Sp->RSP, X29->RBP, X27->RBX, X25/X26->RDI/RSI,
X19..X22->R12..R15) before printing it.

ALGORITHM (Microsoft x64 unwinding):
  * .pdata is a sorted array of RUNTIME_FUNCTION { BeginAddress, EndAddress, UnwindInfoAddress } (RVAs);
    binary-search it for the function containing RIP.
  * UNWIND_INFO := { u8 Version:3|Flags:5, u8 SizeOfProlog, u8 CountOfCodes,
                     u8 FrameRegister:4|FrameOffset:4, UNWIND_CODE[CountOfCodes],
                     [chained RUNTIME_FUNCTION when UNW_FLAG_CHAININFO] }
  * Replay the unwind codes to pop the frame, yielding the caller's RSP, the return address at [RSP], and any
    restored non-volatile registers. Repeat until control leaves the image or the captured stack runs out.
  * A leaf function has no .pdata entry: its return address is simply at [RSP].
"""

import bisect
import re
import struct
import sys

UWOP_PUSH_NONVOL, UWOP_ALLOC_LARGE, UWOP_ALLOC_SMALL, UWOP_SET_FPREG = 0, 1, 2, 3
UWOP_SAVE_NONVOL, UWOP_SAVE_NONVOL_FAR = 4, 5
UWOP_SAVE_XMM128, UWOP_SAVE_XMM128_FAR, UWOP_PUSH_MACHFRAME = 8, 9, 10

# UNWIND_CODE register numbers use the x64 encoding order.
REGS = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
        "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]


class Image:
    """A PE image, read for its sections and .pdata."""

    def __init__(self, path):
        self.raw = open(path, "rb").read()
        pe = struct.unpack_from("<I", self.raw, 0x3C)[0]
        nsec = struct.unpack_from("<H", self.raw, pe + 6)[0]
        optsz = struct.unpack_from("<H", self.raw, pe + 20)[0]
        self.base = struct.unpack_from("<Q", self.raw, pe + 24 + 24)[0]
        self.secs = []
        for i in range(nsec):
            o = pe + 24 + optsz + i * 40
            name = self.raw[o:o + 8].rstrip(b"\0").decode()
            vsz, va, rsz, rptr = struct.unpack_from("<IIII", self.raw, o + 8)
            self.secs.append((name, va, max(vsz, rsz), rptr))
        pdata = [s for s in self.secs if s[0] == ".pdata"]
        if not pdata:
            raise SystemExit(f"{path}: no .pdata — cannot unwind this image")
        self.pdata_off, self.pdata_n = pdata[0][3], pdata[0][2] // 12
        self.starts = [struct.unpack_from("<I", self.raw, self.pdata_off + i * 12)[0]
                       for i in range(self.pdata_n)]
        text = [s for s in self.secs if s[0] == ".text"]
        self.text_lo = self.base + text[0][1] if text else self.base
        self.text_hi = self.text_lo + (text[0][2] if text else 0)

    def at(self, rva, n):
        for _name, va, size, rptr in self.secs:
            if va <= rva < va + size:
                o = rptr + (rva - va)
                return self.raw[o:o + n]
        return b""

    def runtime_function(self, rva):
        i = bisect.bisect_right(self.starts, rva) - 1
        if i < 0:
            return None
        begin, end, unwind = struct.unpack_from("<III", self.raw, self.pdata_off + i * 12)
        return (begin, end, unwind) if begin <= rva < end else None


class Stack:
    """The captured stack slice, addressable by absolute guest address."""

    def __init__(self):
        self.chunks = []   # (addr, bytes), kept sorted

    def add(self, addr, data):
        self.chunks.append((addr, data))

    def finish(self):
        self.chunks.sort()
        self.addrs = [c[0] for c in self.chunks]

    def qword(self, addr):
        i = bisect.bisect_right(self.addrs, addr) - 1
        if i < 0:
            return None
        base, data = self.chunks[i]
        off = addr - base
        if 0 <= off and off + 8 <= len(data):
            return struct.unpack_from("<Q", data, off)[0]
        return None

    @property
    def size(self):
        return sum(len(d) for _a, d in self.chunks)


def unwind_frame(img, unwind_rva, regs, rsp, stack):
    """Replay one function's unwind codes; return the caller-side RSP, or None if unusable."""
    hdr = img.at(unwind_rva, 4)
    if len(hdr) < 4:
        return None
    ver_flags, _prolog, count, frame = hdr[0], hdr[1], hdr[2], hdr[3]
    if (ver_flags & 7) not in (1, 2):
        return None
    flags = ver_flags >> 3
    frame_reg, frame_off = frame & 0xF, (frame >> 4) * 16
    codes = img.at(unwind_rva + 4, count * 2)

    # With an established frame pointer, RSP is derived from it rather than tracked.
    if frame_reg:
        rsp = regs.get(REGS[frame_reg], rsp) - frame_off

    i = 0
    while i < count and (i + 1) * 2 <= len(codes):
        op_info = codes[i * 2 + 1]
        op, info = op_info & 0xF, op_info >> 4
        if op == UWOP_PUSH_NONVOL:
            val = stack.qword(rsp)
            if val is not None:
                regs[REGS[info]] = val
            rsp += 8
            i += 1
        elif op == UWOP_ALLOC_LARGE:
            if info == 0:
                rsp += struct.unpack_from("<H", codes, (i + 1) * 2)[0] * 8
                i += 2
            else:
                rsp += struct.unpack_from("<I", codes, (i + 1) * 2)[0]
                i += 3
        elif op == UWOP_ALLOC_SMALL:
            rsp += info * 8 + 8
            i += 1
        elif op in (UWOP_SET_FPREG,):
            i += 1
        elif op in (UWOP_SAVE_NONVOL, UWOP_SAVE_XMM128):
            i += 2
        elif op in (UWOP_SAVE_NONVOL_FAR, UWOP_SAVE_XMM128_FAR):
            i += 3
        elif op == UWOP_PUSH_MACHFRAME:
            rsp += 40 if info else 48
            i += 1
        else:
            return None

    if flags & 0x4:  # UNW_FLAG_CHAININFO — unwind the parent function as well
        chain = img.at(unwind_rva + 4 + ((count + 1) & ~1) * 2, 12)
        if len(chain) == 12:
            return unwind_frame(img, struct.unpack_from("<III", chain, 0)[2], regs, rsp, stack)
    return rsp


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__.strip().splitlines()[8].strip())
    img = Image(sys.argv[1])
    stack = Stack()
    regs, rip, rsp = {}, None, None

    for line in open(sys.argv[2], "rb"):
        s = line.decode("utf-8", "replace")
        m = re.search(r"PROPNIX-CAP-REGS (.*)$", s)
        if m:
            for k, v in re.findall(r"(\w+)=([0-9A-Fa-fx]+)", m.group(1)):
                regs[k] = int(v, 16)
            rip, rsp = regs.get("rip"), regs.get("rsp")
        m = re.search(r"PROPNIX-CAP-STACK ([0-9A-Fa-f]+) ([0-9a-f]+)", s)
        if m:
            stack.add(int(m.group(1), 16), bytes.fromhex(m.group(2)))
    stack.finish()

    if rip is None:
        raise SystemExit("no PROPNIX-CAP-REGS line in the log — the capture hook did not run")
    print(f"  fault rip={rip:#x} rsp={rsp:#x}   captured stack: {stack.size} bytes")
    print("  === guest call stack (exact, via .pdata) ===")

    for depth in range(64):
        rf = img.runtime_function(rip - img.base)
        where = f"  func {img.base + rf[0]:#x}..{img.base + rf[1]:#x}" if rf else "  [leaf/no unwind data]"
        print(f"    #{depth:<2} {rip:#014x}{where}")
        if rf is None:
            ret = stack.qword(rsp)
            if ret is None:
                print("       (return address beyond the captured stack — stopping)")
                break
            rip, rsp = ret, rsp + 8
        else:
            new_rsp = unwind_frame(img, rf[2], regs, rsp, stack)
            if new_rsp is None:
                print("       (unwind data unusable — stopping)")
                break
            ret = stack.qword(new_rsp)
            if ret is None:
                print("       (return address beyond the captured stack — stopping)")
                break
            rip, rsp = ret, new_rsp + 8
        if not (img.text_lo <= rip < img.text_hi):
            print(f"    #-- {rip:#014x}  [outside the image — stopping]")
            break


if __name__ == "__main__":
    main()
