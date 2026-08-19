//! Reading and rewriting `pkgs/games/<game>/versions.json`.
//!
//! MINIMAL DIFFS. The file is held as a `serde_json::Value` with `preserve_order`, and only the specific
//! values that change are replaced — unknown keys survive, and JSON number-vs-string types are never
//! coerced (the fetcher signatures are closed, so `appId` must stay a number and `manifestId` a string, or
//! evaluation fails). Verified: all 17 current versions.json files round-trip byte-identically through
//! `to_string_pretty` + a trailing newline, so a rewrite touches only the lines it means to.
//!
//! ALL-OR-NOTHING. A game is updated as a unit: its base payloads AND every DLC entry, or nothing. A base
//! game moved forward while a DLC stayed behind is exactly the mismatch that breaks at runtime, so
//! `Transaction` accumulates every recomputed pin in memory and writes only once all of them succeeded.
//!
//! NOT OWNED IS NOT A FAILURE. If the credential account does not own a title (or one of its DLC), the
//! whole game is left untouched and reported as skipped — a no-op, not an error. That keeps a shared CI
//! account from turning "I don't own Skyrim" into a red build every week.

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::{Map, Value};

#[derive(Debug)]
pub enum Error {
    Io(std::io::Error),
    Json(serde_json::Error),
    Schema(String),
    /// A `fetchInfo` key this binary has never heard of. Its own variant rather than a `Schema` string
    /// because the exit-code classifier reads the TYPE (see `pin::blocked_from`): this one is a
    /// human/upgrade problem — an older deployed propnix meeting a newer file — so it must exit 4 and
    /// open an issue, while every other schema error stays a red run. It RENDERS identically to
    /// `Schema`, so the message a human reads is unchanged.
    UnknownFetcher(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Io(e) => write!(f, "io error: {e}"),
            Error::Json(e) => write!(f, "malformed versions.json: {e}"),
            Error::Schema(m) | Error::UnknownFetcher(m) => {
                write!(f, "unexpected versions.json shape: {m}")
            }
        }
    }
}

impl std::error::Error for Error {}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}
impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::Json(e)
    }
}

/// Where a pin lives in the file. `fetchInfo.<fetcher>.<platform>[i]`, or `dlc.<name>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PinLoc {
    Payload {
        fetcher: String,
        platform: String,
        index: usize,
    },
    Dlc {
        name: String,
    },
}

impl std::fmt::Display for PinLoc {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PinLoc::Payload {
                fetcher,
                platform,
                index,
            } => write!(f, "fetchInfo.{fetcher}.{platform}[{index}]"),
            PinLoc::Dlc { name } => write!(f, "dlc.{name}"),
        }
    }
}

/// Which store a pin belongs to. A PAYLOAD pin is classified by its `fetchInfo` key, which is the
/// authoritative statement of which fetcher will consume the row; only a `dlc` entry — which carries no
/// fetcher name of its own — is classified structurally.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Store {
    Steam,
    GogGalaxy,
    /// A GOG offline installer (`fileId`, flat hash, no version pin at all). Nothing to update: the
    /// upstream slot is repointed in place, so there is no "newer version" to detect.
    GogInstaller,
}

/// One pin, read out of the file.
#[derive(Debug, Clone)]
pub struct Pin {
    pub loc: PinLoc,
    pub store: Store,
    pub obj: Map<String, Value>,
}

impl Pin {
    pub fn str_field(&self, k: &str) -> Result<&str, Error> {
        self.obj
            .get(k)
            .and_then(Value::as_str)
            .ok_or_else(|| Error::Schema(format!("{} is missing a string {k:?}", self.loc)))
    }

    pub fn u64_field(&self, k: &str) -> Result<u64, Error> {
        self.obj
            .get(k)
            .and_then(Value::as_u64)
            .ok_or_else(|| Error::Schema(format!("{} is missing a numeric {k:?}", self.loc)))
    }

    pub fn opt_str(&self, k: &str) -> Option<&str> {
        self.obj.get(k).and_then(Value::as_str)
    }

    /// The DLC id, when this pin is a DLC entry.
    pub fn dlc_id(&self) -> Option<&str> {
        self.opt_str("dlcId")
    }

    pub fn is_dlc(&self) -> bool {
        matches!(self.loc, PinLoc::Dlc { .. })
    }
}

/// A loaded versions.json.
///
/// Deliberately has no `save`: this type only ever RENDERS a complete document, and `main.rs` is the one
/// place that writes one. It does so by temp-file + same-directory rename, so a run that dies half way
/// can never leave a partially written pin behind — the file a reader sees is always either the old
/// document or the whole new one, never a truncated mix.
pub struct VersionsFile {
    root: Value,
}

impl VersionsFile {
    pub fn load(path: &Path) -> Result<Self, Error> {
        let text = std::fs::read_to_string(path)?;
        let root: Value = serde_json::from_str(&text)?;
        Ok(Self { root })
    }

    /// Every pin in the file, payloads first then DLC.
    pub fn pins(&self) -> Result<Vec<Pin>, Error> {
        let mut out = Vec::new();
        if let Some(fi) = self.root.get("fetchInfo").and_then(Value::as_object) {
            // BTreeMap for a deterministic fetcher/platform walk regardless of file key order.
            let fetchers: BTreeMap<_, _> = fi.iter().collect();
            for (fetcher, plats) in fetchers {
                let plats = plats
                    .as_object()
                    .ok_or_else(|| Error::Schema(format!("fetchInfo.{fetcher} is not an object")))?;
                let plats: BTreeMap<_, _> = plats.iter().collect();
                for (platform, arr) in plats {
                    let arr = arr.as_array().ok_or_else(|| {
                        Error::Schema(format!("fetchInfo.{fetcher}.{platform} is not an array"))
                    })?;
                    for (index, e) in arr.iter().enumerate() {
                        let obj = e
                            .as_object()
                            .ok_or_else(|| {
                                Error::Schema(format!(
                                    "fetchInfo.{fetcher}.{platform}[{index}] is not an object"
                                ))
                            })?
                            .clone();
                        out.push(Pin {
                            loc: PinLoc::Payload {
                                fetcher: fetcher.clone(),
                                platform: platform.clone(),
                                index,
                            },
                            store: classify_payload(fetcher, &obj)?,
                            obj,
                        });
                    }
                }
            }
        }
        if let Some(dlc) = self.root.get("dlc").and_then(Value::as_object) {
            let dlc: BTreeMap<_, _> = dlc.iter().collect();
            for (name, e) in dlc {
                let obj = e
                    .as_object()
                    .ok_or_else(|| Error::Schema(format!("dlc.{name} is not an object")))?
                    .clone();
                out.push(Pin {
                    loc: PinLoc::Dlc { name: name.clone() },
                    store: classify_dlc(&obj),
                    obj,
                });
            }
        }
        Ok(out)
    }

    fn slot_mut(&mut self, loc: &PinLoc) -> Result<&mut Map<String, Value>, Error> {
        let missing = || Error::Schema(format!("{loc} no longer exists"));
        match loc {
            PinLoc::Payload {
                fetcher,
                platform,
                index,
            } => self
                .root
                .get_mut("fetchInfo")
                .and_then(|v| v.get_mut(fetcher))
                .and_then(|v| v.get_mut(platform))
                .and_then(|v| v.get_mut(*index))
                .and_then(Value::as_object_mut)
                .ok_or_else(missing),
            PinLoc::Dlc { name } => self
                .root
                .get_mut("dlc")
                .and_then(|v| v.get_mut(name))
                .and_then(Value::as_object_mut)
                .ok_or_else(missing),
        }
    }

    /// Replace a value, requiring the key to already exist. Adding a key a fetcher's closed signature
    /// does not accept would break evaluation, so an unknown key is refused rather than inserted.
    pub fn set_existing(&mut self, loc: &PinLoc, key: &str, value: &str) -> Result<(), Error> {
        let slot = self.slot_mut(loc)?;
        if !slot.contains_key(key) {
            return Err(Error::Schema(format!(
                "{loc} has no {key:?} to update; refusing to add a key the fetcher signature may reject"
            )));
        }
        slot.insert(key.to_string(), Value::String(value.to_string()));
        Ok(())
    }

    /// Replace a value, or ADD it when the key is on the insert allowlist. serde_json's preserve_order
    /// map appends a newly inserted key at the END of the row object rather than at some house-style
    /// position — acceptable, since the alternative is rebuilding the row and losing the minimal diff
    /// everywhere else.
    pub fn set_or_insert(&mut self, loc: &PinLoc, key: &str, value: &str) -> Result<(), Error> {
        if !INSERTABLE.contains(&key) {
            return self.set_existing(loc, key, value);
        }
        let slot = self.slot_mut(loc)?;
        slot.insert(key.to_string(), Value::String(value.to_string()));
        Ok(())
    }

    /// Every fetcher key the file pins, sorted. This is what `pin.version` is validated against.
    fn fetcher_keys(&self) -> Vec<String> {
        self.root
            .get("fetchInfo")
            .and_then(Value::as_object)
            .map(|m| {
                let mut v: Vec<String> = m.keys().cloned().collect();
                v.sort();
                v
            })
            .unwrap_or_default()
    }

    /// `pin.version`, normalized to fetcher -> version. Returns the map plus whether the file used the
    /// one-store SHORTHAND (a bare string), which the report renders back verbatim.
    fn parse_pin_version(&self, v: Option<&Value>) -> Result<(BTreeMap<String, String>, bool), Error> {
        let Some(v) = v else {
            return Ok((BTreeMap::new(), false));
        };
        let known = self.fetcher_keys();
        let object_form = |example: &str| {
            format!(
                "`pin.version` must name the store it pins, because a version string means different \
                 things to different stores. Write it as an object, e.g. \
                 {{ \"version\": {{ {example} }}, \"reason\": \"…\" }}. \
                 This game pins: {}",
                if known.is_empty() { "nothing".to_string() } else { known.join(", ") }
            )
        };
        match v {
            // Shorthand: legal only when there is exactly one store to mean.
            Value::String(s) if known.len() == 1 => {
                Ok((BTreeMap::from([(known[0].clone(), s.clone())]), true))
            }
            Value::String(s) => Err(Error::Schema(object_form(
                &known
                    .iter()
                    .map(|k| format!("\"{k}\": \"{s}\""))
                    .collect::<Vec<_>>()
                    .join(", "),
            ))),
            Value::Object(m) => {
                let mut out = BTreeMap::new();
                for (k, val) in m {
                    if !known.contains(k) {
                        return Err(Error::Schema(format!(
                            "`pin.version.{k}` names a fetcher this game does not pin (it pins: {})",
                            if known.is_empty() { "nothing".to_string() } else { known.join(", ") }
                        )));
                    }
                    // A JSON number here used to be silently ignored, which meant "follow upstream" —
                    // exactly the silent no-op this file refuses everywhere else.
                    let s = val.as_str().ok_or_else(|| {
                        Error::Schema(format!(
                            "`pin.version.{k}` must be a STRING (got {val}); a version is never a number \
                             — GOG's are dotted and Steam's are ids too large to survive a JSON double"
                        ))
                    })?;
                    out.insert(k.clone(), s.to_string());
                }
                Ok((out, false))
            }
            _ => Err(Error::Schema(object_form("\"gog\": \"1.2.3\""))),
        }
    }

    /// The game's update policy. Errors rather than guessing if it is malformed.
    pub fn policy(&self) -> Result<Policy, Error> {
        let Some(v) = self.root.get("pin") else {
            return Ok(Policy::default());
        };
        let obj = v
            .as_object()
            .ok_or_else(|| Error::Schema("`pin` must be an object".into()))?;
        for k in obj.keys() {
            if !matches!(k.as_str(), "freeze" | "version" | "reason") {
                return Err(Error::Schema(format!(
                    "unknown key `pin.{k}` (expected freeze, version or reason)"
                )));
            }
        }
        if obj.contains_key("freeze") && obj.get("freeze").and_then(Value::as_bool).is_none() {
            return Err(Error::Schema("`pin.freeze` must be true or false".into()));
        }
        if obj.contains_key("reason") && obj.get("reason").and_then(Value::as_str).is_none() {
            return Err(Error::Schema("`pin.reason` must be a string".into()));
        }
        let (version, shorthand) = self.parse_pin_version(obj.get("version"))?;
        let p = Policy {
            freeze: obj.get("freeze").and_then(Value::as_bool).unwrap_or(false),
            version,
            shorthand,
            reason: obj.get("reason").and_then(Value::as_str).map(str::to_string),
        };
        if !p.is_default() && p.reason.as_deref().unwrap_or("").trim().is_empty() {
            return Err(Error::Schema(
                "`pin` needs a non-empty `reason`: a frozen or version-locked pin with no stated reason \
                 is indistinguishable from an oversight later"
                    .into(),
            ));
        }
        if p.freeze && !p.version.is_empty() {
            return Err(Error::Schema(
                "`pin.freeze` and `pin.version` are mutually exclusive — freeze means never move, \
                 version means sit at exactly that one"
                    .into(),
            ));
        }
        Ok(p)
    }

    pub fn render(&self) -> String {
        // 2-space pretty + trailing newline: the byte-exact shape every current file already has.
        let mut s = serde_json::to_string_pretty(&self.root).expect("Value always serializes");
        s.push('\n');
        s
    }

}

/// Keys the tool may INSERT (not just update): each is part of the fetchers' closed signatures, so
/// adding it can never break evaluation. Everything else stays update-only.
const INSERTABLE: &[&str] = &["depsBuildId"];

/// A payload row's store, from its `fetchInfo` key. The key is what decides which fetcher the row is
/// handed to at eval time, so duck-typing the fields instead would let a row disagree with the fetcher
/// that actually consumes it — and would silently classify a fetcher this binary predates as GOG.
fn classify_payload(fetcher: &str, obj: &Map<String, Value>) -> Result<Store, Error> {
    match fetcher {
        "steam" => Ok(Store::Steam),
        // Both GOG paths live under the one `gog` key; `fileId` is what marks the offline-installer row.
        "gog" => Ok(if obj.contains_key("fileId") {
            Store::GogInstaller
        } else {
            Store::GogGalaxy
        }),
        other => Err(Error::UnknownFetcher(format!(
            "unknown fetcher {other:?} under fetchInfo — this propnix predates it, or the file is wrong"
        ))),
    }
}

/// A `dlc` entry carries no fetcher key by design (it rides its base game's), so this one really must
/// sniff the fields.
fn classify_dlc(obj: &Map<String, Value>) -> Store {
    if obj.contains_key("appId") {
        Store::Steam
    } else if obj.contains_key("fileId") {
        Store::GogInstaller
    } else {
        Store::GogGalaxy
    }
}

/// Per-game update policy, read from the OPTIONAL top-level `pin` object in versions.json:
///
/// ```json
/// "pin": { "freeze": true, "reason": "2.1.x breaks the mod loader" }
/// "pin": { "version": "2.0.77", "reason": "1.4 regressed save loading" }
/// ```
///
/// `freeze` takes this game out of automatic updating entirely. `version` instead names the exact
/// upstream version to sit at, PER STORE — a version string means different things to different stores,
/// and a game may pin more than one:
///
/// ```json
/// "pin": { "version": { "gog": "1.5.12620", "steam": "1.5.78.11" }, "reason": "…" }
/// ```
///
/// A bare string is shorthand, legal only when the game pins exactly one fetcher. A store with no entry
/// simply follows upstream — per-store pinning is independent. What the value MEANS is the store's
/// business (see `pin::check`): GOG resolves it against the builds list and deliberately suppresses the
/// never-move-backwards guard; Steam, which publishes no version→manifest mapping, treats it as a HOLD.
///
/// It lives here, next to the pins it governs, rather than in the game's `default.nix`: this is the file
/// `propnix pin` already reads and rewrites, so the policy costs nothing to consult, and the tool keeps
/// working on a plain checkout without evaluating any Nix. (`dlc` sets the precedent for a non-fetchInfo
/// key here.)
///
/// A `reason` is REQUIRED whenever either field is set — the same discipline the tuning knobs enforce.
/// A frozen pin with no stated reason is indistinguishable from an oversight six months later.
#[derive(Debug, Default, Clone)]
pub struct Policy {
    pub freeze: bool,
    /// fetcher key -> the version to sit at. Empty means "follow upstream everywhere".
    pub version: BTreeMap<String, String>,
    /// The file wrote `version` in the one-store shorthand form, so the report renders it back verbatim.
    shorthand: bool,
    pub reason: Option<String>,
}

impl Policy {
    pub fn is_default(&self) -> bool {
        !self.freeze && self.version.is_empty()
    }

    /// The policy's version, as ONE human string for the report / CI table. Shorthand renders as it was
    /// written; the object form renders compactly as `gog=1.5.12620 steam=1.5.78.11`.
    pub fn pinned_to(&self) -> Option<String> {
        if self.version.is_empty() {
            return None;
        }
        if self.shorthand {
            return self.version.values().next().cloned();
        }
        Some(
            self.version
                .iter()
                .map(|(k, v)| format!("{k}={v}"))
                .collect::<Vec<_>>()
                .join(" "),
        )
    }

    /// Test-only constructor for a frozen policy (the parser is the only production path).
    #[cfg(test)]
    pub fn frozen_for_test(reason: &str) -> Policy {
        Policy {
            freeze: true,
            version: BTreeMap::new(),
            shorthand: false,
            reason: Some(reason.to_string()),
        }
    }

    /// Test-only constructor for the object form (the parser is the only production path).
    #[cfg(test)]
    pub fn for_test(version: &[(&str, &str)], reason: &str) -> Policy {
        Policy {
            freeze: false,
            version: version.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            shorthand: false,
            reason: Some(reason.to_string()),
        }
    }
}

/// Apply a batch of edits ALL-OR-NOTHING.
///
/// Every `(loc, key)` is validated to exist before anything is written, so a batch naming a key some pin
/// does not have leaves the document completely untouched. That is what makes a game's base payloads and
/// its DLC move together or not at all — a base game advanced without its DLC is exactly the mismatch
/// that breaks at runtime.
impl VersionsFile {
    pub fn apply_all(&mut self, edits: &[(PinLoc, String, String)]) -> Result<(), Error> {
        for (loc, key, _) in edits {
            if INSERTABLE.contains(&key.as_str()) {
                self.slot_mut(loc)?; // the row must exist; the key need not
                continue;
            }
            let slot = self.slot_mut(loc)?;
            if !slot.contains_key(key) {
                return Err(Error::Schema(format!(
                    "{loc} has no {key:?} to update; refusing to write ANY of this batch, so a base \
                     game cannot advance without its DLC"
                )));
            }
        }
        for (loc, key, value) in edits {
            self.set_or_insert(loc, key, value)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    const FACTORIO: &str = r#"{
  "fetchInfo": {
    "gog": {
      "x86_64-windows": [
        {
          "pname": "factorio-win",
          "productId": "1238653230",
          "buildId": "59928886516479116",
          "version": "2.1.14",
          "outputHash": "sha256-AAA=",
          "outputHashMode": "recursive",
          "os": "windows",
          "lang": "en",
          "kind": "game",
          "generation": 2
        }
      ]
    }
  },
  "dlc": {
    "space-age": {
      "pname": "factorio-space-age-win",
      "productId": "1238653230",
      "buildId": "59928886516479116",
      "version": "2.1.14",
      "dlcId": "1831417704",
      "outputHash": "sha256-BBB=",
      "outputHashMode": "recursive",
      "os": "windows",
      "lang": "en",
      "kind": "dlc",
      "generation": 2
    }
  }
}
"#;

    fn write_tmp(body: &str) -> PathBuf {
        let mut d = std::env::temp_dir();
        d.push(format!(
            "propnix-pin-vt-{}-{:?}/factorio",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&d).unwrap();
        let p = d.join("versions.json");
        std::fs::write(&p, body).unwrap();
        p
    }

    #[test]
    fn round_trips_byte_identically() {
        let p = write_tmp(FACTORIO);
        let f = VersionsFile::load(&p).unwrap();
        assert_eq!(f.render(), FACTORIO, "rewriting must not reformat the file");
    }

    #[test]
    fn finds_base_and_dlc_pins() {
        let p = write_tmp(FACTORIO);
        let f = VersionsFile::load(&p).unwrap();
        let pins = f.pins().unwrap();
        assert_eq!(pins.len(), 2);
        assert_eq!(pins[0].store, Store::GogGalaxy);
        assert!(!pins[0].is_dlc());
        assert!(pins[1].is_dlc());
        assert_eq!(pins[1].dlc_id(), Some("1831417704"));
        // A GOG DLC rides the base game's build: tandem updating means copying buildId and version
        // across and recomputing only the DLC's own outputHash.
        assert_eq!(
            pins[0].str_field("buildId").unwrap(),
            pins[1].str_field("buildId").unwrap()
        );
    }

    #[test]
    fn preserves_number_types_when_editing() {
        let p = write_tmp(FACTORIO);
        let mut f = VersionsFile::load(&p).unwrap();
        let loc = PinLoc::Payload {
            fetcher: "gog".into(),
            platform: "x86_64-windows".into(),
            index: 0,
        };
        f.set_existing(&loc, "outputHash", "sha256-ZZZ=").unwrap();
        let out = f.render();
        // `generation` must stay a JSON number and `productId` a JSON string: the fetcher signatures are
        // closed and typed, so coercing either breaks evaluation.
        assert!(out.contains("\"generation\": 2\n"), "numbers must stay numbers");
        assert!(!out.contains("\"generation\": \"2\""));
        assert!(out.contains("\"productId\": \"1238653230\""));
        assert!(out.contains("\"outputHash\": \"sha256-ZZZ=\""));
        assert!(!out.contains("sha256-AAA="));
        // Only the one value changed; everything else is byte-for-byte as it was.
        assert_eq!(out, FACTORIO.replace("sha256-AAA=", "sha256-ZZZ="));
    }

    #[test]
    fn refuses_to_add_unknown_keys() {
        let p = write_tmp(FACTORIO);
        let mut f = VersionsFile::load(&p).unwrap();
        let loc = PinLoc::Payload {
            fetcher: "gog".into(),
            platform: "x86_64-windows".into(),
            index: 0,
        };
        // fetchSteamDepot/fetchGogGalaxyBuild have closed signatures — an extra key is an eval error.
        assert!(f.set_existing(&loc, "manifestId", "123").is_err());
    }

    #[test]
    fn apply_all_is_all_or_nothing() {
        let p = write_tmp(FACTORIO);
        let mut f = VersionsFile::load(&p).unwrap();
        let base = PinLoc::Payload {
            fetcher: "gog".into(),
            platform: "x86_64-windows".into(),
            index: 0,
        };
        // A DLC edit naming a key that does not exist must abort the WHOLE batch, leaving the base edit
        // unwritten — otherwise the game would move without its DLC.
        let bad = vec![
            (base.clone(), "outputHash".to_string(), "sha256-NEW=".to_string()),
            (
                PinLoc::Dlc { name: "space-age".into() },
                "nope".to_string(),
                "x".to_string(),
            ),
        ];
        assert!(f.apply_all(&bad).is_err());
        assert_eq!(f.render(), FACTORIO, "a rejected batch must change nothing at all");

        // The same batch minus the bad edit goes through.
        let good = vec![(base, "outputHash".to_string(), "sha256-NEW=".to_string())];
        f.apply_all(&good).unwrap();
        assert_eq!(f.render(), FACTORIO.replace("sha256-AAA=", "sha256-NEW="));
        // Nothing ever touches disk: `propnix pin` emits on stdout and the caller decides where it lands.
        assert_eq!(std::fs::read_to_string(&p).unwrap(), FACTORIO);
    }

    #[test]
    fn policy_defaults_to_following_upstream() {
        let p = write_tmp(FACTORIO);
        assert!(VersionsFile::load(&p).unwrap().policy().unwrap().is_default());
    }

    #[test]
    fn policy_is_parsed_and_validated() {
        let with = |pin: &str| {
            let body = FACTORIO.replace("{\n  \"fetchInfo\"", &format!("{{\n  \"pin\": {pin},\n  \"fetchInfo\""));
            VersionsFile::load(&write_tmp(&body)).unwrap().policy()
        };
        let ok = with(r#"{ "freeze": true, "reason": "mods" }"#).unwrap();
        assert!(ok.freeze && ok.version.is_empty());

        // Factorio pins exactly one fetcher, so the bare-string shorthand is legal and means `gog`.
        let ver = with(r#"{ "version": "2.0.77", "reason": "regression" }"#).unwrap();
        assert_eq!(ver.version.get("gog").map(String::as_str), Some("2.0.77"));
        assert_eq!(ver.pinned_to().as_deref(), Some("2.0.77"), "shorthand renders as written");
        assert!(!ver.freeze);

        // …and the explicit object form is equivalent, but renders store-qualified.
        let obj = with(r#"{ "version": { "gog": "2.0.77" }, "reason": "regression" }"#).unwrap();
        assert_eq!(obj.version, ver.version);
        assert_eq!(obj.pinned_to().as_deref(), Some("gog=2.0.77"));

        // A reason is mandatory: an unexplained freeze is indistinguishable from an oversight later.
        assert!(with(r#"{ "freeze": true }"#).is_err());
        assert!(with(r#"{ "version": "2.0.77", "reason": "  " }"#).is_err());
        // Mutually exclusive.
        assert!(with(r#"{ "freeze": true, "version": "2.0.77", "reason": "r" }"#).is_err());
        // A typo must not silently mean "follow upstream".
        assert!(with(r#"{ "frozen": true, "reason": "r" }"#).is_err());
        assert!(with(r#"{ "freeze": "yes", "reason": "r" }"#).is_err());
        assert!(with(r#"{ "version": "2.0.77", "reason": 7 }"#).is_err());
        // A number is the silent-ignore this rule exists to kill: it used to parse as "follow upstream".
        assert!(with(r#"{ "version": 2, "reason": "r" }"#).is_err());
        assert!(with(r#"{ "version": { "gog": 2 }, "reason": "r" }"#).is_err());
        // A store this game does not pin is a typo, not a no-op.
        assert!(with(r#"{ "version": { "steam": "1" }, "reason": "r" }"#).is_err());
    }

    /// A two-store file, shaped like hollow-knight's.
    const TWO_STORE: &str = r#"{
  "fetchInfo": {
    "gog": {
      "x86_64-windows": [
        { "pname": "hk-win", "productId": "1308320804", "buildId": "59545516053866453",
          "version": "1.5.12620", "outputHash": "sha256-A=", "outputHashMode": "recursive",
          "os": "windows", "lang": "en", "kind": "game", "generation": 2 }
      ]
    },
    "steam": {
      "x86_64-windows": [
        { "pname": "hk-win-steam", "appId": 367520, "depotId": 367521,
          "manifestId": "257781644874438846", "version": "1.5.78.11", "outputHash": "sha256-B=",
          "title": "Hollow Knight (windows, Steam)" }
      ]
    }
  }
}
"#;

    #[test]
    fn a_mixed_store_game_must_say_which_store_a_version_pins() {
        let with = |pin: &str| {
            let body = TWO_STORE.replace("{\n  \"fetchInfo\"", &format!("{{\n  \"pin\": {pin},\n  \"fetchInfo\""));
            VersionsFile::load(&write_tmp(&body)).unwrap().policy()
        };
        // The shorthand is ambiguous here — "1.5.12620" is a GOG version_name and means nothing to
        // Steam — so it must be refused, and the error must show the shape that works.
        let err = with(r#"{ "version": "1.5.12620", "reason": "r" }"#).unwrap_err().to_string();
        assert!(err.contains("\"gog\""), "the error must show the object form; got: {err}");
        assert!(err.contains("\"steam\""), "…naming every store this game pins; got: {err}");

        let p = with(r#"{ "version": { "gog": "1.5.12620", "steam": "1.5.78.11" }, "reason": "r" }"#)
            .unwrap();
        assert_eq!(p.version.get("gog").map(String::as_str), Some("1.5.12620"));
        assert_eq!(p.version.get("steam").map(String::as_str), Some("1.5.78.11"));
        assert_eq!(p.pinned_to().as_deref(), Some("gog=1.5.12620 steam=1.5.78.11"));

        // Per-store pinning is independent: one store held, the other following upstream.
        let one = with(r#"{ "version": { "steam": "1.5.78.11" }, "reason": "r" }"#).unwrap();
        assert_eq!(one.version.len(), 1);
        assert!(!one.version.contains_key("gog"), "an absent store follows upstream");
    }

    #[test]
    fn payload_pins_classify_by_their_fetcher_key() {
        let f = VersionsFile::load(&write_tmp(TWO_STORE)).unwrap();
        let pins = f.pins().unwrap();
        let by_loc = |fetcher: &str| {
            pins.iter()
                .find(|p| matches!(&p.loc, PinLoc::Payload { fetcher: x, .. } if x == fetcher))
                .unwrap()
                .store
        };
        assert_eq!(by_loc("gog"), Store::GogGalaxy);
        assert_eq!(by_loc("steam"), Store::Steam);
    }

    #[test]
    fn an_unknown_fetcher_key_is_refused_not_guessed() {
        // A row under a fetcher this binary predates must NOT be duck-typed into GogGalaxy and then die
        // on a misleading "missing productId".
        let body = TWO_STORE.replace("\"gog\": {", "\"epic\": {");
        let e = VersionsFile::load(&write_tmp(&body)).unwrap().pins().unwrap_err();
        assert!(matches!(e, Error::UnknownFetcher(_)), "must be its own type, got {e:?}");
        assert!(e.to_string().contains("epic"), "the error must name the key: {e}");
    }

    #[test]
    fn only_allowlisted_keys_may_be_inserted() {
        let p = write_tmp(FACTORIO);
        let mut f = VersionsFile::load(&p).unwrap();
        let base = PinLoc::Payload {
            fetcher: "gog".into(),
            platform: "x86_64-windows".into(),
            index: 0,
        };
        // depsBuildId is part of fetchGogGalaxyBuild's closed signature, so adding it cannot break eval.
        f.set_or_insert(&base, "depsBuildId", "12345").unwrap();
        assert!(f.render().contains("\"depsBuildId\": \"12345\""));
        // Anything else stays update-only, through either entry point.
        assert!(f.set_or_insert(&base, "manifestId", "9").is_err());
        assert!(f.set_existing(&base, "depsBuildId2", "9").is_err());
        // …and a batch naming a non-insertable absent key still writes nothing at all.
        let before = f.render();
        assert!(f
            .apply_all(&[
                (base.clone(), "outputHash".into(), "sha256-NEW=".into()),
                (base.clone(), "somethingElse".into(), "x".into()),
            ])
            .is_err());
        assert_eq!(f.render(), before, "a rejected batch must change nothing at all");
        // A batch that only inserts an allowlisted key goes through.
        f.apply_all(&[(
            PinLoc::Dlc { name: "space-age".into() },
            "depsBuildId".into(),
            "777".into(),
        )])
        .unwrap();
        assert!(f.render().contains("\"depsBuildId\": \"777\""));
    }

    #[test]
    fn a_policy_survives_a_rewrite() {
        let body = FACTORIO.replace(
            "{\n  \"fetchInfo\"",
            "{\n  \"pin\": { \"freeze\": true, \"reason\": \"mods\" },\n  \"fetchInfo\"",
        );
        let p = write_tmp(&body);
        let mut f = VersionsFile::load(&p).unwrap();
        f.set_existing(
            &PinLoc::Payload { fetcher: "gog".into(), platform: "x86_64-windows".into(), index: 0 },
            "outputHash",
            "sha256-ZZZ=",
        )
        .unwrap();
        assert!(
            f.render().contains("\"freeze\": true"),
            "the rewriter must preserve unknown top-level keys"
        );
    }

    #[test]
    fn dlc_entries_still_classify_structurally() {
        // A `dlc` entry carries no fetcher key, so this one path keeps sniffing the fields.
        let mut m = Map::new();
        m.insert("appId".into(), Value::from(480));
        assert_eq!(classify_dlc(&m), Store::Steam);
        let mut m = Map::new();
        m.insert("fileId".into(), Value::from("en3installer0"));
        assert_eq!(classify_dlc(&m), Store::GogInstaller);
        assert_eq!(classify_dlc(&Map::new()), Store::GogGalaxy);
    }
}
