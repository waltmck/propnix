# Microsoft Store fetcher — protocol spike

**Verdict: feasible, anonymously, with no Microsoft credentials of any kind.**

```sh
./fe3.py                       # resolve WhatsApp, print files + URLs
./fe3.py 9WZDNCRFJ3TJ          # some other Store product id
./fe3.py 9NKSQGP7F2NH --fetch  # download the package and verify all three digests
```

Python on purpose: PLAN2's rule is Rust for nontrivial helpers, and that still holds for the
real implementation, but a protocol spike wants a fast edit/run loop. Nothing here was
settled enough to port until it worked end to end.

## What is proven

Fully verified on 2026-08-06 against `9NKSQGP7F2NH` (WhatsApp Desktop). (The measured FE3 facts are the
canonical record in RESEARCH §10; this table is the spike's self-contained summary.)

| Claim | Evidence |
|---|---|
| No Microsoft account, token, or client id is needed for a free app | the whole chain runs with an **empty** MSA ticket |
| Real bytes are reachable | full **355,089,031-byte** download completed |
| The bytes are verifiable | FE3's size, SHA1 **and** SHA256 all matched the download |
| The FE3 leg does **not** need `verify=False` | verified TLS 1.3 against a pinned Microsoft root |
| ARM64 Windows payloads are available this way | inner `WhatsApp.Root_2.2630.101.0_arm64.msix`, `WhatsApp.Root.exe` is PE machine **`0xaa64`** |
| Framework dependencies come for free | 8 VCLibs `.appx` (arm64/arm/x64/x86) alongside 2 WhatsApp bundles |

`WhatsApp.Root.exe` declares `EntryPoint="Windows.FullTrustApplication"`, i.e. a normal
Win32 app that merely ships as MSIX — the same shape as `slack-arm64.nix`, so the same
extract-and-run approach applies. It is .NET + WindowsAppSDK/WinUI (`coreclr.dll`,
`DWriteCore.dll`, `dcompi.dll`), which is a much heavier wine target than Slack's
Electron; whether it runs is an open question this spike does not answer.

## The chain

```
DisplayCatalog ──WuCategoryId──▶ GetCookie ──▶ SyncUpdates ×N ──▶ GetExtendedUpdateInfo2 ──▶ signed URL
  (public WebPKI)                └──────────── FE3, pinned Microsoft root ─────────────┘
```

1. **DisplayCatalog** `displaycatalog.mp.microsoft.com/v7.0/products/<pid>` — ordinary
   public JSON over ordinary TLS. Used **only** for the `WuCategoryId`.
2. **`GetCookie`** — returns a ~260-char `EncryptedData` cookie.
3. **`SyncUpdates`**, iterated (below).
4. **`GetExtendedUpdateInfo2`** on the **`/secured`** endpoint, once per leaf identity,
   returning several `FileLocation`s per leaf (the package plus its block maps).
5. **GET** the signed URL. `tlu.dl.delivery.mp.microsoft.com`, plain HTTP, `P1..P4` query
   parameters, expires in hours.

## Five things that each silently produce a wrong answer

Every one of these cost real time, and none of them fails loudly.

### 1. URLs must be HTML-unescaped

The single most expensive bug here. `FileLocation/Url` arrives as escaped text, so
`&amp;` must be unescaped or the request becomes

```
?P1=1786004692&amp;P2=404&amp;P3=2      →  params seen: ['P1', 'amp;P2', 'amp;P3', 'amp;P4']
```

The server parses **one** parameter whose value swallows the rest, considers P2/P3/P4
absent, and returns **403**. That 403 is what an earlier draft of this spike misread as
evidence that free apps are gated behind license acquisition — a conclusion that was
entirely an artifact of the bug. After `html.unescape`: `206`, `bytes 0-31/355088593`,
magic `PK`.

Escaped-XML-inside-XML is the recurring theme: the `<Files>` metadata in `SyncUpdates`
needs the same treatment.

### 2. `SyncUpdates` is a tree walk, not two passes

The category id alone yields **zero** files. The service withholds any update whose
non-leaf ancestors the client has not declared as installed, so each call reveals only
the next layer. Feed the numeric `<ID>`s back as `InstalledNonLeafUpdateIDs` and repeat:

```
round 1: sent   0 → 55 UpdateInfo,  0 files, 110 new ids
round 2: sent 110 → 30 UpdateInfo,  0 files,  60 new ids
round 3: sent 170 → 25 UpdateInfo, 20 files
```

An earlier draft hardcoded two rounds and appeared to work only because of the particular
id set it happened to be holding; from a cold start, two rounds return nothing. The
reference implementations dodge this by shipping a ~380-entry hardcoded snapshot of
`InstalledNonLeafUpdateIDs`; discovering it costs two extra round trips and cannot go
stale.

### 3. The response must be joined across two sections by numeric id

The identity `GetExtendedUpdateInfo2` needs and the file metadata are in *different*
sections that share only an integer:

```xml
<NewUpdates><UpdateInfo>
    <ID>331796237</ID> ... <UpdateIdentity UpdateID="…" RevisionNumber="…"/>
<ExtendedUpdateInfo><Updates><Update>
    <ID>331796237</ID><Xml>…<Files><File FileName="…" Digest="…" Size="…"/>
```

Looking for both inside one `<UpdateInfo>` finds nothing and raises no error. Also:
attribute order is not what it looks like (`FileName` precedes `Digest`), so parse
attributes into a dict rather than positionally.

### 4. `Extended` must be the *only* fragment type

Adding `LocalizedProperties` alongside `Extended` in `ExtendedUpdateInfoParameters`
returns the same 30 `UpdateInfo` blocks with **no `<File>` elements at all** — it
substitutes rather than adds. Measured.

### 5. DisplayCatalog and FE3 describe different builds

```
DisplayCatalog advertises  2.2629.0.0  and  2.2629.100.0    (size 354,987,964)
FE3 actually serves        2.2630.1.0  and  2.2630.101.0    (size 355,089,031)
```

So the catalog's SHA256 verifies nothing downloadable. An earlier draft proposed using it
as the pinned hash precisely so the FE3 leg could stay unverified; that plan fails on the
facts, independently of the security argument. Integrity comes from FE3's own digests
instead — `Size`, the `Digest` attribute (SHA1), and `<AdditionalDigest Algorithm="SHA256">`.

## TLS: pinned root, not disabled verification

`*.delivery.mp.microsoft.com` chains to **Microsoft Update Secure Server CA 2.1** →
**Microsoft Root Certificate Authority 2011**. That root is Microsoft's own PKI, not
WebPKI, so it is absent from Mozilla's bundle and from nixpkgs' `cacert` (checked:
`grep -c` returns 0), and a default client fails with
`unable to get local issuer certificate`.

Vendored as `msroot2011.pem` (Microsoft Root Certificate Authority 2011; its SHA1/SHA256/serial/validity
are in RESEARCH §10) — 2 KB of stable public data.

With that as the trust anchor, verification and hostname checking both pass normally
(TLS 1.3, `TLS_AES_256_GCM_SHA384`). This is strictly better than the `CERT_NONE` the
first draft used, and 2 KB of stable public data is a cheap thing to vendor. The download
URLs themselves are plain **HTTP**, which is fine — those bytes are hash-pinned.

## Anonymity is an accepted value, not a bypass

The WS-Security header must carry a `WindowsUpdateTicketsToken`; a bare `Timestamp` is
rejected with `a:InvalidSecurity`. The MSA ticket is left empty:

```xml
<TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"><User/></TicketType>
```

Measured: empty `<User/>` → **200**; a bogus ticket body → **400**. So the ticket is
parsed and validated, and "empty" is a value the service accepts for free content — this
is not a forged or borrowed credential. Paid or license-gated content was not tested and
should be assumed to need a real account.

## Not done

- Not ported to Rust. Not wired into a Nix FOD.
- No paid/licensed app tested — free apps only.
- URL expiry not handled; a real FOD must resolve at fetch time, not from a pinned URL.
  Only the **hash** is pinnable, which suits a fixed-output derivation well.
- No `.appx` → wine install path; `slack-arm64.nix`'s extract-and-run is the model.
- Whether WhatsApp's WinUI/.NET stack actually runs under wine on aarch64 is untested.
