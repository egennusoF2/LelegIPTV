// External-player launch + detect bridge.
//
// The frontend invokes `launch_external_player` with a binary path and an
// argv vector to either spawn the player detached (mode = "launch") or
// probe a candidate binary's `--version` output (mode = "detect"). Errors
// are returned with a stable prefix so the frontend can map them to
// localized toasts without parsing OS-specific messages:
//
//   "NOT_FOUND:..."   - the binary at `path` does not exist
//   "PERMISSION:..."  - the OS refused execution (executable bit, ACL)
//   "TIMEOUT:..."     - detect mode hit the 2s budget without exiting
//   "OTHER:..."       - anything else

use std::collections::HashMap;
use std::io::Write;
#[cfg(unix)]
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{json, Value};
use tauri::State;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

const DETECT_TIMEOUT_MS: u64 = 2000;
const DETECT_POLL_INTERVAL_MS: u64 = 25;
#[cfg(unix)]
const IPC_WRITE_TIMEOUT_MS: u64 = 1500;

// ---------------------------------------------------------------------------
// Reuse-slot state
// ---------------------------------------------------------------------------
#[derive(Clone, Debug)]
struct Slot {
    pid: u32,
    /// For MPV: socket path (Unix) or pipe name (Windows, e.g. `\\.\pipe\xt-mpv-N`).
    /// For VLC: `host:port` literal string.
    endpoint: String,
}

#[derive(Default)]
pub struct ExternalPlayerState {
    inner: Mutex<HashMap<String, Slot>>,
}

#[derive(Debug, Deserialize, Default)]
pub struct ReuseConfig {
    pub kind: String,
    pub enabled: bool,
    #[serde(default)]
    pub url: String,
}

impl ExternalPlayerState {
    fn get(&self, kind: &str) -> Option<Slot> {
        self.inner.lock().ok()?.get(kind).cloned()
    }

    fn set(&self, kind: &str, slot: Slot) {
        if let Ok(mut guard) = self.inner.lock() {
            guard.insert(kind.to_string(), slot);
        }
    }

    fn drop_slot(&self, kind: &str) {
        if let Ok(mut guard) = self.inner.lock() {
            guard.remove(kind);
        }
    }
}

// ---------------------------------------------------------------------------
// Spawn helpers (unchanged surface)
// ---------------------------------------------------------------------------
fn classify_io_error(err: &std::io::Error) -> String {
    match err.kind() {
        std::io::ErrorKind::NotFound => format!("NOT_FOUND:{err}"),
        std::io::ErrorKind::PermissionDenied => format!("PERMISSION:{err}"),
        _ => format!("OTHER:{err}"),
    }
}

fn build_command(path: &str, args: &[String]) -> Command {
    let mut cmd = Command::new(path);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

fn spawn_launch_inner(path: &str, args: &[String]) -> Result<u32, String> {
    if path.is_empty() {
        return Err("NOT_FOUND:player path is empty".to_string());
    }
    if !Path::new(path).exists() {
        return Err(format!("NOT_FOUND:no file at {path}"));
    }
    let mut cmd = build_command(path, args);
    match cmd.spawn() {
        Ok(child) => Ok(child.id()),
        Err(e) => Err(classify_io_error(&e)),
    }
}

fn spawn_detect(path: String, mut args: Vec<String>) -> Result<String, String> {
    if path.is_empty() {
        return Err("NOT_FOUND:player path is empty".to_string());
    }
    if !args.iter().any(|a| a == "--version") {
        args.push("--version".to_string());
    }
    let mut cmd = Command::new(&path);
    cmd.args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return Err(classify_io_error(&e)),
    };

    let started = Instant::now();
    let budget = Duration::from_millis(DETECT_TIMEOUT_MS);
    loop {
        match child.try_wait() {
            Ok(Some(_status)) => {
                let output = child
                    .wait_with_output()
                    .map_err(|e| format!("OTHER:{e}"))?;
                let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
                if text.trim().is_empty() {
                    text = String::from_utf8_lossy(&output.stderr).into_owned();
                }
                let first_line = text
                    .lines()
                    .next()
                    .map(|line| line.trim().to_string())
                    .unwrap_or_default();
                return Ok(first_line);
            }
            Ok(None) => {
                if started.elapsed() >= budget {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(format!(
                        "TIMEOUT:{path} did not exit within {DETECT_TIMEOUT_MS}ms"
                    ));
                }
                std::thread::sleep(Duration::from_millis(DETECT_POLL_INTERVAL_MS));
            }
            Err(e) => return Err(format!("OTHER:{e}")),
        }
    }
}

// ---------------------------------------------------------------------------
// Endpoint generation
// ---------------------------------------------------------------------------
fn unique_suffix() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    format!("{}-{}", std::process::id(), nanos)
}

fn pick_mpv_endpoint() -> String {
    #[cfg(windows)]
    {
        format!(r"\\.\pipe\xt-mpv-{}", unique_suffix())
    }
    #[cfg(not(windows))]
    {
        let mut dir = std::env::temp_dir();
        dir.push(format!("xt-mpv-{}.sock", unique_suffix()));
        dir.to_string_lossy().into_owned()
    }
}

// ---------------------------------------------------------------------------
// Argv augmentation when reuse is freshly spawned
// ---------------------------------------------------------------------------
fn augment_mpv_args(mut args: Vec<String>, endpoint: &str) -> Vec<String> {
    args.retain(|arg| {
        !(arg.starts_with("--input-ipc-server=")
            || arg.starts_with("--input-ipc-server-path=")
            || arg == "--idle"
            || arg.starts_with("--idle="))
    });
    let src = args.pop();
    args.push(format!("--input-ipc-server={endpoint}"));
    args.push("--idle=yes".to_string());
    args.push("--force-window=immediate".to_string());
    if let Some(src) = src {
        args.push(src);
    }
    args
}

fn augment_vlc_args(mut args: Vec<String>) -> Vec<String> {
    args.retain(|arg| arg != "--play-and-exit");
    let src = args.pop();
    args.push("--one-instance".to_string());
    args.push("--no-playlist-enqueue".to_string());
    if let Some(src) = src {
        args.push(src);
    }
    args
}

// ---------------------------------------------------------------------------
// IPC senders
// ---------------------------------------------------------------------------
#[cfg(unix)]
fn open_mpv_socket(endpoint: &str) -> std::io::Result<std::os::unix::net::UnixStream> {
    use std::os::unix::net::UnixStream;
    let stream = UnixStream::connect(endpoint)?;
    stream.set_write_timeout(Some(Duration::from_millis(IPC_WRITE_TIMEOUT_MS)))?;
    stream.set_read_timeout(Some(Duration::from_millis(IPC_WRITE_TIMEOUT_MS)))?;
    Ok(stream)
}

#[cfg(windows)]
fn open_mpv_pipe(endpoint: &str) -> std::io::Result<std::fs::File> {
    use std::fs::OpenOptions;
    OpenOptions::new()
        .read(true)
        .write(true)
        .open(endpoint)
}

fn build_mpv_loadfile(url: &str, ua: Option<&str>, referer: Option<&str>) -> Vec<u8> {
    let mut opts: Vec<String> = Vec::new();
    if let Some(ua) = ua.filter(|s| !s.is_empty()) {
        opts.push(format!("user-agent=%{}%{}", ua.len(), ua));
    }
    if let Some(referer) = referer.filter(|s| !s.is_empty()) {
        opts.push(format!("referrer=%{}%{}", referer.len(), referer));
    }
    let cmd = if opts.is_empty() {
        json!({ "command": ["loadfile", url, "replace"] })
    } else {
        json!({ "command": ["loadfile", url, "replace", opts.join(",")] })
    };
    let mut bytes = serde_json::to_vec(&cmd).unwrap_or_else(|_| Vec::new());
    bytes.push(b'\n');
    bytes
}

fn build_mpv_unpause() -> Vec<u8> {
    let mut bytes =
        serde_json::to_vec(&json!({ "command": ["set_property", "pause", false] }))
            .unwrap_or_else(|_| Vec::new());
    bytes.push(b'\n');
    bytes
}

fn send_mpv_loadfile(
    endpoint: &str,
    url: &str,
    ua: Option<&str>,
    referer: Option<&str>,
) -> Result<(), String> {
    let payload = build_mpv_loadfile(url, ua, referer);
    let unpause = build_mpv_unpause();

    #[cfg(unix)]
    {
        let mut stream = open_mpv_socket(endpoint).map_err(|e| format!("IPC:{e}"))?;
        stream
            .write_all(&payload)
            .map_err(|e| format!("IPC:{e}"))?;
        stream
            .write_all(&unpause)
            .map_err(|e| format!("IPC:{e}"))?;
        let mut sink = [0u8; 256];
        let _ = stream.set_read_timeout(Some(Duration::from_millis(150)));
        let _ = stream.read(&mut sink);
        Ok(())
    }

    #[cfg(windows)]
    {
        let mut pipe = open_mpv_pipe(endpoint).map_err(|e| format!("IPC:{e}"))?;
        pipe.write_all(&payload).map_err(|e| format!("IPC:{e}"))?;
        pipe.write_all(&unpause).map_err(|e| format!("IPC:{e}"))?;
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Tauri commands
// ---------------------------------------------------------------------------
#[tauri::command]
pub async fn launch_external_player(
    state: State<'_, ExternalPlayerState>,
    path: String,
    args: Vec<String>,
    mode: String,
    reuse: Option<ReuseConfig>,
) -> Result<Value, String> {
    match mode.as_str() {
        "detect" => {
            let version = tauri::async_runtime::spawn_blocking(move || spawn_detect(path, args))
                .await
                .map_err(|e| format!("OTHER:join: {e}"))??;
            Ok(json!({ "version": version }))
        }
        "exists" => {
            if path.is_empty() {
                return Err("NOT_FOUND:player path is empty".to_string());
            }
            if Path::new(&path).exists() {
                Ok(json!({ "version": "(path verified)" }))
            } else {
                Err(format!("NOT_FOUND:no file at {path}"))
            }
        }
        "launch" => launch_mode(state, path, args, reuse).await,
        other => Err(format!("OTHER:unknown mode '{other}'")),
    }
}

async fn launch_mode(
    state: State<'_, ExternalPlayerState>,
    path: String,
    args: Vec<String>,
    reuse: Option<ReuseConfig>,
) -> Result<Value, String> {
    let reuse = reuse.unwrap_or_default();
    let kind = reuse.kind.clone();

    if reuse.enabled && kind == "mpv" && !reuse.url.is_empty() {
        // MPV: drive the existing window via JSON-IPC over its socket / pipe.
        if let Some(slot) = state.get(&kind) {
            let ua = extract_arg(&args, "--user-agent=");
            let referer = extract_arg(&args, "--referrer=");
            match send_mpv_loadfile(
                &slot.endpoint,
                &reuse.url,
                ua.as_deref(),
                referer.as_deref(),
            ) {
                Ok(()) => return Ok(json!({ "pid": slot.pid, "reused": true })),
                Err(err) => {
                    log::warn!("[external-player] mpv reuse send failed: {err}");
                    state.drop_slot(&kind);
                }
            }
        }

        let endpoint = pick_mpv_endpoint();
        let augmented = augment_mpv_args(args.clone(), &endpoint);
        let path_for_spawn = path.clone();
        let pid = tauri::async_runtime::spawn_blocking(move || {
            spawn_launch_inner(&path_for_spawn, &augmented)
        })
        .await
        .map_err(|e| format!("OTHER:join: {e}"))??;
        state.set(&kind, Slot { pid, endpoint });
        return Ok(json!({ "pid": pid, "reused": false }));
    }

    if reuse.enabled && kind == "vlc" && !reuse.url.is_empty() {
        let augmented = augment_vlc_args(args.clone());
        let path_for_spawn = path.clone();
        let pid = tauri::async_runtime::spawn_blocking(move || {
            spawn_launch_inner(&path_for_spawn, &augmented)
        })
        .await
        .map_err(|e| format!("OTHER:join: {e}"))??;
        let reused = state.get(&kind).is_some();
        // VLC reuse is handled by --one-instance; the slot is just a presence
        // flag for `reused`, so the endpoint stays empty.
        state.set(&kind, Slot { pid, endpoint: String::new() });
        return Ok(json!({ "pid": pid, "reused": reused }));
    }

    // Plain spawn-and-forget fallthrough.
    let pid =
        tauri::async_runtime::spawn_blocking(move || spawn_launch_inner(&path, &args))
            .await
            .map_err(|e| format!("OTHER:join: {e}"))??;
    Ok(json!({ "pid": pid, "reused": false }))
}

fn extract_arg(args: &[String], prefix: &str) -> Option<String> {
    for arg in args {
        if let Some(rest) = arg.strip_prefix(prefix) {
            return Some(rest.to_string());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn augment_mpv_strips_existing_ipc_server() {
        let args = vec![
            "--force-window=immediate".to_string(),
            "--input-ipc-server=/old/path".to_string(),
            "--idle=no".to_string(),
            "https://example.com/stream.m3u8".to_string(),
        ];
        let out = augment_mpv_args(args, "/new/path");
        assert!(!out.iter().any(|arg| arg == "--idle=no"));
        assert!(!out
            .iter()
            .any(|arg| arg.starts_with("--input-ipc-server=/old")));
        assert!(out.contains(&"--input-ipc-server=/new/path".to_string()));
        assert!(out.contains(&"--idle=yes".to_string()));
        assert_eq!(out.last().unwrap(), "https://example.com/stream.m3u8");
    }

    #[test]
    fn augment_vlc_drops_play_and_exit_and_adds_one_instance() {
        let args = vec![
            "--no-qt-error-dialogs".to_string(),
            "--play-and-exit".to_string(),
            "https://example.com/stream.m3u8".to_string(),
        ];
        let out = augment_vlc_args(args);
        assert!(!out.iter().any(|arg| arg == "--play-and-exit"));
        assert!(out.contains(&"--no-qt-error-dialogs".to_string()));
        assert!(out.contains(&"--one-instance".to_string()));
        assert!(out.contains(&"--no-playlist-enqueue".to_string()));
        assert_eq!(out.last().unwrap(), "https://example.com/stream.m3u8");
    }

    #[test]
    fn build_mpv_loadfile_includes_url_and_options() {
        let bytes = build_mpv_loadfile(
            "https://e.test/x.m3u8",
            Some("AgentX"),
            Some("https://r.test/"),
        );
        let s = String::from_utf8(bytes).unwrap();
        assert!(s.contains("loadfile"));
        assert!(s.contains("https://e.test/x.m3u8"));
        assert!(s.contains("user-agent="));
        assert!(s.contains("AgentX"));
        assert!(s.ends_with('\n'));
    }

    #[test]
    fn build_mpv_loadfile_preserves_comma_in_user_agent() {
        let ua = "Mozilla/5.0 (X11; Linux x86_64), Gecko/2010";
        let referer = "https://r.test/, with comma";
        let bytes = build_mpv_loadfile("https://e.test/x.m3u8", Some(ua), Some(referer));
        let line = String::from_utf8(bytes).unwrap();

        let parsed: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        let cmd = parsed["command"].as_array().expect("command must be an array");
        assert_eq!(cmd[0], "loadfile");
        assert_eq!(cmd[1], "https://e.test/x.m3u8");
        assert_eq!(cmd[2], "replace");

        let opts = cmd[3].as_str().expect("opts must be a string");
        assert!(
            opts.contains(&format!("user-agent=%{}%{}", ua.len(), ua)),
            "opts string must percent-length-encode the UA so commas in the value don't terminate it; got {opts:?}"
        );
        assert!(opts.contains(&format!("referrer=%{}%{}", referer.len(), referer)));
    }

    #[test]
    fn build_mpv_loadfile_uses_three_arg_form_when_no_options() {
        let bytes = build_mpv_loadfile("https://e.test/x.m3u8", None, None);
        let parsed: serde_json::Value =
            serde_json::from_str(String::from_utf8(bytes).unwrap().trim()).unwrap();
        let cmd = parsed["command"].as_array().unwrap();
        assert_eq!(cmd.len(), 3);
        assert_eq!(cmd[2], "replace");
    }
}
