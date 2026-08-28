//! propnix-steam-cred — decoding of the STORED Steam credential: the path-preserving tar of
//! DepotDownloader's `account.config` that `propnix cred add steam` writes under
//! `<credentialDir>/steam/<username>/depotdownloader-store.tar`.
//!
//! A LIBRARY crate (path dep), because TWO programs read that store and must agree byte-for-byte on what
//! it contains:
//!
//!   * `propnix` (pin/download) needs the refresh TOKENS themselves — it logs in with them;
//!   * `propnix-launcher` needs only the IDENTITY a token names — the JWT `sub` claim is the SteamID64,
//!     the same field steam-vent parses (`SteamID::from_steam64(sub.parse())`) before logging in — which
//!     it seats as the gbe_fork offline-entitlement shim's account. The token itself never leaves the
//!     launcher process and is never handed to the game.
//!
//! What lives here is the pure WIRE-FORMAT walking (tar layout, .NET raw DEFLATE, protobuf-net Dictionary
//! encoding, JWT shape) and the store's tar DISCOVERY. Policy stays with the callers: the cli owns the
//! error taxonomy, the sudo-escalated permission repair and the expiry UX; the launcher owns "identity is
//! best-effort — never fail a launch over it".

use std::io::Read;
use std::path::{Path, PathBuf};

/// Every stored credential tar under `<cred_dir>/steam`, SORTED so multi-account iteration order never
/// depends on readdir: `steam/<username>/depotdownloader-store.tar` per account, plus any flat
/// `steam/*.tar` (the CI layout). A missing store yields an empty list — "no credential" is the caller's
/// message to give (and the cli's carries the `propnix cred add steam` pointer).
pub fn store_tars(cred_dir: &Path) -> Vec<PathBuf> {
    let mut tars: Vec<PathBuf> = Vec::new();
    let steam = cred_dir.join("steam");
    if let Ok(rd) = std::fs::read_dir(&steam) {
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                tars.push(p.join("depotdownloader-store.tar"));
            } else if p.extension().map(|x| x == "tar").unwrap_or(false) {
                tars.push(p); // flat CI layout: <cred>/steam/store.tar
            }
        }
    }
    tars.retain(|p| p.exists());
    tars.sort();
    tars
}

/// Find `account.config` in ONE stored tar and pull every (account name, refresh-token JWT) out of it.
///
/// The file is DepotDownloader's `AccountSettingsStore`: **raw DEFLATE** (no zlib header — .NET's
/// `DeflateStream` uses windowBits -15) wrapping a protobuf-net message. protobuf-net encodes a
/// `Dictionary` as one length-delimited field per entry at the member's field number, each entry being
/// `field 1 = key, field 2 = value`. `LoginTokens` is member 4.
///
/// Rather than model the whole schema we walk the wire format and collect (string, string) pairs from
/// field 4, then keep only values shaped like a JWT. `ContentServerPenalty` (member 2) is not
/// mistakable for it: its entries carry a varint in field 2, not a string.
pub fn login_tokens_in_tar(reader: impl Read) -> Result<Vec<(String, String)>, String> {
    let mut out = Vec::new();
    let mut ar = tar::Archive::new(reader);
    let entries = ar.entries().map_err(|e| format!("reading credential tar: {e}"))?;
    for entry in entries {
        let mut entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };
        let is_cfg = entry
            .path()
            .map(|p| p.file_name().map(|n| n == "account.config").unwrap_or(false))
            .unwrap_or(false);
        if !is_cfg {
            continue;
        }
        let mut raw = Vec::new();
        entry
            .read_to_end(&mut raw)
            .map_err(|e| format!("reading account.config: {e}"))?;
        let mut plain = Vec::new();
        flate2::read::DeflateDecoder::new(&raw[..])
            .read_to_end(&mut plain)
            .map_err(|_| {
                "account.config did not inflate — the stored credential is truncated or corrupt \
                 (if it came from a CI secret, the base64 did not round-trip)"
                    .to_string()
            })?;
        out.extend(
            string_pairs_in_field(&plain, 4)
                .into_iter()
                .filter(|(_, v)| looks_like_jwt(v)),
        );
    }
    Ok(out)
}

/// Is this string a JWT? The protobuf scan works on an UNKNOWN schema, so shape alone is not enough —
/// require the payload segment to actually base64url-decode into a JSON object, or a coincidentally
/// dotted string could be mistaken for the credential.
pub fn looks_like_jwt(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    if parts.len() != 3 || parts.iter().any(|p| p.is_empty()) {
        return false;
    }
    matches!(payload_of(parts[1]), Some(serde_json::Value::Object(_)))
}

/// The `exp` claim (UNIX seconds), for the cli's expiry check — steam-vent does not check it, so a stale
/// token would otherwise surface as an opaque login failure.
pub fn jwt_expiry(jwt: &str) -> Option<u64> {
    jwt_payload(jwt)?.get("exp").and_then(serde_json::Value::as_u64)
}

/// The SteamID64 a token names: the `sub` claim. Steam writes it as a DECIMAL STRING (steam-vent's
/// `AccessToken.sub` is a `String` it `.parse()`es into a SteamID64); a bare number is accepted too
/// rather than betting on that representation never changing.
pub fn jwt_steam_id(jwt: &str) -> Option<u64> {
    match jwt_payload(jwt)?.get("sub")? {
        serde_json::Value::String(s) => s.parse().ok(),
        n => n.as_u64(),
    }
}

/// The decoded payload segment of a JWT, or None for anything not shaped like one.
fn jwt_payload(jwt: &str) -> Option<serde_json::Value> {
    payload_of(jwt.split('.').nth(1)?)
}

fn payload_of(segment: &str) -> Option<serde_json::Value> {
    use base64::Engine;
    let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(segment)
        .ok()?;
    serde_json::from_slice(&raw).ok()
}

/// Walk protobuf wire format and collect (string, string) pairs from length-delimited entries at
/// `field`. Anything that does not parse as such an entry is skipped.
pub fn string_pairs_in_field(buf: &[u8], field: u32) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for (f, bytes) in top_level_fields(buf) {
        if f != field {
            continue;
        }
        let mut k: Option<String> = None;
        let mut v: Option<String> = None;
        for (sub, sb) in top_level_fields(&bytes) {
            match sub {
                1 => k = String::from_utf8(sb.to_vec()).ok(),
                2 => v = String::from_utf8(sb.to_vec()).ok(),
                _ => {}
            }
        }
        if let (Some(k), Some(v)) = (k, v) {
            out.push((k, v));
        }
    }
    out
}

/// Yield (field number, payload) for every LENGTH-DELIMITED field; skip other wire types correctly so
/// the walk stays in sync.
fn top_level_fields(buf: &[u8]) -> Vec<(u32, Vec<u8>)> {
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < buf.len() {
        let (tag, n) = match varint(&buf[i..]) {
            Some(x) => x,
            None => break,
        };
        i += n;
        let field = (tag >> 3) as u32;
        match tag & 7 {
            0 => match varint(&buf[i..]) {
                Some((_, n)) => i += n,
                None => break,
            },
            1 => i += 8,
            5 => i += 4,
            2 => {
                let (len, n) = match varint(&buf[i..]) {
                    Some(x) => x,
                    None => break,
                };
                i += n;
                let end = match i.checked_add(len as usize) {
                    Some(e) if e <= buf.len() => e,
                    _ => break,
                };
                out.push((field, buf[i..end].to_vec()));
                i = end;
            }
            _ => break,
        }
    }
    out
}

fn varint(b: &[u8]) -> Option<(u64, usize)> {
    let mut v = 0u64;
    let mut shift = 0;
    for (i, byte) in b.iter().enumerate().take(10) {
        v |= ((byte & 0x7f) as u64) << shift;
        if byte & 0x80 == 0 {
            return Some((v, i + 1));
        }
        shift += 7;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A JWT-shaped token whose payload really is JSON (`looks_like_jwt` checks that), carrying the
    /// claims a real Steam refresh token does.
    fn fake_jwt(sub: &str, exp: u64) -> String {
        use base64::Engine;
        let b64 = |s: &str| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(s.as_bytes());
        format!(
            "{}.{}.sig",
            b64(r#"{"alg":"EdDSA"}"#),
            b64(&format!(r#"{{"iss":"steam","sub":"{sub}","exp":{exp}}}"#))
        )
    }

    #[test]
    fn jwt_claims_are_read_from_the_payload() {
        let jwt = fake_jwt("76561198000000000", 1234567890);
        assert!(looks_like_jwt(&jwt));
        assert_eq!(jwt_expiry(&jwt), Some(1234567890));
        assert_eq!(jwt_steam_id(&jwt), Some(76561198000000000));
        assert!(!looks_like_jwt("not-a-jwt"));
        assert!(!looks_like_jwt("ey.only.two")); // right shape, but the payload is not JSON
        assert_eq!(jwt_steam_id("not-a-jwt"), None);
        // A numeric `sub` decodes too — the string form is what Steam emits today, not a contract.
        use base64::Engine;
        let b64 = |s: &str| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(s.as_bytes());
        let numeric = format!("{}.{}.sig", b64("{}"), b64(r#"{"sub":42}"#));
        assert_eq!(jwt_steam_id(&numeric), Some(42));
    }

    #[test]
    fn protobuf_walk_finds_map_entries_and_skips_varint_valued_ones() {
        // field 4 (LoginTokens): {key:"alice", value:"tok"}      -> collected
        // field 2 (ContentServerPenalty): {key:"cache1", value:7} -> value is a varint, so skipped
        let mut b = Vec::new();
        let entry4 = {
            let mut e = Vec::new();
            e.push(0x0A);
            e.push(5);
            e.extend_from_slice(b"alice");
            e.push(0x12);
            e.push(3);
            e.extend_from_slice(b"tok");
            e
        };
        b.push(0x22); // field 4, wire type 2
        b.push(entry4.len() as u8);
        b.extend_from_slice(&entry4);
        let entry2 = {
            let mut e = Vec::new();
            e.push(0x0A);
            e.push(6);
            e.extend_from_slice(b"cache1");
            e.push(0x10); // field 2, VARINT
            e.push(7);
            e
        };
        b.push(0x12); // field 2, wire type 2
        b.push(entry2.len() as u8);
        b.extend_from_slice(&entry2);

        let got = string_pairs_in_field(&b, 4);
        assert_eq!(got, vec![("alice".to_string(), "tok".to_string())]);
        // The penalty entry has no string in field 2, so it yields nothing even if asked for.
        assert!(string_pairs_in_field(&b, 2).is_empty());
    }

    /// A credential tar shaped exactly like the one `propnix cred add steam` stores: a path-preserving
    /// tar of DepotDownloader's `account.config`, itself raw DEFLATE over a protobuf-net message whose
    /// member 4 (`LoginTokens`) maps account name -> refresh token.
    fn cred_tar(accounts: &[(&str, &str)]) -> Vec<u8> {
        use std::io::Write;
        let mut proto = Vec::new();
        for (k, v) in accounts {
            let mut entry = Vec::new();
            entry.push(0x0A); // field 1, len-delimited
            entry.push(k.len() as u8);
            entry.extend_from_slice(k.as_bytes());
            entry.push(0x12); // field 2, len-delimited
            // A token is longer than 127 bytes, so its length is a two-byte varint.
            let n = v.len();
            assert!(n < 1 << 14);
            if n < 128 {
                entry.push(n as u8);
            } else {
                entry.push((n & 0x7f) as u8 | 0x80);
                entry.push((n >> 7) as u8);
            }
            entry.extend_from_slice(v.as_bytes());

            proto.push(0x22); // field 4 (LoginTokens), len-delimited
            let m = entry.len();
            assert!(m < 1 << 14);
            if m < 128 {
                proto.push(m as u8);
            } else {
                proto.push((m & 0x7f) as u8 | 0x80);
                proto.push((m >> 7) as u8);
            }
            proto.extend_from_slice(&entry);
        }
        let mut enc = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::fast());
        enc.write_all(&proto).unwrap();
        let deflated = enc.finish().unwrap();

        let mut ar = tar::Builder::new(Vec::new());
        let mut hdr = tar::Header::new_gnu();
        hdr.set_size(deflated.len() as u64);
        hdr.set_mode(0o600);
        hdr.set_cksum();
        ar.append_data(&mut hdr, "DepotDownloader/account.config", &deflated[..])
            .unwrap();
        ar.into_inner().unwrap()
    }

    #[test]
    fn a_stored_tar_round_trips_to_its_login_tokens() {
        let alice = fake_jwt("76561198000000001", 4_000_000_000);
        let zoe = fake_jwt("76561198000000002", 4_000_000_000);
        let tar = cred_tar(&[("alice", &alice), ("zoe", &zoe), ("noise", "not-a-jwt")]);
        let got = login_tokens_in_tar(&tar[..]).unwrap();
        let full = vec![("alice".to_string(), alice), ("zoe".to_string(), zoe)];
        assert_eq!(got, full, "every JWT-shaped LoginTokens entry, and nothing that is not one");
        // Truncation MID-ENTRY (the tar header is 512 bytes, so byte 600 is inside account.config's
        // data) yields a PREFIX of the real list, never garbage: flate2 stops cleanly at a cut
        // raw-deflate stream (no error — verified) and the protobuf walk drops any half-present pair,
        // so the symptom of a mangled stored credential is the callers' "holds no login token" (or a
        // missing account), never a corrupt token.
        let cut = login_tokens_in_tar(&tar[..600]).unwrap();
        assert!(
            cut.len() < full.len() && cut == full[..cut.len()],
            "a cut credential must only ever LOSE tokens, got {cut:?}"
        );
    }

    #[test]
    fn discovery_finds_both_layouts_sorted() {
        let root = std::env::temp_dir().join(format!(
            "propnix-steamcred-lib-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        assert!(store_tars(&root).is_empty(), "a missing store is empty, not an error");

        std::fs::create_dir_all(root.join("steam/zoe")).unwrap();
        std::fs::create_dir_all(root.join("steam/alice")).unwrap();
        std::fs::write(root.join("steam/zoe/depotdownloader-store.tar"), b"").unwrap();
        std::fs::write(root.join("steam/alice/depotdownloader-store.tar"), b"").unwrap();
        std::fs::write(root.join("steam/ci.tar"), b"").unwrap(); // flat CI layout
        std::fs::create_dir_all(root.join("steam/empty-account")).unwrap(); // no tar inside → skipped

        let got: Vec<String> = store_tars(&root)
            .iter()
            .map(|p| p.strip_prefix(&root).unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            got,
            vec![
                "steam/alice/depotdownloader-store.tar",
                "steam/ci.tar",
                "steam/zoe/depotdownloader-store.tar",
            ]
        );
        let _ = std::fs::remove_dir_all(&root);
    }
}
