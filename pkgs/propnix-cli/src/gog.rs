//! GOG account provider. Login is the GOG Galaxy OAuth2 authorization-code flow: GOG's login form is
//! reCAPTCHA-gated, so a CLI can't take a username/password directly — instead we open the Galaxy auth URL
//! in the user's browser (xdg-open; print it as a fallback), they log in there, and paste back the
//! `on_login_success?...code=…` redirect URL. We exchange that code for tokens at `auth.gog.com/token` and
//! write the flat `galaxy_tokens.json` the fetcher already consumes. After this one-time mint the fetcher
//! only ever uses the (non-rotating) refresh_token, non-interactively.

use crate::provider::{Credential, Provider};
use std::io::Write;
use std::process::Command;

// The public GOG Galaxy desktop-client credentials (shipped in every Galaxy client; not secret). Same pair
// gogdl/lgogdownloader use, and what our fetcher's refresh already relies on.
const CLIENT_ID: &str = "46899977096215655";
const CLIENT_SECRET: &str = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9";
// The redirect_uri MUST match byte-for-byte between the auth URL and the token exchange.
const REDIRECT_URI: &str = "https://embed.gog.com/on_login_success?origin=client";
// Pre-encoded auth URL (redirect_uri percent-encoded); layout=client2 is the Galaxy desktop login.
const AUTH_URL: &str = "https://auth.gog.com/auth?client_id=46899977096215655&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=client2";

pub struct Gog;

impl Provider for Gog {
    fn type_name(&self) -> &'static str {
        "gog"
    }
    fn display_name(&self) -> &'static str {
        "GOG"
    }
    fn token_filename(&self) -> &'static str {
        "galaxy_tokens.json"
    }

    fn login(&self) -> Result<Credential, String> {
        // 1. Open the login page in the user's browser (best-effort), else print it to open manually.
        eprintln!("propnix: opening the GOG login page in your browser…");
        let opened = Command::new("xdg-open")
            .arg(AUTH_URL)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if opened {
            eprintln!("propnix: if it didn't open, use this URL:");
        } else {
            eprintln!("propnix: couldn't open a browser automatically — open this URL yourself:");
        }
        eprintln!("  {AUTH_URL}\n");
        eprintln!(
            "Log in in the browser (password, 2FA and captcha all happen there). When it finishes it lands\n\
             on a blank/error page whose address looks like\n  \
             https://embed.gog.com/on_login_success?origin=client&code=…\n\
             Copy that FULL address (or just the code) and paste it below."
        );

        // 2. Read back the redirect URL / code and extract the authorization code.
        eprint!("Redirect URL or code: ");
        std::io::stderr().flush().ok();
        let mut line = String::new();
        std::io::stdin()
            .read_line(&mut line)
            .map_err(|e| format!("reading input: {e}"))?;
        let code = extract_code(line.trim());
        if code.is_empty() {
            return Err("no authorization code found in the pasted input".into());
        }

        // 3. Exchange the code for tokens (authorization_code grant). Secrets travel in the request, never
        //    in a subprocess argv.
        // Don't surface the ureq error verbatim — its Display includes the full request URL (client_secret +
        // the auth code). Report just the HTTP status / a transport summary.
        let token_body: serde_json::Value = ureq::get("https://auth.gog.com/token")
            .query("client_id", CLIENT_ID)
            .query("client_secret", CLIENT_SECRET)
            .query("grant_type", "authorization_code")
            .query("code", &code)
            .query("redirect_uri", REDIRECT_URI)
            .call()
            .map_err(|e| match e {
                ureq::Error::Status(code, _) => format!(
                    "GOG rejected the authorization code (HTTP {code}) — it may be expired or already used; \
                     re-run `propnix cred add gog` and paste a fresh redirect URL"
                ),
                ureq::Error::Transport(t) => format!("could not reach GOG's token endpoint: {t}"),
            })?
            .into_json()
            .map_err(|e| format!("parsing GOG token response: {e}"))?;

        let access_token = token_body
            .get("access_token")
            .and_then(|v| v.as_str())
            .ok_or("GOG token response had no access_token")?
            .to_string();
        if token_body.get("refresh_token").and_then(|v| v.as_str()).is_none() {
            return Err("GOG token response had no refresh_token".into());
        }

        // 4. Resolve the account username (for the label + the store dir). Best-effort — fall back to the
        //    numeric user_id if the lookup fails.
        let username = fetch_username(&access_token)
            .or_else(|| token_body.get("user_id").and_then(|v| v.as_str()).map(str::to_string))
            .ok_or("could not determine the GOG account username")?;

        // 5. Build galaxy_tokens.json: the token response, plus the client_id/client_secret keys the existing
        //    file format carries (the fetcher's gogdl refresh uses its own hardcoded pair, but keep the shape).
        let mut token = token_body;
        token["client_id"] = serde_json::Value::String(CLIENT_ID.to_string());
        token["client_secret"] = serde_json::Value::String(CLIENT_SECRET.to_string());
        let bytes = serde_json::to_vec_pretty(&token)
            .map_err(|e| format!("serializing token: {e}"))?;

        Ok(Credential { username, token: bytes })
    }
}

/// GOG's account username, via the Galaxy `userData.json` endpoint. None on any failure.
fn fetch_username(access_token: &str) -> Option<String> {
    let body: serde_json::Value = ureq::get("https://embed.gog.com/userData.json")
        .set("Authorization", &format!("Bearer {access_token}"))
        .call()
        .ok()?
        .into_json()
        .ok()?;
    body.get("username")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// Pull the `code` out of a pasted `on_login_success?...code=XYZ[&…]` URL; if the input has no `code=` (the
/// user pasted just the code) return it as-is. Trims a trailing fragment/query on the code too.
fn extract_code(input: &str) -> String {
    match input.find("code=") {
        Some(i) => {
            let rest = &input[i + "code=".len()..];
            rest.split(['&', '#']).next().unwrap_or("").to_string()
        }
        None => input.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::extract_code;
    #[test]
    fn code_from_url() {
        assert_eq!(
            extract_code("https://embed.gog.com/on_login_success?origin=client&code=ABC123&x=1"),
            "ABC123"
        );
        assert_eq!(extract_code("https://www.gog.com/on_login_success?code=DEF456"), "DEF456");
        assert_eq!(extract_code("PLAINCODE"), "PLAINCODE");
    }
}
