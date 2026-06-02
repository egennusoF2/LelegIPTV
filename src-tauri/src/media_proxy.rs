use std::{
    collections::HashMap,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::OnceLock,
    time::Duration,
};

use percent_encoding::{percent_decode_str, utf8_percent_encode, NON_ALPHANUMERIC};

const DEFAULT_USER_AGENT: &str = "VLC/3.0.20 LibVLC/3.0.20";
const IPTV_UA_HLS: &str = "Mozilla/5.0 (Linux; Android 9; SM-G960F) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 IPTVSmartersPlayer/3.1.5";

static PORT: OnceLock<u16> = OnceLock::new();

#[tauri::command]
pub fn media_proxy_url(
    url: String,
    user_agent: Option<String>,
    referer: Option<String>,
) -> Result<String, String> {
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return Err("invalid media url".into());
    }
    let port = ensure_server()?;
    let encoded = utf8_percent_encode(&url, NON_ALPHANUMERIC).to_string();
    let mut out = format!("http://127.0.0.1:{port}/stream?url={encoded}");
    if let Some(user_agent) = user_agent.filter(|v| !v.trim().is_empty()) {
        out.push_str("&ua=");
        out.push_str(&utf8_percent_encode(user_agent.trim(), NON_ALPHANUMERIC).to_string());
    }
    if let Some(referer) = referer.filter(|v| !v.trim().is_empty()) {
        out.push_str("&referer=");
        out.push_str(&utf8_percent_encode(referer.trim(), NON_ALPHANUMERIC).to_string());
    }
    Ok(out)
}

fn ensure_server() -> Result<u16, String> {
    if let Some(port) = PORT.get() {
        return Ok(*port);
    }
    let listener = TcpListener::bind(("127.0.0.1", 0)).map_err(|e| e.to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let _ = PORT.set(port);
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            std::thread::spawn(move || {
                let _ = handle_client(stream);
            });
        }
    });
    Ok(port)
}

fn handle_client(mut stream: TcpStream) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    stream.set_write_timeout(Some(Duration::from_secs(30)))?;

    let mut request = Vec::new();
    let mut buf = [0_u8; 4096];
    loop {
        let read = stream.read(&mut buf)?;
        if read == 0 {
            return Ok(());
        }
        request.extend_from_slice(&buf[..read]);
        if request.windows(4).any(|w| w == b"\r\n\r\n") || request.len() > 64 * 1024 {
            break;
        }
    }

    let request = String::from_utf8_lossy(&request);
    let mut lines = request.split("\r\n");
    let first = lines.next().unwrap_or_default();
    let mut first_parts = first.split_whitespace();
    let method = first_parts.next().unwrap_or_default();
    let path = first_parts.next().unwrap_or_default();
    let headers = parse_headers(lines);

    if method == "OPTIONS" {
        write_empty(&mut stream, 204, "No Content", &[])?;
        return Ok(());
    }
    if method != "GET" && method != "HEAD" {
        write_text(&mut stream, 405, "Method Not Allowed", "method not allowed")?;
        return Ok(());
    }

    let target = target_request(path);
    let Some(url) = target.url else {
        write_text(&mut stream, 400, "Bad Request", "missing url")?;
        return Ok(());
    };
    if !url.starts_with("http://") && !url.starts_with("https://") {
        write_text(&mut stream, 400, "Bad Request", "invalid url")?;
        return Ok(());
    }

    match fetch_upstream_resilient(
        &url,
        method,
        headers.get("range").map(String::as_str),
        target.user_agent.as_deref(),
        target.referer.as_deref(),
    ) {
        Ok(upstream) => {
            write_upstream(
                &mut stream,
                method,
                &url,
                target.user_agent.as_deref(),
                target.referer.as_deref(),
                upstream,
            )?;
        }
        Err(error) => {
            write_text(
                &mut stream,
                502,
                "Bad Gateway",
                &format!("upstream error: {error}"),
            )?;
        }
    }
    Ok(())
}

fn parse_headers<'a>(lines: impl Iterator<Item = &'a str>) -> HashMap<String, String> {
    let mut headers = HashMap::new();
    for line in lines {
        if line.is_empty() {
            break;
        }
        if let Some((key, value)) = line.split_once(':') {
            headers.insert(key.trim().to_ascii_lowercase(), value.trim().to_string());
        }
    }
    headers
}

struct TargetRequest {
    url: Option<String>,
    user_agent: Option<String>,
    referer: Option<String>,
}

fn decode_query_value(value: &str) -> Option<String> {
    percent_decode_str(value)
        .decode_utf8()
        .ok()
        .map(|v| v.to_string())
}

fn target_request(path: &str) -> TargetRequest {
    let mut target = TargetRequest {
        url: None,
        user_agent: None,
        referer: None,
    };
    let Some(query) = path.split_once('?').map(|v| v.1) else {
        return target;
    };
    for pair in query.split('&') {
        let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
        match key {
            "url" => target.url = decode_query_value(value),
            "ua" => target.user_agent = decode_query_value(value),
            "referer" => target.referer = decode_query_value(value),
            _ => {}
        }
    }
    target
}

fn origin_for(url: &str) -> Option<String> {
    let parsed = reqwest::Url::parse(url).ok()?;
    Some(format!("{}://{}/", parsed.scheme(), parsed.host_str()?))
}

fn is_iptv_media_url(url: &str) -> bool {
    let Ok(parsed) = reqwest::Url::parse(url) else {
        return false;
    };
    let path = parsed.path().to_lowercase();
    if path.ends_with(".m3u8")
        || path.ends_with(".ts")
        || path.ends_with(".m4s")
        || path.ends_with(".mp4")
        || path.ends_with(".mkv")
    {
        return true;
    }
    path.contains("/live/")
        || path.contains("/movie/")
        || path.contains("/series/")
        || path.contains("/timeshift/")
        || path.contains("/play/")
}

fn resolve_upstream_user_agent(url: &str, client_ua: Option<&str>) -> String {
    if let Some(ua) = client_ua.filter(|v| !v.trim().is_empty()) {
        return ua.to_string();
    }
    if url.contains(".m3u8") || url.contains("/live/") {
        return IPTV_UA_HLS.to_string();
    }
    if url.contains("/movie/") || url.contains("/series/") {
        return DEFAULT_USER_AGENT.to_string();
    }
    if is_iptv_media_url(url) {
        return IPTV_UA_HLS.to_string();
    }
    DEFAULT_USER_AGENT.to_string()
}

fn is_local_proxy_url(url: &str) -> bool {
    reqwest::Url::parse(url)
        .ok()
        .map(|parsed| {
            let host = parsed.host_str().unwrap_or("");
            (host == "127.0.0.1" || host == "localhost") && parsed.path() == "/stream"
        })
        .unwrap_or(false)
}

fn resolve_playlist_url(base: &str, reference: &str) -> String {
    if reference.starts_with("http://") || reference.starts_with("https://") {
        return reference.to_string();
    }
    reqwest::Url::parse(base)
        .ok()
        .and_then(|base_url| base_url.join(reference).ok().map(|joined| joined.to_string()))
        .unwrap_or_else(|| reference.to_string())
}

fn wrap_url_for_media_proxy(
    absolute_url: &str,
    port: u16,
    user_agent: Option<&str>,
    referer: Option<&str>,
) -> String {
    if is_local_proxy_url(absolute_url) {
        return absolute_url.to_string();
    }
    if !absolute_url.starts_with("http://") && !absolute_url.starts_with("https://") {
        return absolute_url.to_string();
    }
    let encoded = utf8_percent_encode(absolute_url, NON_ALPHANUMERIC).to_string();
    let mut out = format!("http://127.0.0.1:{port}/stream?url={encoded}");
    if let Some(ua) = user_agent.filter(|v| !v.trim().is_empty()) {
        out.push_str("&ua=");
        out.push_str(&utf8_percent_encode(ua.trim(), NON_ALPHANUMERIC).to_string());
    }
    if let Some(referer) = referer.filter(|v| !v.trim().is_empty()) {
        out.push_str("&referer=");
        out.push_str(&utf8_percent_encode(referer.trim(), NON_ALPHANUMERIC).to_string());
    }
    out
}

fn rewrite_uri_attributes(
    line: &str,
    base_url: &str,
    port: u16,
    user_agent: Option<&str>,
    referer: Option<&str>,
) -> String {
    let mut out = line.to_string();
    let mut search_from = 0;
    while let Some(rel) = out[search_from..].find("URI=\"") {
        let start = search_from + rel + 5;
        let Some(end_rel) = out[start..].find('"') else {
            break;
        };
        let uri = &out[start..start + end_rel];
        let abs = resolve_playlist_url(base_url, uri);
        if abs.starts_with("http://") || abs.starts_with("https://") {
            let wrapped = wrap_url_for_media_proxy(&abs, port, user_agent, referer);
            out.replace_range(start..start + end_rel, &wrapped);
            search_from = start + wrapped.len();
        } else {
            search_from = start + end_rel;
        }
    }
    out
}

fn rewrite_m3u8_line(
    line: &str,
    base_url: &str,
    port: u16,
    user_agent: Option<&str>,
    referer: Option<&str>,
) -> String {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return line.to_string();
    }
    if is_local_proxy_url(trimmed) {
        return line.to_string();
    }
    if trimmed.contains("URI=\"") {
        return rewrite_uri_attributes(line, base_url, port, user_agent, referer);
    }
    if !trimmed.starts_with('#') {
        if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
            return wrap_url_for_media_proxy(trimmed, port, user_agent, referer);
        }
        let abs = resolve_playlist_url(base_url, trimmed);
        if abs.starts_with("http://") || abs.starts_with("https://") {
            return wrap_url_for_media_proxy(&abs, port, user_agent, referer);
        }
    }
    line.to_string()
}

fn rewrite_m3u8_playlist(
    body: &str,
    base_url: &str,
    port: u16,
    user_agent: Option<&str>,
    referer: Option<&str>,
) -> String {
    body.split_inclusive('\n')
        .map(|line| {
            let normalized = line.strip_suffix('\n').unwrap_or(line);
            let rewritten = rewrite_m3u8_line(normalized, base_url, port, user_agent, referer);
            if line.ends_with('\n') {
                format!("{rewritten}\n")
            } else {
                rewritten
            }
        })
        .collect()
}

fn body_looks_like_m3u8(body: &[u8], target_url: &str, content_type: Option<&str>) -> bool {
    if let Ok(text) = std::str::from_utf8(body) {
        let trimmed = text.trim_start();
        if trimmed.starts_with('<') || trimmed.starts_with('{') {
            return false;
        }
        if text.contains("#EXTM3U") || text.contains("#EXT-X-") {
            return true;
        }
    }
    if target_url.contains(".m3u8") {
        return true;
    }
    if let Some(ct) = content_type {
        let lower = ct.to_ascii_lowercase();
        if lower.contains("mpegurl") || lower.contains("m3u8") || lower.contains("vnd.apple") {
            return true;
        }
    }
    false
}

fn fetch_upstream_resilient(
    url: &str,
    method: &str,
    range: Option<&str>,
    user_agent: Option<&str>,
    referer: Option<&str>,
) -> Result<reqwest::blocking::Response, reqwest::Error> {
    let ua = resolve_upstream_user_agent(url, user_agent);
    if method == "HEAD" {
        match fetch_upstream(url, "HEAD", range, Some(&ua), referer) {
            Ok(response) => {
                let status = response.status().as_u16();
                if response.status().is_success() || status == 206 {
                    return Ok(response);
                }
                if status == 405 || status == 501 || status == 403 || status >= 500 {
                    let fallback_range = range.filter(|v| !v.trim().is_empty()).unwrap_or("bytes=0-0");
                    return fetch_upstream(url, "GET", Some(fallback_range), Some(&ua), referer);
                }
                Ok(response)
            }
            Err(_) => {
                let fallback_range = range.filter(|v| !v.trim().is_empty()).unwrap_or("bytes=0-0");
                fetch_upstream(url, "GET", Some(fallback_range), Some(&ua), referer)
            }
        }
    } else {
        fetch_upstream(url, method, range, Some(&ua), referer)
    }
}

fn fetch_upstream(
    url: &str,
    method: &str,
    range: Option<&str>,
    user_agent: Option<&str>,
    referer: Option<&str>,
) -> Result<reqwest::blocking::Response, reqwest::Error> {
    let client = reqwest::blocking::Client::builder()
        .redirect(reqwest::redirect::Policy::limited(5))
        .connect_timeout(Duration::from_secs(10))
        .build()?;
    let request_method = if method == "HEAD" {
        reqwest::Method::HEAD
    } else {
        reqwest::Method::GET
    };
    let ua = user_agent
        .filter(|v| !v.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| resolve_upstream_user_agent(url, None));
    let mut request = client
        .request(request_method.clone(), url)
        .header(reqwest::header::USER_AGENT, ua.clone());
    if let Some(range) = range.filter(|v| !v.trim().is_empty()) {
        request = request.header(reqwest::header::RANGE, range);
    }
    if let Some(referer) = referer
        .filter(|v| !v.trim().is_empty())
        .map(str::to_string)
        .or_else(|| origin_for(url))
    {
        request = request.header(reqwest::header::REFERER, referer);
    }
    let response = request.send()?;
    if response.status().is_server_error() && url.starts_with("https://") {
        let fallback = url.replacen("https://", "http://", 1);
        let mut fallback_request = client
            .request(request_method, fallback)
            .header(reqwest::header::USER_AGENT, ua);
        if let Some(range) = range.filter(|v| !v.trim().is_empty()) {
            fallback_request = fallback_request.header(reqwest::header::RANGE, range);
        }
        if let Some(referer) = referer
            .filter(|v| !v.trim().is_empty())
            .map(str::to_string)
            .or_else(|| origin_for(url))
        {
            fallback_request = fallback_request.header(reqwest::header::REFERER, referer);
        }
        if let Ok(fallback_response) = fallback_request.send() {
            return Ok(fallback_response);
        }
    }
    Ok(response)
}

fn status_text(status: u16) -> &'static str {
    match status {
        200 => "OK",
        204 => "No Content",
        206 => "Partial Content",
        400 => "Bad Request",
        405 => "Method Not Allowed",
        416 => "Range Not Satisfiable",
        502 => "Bad Gateway",
        _ => "OK",
    }
}

fn write_common_headers(stream: &mut TcpStream, status: u16, reason: &str) -> std::io::Result<()> {
    write!(stream, "HTTP/1.1 {status} {reason}\r\n")?;
    write!(stream, "Access-Control-Allow-Origin: *\r\n")?;
    write!(
        stream,
        "Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges\r\n"
    )?;
    write!(stream, "Connection: close\r\n")?;
    Ok(())
}

fn write_empty(
    stream: &mut TcpStream,
    status: u16,
    reason: &str,
    extra_headers: &[(&str, String)],
) -> std::io::Result<()> {
    write_common_headers(stream, status, reason)?;
    for (key, value) in extra_headers {
        write!(stream, "{key}: {value}\r\n")?;
    }
    write!(stream, "Content-Length: 0\r\n\r\n")?;
    stream.flush()
}

fn write_text(
    stream: &mut TcpStream,
    status: u16,
    reason: &str,
    text: &str,
) -> std::io::Result<()> {
    write_common_headers(stream, status, reason)?;
    write!(stream, "Content-Type: text/plain; charset=utf-8\r\n")?;
    write!(stream, "Content-Length: {}\r\n\r\n", text.len())?;
    stream.write_all(text.as_bytes())?;
    stream.flush()
}

fn write_upstream(
    stream: &mut TcpStream,
    method: &str,
    target_url: &str,
    user_agent: Option<&str>,
    referer: Option<&str>,
    mut response: reqwest::blocking::Response,
) -> std::io::Result<()> {
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    let content_type = headers
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok());

    // For binary media responses (TS segments, MP4, etc.) stream directly without
    // buffering the full body in RAM. Buffering causes live HLS stalls because
    // AVFoundation must wait for the entire segment before decoding can begin.
    // M3U8 manifests must still be buffered to rewrite segment URLs.
    let is_head = method == "HEAD";
    let needs_rewrite = !is_head && body_looks_like_m3u8(&[], target_url, content_type);

    if !is_head && !needs_rewrite {
        // Streaming path: write headers then pipe body directly
        write_common_headers(stream, status, status_text(status))?;
        for (header, dst) in [
            (reqwest::header::CONTENT_TYPE, "Content-Type"),
            (reqwest::header::CONTENT_LENGTH, "Content-Length"),
            (reqwest::header::CONTENT_RANGE, "Content-Range"),
            (reqwest::header::ACCEPT_RANGES, "Accept-Ranges"),
        ] {
            if let Some(value) = headers.get(&header).and_then(|v| v.to_str().ok()) {
                write!(stream, "{dst}: {value}\r\n")?;
            }
        }
        write!(stream, "\r\n")?;
        std::io::copy(&mut response, stream)?;
        return stream.flush();
    }

    // Buffered path: M3U8 (needs URL rewriting) or HEAD
    let mut body = if is_head {
        Vec::new()
    } else {
        response.bytes().map(|b| b.to_vec()).unwrap_or_default()
    };
    if !is_head {
        if let Some(port) = PORT.get().copied() {
            if body_looks_like_m3u8(&body, target_url, content_type) {
                let text = String::from_utf8_lossy(&body);
                let rewritten =
                    rewrite_m3u8_playlist(&text, target_url, port, user_agent, referer);
                body = rewritten.into_bytes();
            }
        }
    }
    write_common_headers(stream, status, status_text(status))?;
    for (header, dst) in [
        (reqwest::header::CONTENT_TYPE, "Content-Type"),
        (reqwest::header::CONTENT_LENGTH, "Content-Length"),
        (reqwest::header::CONTENT_RANGE, "Content-Range"),
        (reqwest::header::ACCEPT_RANGES, "Accept-Ranges"),
    ] {
        if let Some(value) = headers.get(&header).and_then(|v| v.to_str().ok()) {
            if header == reqwest::header::CONTENT_LENGTH && !is_head {
                continue;
            }
            write!(stream, "{dst}: {value}\r\n")?;
        }
    }
    if !headers.contains_key(reqwest::header::CONTENT_LENGTH) || !is_head {
        write!(stream, "Content-Length: {}\r\n", body.len())?;
    }
    write!(stream, "\r\n")?;
    if !is_head {
        stream.write_all(&body)?;
    }
    stream.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rewrites_segment_urls_in_playlist() {
        let body = "#EXTM3U\n#EXTINF:6.0,\nhttp://cdn.example.com/live/seg.ts\n";
        let out = rewrite_m3u8_playlist(
            body,
            "http://panel.example.com/live/u/p/1.m3u8",
            9123,
            Some(IPTV_UA_HLS),
            Some("http://panel.example.com/"),
        );
        assert!(out.contains("http://127.0.0.1:9123/stream?url="));
        assert!(!out.contains("http://cdn.example.com/live/seg.ts"));
    }

    #[test]
    fn resolves_relative_playlist_entries() {
        let body = "#EXTM3U\nvariant.m3u8\n";
        let out = rewrite_m3u8_playlist(
            body,
            "http://panel.example.com/live/u/p/master.m3u8",
            9000,
            None,
            None,
        );
        assert!(out.contains("http://127.0.0.1:9000/stream?url="));
        assert!(!out.contains("\nvariant.m3u8\n"));
    }
}
