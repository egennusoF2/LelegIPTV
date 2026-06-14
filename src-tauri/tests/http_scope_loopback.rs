//! Verifies Tauri HTTP ACL patterns allow the Rust media proxy URL shape.

use url::Url;

// Mirrors tauri-plugin-http scope parsing (urlpattern constructor strings).
fn pattern_allowed(pattern: &str, target: &str) -> bool {
    use urlpattern::{UrlPattern, UrlPatternMatchInput};

    let mut init =
        urlpattern::UrlPatternInit::parse_constructor_string::<regex::Regex>(pattern, None)
            .expect("pattern");
    if init.search.as_ref().map(|p| p.is_empty()).unwrap_or(true) {
        init.search.replace("*".to_string());
    }
    if init.hash.as_ref().map(|p| p.is_empty()).unwrap_or(true) {
        init.hash.replace("*".to_string());
    }
    if init
        .pathname
        .as_ref()
        .map(|p| p.is_empty() || p == "/")
        .unwrap_or(true)
    {
        init.pathname.replace("*".to_string());
    }
    let entry: UrlPattern<regex::Regex> =
        UrlPattern::parse(init, Default::default()).expect("urlpattern");
    let url = Url::parse(target).expect("url");
    entry
        .test(UrlPatternMatchInput::Url(url))
        .unwrap_or_default()
}

const PROXY_URL: &str = "http://127.0.0.1:52643/__stream?url=http%3A%2F%2Fexample.com%2Flive%2Fa%2Fb%2F1.m3u8&ua=test&referer=http%3A%2F%2Fexample.com%2F";

const PATTERNS: &[&str] = &[
    "http://**/*",
    "http://127.0.0.1:*",
    "http://127.0.0.1:*/*",
    "*://127.0.0.1:*",
    "*://127.0.0.1:*/*",
    "*://*:*",
    "*://*:*/*",
];

#[test]
fn loopback_media_proxy_matches_acl_patterns() {
    let mut any = false;
    for pattern in PATTERNS {
        if pattern_allowed(pattern, PROXY_URL) {
            any = true;
            break;
        }
    }
    assert!(
        any,
        "no ACL pattern matched proxy URL; update capabilities/default.json"
    );
}

#[test]
fn http_wildcard_host_does_not_match_ip_loopback() {
    assert!(
        !pattern_allowed("http://**/*", PROXY_URL),
        "http://**/* must not be relied on for 127.0.0.1 (Tauri quirk)"
    );
}
