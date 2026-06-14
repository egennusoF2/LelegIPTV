use std::{
    collections::{hash_map::DefaultHasher, HashMap},
    fs,
    fs::File,
    hash::{Hash, Hasher},
    io::{BufReader, Read, Seek, SeekFrom, Write},
    net::{TcpListener, TcpStream},
    path::PathBuf,
    process::{Command, Stdio},
    sync::OnceLock,
    time::Duration,
};

use percent_encoding::{percent_decode_str, utf8_percent_encode, NON_ALPHANUMERIC};
use serde::Serialize;
use serde_json::Value;

const DEFAULT_USER_AGENT: &str = "VLC/3.0.20 LibVLC/3.0.20";
const IPTV_UA_HLS: &str = "Mozilla/5.0 (Linux; Android 9; SM-G960F) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 IPTVSmartersPlayer/3.1.5";

static PORT: OnceLock<u16> = OnceLock::new();
static HTTP_CLIENT: OnceLock<reqwest::blocking::Client> = OnceLock::new();
const MAX_SUBTITLE_TRACKS: usize = 32;

fn shared_http_client() -> &'static reqwest::blocking::Client {
    HTTP_CLIENT.get_or_init(|| {
        reqwest::blocking::Client::builder()
            .cookie_store(true)
            .redirect(reqwest::redirect::Policy::limited(5))
            .connect_timeout(Duration::from_secs(8))
            .timeout(Duration::from_secs(300))
            .build()
            .expect("media_proxy http client")
    })
}

/// On macOS, return the `xtproxy://localhost` custom scheme base so WKWebView
/// can load media without triggering mixed-content blocking against `tauri://localhost`.
/// On all other platforms keep the plain loopback address.
fn stream_proxy_base(port: u16) -> String {
    #[cfg(target_os = "macos")]
    {
        let _ = port;
        return "xtproxy://localhost".to_string();
    }
    #[cfg(not(target_os = "macos"))]
    format!("http://127.0.0.1:{port}")
}

/// Start the loopback proxy early so the first channel tune does not wait on bind.
pub fn warmup() {
    let _ = ensure_server();
}

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
    let mut out = format!("{}/__stream?url={encoded}", stream_proxy_base(port));
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

// ---------------------------------------------------------------------------
// FFmpeg transcoding (MKV → MPEG-TS for WKWebView playback via mpegts.js)
// ---------------------------------------------------------------------------

/// Returns the path of the first usable `ffmpeg` binary found on the system.
/// Checks common Homebrew and system locations so we don't depend on PATH being
/// set correctly when the macOS app is launched from Finder.
fn find_ffmpeg() -> Option<PathBuf> {
    let candidates = [
        "/opt/homebrew/bin/ffmpeg", // Homebrew arm64 (Apple Silicon)
        "/usr/local/bin/ffmpeg",    // Homebrew x86_64
        "/usr/bin/ffmpeg",          // system (Linux)
    ];
    for path in &candidates {
        if std::path::Path::new(path).exists() {
            return Some(PathBuf::from(path));
        }
    }
    // Last resort: ask the shell — works when app is launched from a terminal
    if let Ok(out) = Command::new("which").arg("ffmpeg").output() {
        if out.status.success() {
            if let Ok(s) = std::str::from_utf8(&out.stdout) {
                let t = s.trim();
                if !t.is_empty() && std::path::Path::new(t).exists() {
                    return Some(PathBuf::from(t));
                }
            }
        }
    }
    None
}

fn find_ffprobe() -> Option<PathBuf> {
    let candidates = [
        "/opt/homebrew/bin/ffprobe",
        "/usr/local/bin/ffprobe",
        "/usr/bin/ffprobe",
    ];
    for path in &candidates {
        if std::path::Path::new(path).exists() {
            return Some(PathBuf::from(path));
        }
    }
    if let Some(ffmpeg) = find_ffmpeg() {
        if let Some(dir) = ffmpeg.parent() {
            let sibling = dir.join("ffprobe");
            if sibling.exists() {
                return Some(sibling);
            }
        }
    }
    if let Ok(out) = Command::new("which").arg("ffprobe").output() {
        if out.status.success() {
            if let Ok(s) = std::str::from_utf8(&out.stdout) {
                let t = s.trim();
                if !t.is_empty() && std::path::Path::new(t).exists() {
                    return Some(PathBuf::from(t));
                }
            }
        }
    }
    None
}

/// Build a loopback URL for the `/__transcode` endpoint (FFmpeg MKV→TS).
#[tauri::command]
pub fn transcode_proxy_url(
    url: String,
    user_agent: Option<String>,
    referer: Option<String>,
    audio_index: Option<u32>,
    start_seconds: Option<f64>,
) -> Result<String, String> {
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return Err("invalid media url".into());
    }
    let port = ensure_server()?;
    let encoded = utf8_percent_encode(&url, NON_ALPHANUMERIC).to_string();
    let mut out = format!("{}/__transcode?url={encoded}", stream_proxy_base(port));
    if let Some(ua) = user_agent.filter(|v| !v.trim().is_empty()) {
        out.push_str("&ua=");
        out.push_str(&utf8_percent_encode(ua.trim(), NON_ALPHANUMERIC).to_string());
    }
    if let Some(r) = referer.filter(|v| !v.trim().is_empty()) {
        out.push_str("&referer=");
        out.push_str(&utf8_percent_encode(r.trim(), NON_ALPHANUMERIC).to_string());
    }
    if let Some(index) = audio_index {
        out.push_str("&audio=");
        out.push_str(&index.to_string());
    }
    if let Some(start) = start_seconds.filter(|v| v.is_finite() && *v > 0.5) {
        out.push_str("&start=");
        out.push_str(&format!("{:.3}", start.max(0.0)));
    }
    Ok(out)
}

#[tauri::command]
pub fn vod_hls_proxy_url(
    url: String,
    user_agent: Option<String>,
    referer: Option<String>,
    audio_index: Option<u32>,
) -> Result<String, String> {
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return Err("invalid media url".into());
    }
    let port = ensure_server()?;
    let encoded = utf8_percent_encode(&url, NON_ALPHANUMERIC).to_string();
    let mut out = format!(
        "{}/__vod_hls?url={encoded}&audio={}",
        stream_proxy_base(port),
        audio_index.unwrap_or(0)
    );
    if let Some(ua) = user_agent.filter(|v| !v.trim().is_empty()) {
        out.push_str("&ua=");
        out.push_str(&utf8_percent_encode(ua.trim(), NON_ALPHANUMERIC).to_string());
    }
    if let Some(r) = referer.filter(|v| !v.trim().is_empty()) {
        out.push_str("&referer=");
        out.push_str(&utf8_percent_encode(r.trim(), NON_ALPHANUMERIC).to_string());
    }
    Ok(out)
}

/// Handle `GET /__transcode?url=…` — spawns `ffmpeg -i <url> -c copy -f mpegts pipe:1`
/// and streams the output back to the caller as `video/mp2t`.
///
/// This mirrors what Megacubo's `StreamerFFmpeg` does internally: the container is
/// remuxed (codec-copy, no transcoding) so WKWebView never sees the MKV wrapper and
/// mpegts.js can play the stream directly.
fn handle_transcode(stream: &mut TcpStream, path: &str, method: &str) -> std::io::Result<()> {
    if method == "OPTIONS" {
        return write_empty(stream, 204, "No Content", &[]);
    }
    if method != "GET" && method != "HEAD" {
        return write_text(stream, 405, "Method Not Allowed", "method not allowed");
    }

    let target = target_request(path);
    let Some(url) = target.url else {
        return write_text(stream, 400, "Bad Request", "missing url");
    };
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return write_text(stream, 400, "Bad Request", "invalid url");
    }

    let Some(ffmpeg_bin) = find_ffmpeg() else {
        log::warn!("[media_proxy] ffmpeg not found; cannot transcode {}", url);
        return write_text(stream, 503, "Service Unavailable", "ffmpeg not found");
    };

    let user_agent = target
        .user_agent
        .as_deref()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or(DEFAULT_USER_AGENT);

    let referer = target.referer.as_deref().filter(|v| !v.trim().is_empty());
    let audio_index = target.audio_index.unwrap_or(0);
    let start_seconds = target.start_seconds.unwrap_or(0.0).max(0.0);

    // For HEAD requests we just confirm FFmpeg exists and return OK — mpegts.js
    // uses HEAD to check reachability before attaching.
    if method == "HEAD" {
        return write_empty(
            stream,
            200,
            "OK",
            &[
                ("Content-Type", "video/mp2t".to_string()),
                ("Cache-Control", "no-cache".to_string()),
            ],
        );
    }

    log::info!(
        "[media_proxy] transcode GET {} audio {} start {:.3}",
        redact_media_url(&url),
        audio_index,
        start_seconds
    );

    let mut args: Vec<String> = vec![
        "-hide_banner".into(),
        "-loglevel".into(),
        "error".into(),
        "-user_agent".into(),
        user_agent.to_string(),
    ];
    if let Some(r) = referer {
        // Pass referer as a custom header via -headers
        args.extend(["-headers".into(), format!("Referer: {r}\r\n")]);
    }
    if start_seconds > 0.5 {
        args.extend(["-ss".into(), format!("{start_seconds:.3}")]);
    }
    args.extend([
        "-fflags".into(),
        "+genpts+discardcorrupt".into(),
        "-i".into(),
        url.clone(),
        "-map".into(),
        "0:v:0?".into(),
        "-map".into(),
        format!("0:a:{audio_index}?"),
        "-c:v".into(),
        "copy".into(),
        "-c:a".into(),
        "aac".into(),
        "-b:a".into(),
        "192k".into(),
        "-f".into(),
        "mpegts".into(),
        "pipe:1".into(),
    ]);

    let mut child = match Command::new(&ffmpeg_bin)
        .args(&args)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            log::warn!("[media_proxy] ffmpeg spawn error: {e}");
            return write_text(stream, 500, "Internal Server Error", "ffmpeg spawn failed");
        }
    };

    let stdout = match child.stdout.take() {
        Some(s) => s,
        None => {
            let _ = child.kill();
            return write_text(stream, 500, "Internal Server Error", "no ffmpeg stdout");
        }
    };

    // No per-write deadline for the streaming portion — each individual write
    // on a loopback socket is instantaneous; the timeout only risks killing a
    // legitimate long-running movie stream.
    let _ = stream.set_write_timeout(None);

    // Write response headers (HTTP/1.0-style: no Content-Length, close on EOF)
    write_common_headers(stream, 200, "OK")?;
    write!(stream, "Content-Type: video/mp2t\r\n")?;
    write!(stream, "Cache-Control: no-cache\r\n")?;
    write!(stream, "Connection: close\r\n")?;
    write!(stream, "\r\n")?;
    stream.flush()?;

    // Pipe FFmpeg stdout → TCP socket
    let mut reader = BufReader::new(stdout);
    let mut buf = [0u8; 65536];
    let mut total_bytes: u64 = 0;
    let mut chunks: u64 = 0;
    let mut end_reason = "ffmpeg_eof";
    loop {
        match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if stream.write_all(&buf[..n]).is_err() {
                    // Client disconnected — kill FFmpeg immediately
                    end_reason = "client_disconnect";
                    break;
                }
                total_bytes += n as u64;
                chunks += 1;
            }
            Err(_) => {
                end_reason = "ffmpeg_read_error";
                break;
            }
        }
    }
    let _ = stream.flush();
    let _ = child.kill();
    let status = child.wait().ok();
    log::info!(
        "[media_proxy] transcode end {} audio {} start {:.3} reason={} bytes={} chunks={} status={:?}",
        redact_media_url(&url),
        audio_index,
        start_seconds,
        end_reason,
        total_bytes,
        chunks,
        status
    );
    Ok(())
}

// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct VodAudioTrack {
    index: usize,
    language: String,
    label: String,
    codec: String,
}

#[derive(Serialize)]
struct VodSubtitleTrack {
    index: usize,
    language: String,
    label: String,
    codec: String,
    src: String,
}

#[derive(Serialize)]
struct VodStreamsResponse {
    audio: Vec<VodAudioTrack>,
    subtitles: Vec<VodSubtitleTrack>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

fn ffmpeg_header_args(user_agent: &str, referer: Option<&str>) -> Vec<String> {
    let mut args = vec!["-user_agent".to_string(), user_agent.to_string()];
    if let Some(r) = referer.filter(|v| !v.trim().is_empty()) {
        args.extend(["-headers".to_string(), format!("Referer: {r}\r\n")]);
    }
    args
}

fn stream_tag(stream: &Value, key: &str) -> String {
    stream
        .get("tags")
        .and_then(|tags| tags.get(key))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

fn stream_codec(stream: &Value) -> String {
    stream
        .get("codec_name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

fn is_extractable_subtitle_codec(codec: &str) -> bool {
    let name = codec.to_ascii_lowercase();
    if name.contains("hdmv")
        || name.contains("pgs")
        || name == "dvd_subtitle"
        || name.contains("dvb_sub")
        || name.contains("xsub")
        || name.contains("bitmap")
    {
        return false;
    }
    matches!(
        name.as_str(),
        "subrip" | "srt" | "ass" | "ssa" | "mov_text" | "text" | "webvtt"
    ) || name.contains("subrip")
        || name.contains("ass")
        || name.contains("microdvd")
        || name.contains("subviewer")
        || name.contains("sami")
}

fn handle_vod_streams(stream: &mut TcpStream, path: &str, method: &str) -> std::io::Result<()> {
    if method == "OPTIONS" {
        return write_empty(stream, 204, "No Content", &[]);
    }
    if method != "GET" {
        return write_text(stream, 405, "Method Not Allowed", "method not allowed");
    }

    let target = target_request(path);
    let Some(url) = target.url else {
        return write_json(
            stream,
            400,
            "Bad Request",
            &VodStreamsResponse {
                audio: Vec::new(),
                subtitles: Vec::new(),
                error: Some("missing url".to_string()),
            },
        );
    };
    let Some(ffprobe_bin) = find_ffprobe() else {
        return write_json(
            stream,
            503,
            "Service Unavailable",
            &VodStreamsResponse {
                audio: Vec::new(),
                subtitles: Vec::new(),
                error: Some("ffprobe not found".to_string()),
            },
        );
    };

    let user_agent = target
        .user_agent
        .as_deref()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or(DEFAULT_USER_AGENT);
    let referer = target.referer.as_deref().filter(|v| !v.trim().is_empty());
    log::info!("[media_proxy] vod streams {}", redact_media_url(&url));

    let mut args = vec![
        "-v".to_string(),
        "error".to_string(),
        "-print_format".to_string(),
        "json".to_string(),
        "-show_streams".to_string(),
    ];
    args.extend(ffmpeg_header_args(user_agent, referer));
    args.push(url.clone());

    let output = match Command::new(ffprobe_bin).args(&args).output() {
        Ok(output) => output,
        Err(error) => {
            return write_json(
                stream,
                502,
                "Bad Gateway",
                &VodStreamsResponse {
                    audio: Vec::new(),
                    subtitles: Vec::new(),
                    error: Some(format!("ffprobe failed: {error}")),
                },
            )
        }
    };
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return write_json(
            stream,
            502,
            "Bad Gateway",
            &VodStreamsResponse {
                audio: Vec::new(),
                subtitles: Vec::new(),
                error: Some(stderr.chars().take(240).collect()),
            },
        );
    }

    let parsed: Value = match serde_json::from_slice(&output.stdout) {
        Ok(value) => value,
        Err(error) => {
            return write_json(
                stream,
                502,
                "Bad Gateway",
                &VodStreamsResponse {
                    audio: Vec::new(),
                    subtitles: Vec::new(),
                    error: Some(format!("ffprobe json: {error}")),
                },
            )
        }
    };

    let streams = parsed
        .get("streams")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut audio = Vec::new();
    let mut subtitles = Vec::new();
    let mut subtitle_stream_index = 0usize;

    for item in streams {
        let codec_type = item.get("codec_type").and_then(Value::as_str).unwrap_or("");
        let codec = stream_codec(&item);
        let language = stream_tag(&item, "language");
        let title = stream_tag(&item, "title");
        if codec_type == "audio" {
            let index = audio.len();
            audio.push(VodAudioTrack {
                index,
                language: language.clone(),
                label: if title.is_empty() { language } else { title },
                codec,
            });
        } else if codec_type == "subtitle" {
            if subtitles.len() < MAX_SUBTITLE_TRACKS && is_extractable_subtitle_codec(&codec) {
                let index = subtitle_stream_index;
                let label = if !title.is_empty() {
                    title.clone()
                } else if !language.is_empty() {
                    language.clone()
                } else {
                    codec.clone()
                };
                subtitles.push(VodSubtitleTrack {
                    index,
                    language,
                    label,
                    codec,
                    src: format!(
                        "/__vod_subtitle?url={}&index={}",
                        utf8_percent_encode(&url, NON_ALPHANUMERIC),
                        index
                    ),
                });
            }
            subtitle_stream_index += 1;
        }
    }

    write_json(
        stream,
        200,
        "OK",
        &VodStreamsResponse {
            audio,
            subtitles,
            error: None,
        },
    )
}

fn handle_vod_subtitle(stream: &mut TcpStream, path: &str, method: &str) -> std::io::Result<()> {
    if method == "OPTIONS" {
        return write_empty(stream, 204, "No Content", &[]);
    }
    if method != "GET" {
        return write_text(stream, 405, "Method Not Allowed", "method not allowed");
    }
    let target = target_request(path);
    let Some(url) = target.url else {
        return write_text(stream, 400, "Bad Request", "missing url");
    };
    let user_agent = target
        .user_agent
        .as_deref()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or(DEFAULT_USER_AGENT);
    let referer = target.referer.as_deref().filter(|v| !v.trim().is_empty());
    let subtitle_index = target.subtitle_index.unwrap_or(0);
    let out = vod_subtitle_cache_path(&url, subtitle_index);
    let ready = out.exists() && out.metadata().map(|m| m.len() > 8).unwrap_or(false);
    if target.status_only {
        return write_json(stream, 200, "OK", &serde_json::json!({ "ready": ready }));
    }
    log::info!(
        "[media_proxy] vod subtitle {} index {}",
        redact_media_url(&url),
        subtitle_index
    );
    let path = match ensure_vod_subtitle_file(&url, user_agent, referer, subtitle_index) {
        Ok(path) => path,
        Err(error) => return write_text(stream, 502, "Bad Gateway", &error.to_string()),
    };
    if target.wait_only {
        return write_empty(stream, 204, "No Content", &[]);
    }
    let body = fs::read(&path)?;
    write_common_headers(stream, 200, "OK")?;
    write!(stream, "Content-Type: text/vtt; charset=utf-8\r\n")?;
    write!(stream, "Content-Length: {}\r\n\r\n", body.len())?;
    stream.write_all(&body)?;
    stream.flush()
}

fn vod_remux_cache_path(url: &str, audio_index: u32) -> PathBuf {
    let mut hasher = DefaultHasher::new();
    url.hash(&mut hasher);
    audio_index.hash(&mut hasher);
    let hash = hasher.finish();
    std::env::temp_dir()
        .join("lelegiptv-vod-remux")
        .join(format!("{hash:016x}-a{audio_index}.mp4"))
}

fn vod_subtitle_cache_path(url: &str, subtitle_index: u32) -> PathBuf {
    let mut hasher = DefaultHasher::new();
    url.hash(&mut hasher);
    subtitle_index.hash(&mut hasher);
    let hash = hasher.finish();
    std::env::temp_dir()
        .join("lelegiptv-vod-subtitles")
        .join(format!("{hash:016x}-s{subtitle_index}.vtt"))
}

fn ensure_vod_subtitle_file(
    url: &str,
    user_agent: &str,
    referer: Option<&str>,
    subtitle_index: u32,
) -> std::io::Result<PathBuf> {
    let out = vod_subtitle_cache_path(url, subtitle_index);
    if out.exists() && out.metadata().map(|m| m.len() > 8).unwrap_or(false) {
        return Ok(out);
    }
    let Some(parent) = out.parent() else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            "invalid subtitle path",
        ));
    };
    fs::create_dir_all(parent)?;
    let tmp = out.with_extension("vtt.tmp");
    let _ = fs::remove_file(&tmp);
    let Some(ffmpeg_bin) = find_ffmpeg() else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "ffmpeg not found",
        ));
    };

    let mut args = vec![
        "-hide_banner".to_string(),
        "-loglevel".to_string(),
        "error".to_string(),
    ];
    args.extend(ffmpeg_header_args(user_agent, referer));
    args.extend([
        "-i".to_string(),
        url.to_string(),
        "-map".to_string(),
        format!("0:s:{subtitle_index}"),
        "-c:s".to_string(),
        "webvtt".to_string(),
        "-f".to_string(),
        "webvtt".to_string(),
        tmp.to_string_lossy().to_string(),
    ]);
    log::info!(
        "[media_proxy] vod subtitle extract {} index {}",
        redact_media_url(url),
        subtitle_index
    );
    let output = Command::new(ffmpeg_bin).args(&args).output()?;
    if !output.status.success() {
        let _ = fs::remove_file(&tmp);
        let err = String::from_utf8_lossy(&output.stderr);
        log::warn!(
            "[media_proxy] vod subtitle extract failed {}",
            err.chars().take(240).collect::<String>()
        );
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            "ffmpeg subtitle extract failed",
        ));
    }
    if !tmp.exists() || tmp.metadata().map(|m| m.len() <= 8).unwrap_or(true) {
        let _ = fs::remove_file(&tmp);
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            "subtitle extract produced no cues",
        ));
    }
    fs::rename(&tmp, &out)?;
    Ok(out)
}

fn vod_hls_cache_dir(url: &str, audio_index: u32) -> PathBuf {
    let mut hasher = DefaultHasher::new();
    url.hash(&mut hasher);
    audio_index.hash(&mut hasher);
    let hash = hasher.finish();
    std::env::temp_dir()
        .join("lelegiptv-vod-hls")
        .join(format!("{hash:016x}-a{audio_index}"))
}

fn vod_hls_ready(url: &str, audio_index: u32) -> bool {
    let dir = vod_hls_cache_dir(url, audio_index);
    if !dir.join("index.m3u8").exists() {
        return false;
    }
    fs::read_dir(dir)
        .ok()
        .map(|mut entries| {
            entries.any(|entry| {
                entry
                    .ok()
                    .and_then(|e| {
                        e.path()
                            .extension()
                            .map(|v| v.to_string_lossy().to_string())
                    })
                    .map(|ext| ext.eq_ignore_ascii_case("ts") || ext.eq_ignore_ascii_case("m4s"))
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

fn vod_hls_running(url: &str, audio_index: u32) -> bool {
    vod_hls_cache_dir(url, audio_index)
        .join(".ffmpeg-running")
        .exists()
}

fn vod_hls_complete(url: &str, audio_index: u32) -> bool {
    let dir = vod_hls_cache_dir(url, audio_index);
    dir.join("index.m3u8").exists() && !vod_hls_running(url, audio_index)
}

fn spawn_vod_hls(
    url: &str,
    user_agent: &str,
    referer: Option<&str>,
    audio_index: u32,
) -> std::io::Result<PathBuf> {
    let dir = vod_hls_cache_dir(url, audio_index);
    let index = dir.join("index.m3u8");
    if vod_hls_ready(url, audio_index) {
        return Ok(index);
    }
    fs::create_dir_all(&dir)?;
    let lock = dir.join(".ffmpeg-running");
    if lock.exists() {
        let stale = lock
            .metadata()
            .and_then(|meta| meta.modified())
            .ok()
            .and_then(|modified| modified.elapsed().ok())
            .map(|elapsed| elapsed > Duration::from_secs(120))
            .unwrap_or(false);
        if stale {
            let _ = fs::remove_file(&lock);
        } else {
            return Ok(index);
        }
    }
    if lock.exists() {
        return Ok(index);
    }
    let Some(ffmpeg_bin) = find_ffmpeg() else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "ffmpeg not found",
        ));
    };
    fs::write(&lock, b"running")?;

    let mut args = vec![
        "-hide_banner".to_string(),
        "-loglevel".to_string(),
        "error".to_string(),
    ];
    args.extend(ffmpeg_header_args(user_agent, referer));
    args.extend([
        "-fflags".to_string(),
        "+genpts+discardcorrupt".to_string(),
        "-i".to_string(),
        url.to_string(),
        "-map".to_string(),
        "0:v:0?".to_string(),
        "-map".to_string(),
        format!("0:a:{audio_index}?"),
        "-sn".to_string(),
        "-c:v".to_string(),
        "copy".to_string(),
        "-c:a".to_string(),
        "aac".to_string(),
        "-b:a".to_string(),
        "192k".to_string(),
        "-max_muxing_queue_size".to_string(),
        "1024".to_string(),
        "-f".to_string(),
        "hls".to_string(),
        "-hls_time".to_string(),
        "6".to_string(),
        "-hls_list_size".to_string(),
        "0".to_string(),
        "-hls_playlist_type".to_string(),
        "event".to_string(),
        "-hls_flags".to_string(),
        "independent_segments+temp_file".to_string(),
        "-hls_segment_filename".to_string(),
        dir.join("seg_%05d.ts").to_string_lossy().to_string(),
        index.to_string_lossy().to_string(),
    ]);
    log::info!(
        "[media_proxy] vod hls spawn {} audio {}",
        redact_media_url(url),
        audio_index
    );
    let log_path = dir.join("ffmpeg.log");
    let stderr = File::create(&log_path)
        .map(Stdio::from)
        .unwrap_or_else(|_| Stdio::null());
    match Command::new(ffmpeg_bin)
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(stderr)
        .spawn()
    {
        Ok(mut child) => {
            let lock_path = lock.clone();
            let redacted = redact_media_url(url);
            std::thread::spawn(move || {
                match child.wait() {
                    Ok(status) => {
                        log::info!(
                            "[media_proxy] vod hls ffmpeg exited {} {}",
                            status,
                            redacted
                        );
                    }
                    Err(error) => {
                        log::warn!("[media_proxy] vod hls ffmpeg wait failed {}", error);
                    }
                }
                let _ = fs::remove_file(lock_path);
            });
            Ok(index)
        }
        Err(error) => {
            let _ = fs::remove_file(lock);
            Err(error)
        }
    }
}

fn wait_for_file(path: &PathBuf, timeout: Duration) -> bool {
    let started = std::time::Instant::now();
    while started.elapsed() < timeout {
        if path.exists() && path.metadata().map(|m| m.len() > 0).unwrap_or(false) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    path.exists() && path.metadata().map(|m| m.len() > 0).unwrap_or(false)
}

fn wait_for_vod_hls(url: &str, audio_index: u32, timeout: Duration) -> bool {
    let started = std::time::Instant::now();
    while started.elapsed() < timeout {
        if vod_hls_ready(url, audio_index) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    vod_hls_ready(url, audio_index)
}

fn wait_for_vod_hls_complete(url: &str, audio_index: u32, timeout: Duration) -> bool {
    let started = std::time::Instant::now();
    while started.elapsed() < timeout {
        if vod_hls_complete(url, audio_index) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    vod_hls_complete(url, audio_index)
}

fn ensure_vod_remux_file(
    url: &str,
    user_agent: &str,
    referer: Option<&str>,
    audio_index: u32,
) -> std::io::Result<PathBuf> {
    let out = vod_remux_cache_path(url, audio_index);
    if out.exists() && out.metadata().map(|m| m.len() > 1024).unwrap_or(false) {
        return Ok(out);
    }
    let Some(parent) = out.parent() else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            "invalid remux path",
        ));
    };
    fs::create_dir_all(parent)?;
    let tmp = out.with_extension("mp4.tmp");
    let _ = fs::remove_file(&tmp);
    let Some(ffmpeg_bin) = find_ffmpeg() else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "ffmpeg not found",
        ));
    };

    let mut args = vec![
        "-hide_banner".to_string(),
        "-loglevel".to_string(),
        "error".to_string(),
    ];
    args.extend(ffmpeg_header_args(user_agent, referer));
    args.extend([
        "-fflags".to_string(),
        "+genpts+discardcorrupt".to_string(),
        "-i".to_string(),
        url.to_string(),
        "-map".to_string(),
        "0:v:0?".to_string(),
        "-map".to_string(),
        format!("0:a:{audio_index}?"),
        "-sn".to_string(),
        "-c:v".to_string(),
        "copy".to_string(),
        "-c:a".to_string(),
        "aac".to_string(),
        "-b:a".to_string(),
        "192k".to_string(),
        "-movflags".to_string(),
        "+faststart".to_string(),
        "-f".to_string(),
        "mp4".to_string(),
        tmp.to_string_lossy().to_string(),
    ]);

    log::info!(
        "[media_proxy] vod remux {} audio {}",
        redact_media_url(url),
        audio_index
    );
    let output = Command::new(ffmpeg_bin).args(&args).output()?;
    if !output.status.success() {
        let _ = fs::remove_file(&tmp);
        let err = String::from_utf8_lossy(&output.stderr);
        log::warn!(
            "[media_proxy] vod remux failed {}",
            err.chars().take(240).collect::<String>()
        );
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            "ffmpeg remux failed",
        ));
    }
    fs::rename(&tmp, &out)?;
    Ok(out)
}

fn serve_file_range(
    stream: &mut TcpStream,
    path: PathBuf,
    method: &str,
    content_type: &str,
    range_header: Option<&str>,
) -> std::io::Result<()> {
    let mut file = File::open(&path)?;
    let total = file.metadata()?.len();
    let mut start = 0u64;
    let mut end = total.saturating_sub(1);
    let mut partial = false;
    if let Some(range) = range_header {
        if let Some(raw) = range.strip_prefix("bytes=") {
            let mut parts = raw.splitn(2, '-');
            if let Some(a) = parts.next().filter(|v| !v.is_empty()) {
                if let Ok(value) = a.parse::<u64>() {
                    start = value.min(total);
                    partial = true;
                }
            }
            if let Some(b) = parts.next().filter(|v| !v.is_empty()) {
                if let Ok(value) = b.parse::<u64>() {
                    end = value.min(total.saturating_sub(1));
                    partial = true;
                }
            }
        }
    }
    if start >= total || start > end {
        write_common_headers(stream, 416, "Range Not Satisfiable")?;
        write!(stream, "Content-Range: bytes */{total}\r\n")?;
        write!(stream, "Content-Length: 0\r\n\r\n")?;
        return stream.flush();
    }
    let len = end - start + 1;
    let status = if partial { 206 } else { 200 };
    write_common_headers(stream, status, status_text(status))?;
    write!(stream, "Content-Type: {content_type}\r\n")?;
    write!(stream, "Accept-Ranges: bytes\r\n")?;
    if partial {
        write!(stream, "Content-Range: bytes {start}-{end}/{total}\r\n")?;
    }
    write!(stream, "Content-Length: {len}\r\n\r\n")?;
    if method == "HEAD" {
        return stream.flush();
    }
    file.seek(SeekFrom::Start(start))?;
    let mut remaining = len;
    let mut buf = [0u8; 65536];
    while remaining > 0 {
        let to_read = usize::min(buf.len(), remaining as usize);
        let read = file.read(&mut buf[..to_read])?;
        if read == 0 {
            break;
        }
        stream.write_all(&buf[..read])?;
        remaining -= read as u64;
    }
    stream.flush()
}

fn handle_vod_remux(
    stream: &mut TcpStream,
    path: &str,
    method: &str,
    range_header: Option<&str>,
) -> std::io::Result<()> {
    if method == "OPTIONS" {
        return write_empty(stream, 204, "No Content", &[]);
    }
    if method != "GET" && method != "HEAD" {
        return write_text(stream, 405, "Method Not Allowed", "method not allowed");
    }
    let target = target_request(path);
    let Some(url) = target.url else {
        return write_text(stream, 400, "Bad Request", "missing url");
    };
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return write_text(stream, 400, "Bad Request", "invalid url");
    }
    let audio_index = target.audio_index.unwrap_or(0);
    let out = vod_remux_cache_path(&url, audio_index);
    let ready = out.exists() && out.metadata().map(|m| m.len() > 1024).unwrap_or(false);
    if target.status_only {
        return write_json(stream, 200, "OK", &serde_json::json!({ "ready": ready }));
    }
    let user_agent = target
        .user_agent
        .as_deref()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or(DEFAULT_USER_AGENT);
    let referer = target.referer.as_deref().filter(|v| !v.trim().is_empty());
    if target.wait_only {
        match ensure_vod_remux_file(&url, user_agent, referer, audio_index) {
            Ok(_) => return write_empty(stream, 204, "No Content", &[]),
            Err(error) => return write_text(stream, 502, "Bad Gateway", &error.to_string()),
        }
    }
    match ensure_vod_remux_file(&url, user_agent, referer, audio_index) {
        Ok(path) => serve_file_range(stream, path, method, "video/mp4", range_header),
        Err(error) => write_text(stream, 502, "Bad Gateway", &error.to_string()),
    }
}

fn rewrite_vod_hls_playlist(
    text: &str,
    url: &str,
    audio_index: u32,
    file_name: Option<&str>,
) -> String {
    let encoded = utf8_percent_encode(url, NON_ALPHANUMERIC).to_string();
    let origin = PORT
        .get()
        .map(|&port| stream_proxy_base(port))
        .unwrap_or_default();
    let mut out = String::with_capacity(text.len() + 256);
    let base_file = file_name.unwrap_or("");
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty()
            || trimmed.starts_with('#')
            || trimmed.starts_with("http://")
            || trimmed.starts_with("https://")
        {
            out.push_str(line);
            out.push('\n');
            continue;
        }
        let child = if base_file.contains('/') {
            let mut parts: Vec<&str> = base_file.split('/').collect();
            parts.pop();
            if parts.is_empty() {
                trimmed.to_string()
            } else {
                format!("{}/{}", parts.join("/"), trimmed)
            }
        } else {
            trimmed.to_string()
        };
        let path_child = child
            .replace('\\', "/")
            .replace('?', "%3F")
            .replace('#', "%23")
            .replace(' ', "%20");
        let encoded_child = utf8_percent_encode(&child, NON_ALPHANUMERIC).to_string();
        let segment_path = format!(
            "/__vod_hls/{path_child}?url={encoded}&audio={audio_index}&file={encoded_child}"
        );
        out.push_str(&origin);
        out.push_str(&segment_path);
        out.push('\n');
    }
    out
}

fn normalize_vod_hls_playlist(
    text: &str,
    url: &str,
    audio_index: u32,
    file_name: Option<&str>,
) -> String {
    let rewritten = rewrite_vod_hls_playlist(text, url, audio_index, file_name);
    let mut out = Vec::new();
    let mut has_endlist = false;
    let mut has_playlist_type = false;
    for line in rewritten.lines() {
        let trimmed = line.trim();
        if trimmed.eq_ignore_ascii_case("#EXT-X-ENDLIST") {
            has_endlist = true;
            out.push("#EXT-X-ENDLIST".to_string());
        } else if trimmed.starts_with("#EXT-X-PLAYLIST-TYPE:") {
            has_playlist_type = true;
            out.push("#EXT-X-PLAYLIST-TYPE:VOD".to_string());
        } else {
            out.push(line.to_string());
        }
    }
    if !has_playlist_type {
        let insert_at = out
            .iter()
            .position(|line| line.starts_with("#EXT-X-INDEPENDENT-SEGMENTS"))
            .map(|idx| idx + 1)
            .unwrap_or_else(|| usize::min(4, out.len()));
        out.insert(insert_at, "#EXT-X-PLAYLIST-TYPE:VOD".to_string());
    }
    if !has_endlist {
        out.push("#EXT-X-ENDLIST".to_string());
    }
    format!("{}\n", out.join("\n"))
}

fn handle_vod_hls(
    stream: &mut TcpStream,
    path: &str,
    method: &str,
    range_header: Option<&str>,
) -> std::io::Result<()> {
    if method == "OPTIONS" {
        return write_empty(stream, 204, "No Content", &[]);
    }
    if method != "GET" && method != "HEAD" {
        return write_text(stream, 405, "Method Not Allowed", "method not allowed");
    }
    let target = target_request(path);
    let Some(url) = target.url else {
        return write_text(stream, 400, "Bad Request", "missing url");
    };
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return write_text(stream, 400, "Bad Request", "invalid url");
    }
    let audio_index = target.audio_index.unwrap_or(0);
    let user_agent = target
        .user_agent
        .as_deref()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or(DEFAULT_USER_AGENT);
    let referer = target.referer.as_deref().filter(|v| !v.trim().is_empty());
    let _ = spawn_vod_hls(&url, user_agent, referer, audio_index);

    if target.status_only {
        return write_json(
            stream,
            200,
            "OK",
            &serde_json::json!({ "ready": vod_hls_ready(&url, audio_index) }),
        );
    }
    if target.wait_only {
        if wait_for_vod_hls(&url, audio_index, Duration::from_secs(30)) {
            return write_empty(stream, 204, "No Content", &[]);
        }
        return write_text(stream, 503, "Service Unavailable", "vod hls not ready");
    }

    let path_file = path
        .split_once('?')
        .map(|(left, _)| left)
        .unwrap_or(path)
        .strip_prefix("/__vod_hls/")
        .and_then(|value| percent_decode_str(value).decode_utf8().ok())
        .map(|value| value.to_string());
    let file_name = target
        .file_name
        .as_deref()
        .or(path_file.as_deref())
        .unwrap_or("index.m3u8");
    let clean_file = file_name.trim_start_matches('/').replace("..", "");
    let file_path = vod_hls_cache_dir(&url, audio_index).join(&clean_file);
    if clean_file.ends_with(".m3u8") {
        if clean_file == "index.m3u8" {
            if !wait_for_vod_hls_complete(&url, audio_index, Duration::from_secs(300)) {
                return write_text(
                    stream,
                    503,
                    "Service Unavailable",
                    "vod hls still preparing",
                );
            }
        } else if !wait_for_vod_hls(&url, audio_index, Duration::from_secs(30)) {
            return write_text(stream, 503, "Service Unavailable", "vod hls not ready");
        }
        let text = fs::read_to_string(&file_path).or_else(|_| {
            fs::read_to_string(vod_hls_cache_dir(&url, audio_index).join("index.m3u8"))
        })?;
        let body = if clean_file == "index.m3u8" {
            let body = normalize_vod_hls_playlist(&text, &url, audio_index, Some(&clean_file));
            log::info!(
                "[media_proxy] vod hls complete manifest {} audio {} bytes {}",
                redact_media_url(&url),
                audio_index,
                body.len()
            );
            body
        } else {
            rewrite_vod_hls_playlist(&text, &url, audio_index, Some(&clean_file))
        };
        write_common_headers(stream, 200, "OK")?;
        write!(stream, "Content-Type: application/vnd.apple.mpegurl\r\n")?;
        write!(
            stream,
            "Cache-Control: no-store, no-cache, must-revalidate\r\n"
        )?;
        write!(stream, "Pragma: no-cache\r\n")?;
        write!(stream, "Content-Length: {}\r\n\r\n", body.len())?;
        if method != "HEAD" {
            stream.write_all(body.as_bytes())?;
        }
        return stream.flush();
    }
    if !wait_for_file(&file_path, Duration::from_secs(90)) {
        log::warn!(
            "[media_proxy] vod hls segment not ready {} audio {} file {} running={}",
            redact_media_url(&url),
            audio_index,
            clean_file,
            vod_hls_running(&url, audio_index)
        );
        return write_text(
            stream,
            503,
            "Service Unavailable",
            "vod hls segment not ready",
        );
    }
    serve_file_range(stream, file_path, method, "video/mp2t", range_header)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaProxyFetchResponse {
    pub status: u16,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

/// Fetch IPTV media in-process (avoids WKWebView → loopback HTTP, which often hangs).
#[tauri::command]
pub fn media_proxy_fetch(
    url: String,
    method: Option<String>,
    range: Option<String>,
    user_agent: Option<String>,
    referer: Option<String>,
) -> Result<MediaProxyFetchResponse, String> {
    let _ = ensure_server();
    let method = method.unwrap_or_else(|| "GET".to_string());
    let url = normalize_xtream_media_url(&unwrap_nested_proxy_url(&url));
    log::info!("[media_proxy] fetch {} {}", method, redact_media_url(&url));
    match fetch_media_body(
        &url,
        &method,
        range.as_deref(),
        user_agent.as_deref(),
        referer.as_deref(),
    ) {
        Ok(response) => {
            log::info!(
                "[media_proxy] ok {} {} bytes",
                response.status,
                response.body.len()
            );
            Ok(response)
        }
        Err(error) => {
            log::warn!("[media_proxy] failed {}: {error}", redact_media_url(&url));
            Err(error)
        }
    }
}

fn redact_media_url(url: &str) -> String {
    let mut out = url.to_string();
    if let Ok(parsed) = reqwest::Url::parse(url) {
        let mut segments = parsed.path().split('/').collect::<Vec<_>>();
        for i in 0..segments.len() {
            let seg = segments[i];
            if seg == "live" || seg == "movie" || seg == "series" {
                if i + 2 < segments.len() {
                    segments[i + 1] = "***";
                    segments[i + 2] = "***";
                }
                break;
            }
        }
        let path = segments.join("/");
        out = format!(
            "{}://{}{}",
            parsed.scheme(),
            parsed.host_str().unwrap_or(""),
            path
        );
    }
    out.chars().take(160).collect()
}

fn normalize_xtream_media_url(url: &str) -> String {
    let Ok(mut parsed) = reqwest::Url::parse(url) else {
        return url.to_string();
    };
    let path = parsed.path().to_lowercase();
    if parsed.scheme() == "https"
        && (path.contains("/live/")
            || path.contains("/movie/")
            || path.contains("/series/")
            || path.contains("/timeshift/"))
    {
        let _ = parsed.set_scheme("http");
        if parsed.port() == Some(443) {
            let _ = parsed.set_port(None);
        }
    }
    parsed.to_string()
}

fn infer_live_manifest_referer(url: &str) -> Option<String> {
    let parsed = reqwest::Url::parse(url).ok()?;
    let segments: Vec<&str> = parsed.path().split('/').filter(|s| !s.is_empty()).collect();
    if segments.len() >= 5 && segments[0] == "hls" && segments[1] == "live" {
        let host = parsed.host_str()?;
        return Some(format!(
            "{}://{}/live/{}/{}/{}.m3u8",
            parsed.scheme(),
            host,
            segments[2],
            segments[3],
            segments[4]
        ));
    }
    None
}

fn effective_upstream_referer(url: &str, referer: Option<&str>) -> Option<String> {
    let inferred = infer_live_manifest_referer(url);
    let Some(r) = referer.filter(|v| !v.trim().is_empty()) else {
        return inferred;
    };
    if let Some(manifest) = &inferred {
        let r_trim = r.trim();
        if r_trim.ends_with('/') && !r_trim.contains(".m3u8") {
            return Some(manifest.clone());
        }
    }
    Some(r.to_string())
}

fn fetch_media_body(
    url: &str,
    method: &str,
    range: Option<&str>,
    user_agent: Option<&str>,
    referer: Option<&str>,
) -> Result<MediaProxyFetchResponse, String> {
    let ua = resolve_upstream_user_agent(url, user_agent);
    let referer = effective_upstream_referer(url, referer);
    let referer_ref = referer.as_deref();
    let response = fetch_upstream_resilient(url, method, range, Some(ua.as_str()), referer_ref)
        .map_err(|e| format!("upstream: {e}"))?;
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    let content_type = headers
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    let is_head = method == "HEAD";
    let mut body = if is_head {
        Vec::new()
    } else {
        response
            .bytes()
            .map(|b| b.to_vec())
            .map_err(|e| format!("read body: {e}"))?
    };
    if !is_head && body.is_empty() && (status == 200 || status == 206) && is_media_segment_url(url)
    {
        log::warn!(
            "[media_proxy] empty segment body; retrying without range {}",
            redact_media_url(url)
        );
        let alt_ua = if ua == IPTV_UA_HLS {
            DEFAULT_USER_AGENT.to_string()
        } else {
            IPTV_UA_HLS.to_string()
        };
        for (try_ua, delay_ms) in [
            (ua.as_str(), 0_u64),
            (ua.as_str(), 80),
            (alt_ua.as_str(), 120),
            (alt_ua.as_str(), 200),
        ] {
            if delay_ms > 0 {
                std::thread::sleep(Duration::from_millis(delay_ms));
            }
            if let Ok(retry) = fetch_upstream_resilient(url, "GET", None, Some(try_ua), referer_ref)
            {
                let retry_status = retry.status().as_u16();
                if retry_status == 200 || retry_status == 206 {
                    if let Ok(bytes) = retry.bytes() {
                        body = bytes.to_vec();
                        if !body.is_empty() {
                            log::info!(
                                "[media_proxy] segment retry ok {} bytes (ua={})",
                                body.len(),
                                if try_ua == alt_ua.as_str() {
                                    "alt"
                                } else {
                                    "primary"
                                }
                            );
                            break;
                        }
                    }
                }
            }
        }
    }
    if !is_head {
        if let Some(port) = PORT.get().copied() {
            if body_looks_like_m3u8(&body, url, content_type.as_deref()) {
                let text = String::from_utf8_lossy(&body);
                let rewritten =
                    rewrite_m3u8_playlist(&text, url, port, Some(ua.as_str()), referer.as_deref());
                let trimmed = trim_live_media_playlist(&rewritten);
                body = trimmed.into_bytes();
            }
        }
    }
    let mut out_status = normalize_head_response_status(method, status);
    if !is_head
        && body.is_empty()
        && is_media_segment_url(url)
        && (out_status == 200 || out_status == 206)
    {
        log::warn!(
            "[media_proxy] expired/empty segment → 410 {}",
            redact_media_url(url)
        );
        out_status = 410;
    }
    let mut out_headers = HashMap::new();
    if let Some(ct) = content_type {
        out_headers.insert("content-type".to_string(), ct);
    }
    if !is_head {
        out_headers.insert("content-length".to_string(), body.len().to_string());
    }
    if let Some(ar) = headers
        .get(reqwest::header::ACCEPT_RANGES)
        .and_then(|v| v.to_str().ok())
    {
        out_headers.insert("accept-ranges".to_string(), ar.to_string());
    }
    if let Some(cr) = headers
        .get(reqwest::header::CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
    {
        out_headers.insert("content-range".to_string(), cr.to_string());
    }
    Ok(MediaProxyFetchResponse {
        status: out_status,
        headers: out_headers,
        body,
    })
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

    let path_only = path.split('?').next().unwrap_or(path);
    if path_only != "/stream"
        && path_only != "/__stream"
        && path_only != "/__transcode"
        && path_only != "/__vod_streams"
        && path_only != "/__vod_subtitle"
        && path_only != "/__vod_remux"
        && path_only != "/__vod_hls"
        && !path_only.starts_with("/__vod_hls/")
    {
        write_text(&mut stream, 404, "Not Found", "not found")?;
        return Ok(());
    }

    if path_only == "/__transcode" {
        return handle_transcode(&mut stream, path, method);
    }
    if path_only == "/__vod_streams" {
        return handle_vod_streams(&mut stream, path, method);
    }
    if path_only == "/__vod_subtitle" {
        return handle_vod_subtitle(&mut stream, path, method);
    }
    if path_only == "/__vod_remux" {
        return handle_vod_remux(
            &mut stream,
            path,
            method,
            headers.get("range").map(String::as_str),
        );
    }
    if path_only == "/__vod_hls" || path_only.starts_with("/__vod_hls/") {
        return handle_vod_hls(
            &mut stream,
            path,
            method,
            headers.get("range").map(String::as_str),
        );
    }

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

    let user_agent = upstream_user_agent_from_request(&headers, &url, target.user_agent.as_deref());
    let referer_raw = upstream_referer_from_request(&headers, &url, target.referer.as_deref());
    let referer = effective_upstream_referer(&url, referer_raw.as_deref());
    match fetch_upstream_resilient(
        &url,
        method,
        headers.get("range").map(String::as_str),
        Some(user_agent.as_str()),
        referer.as_deref(),
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
    audio_index: Option<u32>,
    start_seconds: Option<f64>,
    subtitle_index: Option<u32>,
    file_name: Option<String>,
    wait_only: bool,
    status_only: bool,
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
        audio_index: None,
        start_seconds: None,
        subtitle_index: None,
        file_name: None,
        wait_only: false,
        status_only: false,
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
            "audio" => target.audio_index = value.parse::<u32>().ok(),
            "start" => target.start_seconds = value.parse::<f64>().ok(),
            "index" => target.subtitle_index = value.parse::<u32>().ok(),
            "file" => target.file_name = decode_query_value(value),
            "wait" => target.wait_only = value == "1" || value.eq_ignore_ascii_case("true"),
            "status" => target.status_only = value == "1" || value.eq_ignore_ascii_case("true"),
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

fn upstream_user_agent_from_request(
    headers: &HashMap<String, String>,
    url: &str,
    query_ua: Option<&str>,
) -> String {
    if let Some(ua) = headers.get("x-xt-ua").filter(|v| !v.trim().is_empty()) {
        return ua.clone();
    }
    resolve_upstream_user_agent(url, query_ua)
}

fn upstream_referer_from_request(
    headers: &HashMap<String, String>,
    url: &str,
    query_referer: Option<&str>,
) -> Option<String> {
    if let Some(referer) = headers.get("x-xt-referer").filter(|v| !v.trim().is_empty()) {
        return Some(referer.clone());
    }
    if let Some(referer) = query_referer.filter(|v| !v.trim().is_empty()) {
        return Some(referer.to_string());
    }
    origin_for(url)
}

fn resolve_upstream_user_agent(url: &str, client_ua: Option<&str>) -> String {
    if let Some(ua) = client_ua.filter(|v| !v.trim().is_empty()) {
        return ua.to_string();
    }
    if url.contains("/movie/") || url.contains("/series/") {
        return DEFAULT_USER_AGENT.to_string();
    }
    if url.contains(".m3u8") || url.contains("/live/") {
        return IPTV_UA_HLS.to_string();
    }
    if is_iptv_media_url(url) {
        return IPTV_UA_HLS.to_string();
    }
    DEFAULT_USER_AGENT.to_string()
}

fn is_local_proxy_url(url: &str) -> bool {
    // xtproxy:// custom scheme (macOS WKWebView) — always a local proxy URL.
    if url.starts_with("xtproxy://") {
        return true;
    }
    reqwest::Url::parse(url)
        .ok()
        .map(|parsed| {
            let host = parsed.host_str().unwrap_or("");
            (host == "127.0.0.1" || host == "localhost")
                && (parsed.path() == "/stream" || parsed.path() == "/__stream")
        })
        .unwrap_or(false)
}

fn unwrap_nested_proxy_url(url: &str) -> String {
    let mut current = url.trim().to_string();
    for _ in 0..6 {
        if !is_local_proxy_url(&current) {
            break;
        }
        let Ok(parsed) = reqwest::Url::parse(&current) else {
            break;
        };
        let Some(inner) = parsed
            .query_pairs()
            .find(|(key, _)| key == "url")
            .map(|(_, value)| value.into_owned())
        else {
            break;
        };
        if inner.is_empty() || inner == current {
            break;
        }
        current = inner;
    }
    current
}

fn resolve_playlist_url(base: &str, reference: &str) -> String {
    if reference.starts_with("http://") || reference.starts_with("https://") {
        return reference.to_string();
    }
    reqwest::Url::parse(base)
        .ok()
        .and_then(|base_url| {
            base_url
                .join(reference)
                .ok()
                .map(|joined| joined.to_string())
        })
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
    let mut out = format!("{}/__stream?url={encoded}", stream_proxy_base(port));
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

/// Drop stale EXTINF entries (Megacubo live-window behaviour). Xtream often returns
/// HTTP 200 with an empty body for segments outside the live window.
fn trim_live_media_playlist(body: &str) -> String {
    const KEEP: usize = 2;
    if !body.contains("#EXTINF")
        || body.contains("#EXT-X-STREAM-INF")
        || body.contains("#EXT-X-ENDLIST")
    {
        return body.to_string();
    }
    let lines: Vec<&str> = body.lines().collect();
    let mut header: Vec<&str> = Vec::new();
    let mut segments: Vec<(Vec<&str>, &str)> = Vec::new();
    let mut i = 0usize;
    while i < lines.len() {
        let line = lines[i];
        if line.starts_with("#EXTINF") {
            let mut extinf = vec![line];
            i += 1;
            while i < lines.len() && lines[i].starts_with('#') && !lines[i].starts_with("#EXTINF") {
                extinf.push(lines[i]);
                i += 1;
            }
            let url = if i < lines.len() && !lines[i].starts_with('#') {
                lines[i]
            } else {
                ""
            };
            if !url.is_empty() {
                segments.push((extinf, url));
                i += 1;
            } else {
                segments.push((extinf, url));
            }
        } else if segments.is_empty() {
            header.push(line);
            i += 1;
        } else {
            i += 1;
        }
    }
    if segments.len() < 2 {
        return body.to_string();
    }
    if segments.len() <= KEEP {
        let drop = segments.len().saturating_sub(1);
        if drop == 0 {
            return body.to_string();
        }
        let kept = &segments[drop..];
        let base_seq = body
            .lines()
            .find_map(|line| {
                line.strip_prefix("#EXT-X-MEDIA-SEQUENCE:")
                    .map(|v| v.trim().parse::<u64>().unwrap_or(0))
            })
            .unwrap_or(0);
        let new_seq = base_seq.saturating_add(drop as u64);
        let mut out: Vec<String> = Vec::new();
        let mut bumped = false;
        for line in header {
            if line.starts_with("#EXT-X-MEDIA-SEQUENCE:") {
                out.push(format!("#EXT-X-MEDIA-SEQUENCE:{new_seq}"));
                bumped = true;
            } else {
                out.push(line.to_string());
            }
        }
        if !bumped {
            out.push(format!("#EXT-X-MEDIA-SEQUENCE:{new_seq}"));
        }
        for (extinf, url) in kept {
            for l in extinf {
                out.push((*l).to_string());
            }
            out.push(url.to_string());
        }
        return format!("{}\n", out.join("\n"));
    }
    let drop = segments.len() - KEEP;
    let kept = &segments[drop..];
    let base_seq = body
        .lines()
        .find_map(|line| {
            line.strip_prefix("#EXT-X-MEDIA-SEQUENCE:")
                .map(|v| v.trim().parse::<u64>().unwrap_or(0))
        })
        .unwrap_or(0);
    let new_seq = base_seq.saturating_add(drop as u64);
    let mut out: Vec<String> = Vec::new();
    let mut bumped = false;
    for line in header {
        if line.starts_with("#EXT-X-MEDIA-SEQUENCE:") {
            out.push(format!("#EXT-X-MEDIA-SEQUENCE:{new_seq}"));
            bumped = true;
        } else {
            out.push(line.to_string());
        }
    }
    if !bumped {
        out.push(format!("#EXT-X-MEDIA-SEQUENCE:{new_seq}"));
    }
    for (extinf, url) in kept {
        for l in extinf {
            out.push((*l).to_string());
        }
        out.push(url.to_string());
    }
    format!("{}\n", out.join("\n"))
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

fn should_buffer_and_rewrite_m3u8(target_url: &str, content_type: Option<&str>) -> bool {
    let lower = target_url.to_ascii_lowercase();
    if lower.contains(".m3u8") || lower.contains("/timeshift/") {
        return true;
    }
    if lower.contains("/live/")
        && !lower.contains(".ts")
        && !lower.contains(".m4s")
        && !lower.contains(".mp4")
    {
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
                    let fallback_range = range
                        .filter(|v| !v.trim().is_empty())
                        .unwrap_or("bytes=0-0");
                    return fetch_upstream(url, "GET", Some(fallback_range), Some(&ua), referer);
                }
                Ok(response)
            }
            Err(_) => {
                let fallback_range = range
                    .filter(|v| !v.trim().is_empty())
                    .unwrap_or("bytes=0-0");
                fetch_upstream(url, "GET", Some(fallback_range), Some(&ua), referer)
            }
        }
    } else {
        fetch_upstream(url, method, range, Some(&ua), referer)
    }
}

fn is_media_segment_url(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    // Xtream `/live/user/pass/id.ts` is a continuous MPEG-TS feed, not an HLS segment.
    if lower.contains("/live/") && !lower.contains("/hls/") {
        return false;
    }
    lower.contains("/hls/")
        && (lower.contains(".ts")
            || lower.contains(".m4s")
            || lower.contains(".mp2t")
            || lower.contains(".mp4"))
}

fn fetch_upstream(
    url: &str,
    method: &str,
    range: Option<&str>,
    user_agent: Option<&str>,
    referer: Option<&str>,
) -> Result<reqwest::blocking::Response, reqwest::Error> {
    let client = shared_http_client();
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
    if url.contains("/live/") && url.contains(".m3u8") {
        request = request
            .header(reqwest::header::CACHE_CONTROL, "no-cache")
            .header(reqwest::header::PRAGMA, "no-cache");
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

fn write_json<T: Serialize>(
    stream: &mut TcpStream,
    status: u16,
    reason: &str,
    payload: &T,
) -> std::io::Result<()> {
    let body = serde_json::to_vec(payload).unwrap_or_else(|_| b"{}".to_vec());
    write_common_headers(stream, status, reason)?;
    write!(stream, "Content-Type: application/json; charset=utf-8\r\n")?;
    write!(stream, "Content-Length: {}\r\n\r\n", body.len())?;
    stream.write_all(&body)?;
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
    let needs_rewrite = should_buffer_and_rewrite_m3u8(target_url, content_type);

    if !needs_rewrite {
        // Streaming path: write headers then pipe body directly (segments, MP4, …)
        let out_status = normalize_head_response_status(method, status);
        write_common_headers(stream, out_status, status_text(out_status))?;
        if is_head && status == 206 {
            write_head_ok_from_partial(&headers, stream)?;
        } else {
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
        }
        write!(stream, "\r\n")?;
        if !is_head {
            std::io::copy(&mut response, stream)?;
        }
        return stream.flush();
    }

    // Buffered path: M3U8 (needs URL rewriting) or HEAD on manifests
    let mut body = if is_head {
        Vec::new()
    } else {
        response.bytes().map(|b| b.to_vec()).unwrap_or_default()
    };
    if !is_head {
        if let Some(port) = PORT.get().copied() {
            if body_looks_like_m3u8(&body, target_url, content_type) {
                let text = String::from_utf8_lossy(&body);
                let rewritten = rewrite_m3u8_playlist(&text, target_url, port, user_agent, referer);
                body = rewritten.into_bytes();
            }
        }
    }
    let out_status = normalize_head_response_status(method, status);
    write_common_headers(stream, out_status, status_text(out_status))?;
    if is_head && status == 206 {
        write_head_ok_from_partial(&headers, stream)?;
    } else {
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
    }
    if !is_head || body.is_empty() {
        write!(stream, "Content-Length: {}\r\n", body.len())?;
    }
    write!(stream, "\r\n")?;
    if !is_head {
        stream.write_all(&body)?;
    }
    stream.flush()
}

fn normalize_head_response_status(method: &str, status: u16) -> u16 {
    if method == "HEAD" && status == 206 {
        200
    } else {
        status
    }
}

fn write_head_ok_from_partial(
    headers: &reqwest::header::HeaderMap,
    stream: &mut TcpStream,
) -> std::io::Result<()> {
    if let Some(ct) = headers
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
    {
        write!(stream, "Content-Type: {ct}\r\n")?;
    }
    if let Some(range) = headers
        .get(reqwest::header::CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
    {
        if let Some(total) = range
            .rsplit('/')
            .next()
            .filter(|part| part.chars().all(|c| c.is_ascii_digit()))
        {
            write!(stream, "Content-Length: {total}\r\n")?;
        }
    }
    if let Some(ar) = headers
        .get(reqwest::header::ACCEPT_RANGES)
        .and_then(|v| v.to_str().ok())
    {
        write!(stream, "Accept-Ranges: {ar}\r\n")?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// xtproxy:// custom URI scheme handler (macOS only)
//
// WKWebView on macOS serves the UI from `tauri://localhost` (a secure custom
// scheme). Plain `http://127.0.0.1` requests are blocked by WebKit's mixed-
// content policy.  By registering a second custom scheme (`xtproxy://`) we
// bypass that restriction entirely: custom→custom cross-origin loads are not
// subject to mixed-content rules.
//
// The handler is registered in `lib.rs` via
// `register_asynchronous_uri_scheme_protocol("xtproxy", ...)` and simply
// forwards the request to the local TCP proxy server.
// ---------------------------------------------------------------------------

pub fn handle_xtproxy_request(
    request: tauri::http::Request<Vec<u8>>,
) -> tauri::http::Response<Vec<u8>> {
    let port = match ensure_server() {
        Ok(p) => p,
        Err(e) => {
            return xtproxy_error(503, &format!("proxy unavailable: {e}"));
        }
    };

    // Convert `xtproxy://localhost/path?query` → `http://127.0.0.1:{port}/path?query`
    let uri = request.uri();
    let path_and_query = uri
        .path_and_query()
        .map(|pq| pq.as_str())
        .unwrap_or("/");
    let target_url = format!("http://127.0.0.1:{port}{path_and_query}");

    let client = shared_http_client();
    let method_str = request.method().as_str();
    let reqwest_method: reqwest::Method =
        method_str.parse().unwrap_or(reqwest::Method::GET);

    let mut req_builder = client.request(reqwest_method, &target_url);

    // Forward Range header so byte-range video seeking works.
    if let Some(range_val) = request.headers().get("range") {
        if let Ok(rv) = reqwest::header::HeaderValue::from_bytes(range_val.as_bytes()) {
            req_builder = req_builder.header(reqwest::header::RANGE, rv);
        }
    }

    let resp = match req_builder.send() {
        Ok(r) => r,
        Err(e) => {
            return xtproxy_error(502, &format!("upstream error: {e}"));
        }
    };

    let status = resp.status().as_u16();
    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/octet-stream")
        .to_string();
    let content_range = resp
        .headers()
        .get(reqwest::header::CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    let accept_ranges = resp
        .headers()
        .get(reqwest::header::ACCEPT_RANGES)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    let body = resp.bytes().unwrap_or_default().to_vec();

    let mut builder = tauri::http::Response::builder()
        .status(status)
        .header("content-type", &content_type)
        .header("access-control-allow-origin", "*")
        .header(
            "access-control-expose-headers",
            "Content-Length, Content-Range, Accept-Ranges",
        );

    if let Some(cr) = content_range {
        builder = builder.header("content-range", cr);
    }
    if let Some(ar) = accept_ranges {
        builder = builder.header("accept-ranges", ar);
    }

    builder
        .body(body)
        .unwrap_or_else(|_| xtproxy_error(500, "response build error"))
}

fn xtproxy_error(status: u16, msg: &str) -> tauri::http::Response<Vec<u8>> {
    tauri::http::Response::builder()
        .status(status)
        .header("content-type", "text/plain")
        .header("access-control-allow-origin", "*")
        .body(msg.as_bytes().to_vec())
        .unwrap_or_else(|_| {
            tauri::http::Response::builder()
                .status(500)
                .body(b"error".to_vec())
                .unwrap()
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn live_mpegts_url_is_not_an_hls_segment() {
        assert!(!is_media_segment_url(
            "http://panel.example.com/live/user/pass/462973.ts"
        ));
        assert!(is_media_segment_url(
            "http://panel.example.com/hls/live/user/pass/462973/abc/462973_5.ts"
        ));
    }

    #[test]
    fn trims_stale_live_segments_from_media_playlist() {
        let body = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-MEDIA-SEQUENCE:100\n#EXTINF:2,\nhttp://x/100.ts\n#EXTINF:2,\nhttp://x/101.ts\n#EXTINF:2,\nhttp://x/102.ts\n#EXTINF:2,\nhttp://x/103.ts\n#EXTINF:2,\nhttp://x/104.ts\n#EXTINF:2,\nhttp://x/105.ts\n#EXTINF:2,\nhttp://x/106.ts\n";
        let out = trim_live_media_playlist(body);
        assert!(out.contains("#EXT-X-MEDIA-SEQUENCE:105"));
        assert!(!out.contains("100.ts"));
        assert!(!out.contains("104.ts"));
        assert!(out.contains("105.ts"));
        assert!(out.contains("106.ts"));
    }

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
        #[cfg(target_os = "macos")]
        assert!(out.contains("xtproxy://localhost/__stream?url="));
        #[cfg(not(target_os = "macos"))]
        assert!(out.contains("http://127.0.0.1:9123/__stream?url="));
        assert!(!out.contains("http://cdn.example.com/live/seg.ts"));
    }

    #[test]
    fn live_path_without_m3u8_suffix_is_rewritten() {
        assert!(should_buffer_and_rewrite_m3u8(
            "http://panel.example.com/live/user/pass/99123",
            Some("application/octet-stream"),
        ));
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
        #[cfg(target_os = "macos")]
        assert!(out.contains("xtproxy://localhost/__stream?url="));
        #[cfg(not(target_os = "macos"))]
        assert!(out.contains("http://127.0.0.1:9000/__stream?url="));
        assert!(!out.contains("\nvariant.m3u8\n"));
    }
}
