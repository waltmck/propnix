# propnix — update automation & pin format

Design for how propnix pins payloads (games + DLCs, across the GoG-Galaxy / GoG-offline / MS-Store
backends), auto-bumps them, and runs the bump in CI. Resolves the M1 investigation flagged in
`PLAN2.md §3.5`. Builds on measured facts in `RESEARCH.md` §7 (GoG fetch/credentials), §8 (MojoSetup
layout), §10 (MS-Store / FE3 delivery), §13 (FODs + CA certs). Values that require a credentialed run to
obtain are marked `‹placeholder›`; §6 separates what is mechanically certain from what needs a test.

---

## 1. Streaming-hash verdict — can we pin without storing the whole game?

| Backend | FOD hash mode | Pin *bump* without full download? | Peak disk to compute the pin |
|---|---|---|---|
| **`gog-offline-linux`** (`.sh` MojoSetup) | **flat** `sha256` (`.sh` never split at any size — assert `len(files)==1`, RESEARCH §7) | **Yes — O(1) stream.** `curl -L <signed-url> \| sha256sum`; disk + RAM constant whether 1.2 GB or 15.9 GB. GOG also publishes the whole-file MD5 in a few-KB `.xml` sidecar, but the Nix-preferred flat `sha256` needs one streaming pass. | **O(1)** streamed (else the full `.sh` landed, then `nix hash file`) |
| **`gog-galaxy-windows`** (gen-2 depot) | **recursive** NAR `sha256` | **No — must materialize.** A gen-2 build is many compressed depot chunks reassembled locally; there is **no whole-build/whole-game hash in the protocol** (only per-chunk MD5 and per-file MD5/SHA-256). The NAR hash (contents + sorted names + exec bit + symlink targets; mtimes/non-exec bits ignored) is **not derivable** from upstream hashes, so the whole tree must exist at once. | **≈ Σ `depot.size`** (assembled tree) + a bounded RAM chunk buffer |
| **`msstore`** (FE3 / MSIX) | **flat** `sha256`, per file | **Yes — zero bytes.** FE3 publishes the file's SHA256 **in standard base64, which is exactly the SRI hash body**: RESEARCH §10 measured `I/MVywKPAIYHPUYmIuhMgpo20O+AjInq5jBMKOiiz0s=`, and the pin is literally `outputHash = "sha256-I/MV…z0s="`. No credentials, no download. | **~0** (read from FE3 metadata) |

**Runner-sizing rule:** the two flat backends (Linux `.sh`, MS-Store) are size-independent to *pin* — they
run on the smallest runner even at 15.9 GB. Only **`gog-galaxy-windows`** is disk-bound, at ≈ the full
assembled game. `Σ depot.size` (assembled) and `Σ depot.compressedSize` (download volume) are both readable
from the unauthenticated repository manifest **before** downloading, so CI can size the runner up front.

**Authority note.** For a flat payload a streaming `sha256sum` equals the flat FOD `outputHash` after SRI
re-encoding (`nix hash convert --hash-algo sha256 --to sri <hex>`) — same bytes, same algorithm, only the
text encoding differs. For a recursive payload only the FOD itself (or `nix hash path` over the assembled
tree) is authoritative, because NAR canonicalization must be produced by the same builder. The pipeline
therefore treats **the FOD as the single source of truth for its own hash**, using streaming only as a
validated fast-path for flat backends.

**Lowering the Windows peak below full-game** (each is new code + a credentialed test, not adopted now):
(a) pin the *compressed* depot set (recursive hash of the chunk dir named by `compressedMd5`) and reassemble
in a downstream pure derivation — peak ≈ `Σ compressedSize` (~30–60% of assembled); or (b) pin a canonical
stream-assembled tar (deterministic headers, flat) through `sha256sum` — peak ≈ one chunk. Absent those, the
realistic minimum is the full assembled game.

---

## 2. Pin format

**Decision:** one **generated JSON lockfile per package** at `pkgs/games/<name>/versions.json` (reserved in
`PLAN2 §10`), read purely with `lib.importJSON`.

**Chosen over the alternatives, and why:**
- **`importJSON` lockfile beside a hand-authored expr** (chromium `upstream-info`, `sources.json` + `importJSON`) — **adopted**. Our pin has many hashes (base + N DLC × up to 3 backends) plus `{name,size,sha256}` arrays. JSON is machine-writable with `jq` keyed by an *attribute path* (never by text position), `lib.importJSON` reads it with no IFD, and canonical re-serialization (`jq -S` + trailing newline) gives deterministic no-op diffs.
- **Inline `version`/`hash` attrs** — **rejected**: fine for one hash, but a multi-hash file forces a fragile text/AST rewriter.
- **nvfetcher** — **rejected as the engine** (builtin fetchers only, resolved via `nix-prefetch*`; no credentialed custom FOD, no multi-part concat, no DLC overlay, no bad-credential `size` pre-check; would hash raw bytes, not our assembled tree). Only its *shape* is borrowed — a generated lockfile beside a config — except our config half *is* the Nix spec (`PLAN2 §4`), so there is no `sources.toml`.

**Schema.** Top level keyed by **backend**; each backend has a `fetcher` name and a `components` map
(`base`, `dlc:<slug>`, `dep:<slug>`, `extras:<slug>`). Every component that is a credentialed FOD carries
exactly one `outputHash` plus self-describing `outputHashMode`/`outputHashAlgo` (so a Tier-1 assert can check
`flat` ↔ `len(files)==1`). Downstream unpack / DLC-overlay-union / arch-selection derivations are ordinary
derivations and are **not** pinned.

- `gog-offline-linux`: `outputHashMode: "flat"`; one `.sh` row; `size` is the bad-credential pre-check (API `size` is wrong, RESEARCH §7); `gogBuildId` from `gameinfo` line 3 is the version authority (RESEARCH §8).
- `gog-galaxy-windows`: `outputHashMode: "recursive"`; keyed by immutable `buildId`; may record the repository-manifest MD5 as plain-string provenance — pinnable but *not* usable as the FOD hash.
- `msstore`: `outputHashMode: "flat"` per component; identity is FE3 `UpdateIdentity` + `InstallerSpecificIdentifier` (**not** DisplayCatalog — the two disagree, RESEARCH §10); each framework dependency is its own reusable `dep:<slug>` component.

### Concrete example — Stellaris + 2 DLC, two GoG backends

Measured-real: offline-Linux `version 4.4.6`, `gogBuildId 92219`, single 15.9 GB `.sh`, DLC are
collision-free directory overlays (RESEARCH §8). Hashes / Windows `buildId`s are `‹placeholder›`.

```json
{
  "schema": 1,
  "pname": "stellaris",
  "backends": {
    "gog-offline-linux": {
      "fetcher": "fetchGogOfflineInstaller",
      "components": {
        "base": {
          "kind": "game", "productId": "281308", "version": "4.4.6",
          "gogBuildId": "92219", "os": "linux",
          "files": [ { "fileId": "en3installer0", "name": "stellaris_4_4_6_92219.sh",
                       "size": 17066395297, "sha256": "sha256-‹BASE-SH›" } ],
          "outputHash": "sha256-‹BASE-SH›", "outputHashMode": "flat", "outputHashAlgo": "sha256"
        },
        "dlc:utopia": {
          "kind": "game", "productId": "1508702879", "version": "3.0.0", "os": "linux",
          "files": [ { "fileId": "en3installer0", "name": "stellaris_utopia_….sh",
                       "size": 78123456, "sha256": "sha256-‹UTO-SH›" } ],
          "outputHash": "sha256-‹UTO-SH›", "outputHashMode": "flat", "outputHashAlgo": "sha256"
        }
      }
    },
    "gog-galaxy-windows": {
      "fetcher": "fetchGogGalaxyBuild",
      "components": {
        "base": {
          "kind": "game", "productId": "281308", "version": "4.4.6",
          "buildId": "‹WIN-BASE-BUILDID›", "manifestId": "‹REPO-MANIFEST-MD5›",
          "os": "windows", "generation": 2,
          "outputHash": "sha256-‹WIN-BASE-TREE›", "outputHashMode": "recursive", "outputHashAlgo": "sha256"
        }
      }
    }
  }
}
```

The two Nix specs (a Linux and a Windows build are separate specs, `PLAN2 §1/§4`) each `importJSON` this one
file and read only their own backend key:

```nix
# pkgs/games/stellaris/linux.nix — pins feed a fetcher; its artifact is the wrapper's payload (PLAN2 §4)
let pins = (lib.importJSON ./versions.json).backends.gog-offline-linux; in
makeAppBox64 {
  pname = "stellaris"; inherit (pins.components.base) version;
  payload = fetchGogOfflineInstaller pins.components.base;
  dlc     = [ (fetchGogOfflineInstaller pins.components."dlc:utopia") ];
  # …tuning.nix, saveDir, exe…
}
```

### MS-Store shape (flat, per-file, credential-free) — WhatsApp `9NKSQGP7F2NH`

`outputHash` is the FE3 SHA256 verbatim as SRI (measured, RESEARCH §10); the framework closure is separate
`dep:` components, each its own flat FOD:

```json
"msstore": {
  "fetcher": "fetchMsStorePackage",
  "components": {
    "base": {
      "kind": "app", "productId": "9NKSQGP7F2NH", "version": "2.2630.101.0", "arch": "arm64",
      "updateId": "‹FE3-UpdateID-GUID›", "revisionNumber": 101,
      "installerSpecificIdentifier": "WhatsApp.Root_2.2630.101.0_arm64",
      "files": [ { "name": "WhatsApp…msixbundle", "size": 355089031,
                   "sha256": "I/MVywKPAIYHPUYmIuhMgpo20O+AjInq5jBMKOiiz0s=" } ],
      "outputHash": "sha256-I/MVywKPAIYHPUYmIuhMgpo20O+AjInq5jBMKOiiz0s=",
      "outputHashMode": "flat", "outputHashAlgo": "sha256"
    }
  }
}
```

**Awkward cases:** single-file Linux `.sh` → `len(files)==1`, `flat` asserted; DLC → first-class
`dlc:<slug>`, each its own FOD (independent version), composed downstream as a real-file overlay *union* (no
symlink farm — PhysFS crashes, RESEARCH §16; `find -type l` asserted empty); `extras`-only entitlements →
`kind:"extras"`, no `buildId`; MS-Store framework closure → per-file `dep:` FODs (dedup across apps);
rollback → write an older `{buildId|fileId, outputHash}` back, resolved from cache + the drop dir.

---

## 3. Fetchers

All three consume a component from `versions.json` and emit a store path; decoupled from the app builders
(`PLAN2 §3.4`).

| Fetcher | Version-pin vs hash-only | Single-file vs tree | Credentials |
|---|---|---|---|
| **`fetchGogGalaxyBuild`** (Windows / Route B) | **Version-addressable** — pins `{version; buildId; hash}`; `buildId` immutable and depot-addressable, GOG retains history to 2018. Clean-store rebuild of an old build works. | **Tree**, `outputHashMode = "recursive"`. Tool: **gogdl** (nixpkgs `gogdl` 1.2.2), not `lgogdownloader --galaxy-install` (shares the `std::out_of_range` bug). | Credentialed FOD (GOG token; `/propnix` bind, trusted user, RESEARCH §7) |
| **`fetchGogOfflineInstaller`** (Linux / Route A) | **Hash-only** — offline installers are latest-only (GOG overwrites the `fileId` slot); `version`/`gogBuildId` are provenance + a loud guard, not an addressable key. Old-build rebuild relies on the private cache. | **Single file**, `outputHashMode = "flat"`; `.sh` never split (assert `len==1`). Download verb `lgogdownloader --download-file` (the only measured-working GOG fetch); tree unpacked downstream. | Credentialed FOD (whole cred dir: `galaxy_tokens.json` + `cookies.txt` + `config.cfg`, RESEARCH §7) |
| **`fetchMsStorePackage`** (Store) | **Hash-only** — FE3 serves only the current approved revision (latest-only). DisplayCatalog's version is unusable for pinning bytes (describes a different build than FE3 serves); FE3's `InstallerSpecificIdentifier` + SHA256 is the authority. | **Single file**, `outputHashMode = "flat"` — each FE3 leaf is one self-contained ZIP, never split. Framework closure is *multiple* flat `dep:` FODs composed downstream; arch selection is extraction-time. | **None** for free apps (empty MSA ticket → 200). Needs `cacert` **and** the vendored `msroot2011.pem` as real store inputs (MS Root CA 2011 is in no public bundle, RESEARCH §13). |

The MS-Store resolver already exists as `poc/msstore/fe3.py` (`fetch_identity(pid, identity, out)`, the FOD
entry point) and handles the five silent-failure traps documented in `poc/msstore/README.md`; it ports to
Rust for production with `fe3.py` as the settled spec. Each fetcher joins the discovery ladder
(`PLAN2 §3.3`): store/cache → hash-keyed drop dir → network. The MS-Store step-3 branch is anonymous and its
failure mode is "identity rolled forward — update the pin," not GOG's "bad/expired credential."

---

## 4. updateScript — how a bump rewrites the pin file

**Outer contract:** a `passthru.updateScript` attrset (nixpkgs standard) shelling to one propnix tool,
`propnix-update`. Driven via `nix-update --use-update-script --flake games.stellaris` or the nixpkgs
`maintainers/scripts/update.nix` runner. `nix-update` is **not** the engine — its regex Nix rewriter cannot
disambiguate ~6 SRI hashes in one file, and its `src` model assumes a single builtin-fetcher upstream, not a
credentialed custom FOD.

```nix
passthru.updateScript = {
  command = [ (lib.getExe propnix-update) "--pin" (toString ./versions.json) ];
  supportedFeatures = [ "commit" ];   # one package may emit MULTIPLE commits (base + DLC + backends)
  attrPath = "games.stellaris";
};
```

**Algorithm** (`propnix-update --pin <file> [--component dlc:utopia] [--version-only] [--repin-only]`):

1. **Load** `versions.json`; capture `UPDATE_NIX_*` env.
2. **Metadata refresh — unauthenticated, no payload, per component:** GoG `api.gog.com/products/<id>?expand=downloads` (new version) + `content-system.gog.com/products/<id>/os/windows/builds?generation=2` (newest immutable `buildId`); offline → newest `fileId`/`name`/`size`; MS-Store FE3 `SyncUpdates` fixpoint + `GetExtendedUpdateInfo2` → identity + per-file SHA256+Size — **which is already the SRI body, so for MS-Store this step *is* the re-pin**. If nothing changed for a backend, skip it (deterministic no-op).
3. **Prime bytes once** (changed non-MS-Store components only): run the credentialed downloader into the hash-keyed drop dir.
4. **Re-pin `outputHash`:** flat (Linux `.sh`) → streaming `curl … | sha256sum` + `nix hash convert --to sri`, or `fakeHash` + `nix build --rebuild` (resolves bytes from the drop dir → no second download); recursive (Windows) → `fakeHash` + `nix build` (authoritative NAR), or `nix hash path`; MS-Store → FE3 base64 SHA256 verbatim.
5. **Write back** with `jq -S` (canonical, atomic temp-file rename).
6. **Verify:** `nix build` the real pin (from drop dir/store, no network) must be green; runs the Tier-1 asserts.
7. **Emit the `commit` JSON array** — one object per changed backend (`{attrPath, oldVersion, newVersion, files, commitMessage}`).

**Flags** mirror `nix-update`: `--version-only` (learn identity, don't fetch — a cheap CI drift check, and
the *whole* MS-Store re-pin), `--repin-only` (re-hash without a version bump), `--component` (scope to one
DLC/dep). **Prefetch tools are ruled out** (`nix-prefetch-url`, `nix store prefetch-file`, `nurl`): they
fetch outside the daemon FOD sandbox, cannot see the `/propnix` bind-mount or reproduce our builder, and
would hash the wrong bytes.

---

## 5. GitHub Actions — workflow skeleton (public / Pro repo)

**Honest runner limits (2026):** standard hosted runner ≈72 GB disk, **14 GB guaranteed free** (~19–22 GB
typical x64, **~45 GB on arm64**); `jlumbroso/free-disk-space` reclaims ~30 GB. Job time 6 h (not binding —
15.9 GB at 50–100 MB/s is minutes). **Larger runners (2 TB SSD) are Team/Enterprise-only — NOT on a Pro
personal account, never free even on public repos** — so "get a bigger disk" is off the table; self-hosted is
the real fallback. Public-repo standard **and** self-hosted minutes are free/unlimited; ingress is not
metered. `ubuntu-24.04-arm` (free, GA for public repos since 2025-08-07) is the default: native target arch
**and** the largest free disk.

**Consequence of §1:** flat/Linux and MS-Store bumps stream (size-independent, any runner). Only
`gog-galaxy-windows` is disk-bound → route to arm64 + cleanup; **BG3-class recursive titles exceed every
hosted runner → self-hosted.**

**Recommended split** (keeps the long-lived GOG credential off Azure infra, since update *detection* is fully
public): a **credential-free `discover` job** polls the public GOG/FE3 APIs and emits a matrix of stale
titles; a **credentialed `repin` job** in a protected Environment fills the hash — small titles on hosted
arm64, BG3-class on the user's self-hosted trusted machine (which also warms the private cache).

```yaml
name: repin-payloads
on:
  schedule: [ { cron: "0 6 * * 1" } ]   # weekly; NEVER pull_request/pull_request_target (fork exfil boundary)
  workflow_dispatch:
concurrency: { group: repin, cancel-in-progress: false }
permissions: { contents: read }        # elevate per-job only

jobs:
  discover:                             # credential-free: detect updates from PUBLIC APIs (200, no auth)
    runs-on: ubuntu-24.04-arm
    outputs: { matrix: "${{ steps.scan.outputs.matrix }}" }
    steps:
      - uses: actions/checkout@<SHA>                    # pin every action to a full commit SHA
      - uses: DeterminateSystems/nix-installer-action@<SHA>
      - id: scan
        run: ./ci/discover-updates.sh                   # emits [{title, backend, mode, runner}] for stale pins

  repin:                                # credentialed: fetch + hash the stale titles
    needs: discover
    if: needs.discover.outputs.matrix != '[]'
    environment: gog-fetch                              # protected env holds the secret (required reviewers)
    permissions: { contents: write, pull-requests: write }
    strategy:
      fail-fast: false
      matrix:
        include: "${{ fromJSON(needs.discover.outputs.matrix) }}"
        # flat / small-recursive -> runner: "ubuntu-24.04-arm"
        # BG3-class recursive     -> runner: ["self-hosted","linux","arm64","big"]  (ephemeral; trusted host)
    runs-on: "${{ matrix.runner }}"
    steps:
      - uses: actions/checkout@<SHA>
      - uses: DeterminateSystems/nix-installer-action@<SHA>
      - name: Free disk (hosted recursive only)
        if: matrix.mode == 'recursive' && !contains(matrix.runner, 'self-hosted')
        uses: jlumbroso/free-disk-space@<SHA>
      - name: Materialize GOG credential (never echoed, masked, off-repo)
        if: startsWith(matrix.backend, 'gog')           # msstore needs no credential
        env: { GOG_CRED_TAR_B64: "${{ secrets.GOG_CRED_TAR_B64 }}" }   # whole dir (§7 needs all three files)
        run: |
          set +x
          install -d -m700 "$RUNNER_TEMP/gogcred"
          printf '%s' "$GOG_CRED_TAR_B64" | base64 -d | tar -xC "$RUNNER_TEMP/gogcred"
      - name: Fetch + hash
        env: { GOG_CRED_DIR: "${{ runner.temp }}/gogcred", TITLE: "${{ matrix.title }}", MODE: "${{ matrix.mode }}" }
        run: |
          set -euo pipefail
          if [ "$MODE" = flat ]; then                   # Linux .sh / MS-Store: stream, O(1) disk
            url=$(./ci/resolve-signed-url.sh "$TITLE")
            sri=$(curl -fSL "$url" | sha256sum | cut -d' ' -f1 \
                  | xargs -I{} nix hash convert --hash-algo sha256 --to sri {})
          else                                          # Windows Galaxy: assemble+unpack tree, then NAR-hash
            ./ci/gogdl-install.sh "$TITLE" "$RUNNER_TEMP/tree"
            sri=$(nix hash path --type sha256 "$RUNNER_TEMP/tree")
          fi
          ./ci/write-pin.sh "$TITLE" "$sri"             # only the short hash string leaves the job
      - name: Cleanup (always)
        if: always()
        run: rm -rf "$RUNNER_TEMP/gogcred" "$RUNNER_TEMP/tree"   # NEVER upload-artifact the payload
      - uses: peter-evans/create-pull-request@<SHA>
        with: { branch: "repin/${{ matrix.title }}", title: "repin ${{ matrix.title }}" }
```

**Security invariants (all verified):** store the GOG credential as **one** secret
`base64(tar(whole-cred-dir))` (§7 needs all three files; `config.cfg`'s `directory = .` silently overrides
`--directory`, so force the output path) in a **protected Environment**, passed only via `env:` — never on a
command line or `echo`'d. **Trigger only `schedule`/`workflow_dispatch`** — fork PRs on public repos don't
receive secrets, which is the protection. **Pin every third-party action to a full commit SHA** — GOG does
not rotate refresh tokens, so a poisoned tag = full account compromise. **Never `upload-artifact` the
payload** (world-downloadable on a public repo, and non-redistributable) and delete it in `if: always()`.
Self-hosted runners on public repos are dangerous by default → gate on `github.repository_owner`, use
`--ephemeral`; propnix's single-user threat model makes "self-hosted" = "the one trusted machine."

---

## 6. Open items needing a credentialed / temporal test

**Measured / mechanically certain (no test needed):** streaming `curl|sha256sum` = flat FOD `outputHash`
after SRI re-encoding; recursive FODs need the full tree on disk; MS-Store FE3 SHA256 is the SRI body
verbatim and needs no credential (RESEARCH §10); `cacert` + `msroot2011.pem` as real build inputs
(RESEARCH §13); the nixpkgs `updateScript`/`commit`-array contracts; all §5 GitHub limits + the fork-PR exfil
boundary; larger runners unavailable on Pro; arm64 hosted runner free for public repos.

**Confirmed since (credentialed run done):**
1. **`fetchGogGalaxyBuild` (gogdl) produces a stably-hashing recursive tree per `buildId`** — ✅ **verified.** gogdl 1.2.2 downloaded Hollow Knight windows/x64 build `59545516053866453` twice into different dirs → byte-identical recursive NAR hash `sha256-zNs+los9+7taVgCKmFrVrKGFHQMqJkB/Pau6nnE5EkU=` (5.26 GB, 1789 files); auth is a `jq` transform of `galaxy_tokens.json` (client-id-keyed, `loginTime:0` → refresh), needing only that one file. Drafted as `wine-fex/fetchGogGalaxyBuild-gogdl.nix`, which **builds end-to-end in the credentialed Nix sandbox and reproduces the pinned hash** from a clean download (`/nix/store/…-hollow-knight-win-galaxy-1.5.12620`, `Hollow Knight.exe` present).

**Still needs a credentialed run to confirm:**
2. Whether the GOG flat fetch can **stream** the `.sh` to stdout/FIFO (`--download-file` writes to a file), and whether `downlink` honors HTTP `Range` (KB-sized `gameinfo` without the full file).
3. Whether `fakeHash` + `nix build` reads bytes from the hash-keyed drop dir without a second 15.9 GB download.
4. Whether gogdl's assembled tree byte-matches the derivation's post-processed tree (DLC overlay) so `nix hash path` equals the FOD hash — else re-pin strictly via `fakeHash` + `nix build`.
5. Actual BG3-class Windows Galaxy tree size (self-hosted disk sizing); `Σ compressedSize` vs `Σ size`.
6. Paid / license-gated apps on both stores (GOG entitlement gating; MS-Store `.msixvc` needs a real ticket + keys).
7. Whether a *superseded* FE3 `(UpdateID, RevisionNumber)` still resolves a live `FileLocation` — the only path to true MS-Store historical version-pinning; untested, do not assume.
8. Multi-`.msixbundle` apps (WhatsApp returned 2) — assert the leaf count matching the pinned identity.

---

**Grounding:** pin files live at `pkgs/games/<name>/versions.json` (`PLAN2 §10`); the MS-Store resolver is
`poc/msstore/fe3.py` + `poc/msstore/msroot2011.pem` + `poc/msstore/README.md`; the fetch policy is
`PLAN2 §3.1–§3.5`, grounded in `RESEARCH §7/§8/§10/§13`.
