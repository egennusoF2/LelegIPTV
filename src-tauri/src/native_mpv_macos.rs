#![cfg(target_os = "macos")]
#![allow(deprecated)]

use cocoa::appkit::{NSOpenGLContext, NSOpenGLPixelFormat, NSOpenGLView, NSView};
use cocoa::base::nil;
use cocoa::foundation::{NSAutoreleasePool, NSPoint, NSRect, NSSize};
use dispatch::Queue;
use libmpv2::{
    render::{mpv_render_update, OpenGLInitParams, RenderContext, RenderParam, RenderParamApiType},
    Mpv,
};
use objc::{msg_send, sel, sel_impl};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use serde_json::Value;
use std::ffi::{c_char, c_void, CString};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use tauri::{Runtime, WebviewWindow};

use crate::native_playback::{NativePlaybackRect, NativePlaybackSnapshot, NativePlaybackTrack};

struct UnsafeSend<T>(T);
unsafe impl<T> Send for UnsafeSend<T> {}

const NS_OPENGL_PROFILE_VERSION_3_2_CORE: u32 = 0x3200;

const LAVF_RECONNECT_OPTS: &str =
    "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=5";

fn run_on_main_sync<T, F>(f: F) -> T
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    if unsafe { libc::pthread_main_np() == 1 } {
        f()
    } else {
        Queue::main().exec_sync(f)
    }
}

pub struct NativeMpvMacos {
    mpv: Option<Mpv>,
    renderer: Option<MacosRenderer>,
    current_url: Option<String>,
    current_rect: Option<NativePlaybackRect>,
}

impl NativeMpvMacos {
    pub fn new() -> Self {
        Self {
            mpv: None,
            renderer: None,
            current_url: None,
            current_rect: None,
        }
    }

    pub fn available() -> bool {
        true
    }

    pub fn attach<R: Runtime>(
        &mut self,
        window: &WebviewWindow<R>,
        rect: NativePlaybackRect,
    ) -> Result<(), String> {
        self.current_rect = Some(rect);
        if let Some(renderer) = self.renderer.as_mut() {
            renderer.set_frame(rect.x, rect.y, rect.width, rect.height);
            return Ok(());
        }
        let mut renderer = MacosRenderer::new(window)?;
        renderer.set_frame(rect.x, rect.y, rect.width, rect.height);
        self.renderer = Some(renderer);
        Ok(())
    }

    pub fn load<R: Runtime>(
        &mut self,
        _app: &tauri::AppHandle<R>,
        src: &str,
        start_seconds: Option<f64>,
        user_agent: Option<String>,
        referer: Option<String>,
    ) -> Result<(), String> {
        if self.renderer.is_none() {
            return Err("NATIVE_MPV_RENDERER:not attached".to_string());
        }

        self.stop_engine_only();
        let mpv = Mpv::with_initializer(|init| {
            for (key, value) in embedded_options() {
                init.set_option(key, value)?;
            }
            Ok(())
        })
        .map_err(|error| format!("NATIVE_MPV_INIT:{error}"))?;
        self.mpv = Some(mpv);

        let mpv = self
            .mpv
            .as_mut()
            .ok_or_else(|| "NATIVE_MPV_INIT:no mpv instance".to_string())?;
        if let Some(ua) = user_agent.filter(|value| !value.trim().is_empty()) {
            let _ = mpv.set_property("user-agent", ua);
        }
        if let Some(referrer) = referer.filter(|value| !value.trim().is_empty()) {
            let _ = mpv.set_property("referrer", referrer);
        }

        self.renderer
            .as_mut()
            .ok_or_else(|| "NATIVE_MPV_RENDERER:not attached".to_string())?
            .attach(mpv)?;

        let resume = start_seconds
            .filter(|seconds| *seconds > 1.0)
            .map(|seconds| format!("start=+{seconds:.3}"));
        if let Some(options) = resume.as_ref() {
            mpv.command("loadfile", &[src, "replace", "0", options])
        } else {
            mpv.command("loadfile", &[src, "replace"])
        }
        .map_err(|error| format!("NATIVE_MPV_LOAD:{error}"))?;
        self.current_url = Some(src.to_string());
        Ok(())
    }

    pub fn play(&self) -> Result<(), String> {
        self.mpv_ref()?
            .set_property("pause", false)
            .map_err(|error| format!("NATIVE_MPV_PLAY:{error}"))
    }

    pub fn pause(&self) -> Result<(), String> {
        self.mpv_ref()?
            .set_property("pause", true)
            .map_err(|error| format!("NATIVE_MPV_PAUSE:{error}"))
    }

    pub fn stop(&mut self) {
        self.stop_engine_only();
        if let Some(renderer) = self.renderer.as_mut() {
            renderer.detach();
        }
        self.renderer = None;
        self.current_url = None;
    }

    pub fn seek(&self, seconds: f64) -> Result<(), String> {
        self.mpv_ref()?
            .command(
                "seek",
                &[&seconds.max(0.0).to_string(), "absolute", "exact"],
            )
            .map_err(|error| format!("NATIVE_MPV_SEEK:{error}"))
    }

    pub fn set_volume(&self, volume: f64) -> Result<(), String> {
        self.mpv_ref()?
            .set_property("volume", volume.clamp(0.0, 100.0))
            .map_err(|error| format!("NATIVE_MPV_VOLUME:{error}"))
    }

    pub fn set_speed(&self, speed: f64) -> Result<(), String> {
        self.mpv_ref()?
            .set_property("speed", speed.clamp(0.25, 4.0))
            .map_err(|error| format!("NATIVE_MPV_SPEED:{error}"))
    }

    pub fn select_audio_track(&self, id: String) -> Result<(), String> {
        let mpv = self.mpv_ref()?;
        if let Ok(track_id) = id.parse::<i64>() {
            mpv.set_property("aid", track_id)
        } else {
            mpv.set_property("aid", id)
        }
        .map_err(|error| format!("NATIVE_MPV_AID:{error}"))
    }

    pub fn select_subtitle_track(&self, id: Option<String>) -> Result<(), String> {
        let mpv = self.mpv_ref()?;
        match id.filter(|value| !value.trim().is_empty()) {
            Some(value) => {
                if let Ok(track_id) = value.parse::<i64>() {
                    mpv.set_property("sid", track_id)
                } else {
                    mpv.set_property("sid", value)
                }
            }
            None => mpv.set_property("sid", "no"),
        }
        .map_err(|error| format!("NATIVE_MPV_SID:{error}"))
    }

    pub fn set_subtitle_delay(&self, seconds: f64) -> Result<(), String> {
        self.mpv_ref()?
            .set_property("sub-delay", seconds)
            .map_err(|error| format!("NATIVE_MPV_SUB_DELAY:{error}"))
    }

    pub fn snapshot(&self) -> NativePlaybackSnapshot {
        let Some(mpv) = self.mpv.as_ref() else {
            return NativePlaybackSnapshot::empty("macos-libmpv", true, None);
        };
        let duration = mpv.get_property::<f64>("duration").unwrap_or(0.0);
        let current_time = mpv.get_property::<f64>("time-pos").unwrap_or(0.0);
        let paused = mpv.get_property::<bool>("pause").unwrap_or(true);
        let ended = mpv.get_property::<bool>("eof-reached").unwrap_or(false);
        let (audio, subtitles) = map_tracks_from_mpv(mpv);
        let selected_audio_id = audio
            .iter()
            .find(|track| track.active)
            .map(|track| track.id.clone());
        let selected_subtitle_id = subtitles
            .iter()
            .find(|track| track.active)
            .map(|track| track.id.clone());
        NativePlaybackSnapshot {
            backend: "macos-libmpv",
            available: true,
            loaded: self.current_url.is_some(),
            paused,
            ended,
            current_time,
            duration,
            audio,
            subtitles,
            selected_audio_id,
            selected_subtitle_id,
            error: None,
        }
    }

    fn mpv_ref(&self) -> Result<&Mpv, String> {
        self.mpv
            .as_ref()
            .ok_or_else(|| "NATIVE_MPV_NOT_LOADED".to_string())
    }

    fn stop_engine_only(&mut self) {
        if let Some(renderer) = self.renderer.as_mut() {
            renderer.detach_render_context();
        }
        if let Some(mpv) = self.mpv.as_ref() {
            let _ = mpv.command("stop", &[]);
        }
        self.mpv = None;
    }
}

fn embedded_options() -> Vec<(&'static str, &'static str)> {
    vec![
        ("vo", "libmpv"),
        ("hwdec", "videotoolbox"),
        ("ao", "coreaudio"),
        ("video-sync", "display-resample"),
        ("cache", "yes"),
        ("cache-secs", "30"),
        ("demuxer-max-bytes", "150MiB"),
        ("demuxer-max-back-bytes", "75MiB"),
        ("stream-lavf-o", LAVF_RECONNECT_OPTS),
        ("network-timeout", "30"),
        ("keep-open", "yes"),
        ("terminal", "no"),
        ("msg-level", "all=warn"),
    ]
}

fn map_tracks_from_mpv(mpv: &Mpv) -> (Vec<NativePlaybackTrack>, Vec<NativePlaybackTrack>) {
    let count = mpv
        .get_property::<String>("track-list/count")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(0);
    let mut audio = Vec::new();
    let mut subtitles = Vec::new();
    for index in 0..count {
        let prefix = format!("track-list/{index}");
        let kind = mpv
            .get_property::<String>(&format!("{prefix}/type"))
            .unwrap_or_default();
        if kind != "audio" && kind != "sub" {
            continue;
        }
        let id = mpv
            .get_property::<String>(&format!("{prefix}/id"))
            .unwrap_or_else(|_| (index + 1).to_string());
        let language = mpv
            .get_property::<String>(&format!("{prefix}/lang"))
            .unwrap_or_default();
        let title = mpv
            .get_property::<String>(&format!("{prefix}/title"))
            .unwrap_or_default();
        let active = mpv
            .get_property::<bool>(&format!("{prefix}/selected"))
            .unwrap_or(false);
        let label = if !title.trim().is_empty() {
            title
        } else if !language.trim().is_empty() {
            language.clone()
        } else if kind == "audio" {
            format!("Audio {}", audio.len() + 1)
        } else {
            format!("Subtitle {}", subtitles.len() + 1)
        };
        let track = NativePlaybackTrack {
            id: id.clone(),
            kind: if kind == "audio" { "audio" } else { "subtitle" },
            label,
            language,
            index: id.parse::<i32>().unwrap_or(index as i32),
            active,
        };
        if kind == "audio" {
            audio.push(track);
        } else {
            subtitles.push(track);
        }
    }
    (audio, subtitles)
}

fn gl_get_proc_address(name: *const c_char) -> *mut c_void {
    static HANDLE: std::sync::OnceLock<usize> = std::sync::OnceLock::new();
    let lib = *HANDLE.get_or_init(|| {
        let path = CString::new("/System/Library/Frameworks/OpenGL.framework/OpenGL").unwrap();
        unsafe { libc::dlopen(path.as_ptr(), libc::RTLD_LAZY | libc::RTLD_GLOBAL) as usize }
    });
    if lib == 0 {
        return std::ptr::null_mut();
    }
    unsafe { libc::dlsym(lib as *mut c_void, name) }
}

struct RenderInner {
    ctx: RenderContext,
    gl_view: *mut c_void,
    gl_context: *mut c_void,
    active: Arc<AtomicBool>,
}

unsafe impl Send for RenderInner {}

struct MacosRenderer {
    gl_view: *mut c_void,
    gl_context: *mut c_void,
    content_view: *mut c_void,
    valid: Arc<AtomicBool>,
    active: Arc<AtomicBool>,
    render_inner: Option<Box<RenderInner>>,
}

unsafe impl Send for MacosRenderer {}
unsafe impl Sync for MacosRenderer {}

impl MacosRenderer {
    fn new<R: Runtime>(window: &WebviewWindow<R>) -> Result<Self, String> {
        let raw = window
            .window_handle()
            .map_err(|error| format!("window handle: {error:?}"))?
            .as_raw();
        let ns_view_ptr = match raw {
            RawWindowHandle::AppKit(handle) => handle.ns_view.as_ptr() as *mut c_void,
            _ => return Err("Expected AppKit window handle".to_string()),
        };
        let ns_view_addr = ns_view_ptr as usize;
        run_on_main_sync(move || unsafe { Self::build_on_main(ns_view_addr as *mut c_void) })
    }

    unsafe fn build_on_main(content_view_ptr: *mut c_void) -> Result<Self, String> {
        let _pool = NSAutoreleasePool::new(nil);
        let content_view = content_view_ptr as *mut objc::runtime::Object;
        let bounds: NSRect = NSView::bounds(content_view);
        let attrs: [u32; 5] = [
            cocoa::appkit::NSOpenGLPFAOpenGLProfile as u32,
            NS_OPENGL_PROFILE_VERSION_3_2_CORE,
            cocoa::appkit::NSOpenGLPFADoubleBuffer as u32,
            cocoa::appkit::NSOpenGLPFAAccelerated as u32,
            0,
        ];
        let pixel_format = NSOpenGLPixelFormat::alloc(nil);
        let pixel_format = NSOpenGLPixelFormat::initWithAttributes_(pixel_format, &attrs);
        if pixel_format == nil {
            return Err("NSOpenGLPixelFormat init failed".to_string());
        }
        let gl_view = NSOpenGLView::alloc(nil);
        let gl_view = NSOpenGLView::initWithFrame_pixelFormat_(gl_view, bounds, pixel_format);
        if gl_view == nil {
            return Err("NSOpenGLView init failed".to_string());
        }
        let gl_context: *mut objc::runtime::Object = msg_send![gl_view, openGLContext];
        if gl_context.is_null() {
            return Err("NSOpenGLView returned nil openGLContext".to_string());
        }
        let _: () = msg_send![
            content_view,
            addSubview: gl_view
            positioned: -1i64
            relativeTo: nil
        ];
        Ok(Self {
            gl_view: gl_view as *mut c_void,
            gl_context: gl_context as *mut c_void,
            content_view: content_view as *mut c_void,
            valid: Arc::new(AtomicBool::new(true)),
            active: Arc::new(AtomicBool::new(true)),
            render_inner: None,
        })
    }

    fn attach(&mut self, mpv: &mut Mpv) -> Result<(), String> {
        self.detach_render_context();
        self.active = Arc::new(AtomicBool::new(true));
        let gl_view_ptr = self.gl_view as usize;
        let gl_context_ptr = self.gl_context as usize;
        let mpv_ctx_addr = mpv.ctx.as_ptr() as usize;
        let result: UnsafeSend<Result<RenderContext, String>> =
            run_on_main_sync(move || -> UnsafeSend<Result<RenderContext, String>> {
                let view = gl_view_ptr as *mut objc::runtime::Object;
                let ctx = gl_context_ptr as *mut objc::runtime::Object;
                let mpv_ctx = mpv_ctx_addr as *mut _;
                unsafe {
                    let _: () = msg_send![view, prepareOpenGL];
                    NSOpenGLContext::setView_(ctx, view);
                    NSOpenGLContext::makeCurrentContext(ctx);
                }

                fn get_proc_address(_ctx: &*mut c_void, name: &str) -> *mut c_void {
                    CString::new(name)
                        .map(|name| gl_get_proc_address(name.as_ptr()))
                        .unwrap_or(std::ptr::null_mut())
                }

                UnsafeSend(
                    RenderContext::new(
                        unsafe { &mut *mpv_ctx },
                        vec![
                            RenderParam::ApiType(RenderParamApiType::OpenGl),
                            RenderParam::InitParams(OpenGLInitParams {
                                get_proc_address,
                                ctx: std::ptr::null_mut(),
                            }),
                        ],
                    )
                    .map_err(|error| format!("mpv_render_context_create:{error}")),
                )
        });
        let render_ctx = result.0?;
        let active = self.active.clone();
        let mut inner = Box::new(RenderInner {
            ctx: render_ctx,
            gl_view: self.gl_view,
            gl_context: self.gl_context,
            active: active.clone(),
        });
        let inner_ptr = &*inner as *const RenderInner as usize;
        let valid = self.valid.clone();
        inner.ctx.set_update_callback(move || {
            let valid = valid.clone();
            let active = active.clone();
            Queue::main().exec_async(move || {
                if !valid.load(Ordering::Acquire) || !active.load(Ordering::Acquire) {
                    return;
                }
                unsafe { render_frame(inner_ptr) };
            });
        });
        self.render_inner = Some(inner);
        Ok(())
    }

    fn set_frame(&mut self, x: f64, y: f64, w: f64, h: f64) {
        let gl_view_ptr = self.gl_view as usize;
        let gl_context_ptr = self.gl_context as usize;
        let content_view_ptr = self.content_view as usize;
        Queue::main().exec_async(move || unsafe {
            let view = gl_view_ptr as *mut objc::runtime::Object;
            let ctx = gl_context_ptr as *mut objc::runtime::Object;
            let parent = content_view_ptr as *mut objc::runtime::Object;
            let is_flipped: bool = msg_send![parent, isFlipped];
            let appkit_y = if is_flipped {
                y
            } else {
                let window: *mut objc::runtime::Object = msg_send![parent, window];
                let ref_height = if !window.is_null() {
                    let layout_rect: NSRect = msg_send![window, contentLayoutRect];
                    layout_rect.size.height
                } else {
                    let bounds: NSRect = NSView::bounds(parent);
                    bounds.size.height
                };
                ref_height - y - h
            };
            let frame = NSRect::new(NSPoint::new(x, appkit_y), NSSize::new(w, h));
            let _: () = msg_send![view, setFrame: frame];
            let _: () = msg_send![ctx, update];
        });
    }

    fn detach_render_context(&mut self) {
        let Some(render_inner) = self.render_inner.take() else {
            return;
        };
        self.active.store(false, Ordering::Release);
        let gl_context_ptr = self.gl_context as usize;
        run_on_main_sync(move || unsafe {
            if gl_context_ptr != 0 {
                let ctx = gl_context_ptr as *mut objc::runtime::Object;
                NSOpenGLContext::makeCurrentContext(ctx);
            }
            drop(render_inner);
        });
    }

    fn detach(&mut self) {
        self.valid.store(false, Ordering::Release);
        let gl_view_ptr = self.gl_view as usize;
        let gl_context_ptr = self.gl_context as usize;
        self.detach_render_context();
        run_on_main_sync(move || unsafe {
            if gl_context_ptr != 0 {
                let ctx = gl_context_ptr as *mut objc::runtime::Object;
                NSOpenGLContext::makeCurrentContext(ctx);
            }
            if gl_view_ptr != 0 {
                let view = gl_view_ptr as *mut objc::runtime::Object;
                let _: () = msg_send![view, removeFromSuperview];
            }
        });
        self.gl_view = std::ptr::null_mut();
    }
}

impl Drop for MacosRenderer {
    fn drop(&mut self) {
        self.detach();
    }
}

unsafe fn render_frame(inner_ptr: usize) {
    let inner = &mut *(inner_ptr as *mut RenderInner);
    if !inner.active.load(Ordering::Acquire) {
        return;
    }
    let view = inner.gl_view as *mut objc::runtime::Object;
    let ctx = inner.gl_context as *mut objc::runtime::Object;
    NSOpenGLContext::setView_(ctx, view);
    NSOpenGLContext::makeCurrentContext(ctx);
    let bounds: NSRect = NSView::bounds(view);
    let window: *mut objc::runtime::Object = msg_send![view, window];
    let scale = if window.is_null() {
        1.0
    } else {
        msg_send![window, backingScaleFactor]
    };
    let width = (bounds.size.width * scale) as i32;
    let height = (bounds.size.height * scale) as i32;
    if width < 1 || height < 1 {
        return;
    }
    if let Ok(flags) = inner.ctx.update() {
        if flags & mpv_render_update::Frame != 0 {
            if inner
                .ctx
                .render::<*mut c_void>(0, width, height, true)
                .is_ok()
            {
                NSOpenGLContext::flushBuffer(ctx);
                inner.ctx.report_swap();
            }
        }
    }
}

#[allow(dead_code)]
fn _json_debug(_value: &Value) {}
