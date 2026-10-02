use std::{io::{self, BufRead, Write}, time::{Duration, Instant, SystemTime, UNIX_EPOCH}, sync::mpsc};
use base64::{Engine, engine::general_purpose::STANDARD};
use image::{DynamicImage, RgbaImage, codecs::jpeg::JpegEncoder};
use serde_json::json;
use windows_capture::{capture::{Context, GraphicsCaptureApiHandler}, frame::Frame,
    graphics_capture_api::InternalCaptureControl, settings::*, window::Window};

type Failure = Box<dyn std::error::Error + Send + Sync>;
struct Options { hwnd: usize, pid: u32, width: u32, fps: u32 }
struct Capture { options: Options, last: Option<Instant>, first_pts: Option<i64>, sequence: u64 }
fn emit(value: serde_json::Value) -> Result<(), Failure> {
    let mut out = io::stdout().lock();
    serde_json::to_writer(&mut out, &value)?; out.write_all(b"\n")?; out.flush()?; Ok(())
}
impl GraphicsCaptureApiHandler for Capture {
    type Flags = Options;
    type Error = Failure;
    fn new(ctx: Context<Options>) -> Result<Self, Failure> {
        Ok(Self { options: ctx.flags, last: None, first_pts: None, sequence: 0 })
    }
    fn on_frame_arrived(&mut self, frame: &mut Frame, control: InternalCaptureControl) -> Result<(), Failure> {
        let window = Window::from_raw_hwnd(self.options.hwnd as *mut std::ffi::c_void);
        if window.process_id()? != self.options.pid { control.stop(); return Err("Window identity changed".into()); }
        if self.last.is_some_and(|last| last.elapsed() < Duration::from_millis(1000 / self.options.fps as u64)) { return Ok(()); }
        self.last = Some(Instant::now());
        let width = frame.width(); let height = frame.height();
        if width == 0 || height == 0 || width as u64 * height as u64 > 16_000_000 { return Err("Invalid capture dimensions".into()); }
        let ticks = frame.timestamp()?.Duration;
        let origin = *self.first_pts.get_or_insert(ticks);
        let buffer = frame.buffer()?;
        let mut scratch = Vec::new();
        let rgba = RgbaImage::from_raw(width, height, buffer.as_nopadding_buffer(&mut scratch).to_vec()).ok_or("Invalid RGBA buffer")?;
        let picture = DynamicImage::ImageRgba8(rgba).resize(self.options.width, 1080, image::imageops::FilterType::Triangle).to_rgb8();
        let mut jpeg = Vec::new(); JpegEncoder::new_with_quality(&mut jpeg, 75).encode_image(&picture)?;
        self.sequence += 1;
        emit(json!({"type":"frame", "sequence":self.sequence, "ptsMs":(ticks-origin) as f64 / 10000.0,
            "capturedAtUnixMs":SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis() as u64,
            "captureTicks100ns":ticks.to_string(), "sourceWidth":width,"sourceHeight":height,
            "width":picture.width(), "height":picture.height(),"backend":"windows-graphics-capture",
            "coordinateSpace":"window", "cursorIncluded":true,"imageBase64":STANDARD.encode(jpeg)}))
    }
    fn on_closed(&mut self) -> Result<(), Failure> { emit(json!({"type":"closed"})) }
}
fn run() -> Result<(), Failure> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 6 { return Err("Usage: mcp-window-capture HWND PID MAX_WIDTH FPS SECONDS".into()); }
    let options = Options { hwnd: args[1].parse()?, pid: args[2].parse()?, width: args[3].parse::<u32>()?.clamp(160,1920), fps: args[4].parse::<u32>()?.clamp(1,15) };
    let seconds = args[5].parse::<u64>()?.clamp(1,120);
    let window = Window::from_raw_hwnd(options.hwnd as *mut std::ffi::c_void);
    let name = window.process_name()?.to_ascii_lowercase();
    if window.process_id()? != options.pid || !["robloxplayerbeta.exe","robloxstudiobeta.exe"].contains(&name.as_str()) {
        return Err("Only an explicitly selected Roblox window is supported".into());
    }
    let settings = Settings::new(window, CursorCaptureSettings::WithCursor, DrawBorderSettings::Default,
        SecondaryWindowSettings::Default, MinimumUpdateIntervalSettings::Default, DirtyRegionSettings::Default, ColorFormat::Rgba8, options);
    let capture = Capture::start_free_threaded(settings)?;
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || { let mut line = String::new(); let _ = io::stdin().lock().read_line(&mut line); let _ = tx.send(()); });
    let _ = rx.recv_timeout(Duration::from_secs(seconds));
    capture.stop()?;
    emit(json!({"type":"stopped"}))
}
fn main() {
    if let Err(error) = run() { let _ = emit(json!({"type":"error","message":error.to_string()})); std::process::exit(1); }
}
