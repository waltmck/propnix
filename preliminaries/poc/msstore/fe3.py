#!/usr/bin/env python3
"""
Spike: resolve a Microsoft Store package to a downloadable URL + verifiable hash,
anonymously, and fetch it.

This is a REVERSE-ENGINEERING SPIKE, in Python on purpose. PLAN's rule is Rust for
nontrivial helpers, and that still applies to the real implementation — but a protocol
spike wants a fast edit/run loop, and none of this was settled enough to port until now.

  ./fe3.py                       # resolve WhatsApp (default), print URLs, do not fetch
  ./fe3.py 9NKSQGP7F2NH          # resolve some other Store product id
  ./fe3.py 9NKSQGP7F2NH --fetch  # ...and download + verify the largest package

NO MICROSOFT CREDENTIALS ARE REQUIRED. An earlier draft of this spike concluded that
free apps were gated behind license acquisition, because the signed URLs 403'd. That was
wrong, and it was self-inflicted: the URLs are carried in SOAP XML as escaped text, so
`&amp;` has to be unescaped or the P2/P3/P4 query parameters silently fold into P1's
value and the signature is incomplete. See `_urls_of`.

Two services are involved, and the split matters:

  1. DisplayCatalog  (displaycatalog.mp.microsoft.com)
       PUBLIC, ordinary WebPKI TLS, no auth. Gives the product's marketing metadata, the
       architectures, and the WuCategoryId that step 2 needs as its input.

  2. FE3 delivery    (fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx)
       SOAP. Resolves the category id to actual files: names, sizes, SHA1 AND SHA256
       digests, framework dependencies, and short-lived signed download URLs.

       Its certificate chains to "Microsoft Update Secure Server CA 2.1", a PRIVATE
       Microsoft PKI which is in no public CA bundle (nor in nixpkgs' cacert) — so a
       default urllib client fails here with CERTIFICATE_VERIFY_FAILED.

       The fix is NOT verify=False. That root ("Microsoft Root Certificate Authority
       2011", SHA1 8F:43:28:8A:...:BC:FE, valid to 2036) is published and stable, and is
       vendored next to this file as msroot2011.pem — so the connection gets full chain
       validation AND hostname checking, just against a pinned private anchor instead of
       Mozilla's set. Measured: verification succeeds, TLS 1.3.

DO NOT use DisplayCatalog's SHA256 to verify FE3's bytes. An earlier draft of this file
proposed exactly that, reasoning that a hash obtained over verified WebPKI would let the
FE3 leg stay unverified. Both halves were wrong. The security half is moot now that FE3
is properly verified; the factual half is worse — the two services do not describe the
same build. Measured for WhatsApp on 2026-08-06:

    DisplayCatalog advertises  2.2629.0.0  and  2.2629.100.0
    FE3 actually serves        2.2630.1.0  and  2.2630.101.0

so the catalog hash matches nothing that can be downloaded. Integrity comes from FE3's
own digests over the pinned-root channel: size, SHA1 attribute, and a SHA256 in an
<AdditionalDigest> child. All three were verified against a full 355 MB download.
"""

import hashlib
import html
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

CATALOG = "https://displaycatalog.mp.microsoft.com/v7.0/products/{pid}?market=US&languages=en-US&fieldsTemplate=Details"
FE3 = "https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx"
WS = "http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService"

HERE = os.path.dirname(os.path.abspath(__file__))
MS_ROOT = os.path.join(HERE, "msroot2011.pem")

# Verified, not disabled — see module docstring. Hostname checking stays on.
_FE3_CTX = ssl.create_default_context(cafile=MS_ROOT)

DEVICE_ATTRS = (
    "BranchReadinessLevel=CB;CurrentBranch=rs_prerelease;OEMModel=;"
    "FlightRing=Retail;AttrDataVer=57;InstallLanguage=en-US;OSUILocale=en-US;"
    "InstallationType=Client;DeviceFamily=Windows.Desktop;"
)


def _now():
    return datetime.now(timezone.utc)


def _ts(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _security_header():
    """WS-Security header with an ANONYMOUS WindowsUpdateTicketsToken.

    A bare Timestamp is rejected with a:InvalidSecurity — the service wants a tickets
    token even for public catalog access. The MSA ticket is left empty, which is what
    makes this anonymous. Measured: empty <User/> -> 200; a bogus ticket body -> 400.
    So the ticket IS parsed and validated; "empty" is an accepted value, not a bypass.
    """
    created, expires = _now(), _now() + timedelta(minutes=5)
    return f"""<o:Security s:mustUnderstand="1"
      xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
      <Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
        <Created>{_ts(created)}</Created>
        <Expires>{_ts(expires)}</Expires>
      </Timestamp>
      <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA"
        xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
        xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">
        <TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"><User/></TicketType>
        <TicketType Name="AAD" Version="1.0" Policy="MBI_SSL"/>
      </wuws:WindowsUpdateTicketsToken>
    </o:Security>"""


def _envelope(action, body, secured=False):
    to = FE3 + ("/secured" if secured else "")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing"
            xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
    <a:Action s:mustUnderstand="1">{WS}/{action}</a:Action>
    <a:MessageID>urn:uuid:{uuid.uuid4()}</a:MessageID>
    <a:To s:mustUnderstand="1">{to}</a:To>
    {_security_header()}
  </s:Header>
  <s:Body>{body}</s:Body>
</s:Envelope>"""


def _post(xml, secured=False):
    url = FE3 + ("/secured" if secured else "")
    req = urllib.request.Request(
        url,
        data=xml.encode("utf-8"),
        headers={"Content-Type": "application/soap+xml; charset=utf-8"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60, context=_FE3_CTX) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def fault_of(xml):
    """Extract a SOAP 1.2 fault subcode/reason, or None if not a fault."""
    if "<s:Fault" not in xml and "<Fault" not in xml:
        return None
    sub = re.search(r"<s:Subcode>\s*<s:Value[^>]*>([^<]+)", xml)
    txt = re.search(r"<s:Text[^>]*>([^<]+)", xml)
    return (sub.group(1) if sub else "?", txt.group(1) if txt else "?")


def _check(xml, what):
    f = fault_of(xml)
    if f:
        raise SystemExit(f"{what}: SOAP fault {f[0]}: {f[1]}")
    return xml


# ---------------------------------------------------------------------------
# 1. DisplayCatalog — public, verified WebPKI, authoritative SHA256.
# ---------------------------------------------------------------------------
def catalog(pid):
    with urllib.request.urlopen(CATALOG.format(pid=pid), timeout=60) as r:
        d = json.load(r)
    out, seen = [], set()
    for sku in d["Product"].get("DisplaySkuAvailabilities", []):
        for pkg in sku.get("Sku", {}).get("Properties", {}).get("Packages", []):
            fd = pkg.get("FulfillmentData") or {}
            name = pkg.get("PackageFullName")
            if name in seen:
                continue  # the catalog repeats packages across SKU availabilities
            seen.add(name)
            out.append(
                {
                    "fullName": name,
                    "arch": pkg.get("Architectures"),
                    "format": pkg.get("PackageFormat"),
                    "size": pkg.get("MaxDownloadSizeInBytes"),
                    "hash": pkg.get("Hash"),
                    "hashAlgo": pkg.get("HashAlgorithm"),
                    "wuCategoryId": fd.get("WuCategoryId"),
                }
            )
    return out


# ---------------------------------------------------------------------------
# 2. GetCookie — no auth, but the tickets token above is mandatory.
# ---------------------------------------------------------------------------
def get_cookie():
    body = f"""<GetCookie xmlns="{WS}">
      <oldCookie/>
      <lastChange>2015-10-21T17:01:07.1472913Z</lastChange>
      <currentTime>{_ts(_now())}</currentTime>
      <protocolVersion>1.40</protocolVersion>
    </GetCookie>"""
    _, xml = _post(_envelope("GetCookie", body))
    _check(xml, "GetCookie")
    m = re.search(r"<EncryptedData>([^<]+)</EncryptedData>", xml)
    if not m:
        raise SystemExit("GetCookie: no EncryptedData in response")
    return m.group(1)


# ---------------------------------------------------------------------------
# 3. SyncUpdates, iterated to a fixpoint.
#
# The category id alone yields ZERO leaf updates. The service withholds any update whose
# non-leaf ancestors the client has not declared as already installed, so each call only
# reveals the next layer of the tree. Feed the numeric ids back as
# InstalledNonLeafUpdateIDs and call again until the <File> metadata appears.
#
# It is NOT two passes. Measured for WhatsApp, walking down from nothing:
#     round 1: sent   0 -> 55 UpdateInfo,  0 files, 110 new ids
#     round 2: sent 110 -> 30 UpdateInfo,  0 files,  60 new ids
#     round 3: sent 170 -> 25 UpdateInfo, 20 files
# An earlier draft hardcoded two rounds and appeared to work only because of the
# particular id set it happened to have; from a cold start two rounds return no files.
#
# Reference implementations (alt-app-installer et al.) instead ship a ~380-entry
# hardcoded snapshot of InstalledNonLeafUpdateIDs, which collapses this to one call.
# Discovering the tree per-request costs two extra round trips and is one fewer thing
# to go stale, which matters for something meant to keep working unattended.
# ---------------------------------------------------------------------------
def _sync_body(cookie, cat_id, nonleaf):
    ids = "".join(f"<int>{i}</int>" for i in nonleaf)
    return f"""<SyncUpdates xmlns="{WS}">
      <cookie>
        <Expiration>2050-01-01T00:00:00Z</Expiration>
        <EncryptedData>{cookie}</EncryptedData>
      </cookie>
      <parameters>
        <ExpressQuery>false</ExpressQuery>
        <InstalledNonLeafUpdateIDs>{ids}</InstalledNonLeafUpdateIDs>
        <OtherCachedUpdateIDs/>
        <SkipSoftwareSync>false</SkipSoftwareSync>
        <NeedTwoGroupOutOfScopeUpdates>true</NeedTwoGroupOutOfScopeUpdates>
        <FilterAppCategoryIds>
          <CategoryIdentifier><Id>{cat_id}</Id></CategoryIdentifier>
        </FilterAppCategoryIds>
        <TreatAppCategoryIdsAsInstalled>true</TreatAppCategoryIdsAsInstalled>
        <AlsoPerformRegularSync>false</AlsoPerformRegularSync>
        <ComputerSpec/>
        <ExtendedUpdateInfoParameters>
          <XmlUpdateFragmentTypes>
            <!-- Extended ALONE. Adding LocalizedProperties here makes the service
                 return the same 30 UpdateInfo blocks with NO <File> elements at all,
                 i.e. it substitutes rather than adds fragments. Measured. -->
            <XmlUpdateFragmentType>Extended</XmlUpdateFragmentType>
          </XmlUpdateFragmentTypes>
          <Locales><string>en-US</string><string>en</string></Locales>
        </ExtendedUpdateInfoParameters>
        <ClientPreferredLanguages><string>en-US</string></ClientPreferredLanguages>
        <ProductsParameters>
          <SyncCurrentVersionOnly>false</SyncCurrentVersionOnly>
          <DeviceAttributes>{DEVICE_ATTRS}</DeviceAttributes>
          <CallerAttributes>Interactive=1;IsSeeker=0;</CallerAttributes>
          <Products/>
        </ProductsParameters>
      </parameters>
    </SyncUpdates>"""


def _sync(cookie, cat_id, nonleaf):
    _, xml = _post(_envelope("SyncUpdates", _sync_body(cookie, cat_id, nonleaf)))
    return _check(xml, "SyncUpdates")


def sync_updates(cookie, cat_id, max_rounds=8, verbose=False):
    """Walk the update tree until the file metadata appears.

    Returns (leaves, unescaped_xml_of_the_final_round).
    """
    known, plain = set(), ""
    for rnd in range(1, max_rounds + 1):
        xml = _sync(cookie, cat_id, sorted(known))
        # The <Files>/<File> payload lives inside an ESCAPED fragment blob, hence the
        # unescape. Same class of bug as the URL one; escaped-XML-inside-XML is the theme.
        plain = html.unescape(xml)
        new = {int(i) for i in re.findall(r"<ID>(\d+)</ID>", xml)} - known
        if verbose:
            print(
                f"  round {rnd}: sent={len(known)} files={plain.count('<File ')} new={len(new)}",
                file=sys.stderr,
            )
        if "<File " in plain:
            break
        if not new:
            return [], plain  # tree exhausted with no files: not a downloadable app
        known |= new
    else:
        raise SystemExit(f"SyncUpdates: no files after {max_rounds} rounds")

    return _leaves_of(plain), plain


def _leaves_of(plain):
    """Join the two halves of a SyncUpdates response.

    The response carries what we need in two SEPARATE sections that share only a numeric
    id, which is the thing that makes this parse non-obvious:

      <NewUpdates><UpdateInfo>
          <ID>331796237</ID> ... <Xml>...<UpdateIdentity UpdateID=".." RevisionNumber=".."/>
      <ExtendedUpdateInfo><Updates><Update>
          <ID>331796237</ID><Xml><ExtendedProperties/><Files><File FileName=".." .../>

    GetExtendedUpdateInfo2 needs the (UpdateID, RevisionNumber) from the first; the
    filename, size and digests only exist in the second. An earlier draft looked for both
    inside one <UpdateInfo> and silently found nothing.
    """
    # id -> (UpdateID, RevisionNumber). Take the FIRST UpdateIdentity carrying a
    # RevisionNumber: later ones are prerequisite references, not this update's identity.
    identity = {}
    for blk in re.findall(r"<UpdateInfo>(.*?)</UpdateInfo>", plain, re.S):
        i = re.search(r"<ID>(\d+)</ID>", blk)
        ident = re.search(
            r'<UpdateIdentity\s+UpdateID="([^"]+)"\s+RevisionNumber="([^"]+)"', blk
        )
        if i and ident:
            identity[i.group(1)] = (ident.group(1), ident.group(2))

    leaves = []
    for blk in re.findall(r"<Update>(.*?)</Update>", plain, re.S):
        i = re.search(r"<ID>(\d+)</ID>", blk)
        fel = re.search(r"<File\s+([^>]*?)/?>", blk)
        if not (i and fel and i.group(1) in identity):
            continue
        # Attribute ORDER is not what it looks like — FileName precedes Digest — so pull
        # attributes into a dict rather than matching them positionally.
        at = dict(re.findall(r'(\w+)="([^"]*)"', fel.group(1)))
        # FE3 also carries a SHA256 in a child element, which is worth more than the SHA1
        # attribute: see the note in resolve() about the catalog disagreeing.
        sha256 = re.search(
            r'<AdditionalDigest\s+Algorithm="SHA256">([^<]+)</AdditionalDigest>', blk
        )
        uid, rev = identity[i.group(1)]
        leaves.append(
            {
                "updateId": uid,
                "revision": rev,
                "digest": at.get("Digest"),
                "digestAlgo": at.get("DigestAlgorithm"),
                "sha256": sha256.group(1) if sha256 else None,
                "fileName": at.get("FileName"),
                # The real package identity, including a version the catalog may not list.
                "identity": at.get("InstallerSpecificIdentifier"),
                "size": int(at["Size"]) if at.get("Size") else None,
            }
        )
    return leaves


# ---------------------------------------------------------------------------
# 4. GetExtendedUpdateInfo2 — the /secured endpoint, per leaf identity.
#    On the plain endpoint this returns InvalidParameters no matter what.
# ---------------------------------------------------------------------------
def _urls_of(xml):
    """Extract (url, sha1_b64) pairs from a GetExtendedUpdateInfo2 response.

    html.unescape is LOAD-BEARING. Without it every URL keeps its literal `&amp;`, so
    urllib sends `P1=...&amp;P2=404&amp;P3=2` — the server parses one parameter named P1
    whose value swallows the rest, treats P2/P3/P4 as absent, and 403s. That 403 is what
    an earlier draft of this file misread as a licensing gate.
    """
    out = []
    for blk in re.findall(r"<FileLocation>(.*?)</FileLocation>", xml, re.S):
        u = re.search(r"<Url>(.*?)</Url>", blk, re.S)
        d = re.search(r"<FileDigest>(.*?)</FileDigest>", blk, re.S)
        if u:
            out.append((html.unescape(u.group(1).strip()), d.group(1).strip() if d else None))
    return out


def file_urls(leaf):
    body = f"""<GetExtendedUpdateInfo2 xmlns="{WS}">
      <updateIDs>
        <UpdateIdentity>
          <UpdateID>{leaf['updateId']}</UpdateID>
          <RevisionNumber>{leaf['revision']}</RevisionNumber>
        </UpdateIdentity>
      </updateIDs>
      <infoTypes>
        <XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType>
        <XmlUpdateFragmentType>FileDecryption</XmlUpdateFragmentType>
      </infoTypes>
      <deviceAttributes>{DEVICE_ATTRS}</deviceAttributes>
    </GetExtendedUpdateInfo2>"""
    _, xml = _post(_envelope("GetExtendedUpdateInfo2", body, secured=True), secured=True)
    _check(xml, "GetExtendedUpdateInfo2")
    return _urls_of(xml)


def resolve(pid):
    """Full anonymous chain. Returns (catalog_packages, [leaf + {'url': ...}]).

    The leaves are NOT just the app: FE3 also returns its framework dependencies, each
    for every architecture. For WhatsApp that is 8 VCLibs .appx files plus 2 WhatsApp
    .msixbundle files. That dependency list is a genuinely useful side effect — it is the
    MSIX equivalent of a DT_NEEDED closure, published by the vendor rather than guessed.

    Note the catalog is only consulted for the WuCategoryId. Its hashes and versions
    describe a different build than FE3 serves; see the module docstring.
    """
    packages = catalog(pid)
    cat_id = next((p["wuCategoryId"] for p in packages if p["wuCategoryId"]), None)
    if not cat_id:
        raise SystemExit(f"{pid}: catalog has no WuCategoryId (not a Store app?)")

    leaves, _ = sync_updates(get_cookie(), cat_id, verbose=True)
    for leaf in leaves:
        # Each leaf yields several FileLocations (the package plus its block maps).
        # Match by the SHA1 digest rather than by URL length, which is what the
        # reference implementations do and which is fragile.
        for url, digest in file_urls(leaf):
            if digest == leaf["digest"]:
                leaf["url"] = url
                break
    return packages, leaves


# ---------------------------------------------------------------------------
# 5. Fetch and verify.
# ---------------------------------------------------------------------------
def fetch(url, dest, expect_size=None):
    sha1, sha256, n = hashlib.sha1(), hashlib.sha256(), 0
    with urllib.request.urlopen(url, timeout=120) as r, open(dest, "wb") as w:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            sha1.update(chunk)
            sha256.update(chunk)
            w.write(chunk)
            n += len(chunk)
            if expect_size:
                pct = 100.0 * n / expect_size
                print(f"\r  {n:,} / {expect_size:,} bytes ({pct:5.1f}%)", end="", file=sys.stderr)
    print(file=sys.stderr)
    import base64

    return {
        "size": n,
        "sha1_b64": base64.b64encode(sha1.digest()).decode(),
        "sha256_b64": base64.b64encode(sha256.digest()).decode(),
        "sha256_hex": sha256.hexdigest(),
        "sri": "sha256-" + base64.b64encode(sha256.digest()).decode(),
    }


def fetch_identity(pid, identity, dest):
    """Resolve, pick the leaf whose package identity is EXACTLY `identity`, fetch, verify.

    This is the entry point a fixed-output derivation wants: the URL is ephemeral so it
    cannot be pinned, but the (product id, identity) pair is stable and the bytes are
    checked against FE3's own digests before nix ever sees them.
    """
    _, leaves = resolve(pid)
    match = [l for l in leaves if l["identity"] == identity]
    if not match:
        have = "\n".join(f"    {l['identity']}" for l in leaves)
        raise SystemExit(
            f"no leaf with identity {identity!r}.\n"
            f"  FE3 currently offers:\n{have}\n"
            "  Store versions roll forward; update the pin."
        )
    leaf = match[0]
    if not leaf.get("url"):
        raise SystemExit(f"{identity}: resolved but no FileLocation matched its digest")

    got = fetch(leaf["url"], dest, leaf["size"])
    for label, want, have in (
        ("size", leaf["size"], got["size"]),
        ("sha1", leaf["digest"], got["sha1_b64"]),
        ("sha256", leaf["sha256"], got["sha256_b64"]),
    ):
        if want and want != have:
            raise SystemExit(f"{identity}: {label} mismatch: expected {want}, got {have}")
    print(f"  verified {identity}: {got['size']:,} bytes, {got['sri']}", file=sys.stderr)
    return got


if __name__ == "__main__":
    # FOD mode: --identity <exact package identity> --out <path>
    if "--identity" in sys.argv:
        a = sys.argv
        pid = a[1]
        identity = a[a.index("--identity") + 1]
        out = a[a.index("--out") + 1]
        fetch_identity(pid, identity, out)
        raise SystemExit(0)

    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    do_fetch = "--fetch" in sys.argv
    pid = argv[0] if argv else "9NKSQGP7F2NH"

    print(f"== 1. DisplayCatalog {pid}  (WebPKI verified) ==")
    packages, leaves = resolve(pid)
    for p in packages:
        print(f"  {p['fullName']}")
        print(f"    arch={p['arch']} fmt={p['format']} size={p['size']:,}")
        print(f"    {p['hashAlgo']}={p['hash']}")

    print(f"\n== 2-4. FE3  (pinned Microsoft Root CA 2011, anonymous) ==")
    print(f"  {len(leaves)} leaf update(s)")
    for leaf in leaves:
        got = "yes" if leaf.get("url") else "NO URL"
        size = f"{leaf['size']:,}" if leaf["size"] else "?"
        print(f"  {leaf['identity']}")
        print(f"    {leaf['fileName']}  size={size}  url={got}")
        print(f"    SHA1={leaf['digest']}  SHA256={leaf['sha256']}")

    biggest = max(
        (l for l in leaves if l.get("url") and l["size"]), key=lambda l: l["size"], default=None
    )
    if not biggest:
        raise SystemExit("no downloadable package resolved")
    print(f"\n  package: {biggest['fileName']}")
    print(f"  url:     {biggest['url'][:110]}...")

    if not do_fetch:
        print("\n(pass --fetch to download and verify)")
        raise SystemExit(0)

    dest = os.path.join(os.environ.get("TMPDIR", "/tmp"), biggest["fileName"])
    print(f"\n== 5. Fetch -> {dest} ==")
    got = fetch(biggest["url"], dest, biggest["size"])

    print("\n== Verify ==")
    checks = [
        ("FE3 size    ", biggest["size"], got["size"]),
        ("FE3 SHA1    ", biggest["digest"], got["sha1_b64"]),
        ("FE3 SHA256  ", biggest["sha256"], got["sha256_b64"]),
    ]
    # The catalog is a DIFFERENT channel describing a possibly different build, so this
    # line is informational — see the note below. Only compare if the versions agree.
    cat = next((p for p in packages if p["fullName"] == biggest["identity"]), None)
    if cat:
        checks.append(("catalog SHA256", cat["hash"], got["sha256_b64"]))
    for label, want, have in checks:
        mark = "OK      " if want == have else "MISMATCH"
        print(f"  {mark} {label}: expected {want} got {have}")
    if not cat:
        print(
            f"\n  NOTE: DisplayCatalog does not list {biggest['identity']} at all\n"
            f"        (it advertises {', '.join(p['fullName'].split('_')[1] for p in packages)});\n"
            "        the catalog SHA256 therefore cannot be used to verify these bytes."
        )
    print(f"\n  nix SRI: {got['sri']}")
