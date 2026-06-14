use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use tauri::Manager;

#[cfg(unix)]
use std::os::unix::net::UnixStream;

#[cfg(target_os = "macos")]
use crate::native_mpv_macos::NativeMpvMacos;

const IPC_TIMEOUT_MS: u64 = 1500;
const MPV_BOOT_TIMEOUT_MS: u64 = 2500;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativePlaybackStatus {
    platform: &'static str,
    available: bool,
    backend: &'static str,
    integrated: bool,
    reason: &'static str,
    next_step: &'static str,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativePlaybackRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub scale_factor: f64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativePlaybackAttachResult {
    attached: bool,
    platform: &'static str,
    window_handle_available: bool,
    view_handle_available: bool,
    rect: NativePlaybackRect,
    reason: String,
    next_step: &'static str,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativePlaybackSource {
    src: String,
    mime: Option<String>,
    start_seconds: Option<f64>,
    expected_duration_seconds: Option<f64>,
    user_agent: Option<String>,
    referer: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativePlaybackTrack {
    pub id: String,
    pub kind: &'static str,
    pub label: String,
    pub language: String,
    pub index: i32,
    pub active: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativePlaybackSnapshot {
    pub backend: &'static str,
    pub available: bool,
    pub loaded: bool,
    pub paused: bool,
    pub ended: bool,
    pub current_time: f64,
    pub duration: f64,
    pub audio: Vec<NativePlaybackTrack>,
    pub subtitles: Vec<NativePlaybackTrack>,
    pub selected_audio_id: Option<String>,
    pub selected_subtitle_id: Option<String>,
    pub error: Option<String>,
}

impl NativePlaybackSnapshot {
    pub fn empty(backend: &'static str, available: bool, error: Option<String>) -> Self {
        Self {
            backend,
            available,
            loaded: false,
            paused: true,
            ended: false,
            current_time: 0.0,
            duration: 0.0,
            audio: Vec::new(),
            subtitles: Vec::new(),
            selected_audio_id: None,
            selected_subtitle_id: None,
            error,
        }
    }
}

struct MpvSession {
    child: Child,
    socket_path: String,
}

static MPV_SESSION: OnceLock<Mutex<Option<MpvSession>>> = OnceLock::new();
static ATTACHED_RECT: OnceLock<Mutex<Option<NativePlaybackRect>>> = OnceLock::new();

#[cfg(target_os = "macos")]
static NATIVE_MPV: OnceLock<Mutex<NativeMpvMacos>> = OnceLock::new();

fn session_slot() -> &'static Mutex<Option<MpvSession>> {
    MPV_SESSION.get_or_init(|| Mutex::new(None))
}

fn attached_rect_slot() -> &'static Mutex<Option<NativePlaybackRect>> {
    ATTACHED_RECT.get_or_init(|| Mutex::new(None))
}

#[cfg(target_os = "macos")]
fn native_mpv_slot() -> &'static Mutex<NativeMpvMacos> {
    NATIVE_MPV.get_or_init(|| Mutex::new(NativeMpvMacos::new()))
}

fn backend_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos-libmpv"
    } else if cfg!(target_os = "linux") {
        "linux-libmpv"
    } else if cfg!(target_os = "windows") {
        "windows-libmpv"
    } else {
        "unsupported"
    }
}

fn platform_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else {
        "unsupported"
    }
}

fn mpv_binary() -> Option<String> {
    let candidates = [
        "/opt/homebrew/bin/mpv",
        "/usr/local/bin/mpv",
        "/usr/bin/mpv",
        "mpv",
    ];
    for candidate in candidates {
        if candidate == "mpv" {
            if Command::new(candidate)
                .arg("--version")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .is_ok()
            {
                return Some(candidate.to_string());
            }
            continue;
        }
        if Path::new(candidate).exists() {
            return Some(candidate.to_string());
        }
    }
    None
}

#[tauri::command]
pub fn native_playback_status() -> NativePlaybackStatus {
    #[cfg(target_os = "macos")]
    let available = NativeMpvMacos::available();
    #[cfg(not(target_os = "macos"))]
    let available = mpv_binary().is_some() && cfg!(unix);
    NativePlaybackStatus {
        platform: platform_name(),
        available,
        backend: backend_name(),
        integrated: cfg!(target_os = "macos") && available,
        reason: if available {
            if cfg!(target_os = "macos") {
                "Embedded libmpv backend is available for macOS."
            } else {
                "MPV IPC backend is available, but native video surface embedding is not implemented yet."
            }
        } else {
            "MPV/libmpv is not available in this build environment."
        },
        next_step: if available {
            if cfg!(target_os = "macos") {
                "Test embedded playback and harden lifecycle, controls, tracks, and distribution bundling."
            } else {
                "Wire the MPV/libmpv video surface into the Tauri macOS window before enabling integrated app playback."
            }
        } else {
            "Install mpv/libmpv and pkg-config, then implement the desktop video surface."
        },
    }
}

#[tauri::command]
pub fn native_playback_attach(
    window: tauri::WebviewWindow,
    rect: NativePlaybackRect,
) -> Result<NativePlaybackAttachResult, String> {
    let mut guard = attached_rect_slot()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    *guard = Some(rect);

    #[cfg(target_os = "macos")]
    {
        native_mpv_slot()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .attach(&window, rect)?;
        let ns_window = window
            .ns_window()
            .map_err(|error| format!("NATIVE_PLAYBACK_WINDOW_HANDLE:{error}"))?;
        let ns_view = window
            .ns_view()
            .map_err(|error| format!("NATIVE_PLAYBACK_VIEW_HANDLE:{error}"))?;
        let window_handle_available = !ns_window.is_null();
        let view_handle_available = !ns_view.is_null();
        return Ok(NativePlaybackAttachResult {
            attached: true,
            platform: platform_name(),
            window_handle_available,
            view_handle_available,
            rect,
            reason: "Embedded libmpv NSOpenGLView surface attached.".to_string(),
            next_step: "Load media through native_playback_load and validate first-frame, tracks, seek, and lifecycle.",
        });
    }

    #[cfg(not(target_os = "macos"))]
    Ok(NativePlaybackAttachResult {
        attached: false,
        platform: platform_name(),
        window_handle_available: false,
        view_handle_available: false,
        rect,
        reason: "Native surface attach is currently implemented only for macOS diagnostics."
            .to_string(),
        next_step: "Implement the platform-specific native rendering surface.",
    })
}

fn unavailable() -> String {
    "NATIVE_PLAYBACK_UNAVAILABLE: MPV IPC backend is unavailable on this platform".to_string()
}

fn not_loaded() -> String {
    "NATIVE_PLAYBACK_NOT_LOADED: call native_playback_load first".to_string()
}

fn ipc_error(message: impl std::fmt::Display) -> String {
    format!("NATIVE_PLAYBACK_IPC:{message}")
}

fn unique_socket_path() -> String {
    let mut path = std::env::temp_dir();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    path.push(format!(
        "leleg-native-mpv-{}-{nanos}.sock",
        std::process::id()
    ));
    path.to_string_lossy().into_owned()
}

#[cfg(unix)]
fn ipc_command(socket_path: &str, command: Value) -> Result<Value, String> {
    let mut stream = UnixStream::connect(socket_path).map_err(ipc_error)?;
    let timeout = Some(Duration::from_millis(IPC_TIMEOUT_MS));
    stream.set_read_timeout(timeout).map_err(ipc_error)?;
    stream.set_write_timeout(timeout).map_err(ipc_error)?;
    let line = serde_json::to_string(&json!({ "command": command }))
        .map_err(|error| ipc_error(format!("json encode: {error}")))?;
    stream.write_all(line.as_bytes()).map_err(ipc_error)?;
    stream.write_all(b"\n").map_err(ipc_error)?;
    stream.flush().map_err(ipc_error)?;

    let mut reader = BufReader::new(stream);
    let mut response = String::new();
    reader.read_line(&mut response).map_err(ipc_error)?;
    if response.trim().is_empty() {
        return Err(ipc_error("empty response"));
    }
    let payload: Value = serde_json::from_str(&response)
        .map_err(|error| ipc_error(format!("json decode: {error}")))?;
    let error = payload
        .get("error")
        .and_then(Value::as_str)
        .unwrap_or("success");
    if error != "success" {
        return Err(ipc_error(error));
    }
    Ok(payload.get("data").cloned().unwrap_or(Value::Null))
}

#[cfg(not(unix))]
fn ipc_command(_socket_path: &str, _command: Value) -> Result<Value, String> {
    Err(unavailable())
}

fn spawn_mpv() -> Result<MpvSession, String> {
    let path = mpv_binary().ok_or_else(unavailable)?;
    let socket_path = unique_socket_path();
    let child = Command::new(path)
        .args([
            "--idle=yes",
            "--force-window=yes",
            "--no-terminal",
            "--no-config",
            "--keep-open=no",
            "--input-default-bindings=yes",
            "--input-media-keys=yes",
            "--osc=yes",
            "--ytdl=no",
            &format!("--input-ipc-server={socket_path}"),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("NATIVE_PLAYBACK_SPAWN:{error}"))?;

    let started = Instant::now();
    while started.elapsed() < Duration::from_millis(MPV_BOOT_TIMEOUT_MS) {
        if ipc_command(&socket_path, json!(["get_property", "pid"])).is_ok() {
            return Ok(MpvSession { child, socket_path });
        }
        std::thread::sleep(Duration::from_millis(40));
    }
    let mut child = child;
    let _ = child.kill();
    Err("NATIVE_PLAYBACK_TIMEOUT: mpv IPC socket did not become ready".to_string())
}

fn ensure_session() -> Result<String, String> {
    let mut guard = session_slot()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let needs_spawn = match guard.as_mut() {
        Some(session) => match session.child.try_wait() {
            Ok(Some(_)) => true,
            Ok(None) => false,
            Err(_) => true,
        },
        None => true,
    };
    if needs_spawn {
        if let Some(session) = guard.take() {
            let _ = std::fs::remove_file(session.socket_path);
        }
        *guard = Some(spawn_mpv()?);
    }
    guard
        .as_ref()
        .map(|session| session.socket_path.clone())
        .ok_or_else(not_loaded)
}

fn active_session_socket() -> Result<String, String> {
    let mut guard = session_slot()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let session = guard.as_mut().ok_or_else(not_loaded)?;
    match session.child.try_wait() {
        Ok(Some(_)) => {
            let session = guard.take();
            if let Some(session) = session {
                let _ = std::fs::remove_file(session.socket_path);
            }
            Err(not_loaded())
        }
        Ok(None) => Ok(session.socket_path.clone()),
        Err(error) => Err(ipc_error(error)),
    }
}

fn set_string_property(socket: &str, property: &str, value: Option<String>) -> Result<(), String> {
    let Some(value) = value.filter(|value| !value.trim().is_empty()) else {
        return Ok(());
    };
    ipc_command(socket, json!(["set_property", property, value])).map(|_| ())
}

#[tauri::command]
pub fn native_playback_load(
    app: tauri::AppHandle,
    source: NativePlaybackSource,
) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        return native_mpv_slot()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .load(
                &app,
                &source.src,
                source.start_seconds,
                source.user_agent,
                source.referer,
            );
    }
    #[cfg(not(target_os = "macos"))]
    {
        let socket = ensure_session()?;
        let _ = (&source.mime, source.expected_duration_seconds);
        set_string_property(&socket, "user-agent", source.user_agent)?;
        set_string_property(&socket, "referrer", source.referer)?;
        ipc_command(&socket, json!(["loadfile", source.src, "replace"]))?;
        if let Some(start) = source.start_seconds.filter(|value| *value > 0.0) {
            let _ = ipc_command(&socket, json!(["seek", start, "absolute", "exact"]));
        }
        Ok(())
    }
}

#[tauri::command]
pub fn native_playback_play() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        return native_mpv_slot()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .play();
    }
    let socket = active_session_socket()?;
    ipc_command(&socket, json!(["set_property", "pause", false])).map(|_| ())
}

#[tauri::command]
pub fn native_playback_pause() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        return native_mpv_slot()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .pause();
    }
    let socket = active_session_socket()?;
    ipc_command(&socket, json!(["set_property", "pause", true])).map(|_| ())
}

#[tauri::command]
pub fn native_playback_stop() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        native_mpv_slot()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .stop();
        return Ok(());
    }
    let socket = active_session_socket()?;
    ipc_command(&socket, json!(["stop"])).map(|_| ())
}

#[tauri::command]
pub fn native_playback_seek(seconds: f64) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        return native_mpv_slot()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .seek(seconds);
    }
    let socket = active_session_socket()?;
    ipc_command(
        &socket,
        json!(["seek", seconds.max(0.0), "absolute", "exact"]),
    )
    .map(|_| ())
}

#[tauri::command]
pub fn native_playback_set_volume(volume: f64) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        return native_mpv_slot()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .set_volume(volume);
    }
    let socket = active_session_socket()?;
    ipc_command(
        &socket,
        json!(["set_property", "volume", volume.clamp(0.0, 100.0)]),
    )
    .map(|_| ())
}

#[tauri::command]
pub fn native_playback_set_speed(speed: f64) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        return native_mpv_slot()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .set_speed(speed);
    }
    let socket = active_session_socket()?;
    ipc_command(
        &socket,
        json!(["set_property", "speed", speed.clamp(0.25, 4.0)]),
    )
    .map(|_| ())
}

#[tauri::command]
pub fn native_playback_select_audio_track(id: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        return native_mpv_slot()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .select_audio_track(id);
    }
    let socket = active_session_socket()?;
    let value = id
        .parse::<i32>()
        .map(Value::from)
        .unwrap_or(Value::String(id));
    ipc_command(&socket, json!(["set_property", "aid", value])).map(|_| ())
}

#[tauri::command]
pub fn native_playback_select_subtitle_track(id: Option<String>) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        return native_mpv_slot()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .select_subtitle_track(id);
    }
    let socket = active_session_socket()?;
    let value = match id.filter(|id| !id.trim().is_empty()) {
        Some(id) => id
            .parse::<i32>()
            .map(Value::from)
            .unwrap_or(Value::String(id)),
        None => Value::String("no".to_string()),
    };
    ipc_command(&socket, json!(["set_property", "sid", value])).map(|_| ())
}

#[tauri::command]
pub fn native_playback_set_subtitle_delay(seconds: f64) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        return native_mpv_slot()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .set_subtitle_delay(seconds);
    }
    let socket = active_session_socket()?;
    ipc_command(&socket, json!(["set_property", "sub-delay", seconds])).map(|_| ())
}

fn get_number(socket: &str, property: &str) -> f64 {
    ipc_command(socket, json!(["get_property", property]))
        .ok()
        .and_then(|value| value.as_f64())
        .unwrap_or(0.0)
}

fn get_bool(socket: &str, property: &str, fallback: bool) -> bool {
    ipc_command(socket, json!(["get_property", property]))
        .ok()
        .and_then(|value| value.as_bool())
        .unwrap_or(fallback)
}

fn mpv_track_label(track: &Value, fallback: &str) -> String {
    track
        .get("title")
        .or_else(|| track.get("external-filename"))
        .or_else(|| track.get("lang"))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(fallback)
        .to_string()
}

fn map_mpv_track(track: &Value, list_index: usize) -> Option<NativePlaybackTrack> {
    let track_type = track.get("type").and_then(Value::as_str)?;
    let kind = match track_type {
        "audio" => "audio",
        "sub" => "subtitle",
        _ => return None,
    };
    let id_num = track
        .get("id")
        .and_then(Value::as_i64)
        .unwrap_or(list_index as i64);
    let id = id_num.to_string();
    Some(NativePlaybackTrack {
        id,
        kind,
        label: mpv_track_label(track, &format!("{kind} {}", list_index + 1)),
        language: track
            .get("lang")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        index: id_num as i32,
        active: track
            .get("selected")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

fn snapshot_from_socket(socket: &str) -> NativePlaybackSnapshot {
    let track_list = ipc_command(socket, json!(["get_property", "track-list"]))
        .ok()
        .and_then(|value| value.as_array().cloned())
        .unwrap_or_default();
    let mut audio = Vec::new();
    let mut subtitles = Vec::new();
    for (index, track) in track_list.iter().enumerate() {
        let Some(mapped) = map_mpv_track(track, index) else {
            continue;
        };
        if mapped.kind == "audio" {
            audio.push(mapped);
        } else {
            subtitles.push(mapped);
        }
    }
    let selected_audio_id = audio
        .iter()
        .find(|track| track.active)
        .map(|track| track.id.clone());
    let selected_subtitle_id = subtitles
        .iter()
        .find(|track| track.active)
        .map(|track| track.id.clone());
    let duration = get_number(socket, "duration");
    let current_time = get_number(socket, "time-pos");
    NativePlaybackSnapshot {
        backend: backend_name(),
        available: true,
        loaded: duration > 0.0 || current_time > 0.0 || !audio.is_empty() || !subtitles.is_empty(),
        paused: get_bool(socket, "pause", true),
        ended: get_bool(socket, "eof-reached", false),
        current_time,
        duration,
        audio,
        subtitles,
        selected_audio_id,
        selected_subtitle_id,
        error: None,
    }
}

#[tauri::command]
pub fn native_playback_state() -> NativePlaybackSnapshot {
    #[cfg(target_os = "macos")]
    {
        return native_mpv_slot()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .snapshot();
    }
    match active_session_socket() {
        Ok(socket) => snapshot_from_socket(&socket),
        Err(error) => NativePlaybackSnapshot {
            backend: backend_name(),
            available: mpv_binary().is_some() && cfg!(unix),
            loaded: false,
            paused: true,
            ended: false,
            current_time: 0.0,
            duration: 0.0,
            audio: Vec::new(),
            subtitles: Vec::new(),
            selected_audio_id: None,
            selected_subtitle_id: None,
            error: Some(error),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_reports_backend_name_and_integration_gate() {
        let status = native_playback_status();
        assert_eq!(status.integrated, cfg!(target_os = "macos"));
        assert!(!status.backend.is_empty());
        assert!(!status.next_step.is_empty());
    }

    #[test]
    fn state_without_loaded_session_is_safe_for_frontend_polling() {
        let state = native_playback_state();
        assert!(!state.loaded);
        assert!(state.paused);
        assert_eq!(state.current_time, 0.0);
        assert_eq!(state.duration, 0.0);
        assert!(state.audio.is_empty());
        assert!(state.subtitles.is_empty());
        if !cfg!(target_os = "macos") {
            assert!(state.error.is_some());
        }
    }

    #[test]
    fn track_mapping_keeps_audio_and_subtitle_metadata() {
        let track = json!({
            "id": 2,
            "type": "audio",
            "title": "Italiano",
            "lang": "ita",
            "selected": true
        });
        let mapped = map_mpv_track(&track, 0).expect("audio track");
        assert_eq!(mapped.id, "2");
        assert_eq!(mapped.kind, "audio");
        assert_eq!(mapped.label, "Italiano");
        assert_eq!(mapped.language, "ita");
        assert!(mapped.active);
    }
}
