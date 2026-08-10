#!/usr/bin/env python3
# Extract all real object members of a GNU `ar` archive into a directory under UNIQUE names
# (dedupe by prefixing an index), skipping the special '/' (symbol map) and '//' (long-name
# table) members. Emits a MANIFEST of the extracted names in archive order.
#
# Why: llvm-mingw ships libclang_rt.builtins-{aarch64,x86_64}.a as ARM64X *hybrid* archives whose
# members appear TWICE under the same member name. When llvm-ar/llvm-ranlib rebuilds the symbol
# index over colliding member names it drops the ARM64EC ('#'-mangled) symbols (e.g.
# `#__chkstk_arm64ec`) and the x86_64 `___chkstk_ms`, so lld can't resolve them. Re-archiving the
# de-duplicated members with `llvm-ar rcs` produces an index that includes the EC symbols.
import sys, os

arc, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)
data = open(arc, 'rb').read()
assert data[:8] == b'!<arch>\n', 'not an ar archive'
pos = 8
longnames = b''
members = []  # (name, bytes)
while pos + 60 <= len(data):
    hdr = data[pos:pos + 60]
    name = hdr[0:16].decode('latin1').rstrip()
    size = int(hdr[48:58].decode('latin1').strip())
    body = data[pos + 60:pos + 60 + size]
    pos += 60 + size
    if pos % 2 == 1:
        pos += 1  # members are 2-byte aligned
    if name == '//':
        longnames = body
        continue
    if name in ('/', '/SYM64/', ''):
        continue  # symbol map — regenerated on re-archive
    if name.startswith('/') and name[1:].isdigit():  # GNU long-name reference '/<offset>'
        off = int(name[1:])
        end = longnames.find(b'\n', off)
        name = longnames[off:end].decode('latin1').rstrip('/')
    else:
        name = name.rstrip('/')
    members.append((name, body))

seen = {}
manifest = []
for name, body in members:
    base = os.path.basename(name)
    n = seen.get(base, 0)
    seen[base] = n + 1
    outname = base if n == 0 else f'{n:04d}_{base}'
    with open(os.path.join(outdir, outname), 'wb') as f:
        f.write(body)
    manifest.append(outname)

with open(os.path.join(outdir, 'MANIFEST'), 'w') as f:
    f.write('\n'.join(manifest) + '\n')
print(f'extracted {len(manifest)} members ({len(seen)} distinct basenames)')
