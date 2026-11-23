//! Lock new Mono streams before the versions.json transaction lands. The Nix resolver owns source
//! discovery; the ordinary Nix package set consumes only the resulting immutable metadata.
use serde::Deserialize;
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::path::Path;
use std::process::{Command, Stdio};

type Error = Box<dyn std::error::Error>;

#[derive(Deserialize)]
struct LockedSource {
    stream: String,
    maintained: bool,
    source: Value,
}

pub fn lock_document(repo: &Path, doc: &str) -> Result<String, Error> {
    lock_with(doc, |version| {
        eprintln!("  Unity {version}: resolving Mono source lock");
        let output = Command::new("nix")
            .args([
                "eval",
                "--impure",
                "--json",
                "--extra-experimental-features",
                "nix-command flakes",
                "--file",
            ])
            .arg(repo.join("emulators/unity-mono/lock-source.nix"))
            .args([
                "--apply",
                "f: f { version = builtins.getEnv \"PROPNIX_UNITY_VERSION\"; }",
            ])
            .env("PROPNIX_UNITY_VERSION", version)
            .stderr(Stdio::inherit())
            .output()
            .map_err(|e| {
                format!("Unity {version}: cannot run the Nix Mono source resolver: {e}")
            })?;
        if !output.status.success() {
            return Err(format!("Unity {version}: Mono source discovery failed; manual packaging is required in emulators/unity-mono (see the Nix error above)").into());
        }
        Ok(serde_json::from_slice(&output.stdout)?)
    })
}

fn stream_of(version: &str) -> Result<String, Error> {
    let parts: Vec<_> = version.split('.').take(2).collect();
    if parts.len() != 2
        || parts
            .iter()
            .any(|p| p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()))
    {
        return Err(format!("invalid Unity version {version:?}").into());
    }
    Ok(parts.join("."))
}

fn lock_with(
    doc: &str,
    mut resolve: impl FnMut(&str) -> Result<LockedSource, Error>,
) -> Result<String, Error> {
    let mut root: Value = serde_json::from_str(doc)?;
    let mut versions = BTreeMap::new();
    if let Some(fetchers) = root.get("fetchInfo").and_then(Value::as_object) {
        for platforms in fetchers.values() {
            if let Some(rows) = platforms.get("x86_64-windows").and_then(Value::as_array) {
                for row in rows {
                    if row.get("unityScripting").and_then(Value::as_str) == Some("il2cpp") {
                        continue;
                    }
                    if let Some(version) = row.get("unityVersion").and_then(Value::as_str) {
                        versions
                            .entry(stream_of(version)?)
                            .or_insert_with(|| version.to_string());
                    }
                }
            }
        }
    }
    let mut locks = Map::new();
    for (stream, version) in versions {
        let lock = resolve(&version)?;
        if lock.stream != stream || !lock.source.is_object() {
            return Err(format!("Unity {version}: invalid Mono source resolver response").into());
        }
        if !lock.maintained {
            locks.insert(stream, lock.source);
        }
    }
    let obj = root
        .as_object_mut()
        .ok_or("versions.json must be an object")?;
    // Rebuild the map from its consumers: old streams disappear when the last Windows pin moves.
    if locks.is_empty() {
        obj.remove("unityMonoSources");
    } else {
        obj.insert("unityMonoSources".into(), Value::Object(locks));
    }
    let mut output = serde_json::to_string_pretty(&root)?;
    output.push('\n');
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn locks_each_windows_mono_stream_once_and_prunes_stale_sources() {
        let doc = json!({"fetchInfo":{"steam":{
            "x86_64-windows":[
                {"unityVersion":"6000.4.1f1","unityScripting":"mono"},
                {"unityVersion":"6000.4.2f1","unityScripting":"mono"},
                {"unityVersion":"6000.5.1f1","unityScripting":"il2cpp"}],
            "x86_64-linux":[{"unityVersion":"6000.6.1f1","unityScripting":"mono"}]}},
            "unityMonoSources":{"6000.1":{"obsolete":true}}});
        let mut calls = Vec::new();
        let output = lock_with(&doc.to_string(), |version| {
            calls.push(version.to_string());
            Ok(LockedSource {
                stream: "6000.4".into(),
                maintained: false,
                source: json!({"mono":{"rev":"locked"}}),
            })
        })
        .unwrap();
        assert_eq!(calls, ["6000.4.1f1"]);
        let output: Value = serde_json::from_str(&output).unwrap();
        assert_eq!(output["fetchInfo"], doc["fetchInfo"]);
        assert_eq!(
            output["unityMonoSources"],
            json!({"6000.4":{"mono":{"rev":"locked"}}})
        );
    }

    #[test]
    fn maintained_sources_leave_existing_documents_unchanged() {
        let doc = json!({"fetchInfo":{"gog":{"x86_64-windows":[{"unityVersion":"6000.3.1f1","unityScripting":"mono"}]}}});
        let text = format!("{}\n", serde_json::to_string_pretty(&doc).unwrap());
        assert_eq!(
            lock_with(&text, |_| Ok(LockedSource {
                stream: "6000.3".into(),
                maintained: true,
                source: json!({})
            }))
            .unwrap(),
            text
        );
    }

    #[test]
    fn discovery_failure_returns_no_partial_document() {
        let doc = r#"{"fetchInfo":{"gog":{"x86_64-windows":[{"unityVersion":"6000.4.1f1"}]}}}"#;
        let error = lock_with(doc, |_| Err("upstream failed".into())).unwrap_err();
        assert_eq!(error.to_string(), "upstream failed");
        assert!(lock_with(doc, |_| Ok(LockedSource {
            stream: "6000.3".into(),
            maintained: false,
            source: json!({})
        }))
        .is_err());
        assert!(stream_of("6000").is_err());
        assert!(stream_of("6000.bad.1f1").is_err());
    }
}
