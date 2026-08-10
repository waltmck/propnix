#!/usr/bin/env python3
"""Generate a DETERMINISTIC, code-signing-only certificate and its wine trust blob.

    ./mk-codesign-cert.py --subject-json subject.json --out DIR [--days 3650] [--seed HEX]

Writes into DIR: cert.crt (PEM), cert.key (PEM), cert.der, blob.hex, thumbprint.

Why deterministic
-----------------
propnix patches vendor binaries for compatibility, which breaks their Authenticode digests;
re-signing them needs a signing identity (see tools/wine-trust-cert.py for the trust side).
Generating that identity inside a nix derivation keeps the constraints legible and editable
in the expression, and keeps a private key out of git — but a randomly generated key in an
INPUT-ADDRESSED store path is a trap: the .drv hash is fixed while the contents are not, so
after a GC and rebuild the same store path can hold a different key while an already-built
payload still carries signatures from the old one. Trust anchor and signatures then
desynchronise silently.

So the key is derived from a seed instead. Three things must line up, and all three were
verified by building twice and comparing bytes:

  * RSA.generate(randfunc=...) from pycryptodome, fed an HMAC-SHA512 counter stream.
    OpenSSL cannot be used for this: its seed source calls getrandom(2), often via syscall()
    directly, so neither LD_PRELOAD path shims (libredirect) nor /dev/urandom redirection
    reach it, and its DRBG personalises with time/pid anyway.
  * A FIXED serial and FIXED validity dates. Any `now()` destroys reproducibility.
  * PKCS#1 v1.5 signing, which is deterministic. RSA-PSS is randomised and would defeat it.

Trade-off, stated plainly: deterministic means every build from the same inputs derives the
SAME key, so this is materially the same exposure as committing a key — it buys legibility
and reproducibility, not secrecy. Genuine per-user keys require generating outside the store
(state dir, mode 0600), which forces signing at runtime and a writable application
directory. That is a different design, not a tweak to this one.

Capabilities
------------
The certificate is issued, and then ASSERTED, to have exactly one power:

    basicConstraints critical CA:FALSE            not a CA
    keyUsage         critical digitalSignature    NO keyCertSign: cannot issue certificates
    extendedKeyUsage critical codeSigning         not usable for TLS, e-mail, anything else

nameConstraints is deliberately absent: RFC 5280 4.2.1.10 defines it as constraining subject
names in SUBSEQUENT certificates in a path, and it MUST appear only in a CA certificate. With
CA:FALSE and no keyCertSign there is nothing beneath this cert to constrain — issuance is
already impossible, which strictly dominates limiting issuance.

Nothing in X.509 restricts WHICH files a code-signing key may sign; no extension expresses
that. The only remaining lever is time, so keep --days short and do not add a timestamp
countersignature, letting signatures expire with the certificate.
"""

import argparse
import datetime
import hashlib
import hmac
import json
import os
import struct
import sys

try:
    from Crypto.PublicKey import RSA
except ImportError:
    sys.exit("needs pycryptodome (python3Packages.pycryptodome)")

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.x509.oid import NameOID
except ImportError:
    sys.exit("needs cryptography (python3Packages.cryptography)")

# Fixed epoch for notBefore. Not "now" — see the module docstring.
NOT_BEFORE = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)

OID_CODE_SIGNING = x509.ObjectIdentifier("1.3.6.1.5.5.7.3.3")

NAME_OIDS = {
    "C": NameOID.COUNTRY_NAME,
    "ST": NameOID.STATE_OR_PROVINCE_NAME,
    "L": NameOID.LOCALITY_NAME,
    "O": NameOID.ORGANIZATION_NAME,
    "OU": NameOID.ORGANIZATIONAL_UNIT_NAME,
    "CN": NameOID.COMMON_NAME,
}

# Wine trust-blob property ids; same format as tools/wine-trust-cert.py, whose output was
# cross-checked byte-for-byte against this one.
CERT_CERT_PROP_ID = 32
CERT_FIRST_USER_PROP_ID = 0x8000


def make_randfunc(seed: bytes):
    """Deterministic byte stream: HMAC-SHA512 in counter mode."""
    state = {"buf": bytearray(), "ctr": 0}

    def randfunc(n):
        while len(state["buf"]) < n:
            state["buf"] += hmac.new(
                seed, state["ctr"].to_bytes(8, "big"), hashlib.sha512
            ).digest()
            state["ctr"] += 1
        out = bytes(state["buf"][:n])
        del state["buf"][:n]
        return out

    return randfunc


def build_name(entries):
    attrs = []
    for e in entries:
        name = e["name"].upper()
        if name not in NAME_OIDS:
            sys.exit(f"unsupported subject attribute {name!r}; use one of {sorted(NAME_OIDS)}")
        attrs.append(x509.NameAttribute(NAME_OIDS[name], e["value"]))
    if not attrs:
        sys.exit("subject must have at least one attribute")
    return x509.Name(attrs)


def assert_capabilities(cert):
    """Refuse to emit anything with more power than intended."""
    bc = cert.extensions.get_extension_for_class(x509.BasicConstraints)
    ku = cert.extensions.get_extension_for_class(x509.KeyUsage)
    eku = cert.extensions.get_extension_for_class(x509.ExtendedKeyUsage)

    problems = []
    if bc.value.ca or not bc.critical:
        problems.append("basicConstraints must be critical CA:FALSE")
    if not ku.critical or not ku.value.digital_signature:
        problems.append("keyUsage must be critical and include digitalSignature")
    if ku.value.key_cert_sign or ku.value.crl_sign:
        problems.append("keyUsage must NOT include keyCertSign/cRLSign — it could mint identities")
    for bad in ("key_encipherment", "data_encipherment", "key_agreement", "content_commitment"):
        if getattr(ku.value, bad):
            problems.append(f"keyUsage must not include {bad}")
    if not eku.critical or list(eku.value) != [OID_CODE_SIGNING]:
        problems.append("extendedKeyUsage must be critical and codeSigning ONLY")
    if problems:
        sys.exit("certificate capability assertions failed:\n  " + "\n  ".join(problems))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--subject-json", required=True,
                    help='JSON list of {"name": "O", "value": "..."} in order')
    ap.add_argument("--out", required=True)
    ap.add_argument("--days", type=int, default=3650)
    ap.add_argument("--seed", default=None,
                    help="hex seed; default derives one from the subject so different "
                         "subjects get different keys")
    args = ap.parse_args()

    subject_entries = json.load(open(args.subject_json))
    canonical = json.dumps(subject_entries, sort_keys=True, separators=(",", ":")).encode()

    if args.seed:
        seed = bytes.fromhex(args.seed)
    else:
        seed = hashlib.sha256(b"propnix-codesign-v1|" + canonical).digest()

    key_obj = RSA.generate(2048, randfunc=make_randfunc(seed))
    key = serialization.load_pem_private_key(key_obj.export_key("PEM"), password=None)

    name = build_name(subject_entries)
    # Serial derived from the seed: deterministic, and distinct per subject. Positive and
    # under 20 octets, as RFC 5280 requires.
    serial = int.from_bytes(hashlib.sha256(b"serial|" + seed).digest()[:16], "big") >> 1

    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(serial)
        .not_valid_before(NOT_BEFORE)
        .not_valid_after(NOT_BEFORE + datetime.timedelta(days=args.days))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True, content_commitment=False, key_encipherment=False,
                data_encipherment=False, key_agreement=False, key_cert_sign=False,
                crl_sign=False, encipher_only=False, decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(x509.ExtendedKeyUsage([OID_CODE_SIGNING]), critical=True)
        # PKCS#1 v1.5 — deterministic. Do not switch to PSS.
        .sign(key, hashes.SHA256())
    )

    assert_capabilities(cert)

    der = cert.public_bytes(serialization.Encoding.DER)
    blob = (
        struct.pack("<III", CERT_FIRST_USER_PROP_ID, 1, 4) + struct.pack("<i", 0)
        + struct.pack("<III", CERT_CERT_PROP_ID, 1, len(der)) + der
    )
    thumb = hashlib.sha1(der).hexdigest().upper()

    os.makedirs(args.out, exist_ok=True)
    w = lambda n, b, mode=0o444: (
        open(os.path.join(args.out, n), "wb").write(b),
        os.chmod(os.path.join(args.out, n), mode),
    )
    w("cert.crt", cert.public_bytes(serialization.Encoding.PEM))
    w("cert.der", der)
    w("cert.key", key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ), 0o400)
    w("blob.hex", blob.hex().upper().encode())
    w("thumbprint", thumb.encode())

    print(f"subject    : {name.rfc4514_string()}")
    print(f"thumbprint : {thumb}")
    print(f"serial     : {serial:x}")
    print(f"validity   : {NOT_BEFORE.date()} .. {(NOT_BEFORE + datetime.timedelta(days=args.days)).date()}")
    print(f"blob       : {len(blob)} bytes")
    print("capabilities: CA:FALSE, keyUsage=digitalSignature, EKU=codeSigning (all critical, asserted)")


if __name__ == "__main__":
    main()
