#!/usr/bin/env python3
"""Make a wine prefix trust a code-signing certificate.

    ./wine-trust-cert.py cert.crt                  # print blob hex + thumbprint
    ./wine-trust-cert.py cert.crt --reg            # print ready-to-run `wine reg add` lines
    ./wine-trust-cert.py cert.crt --apply          # run them against $WINEPREFIX

Why this exists
---------------
propnix patches vendor binaries for compatibility (16K-page section flags, EL0 PMU
instructions, ...). Any byte change breaks the file's Authenticode digest, and apps that
verify their own modules then complain — Zoom shows one modal per bad module and logs
`error code 2148098064` (0x80096010 TRUST_E_BAD_DIGEST). The fix is to re-sign the patched
file and make the prefix trust the signer, so the check genuinely passes instead of being
clicked away.

Re-signing itself is easy:

    osslsigncode sign -certs cert.crt -key cert.key -h sha256 -in x.dll -out x.dll.signed
    osslsigncode verify -CAfile cert.crt x.dll.signed     # expect "Signature verification: ok"

Installing the trust anchor is the part with no obvious route, because wine has no working
tool for it: `programs/certutil` implements only `-decodehex`, and `cryptext`'s PFX entry
points are stubs. So write the registry store directly — `dlls/crypt32/regstore.c` reads a
REG_BINARY `Blob` from a subkey named after the certificate's SHA1 thumbprint.

The blob is a sequence of property records (`dlls/crypt32/serialize.c`):

    struct { DWORD propID; DWORD unknown /* always 1 */; DWORD cb; } followed by cb bytes

Two records are required, and the second one is the trap:

  * CERT_CERT_PROP_ID (32)          — the DER-encoded certificate.
  * CERT_FIRST_USER_PROP_ID (0x8000) — an `int is_new`. NOT optional. wine's
    rootstore.c check_and_store_certs() reads it and `continue`s past any certificate that
    lacks it, logging
        err:crypt:check_and_store_certs CERT_FIRST_USER_PROP_ID property absent for cert
    A blob carrying only the certificate lands in system.reg/user.reg and is then silently
    ignored. Storing is_new = 0 marks it already-vetted so wine leaves it in place.

Measured result (Zoom 7.1.5, wine-staging 11.12): with the patched modules re-signed and
this blob installed, the app's verification error code went 2148098064 -> **0**, i.e.
WinVerifyTrust succeeds.

Limitation, worth knowing before relying on this
------------------------------------------------
This makes a signature VALID and TRUSTED. It does not make it belong to a particular
publisher. An app that pins its own publisher name will still reject the module even at
error code 0 — Zoom does exactly that (its binaries embed "Zoom Communications, Inc." and
compare against the signer's subject). Satisfying such a check would mean issuing a
certificate that claims to be that company, i.e. forging an organisational identity; don't.
For those apps, either leave the warning in place or reconsider whether the payload needs
patching at all.
"""

import argparse
import hashlib
import os
import struct
import subprocess
import sys

CERT_CERT_PROP_ID = 32
CERT_FIRST_USER_PROP_ID = 0x8000

STORES = ("Root", "TrustedPublisher")
ROOTS = ("HKLM", "HKCU")  # wine consults machine and user stores


def to_der(path):
    """Accept PEM or DER; return DER bytes."""
    raw = open(path, "rb").read()
    if raw.lstrip().startswith(b"-----BEGIN"):
        out = subprocess.run(
            ["openssl", "x509", "-in", path, "-outform", "DER"],
            capture_output=True,
        )
        if out.returncode:
            sys.exit(f"openssl could not read {path}:\n{out.stderr.decode()[:300]}")
        return out.stdout
    return raw


def record(prop_id, data):
    return struct.pack("<III", prop_id, 1, len(data)) + data


def build_blob(der):
    # Order is not significant to the reader (it searches by propID), but keep the marker
    # first so a hexdump makes the intent obvious.
    return record(CERT_FIRST_USER_PROP_ID, struct.pack("<i", 0)) + record(
        CERT_CERT_PROP_ID, der
    )


def reg_lines(thumb, blob_hex):
    for root in ROOTS:
        for store in STORES:
            key = rf"{root}\Software\Microsoft\SystemCertificates\{store}\Certificates\{thumb}"
            yield f'wine reg add "{key}" /v Blob /t REG_BINARY /d "{blob_hex}" /f'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cert", help="code-signing certificate, PEM or DER")
    ap.add_argument("--reg", action="store_true", help="print `wine reg add` commands")
    ap.add_argument("--apply", action="store_true", help="run them against $WINEPREFIX")
    args = ap.parse_args()

    der = to_der(args.cert)
    thumb = hashlib.sha1(der).hexdigest().upper()
    blob = build_blob(der)
    blob_hex = blob.hex().upper()

    if not (args.reg or args.apply):
        print(f"thumbprint : {thumb}")
        print(f"blob       : {len(blob)} bytes ({len(der)} of certificate)")
        print(f"blob.hex   : {blob_hex}")
        return

    cmds = list(reg_lines(thumb, blob_hex))
    if args.reg:
        for c in cmds:
            print(c)
        return

    prefix = os.environ.get("WINEPREFIX")
    if not prefix:
        sys.exit("--apply needs WINEPREFIX set")
    print(f"installing {thumb} into {prefix}", file=sys.stderr)
    env = dict(os.environ)
    # Headless, so wine cannot pop a dialog onto the user's desktop.
    env.pop("DISPLAY", None)
    env.pop("WAYLAND_DISPLAY", None)
    for c in cmds:
        subprocess.run(c, shell=True, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run("wineserver -w", shell=True, env=env)
    print("done — verify with: grep -c " + thumb + " $WINEPREFIX/*.reg", file=sys.stderr)


if __name__ == "__main__":
    main()
