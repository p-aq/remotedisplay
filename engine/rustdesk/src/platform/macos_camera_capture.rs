//! remotedisplay: the controller's camera for camera forwarding
//! (docs/specs/camera-audio-forwarding.md, decisions 0004, 0005, 0006 and 0016).
//!
//! [`Capture`] opens a camera and hands out H.264 Annex B access units, one per call,
//! with SPS and PPS in front of every key frame: what `CameraFrame` carries, and says
//! if the camera goes away while it runs (decision 0020). The work is in
//! `macos_camera_capture.mm`; this file wraps it. The sender
//! (`src/client/device_forward.rs`) decides when to start, skip and stop.
//!
//! With `--camera-test-pattern` ([`use_test_pattern`]) a generated test card is offered
//! as one more camera, so the whole path runs without a camera (spec, Controller side ›
//! Testing without a camera).

use hbb_common::{bail, ResultType};
use std::{
    ffi::{c_void, CStr, CString},
    os::raw::{c_char, c_int},
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
};

/// The test card's camera ID; `kTestPatternID` in the .mm.
pub const TEST_PATTERN_ID: &str = "remotedisplay-test-pattern";
const TEST_PATTERN_NAME: &str = "Test pattern";
static TEST_PATTERN: AtomicBool = AtomicBool::new(false);

/// Offers the test card as a camera for the rest of this process (`--camera-test-pattern`).
pub fn use_test_pattern() {
    TEST_PATTERN.store(true, Ordering::Relaxed);
}

/// A camera that can be forwarded. Remote Display Camera itself is never listed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Camera {
    pub id: String,
    pub name: String,
}

/// Whether macOS lets this app use the camera.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    NotDetermined,
    Restricted,
    Denied,
    Allowed,
}

#[derive(Debug, Clone)]
pub struct Config {
    /// `None` for the system's default camera.
    pub device_id: Option<String>,
    pub width: i32,
    pub height: i32,
    pub fps: i32,
    pub bitrate_kbps: i32,
}

impl Default for Config {
    /// The spec's starting point: 1280×720, 30 fps, 2 Mbit/s.
    fn default() -> Self {
        Self {
            device_id: None,
            width: 1280,
            height: 720,
            fps: 30,
            bitrate_kbps: 2000,
        }
    }
}

/// What the camera and encoder actually run at, for `DeviceForwardRequest`.
#[derive(Debug, Clone)]
pub struct Info {
    pub width: i32,
    pub height: i32,
    pub fps: i32,
    pub device_id: String,
    pub device_name: String,
    pub encoder_id: String,
    pub low_latency: bool,
    pub required_hardware: bool,
}

#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct Stats {
    /// Frames the camera delivered.
    pub captured: u64,
    /// Access units handed out.
    pub encoded: u64,
    /// Dropped before encoding: the encoder still had the previous frame.
    pub busy: u64,
    /// Dropped before encoding: starting, or skipping was on.
    pub skipped: u64,
    /// Dropped: not the size the encoder was made for.
    pub mismatched: u64,
    /// Refused or dropped by the encoder.
    pub failed: u64,
}

#[repr(C)]
struct RawInfo {
    width: c_int,
    height: c_int,
    fps: c_int,
    low_latency: bool,
    required_hardware: bool,
    encoder_id: [c_char; 128],
    device_id: [c_char; 256],
    device_name: [c_char; 256],
}

type Encoded = extern "C" fn(ctx: *mut c_void, data: *const u8, len: usize, key: bool, pts_us: i64);
type AccessDone = extern "C" fn(ctx: *mut c_void, granted: bool);
type Each = extern "C" fn(ctx: *mut c_void, id: *const c_char, name: *const c_char);
type Lost = extern "C" fn(ctx: *mut c_void, why: *const c_char);

extern "C" {
    fn MacCameraAuthorizationStatus() -> c_int;
    fn MacCameraRequestAccess(done: AccessDone, ctx: *mut c_void);
    fn MacCameraList(each: Each, ctx: *mut c_void);
    fn MacCameraCaptureStart(
        device_id: *const c_char,
        width: c_int,
        height: c_int,
        fps: c_int,
        bitrate_kbps: c_int,
        callback: Encoded,
        lost: Lost,
        ctx: *mut c_void,
        info: *mut RawInfo,
        error: *mut c_int,
    ) -> *mut c_void;
    fn MacCameraCaptureRequestKeyFrame(capture: *mut c_void);
    fn MacCameraCaptureSetBitrate(capture: *mut c_void, bitrate_kbps: c_int) -> i32;
    fn MacCameraCaptureSetSkipping(capture: *mut c_void, skip: bool);
    fn MacCameraCaptureGetStats(capture: *mut c_void, stats: *mut Stats);
    fn MacCameraCaptureStop(capture: *mut c_void);
}

fn string(chars: &[c_char]) -> String {
    unsafe { CStr::from_ptr(chars.as_ptr()) }
        .to_string_lossy()
        .into_owned()
}

pub fn access() -> Access {
    match unsafe { MacCameraAuthorizationStatus() } {
        1 => Access::Restricted,
        2 => Access::Denied,
        3 => Access::Allowed,
        _ => Access::NotDetermined,
    }
}

/// Shows macOS's camera prompt if the user hasn't answered it yet. `done` runs on
/// another thread with the answer.
pub fn request_access(done: impl FnOnce(bool) + Send + 'static) {
    extern "C" fn answered(ctx: *mut c_void, granted: bool) {
        let done = unsafe { Box::from_raw(ctx as *mut Box<dyn FnOnce(bool) + Send>) };
        done(granted);
    }
    let done: Box<Box<dyn FnOnce(bool) + Send>> = Box::new(Box::new(done));
    unsafe { MacCameraRequestAccess(answered, Box::into_raw(done) as *mut c_void) };
}

/// The Mac's cameras (built-in, USB, Continuity Camera, other apps' virtual cameras),
/// without Remote Display Camera, after the test card when it's on. Needs no camera
/// access.
pub fn list() -> Vec<Camera> {
    extern "C" fn each(ctx: *mut c_void, id: *const c_char, name: *const c_char) {
        let cameras = unsafe { &mut *(ctx as *mut Vec<Camera>) };
        let text = |s: *const c_char| {
            if s.is_null() {
                String::new()
            } else {
                unsafe { CStr::from_ptr(s) }.to_string_lossy().into_owned()
            }
        };
        cameras.push(Camera {
            id: text(id),
            name: text(name),
        });
    }
    let mut cameras = Vec::new();
    if TEST_PATTERN.load(Ordering::Relaxed) {
        cameras.push(Camera {
            id: TEST_PATTERN_ID.to_owned(),
            name: TEST_PATTERN_NAME.to_owned(),
        });
    }
    unsafe { MacCameraList(each, &mut cameras as *mut Vec<Camera> as *mut c_void) };
    cameras
}

/// What the .mm calls back, through its `ctx`.
struct Sink {
    on_frame: Mutex<Box<dyn FnMut(&[u8], bool, i64) + Send>>,
    on_lost: Mutex<Option<Box<dyn FnOnce(&str) + Send>>>,
}

extern "C" fn encoded(ctx: *mut c_void, data: *const u8, len: usize, key: bool, pts_us: i64) {
    if data.is_null() {
        return;
    }
    let sink = unsafe { &*(ctx as *const Sink) };
    let data = unsafe { std::slice::from_raw_parts(data, len) };
    if let Ok(mut on_frame) = sink.on_frame.lock() {
        on_frame(data, key, pts_us);
    }
}

extern "C" fn lost(ctx: *mut c_void, why: *const c_char) {
    let sink = unsafe { &*(ctx as *const Sink) };
    let why = if why.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(why) }
            .to_string_lossy()
            .into_owned()
    };
    let on_lost = sink
        .on_lost
        .lock()
        .ok()
        .and_then(|mut on_lost| on_lost.take());
    if let Some(on_lost) = on_lost {
        on_lost(&why);
    }
}

/// A running camera and encoder. The camera's light is on while this lives.
pub struct Capture {
    raw: *mut c_void,
    sink: *mut Sink,
    info: Info,
}

// The .mm side serializes every call on its own queue or through atomics.
unsafe impl Send for Capture {}
unsafe impl Sync for Capture {}

impl Capture {
    /// Opens the camera as close as it offers to the requested size and frame rate.
    /// `on_frame(annex_b, key, pts_us)` runs on a VideoToolbox thread for each access
    /// unit until the `Capture` is dropped; the first one is a key frame. `on_lost(why)`
    /// runs at most once, on an AVFoundation thread, if the camera goes away first:
    /// unplugged, or its session stopped on an error. No frames follow it; the
    /// `Capture` is still dropped as usual. Don't drop the `Capture` from inside
    /// either callback.
    pub fn start(
        config: &Config,
        on_frame: impl FnMut(&[u8], bool, i64) + Send + 'static,
        on_lost: impl FnOnce(&str) + Send + 'static,
    ) -> ResultType<Capture> {
        if config.device_id.as_deref() == Some(TEST_PATTERN_ID)
            && !TEST_PATTERN.load(Ordering::Relaxed)
        {
            bail!("the test pattern needs --camera-test-pattern");
        }
        let device_id = match &config.device_id {
            Some(id) => Some(CString::new(id.as_str())?),
            None => None,
        };
        let sink: *mut Sink = Box::into_raw(Box::new(Sink {
            on_frame: Mutex::new(Box::new(on_frame)),
            on_lost: Mutex::new(Some(Box::new(on_lost))),
        }));
        let mut raw_info: RawInfo = unsafe { std::mem::zeroed() };
        let mut error: c_int = 0;
        let raw = unsafe {
            MacCameraCaptureStart(
                device_id
                    .as_ref()
                    .map_or(std::ptr::null(), |id| id.as_ptr()),
                config.width,
                config.height,
                config.fps,
                config.bitrate_kbps,
                encoded,
                lost,
                sink as *mut c_void,
                &mut raw_info,
                &mut error,
            )
        };
        if raw.is_null() {
            drop(unsafe { Box::from_raw(sink) });
            match error {
                1 => bail!("camera access not allowed"),
                2 => bail!("camera not found"),
                3 => bail!("camera has no format up to 1920x1080"),
                4 => bail!("camera could not be opened"),
                5 => bail!("no H.264 encoder"),
                _ => bail!("camera failed ({})", error),
            }
        }
        let info = Info {
            width: raw_info.width,
            height: raw_info.height,
            fps: raw_info.fps,
            device_id: string(&raw_info.device_id),
            device_name: string(&raw_info.device_name),
            encoder_id: string(&raw_info.encoder_id),
            low_latency: raw_info.low_latency,
            required_hardware: raw_info.required_hardware,
        };
        Ok(Capture { raw, sink, info })
    }

    pub fn info(&self) -> &Info {
        &self.info
    }

    /// The next frame is a key frame.
    pub fn request_key_frame(&self) {
        unsafe { MacCameraCaptureRequestKeyFrame(self.raw) }
    }

    pub fn set_bitrate(&self, kbps: i32) -> ResultType<()> {
        let status = unsafe { MacCameraCaptureSetBitrate(self.raw, kbps) };
        if status != 0 {
            bail!("bitrate {} kbit/s refused ({})", kbps, status);
        }
        Ok(())
    }

    /// While on, frames are dropped before encoding (decision 0006).
    pub fn set_skipping(&self, skip: bool) {
        unsafe { MacCameraCaptureSetSkipping(self.raw, skip) }
    }

    pub fn stats(&self) -> Stats {
        let mut stats = Stats::default();
        unsafe { MacCameraCaptureGetStats(self.raw, &mut stats) };
        stats
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        // No callback runs after Stop returns, and none is under way, so the sink can go.
        unsafe {
            MacCameraCaptureStop(self.raw);
            drop(Box::from_raw(self.sink));
        }
    }
}

/// NAL unit types in an Annex B access unit, in order.
#[cfg(test)]
fn nal_types(access_unit: &[u8]) -> Vec<u8> {
    let mut types = Vec::new();
    let mut i = 0;
    while i + 3 < access_unit.len() {
        if access_unit[i..i + 3] == [0, 0, 1] {
            types.push(access_unit[i + 3] & 0x1f);
            i += 3;
        } else {
            i += 1;
        }
    }
    types
}

#[cfg(test)]
mod tests {
    use super::nal_types;

    #[test]
    fn finds_nal_units_after_start_codes() {
        let key = [
            0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xce, 0, 0, 0, 1, 0x65, 0x88,
        ];
        assert_eq!(nal_types(&key), [7, 8, 5]);
        assert_eq!(nal_types(&[0, 0, 0, 1, 0x41, 0x9a]), [1]);
        assert!(nal_types(&[0x41, 0x9a, 0, 0]).is_empty());
    }
}

/// The camera tests: they need a camera and macOS's camera prompt, so they're ignored
/// by default. docs/tests/camera-capture/ runs them from their own app bundle. The test
/// card's test needs neither and runs with the others.
#[cfg(test)]
mod capture {
    use super::*;
    use std::{
        io::Write,
        sync::mpsc,
        time::{Duration, Instant},
    };

    struct Unit {
        data: Vec<u8>,
        key: bool,
        pts_us: i64,
    }

    fn collect(rx: &mpsc::Receiver<Unit>, wait: Duration) -> Vec<Unit> {
        let until = Instant::now() + wait;
        let mut units = Vec::new();
        while let Some(left) = until.checked_duration_since(Instant::now()) {
            match rx.recv_timeout(left) {
                Ok(unit) => units.push(unit),
                Err(_) => break,
            }
        }
        units
    }

    // Length-prefixed access units, for the harness's decoder:
    // u32 length, u8 key, i64 pts in microseconds, then the bytes.
    fn dump(units: &[&Unit]) {
        let dir = std::env::temp_dir().join("rd-camera-probe");
        std::fs::create_dir_all(&dir).unwrap();
        let mut file = std::fs::File::create(dir.join("stream.bin")).unwrap();
        for unit in units {
            file.write_all(&(unit.data.len() as u32).to_le_bytes())
                .unwrap();
            file.write_all(&[unit.key as u8]).unwrap();
            file.write_all(&unit.pts_us.to_le_bytes()).unwrap();
            file.write_all(&unit.data).unwrap();
        }
        println!("stream: {}", dir.join("stream.bin").display());
    }

    /// `RD_CAMERA_DUMP=1` also writes what it sent for the harness's decoder (`make pattern`).
    #[test]
    fn sends_the_test_pattern_as_h264() {
        use crate::platform::macos_camera_sink::{Feed, Outcome};
        let config = Config {
            device_id: Some(TEST_PATTERN_ID.to_owned()),
            ..Default::default()
        };
        // Only this test turns the card on, so it's still off here.
        let refused = Capture::start(&config, |_, _, _| {}, |_| {})
            .err()
            .expect("the card started without --camera-test-pattern");
        assert_eq!(
            refused.to_string(),
            "the test pattern needs --camera-test-pattern"
        );
        use_test_pattern();
        assert_eq!(list().first().map(|c| c.id.as_str()), Some(TEST_PATTERN_ID));

        let (tx, rx) = mpsc::channel();
        let capture = Capture::start(
            &config,
            move |data, key, pts_us| {
                let _ = tx.send(Unit {
                    data: data.to_vec(),
                    key,
                    pts_us,
                });
            },
            |why| panic!("the test card went away: {}", why),
        )
        .unwrap();
        let info = capture.info().clone();
        assert_eq!((info.width, info.height, info.fps), (1280, 720, 30));
        assert_eq!(
            (info.device_id.as_str(), info.device_name.as_str()),
            (TEST_PATTERN_ID, TEST_PATTERN_NAME)
        );
        let started = collect(&rx, Duration::from_secs(2));
        capture.request_key_frame();
        let asked = collect(&rx, Duration::from_millis(500));
        let stats = capture.stats();
        drop(capture);
        let _while_stopping = rx.try_iter().count();
        let after_stop = collect(&rx, Duration::from_millis(300));

        let all: Vec<&Unit> = started.iter().chain(&asked).collect();
        if std::env::var_os("RD_CAMERA_DUMP").is_some() {
            dump(&all);
        }
        println!("{} units in 2 s, {:?}, {:?}", started.len(), info, stats);
        // 30 fps for 2 s, with room for a busy machine.
        assert!(started.len() >= 40, "{} units in 2 s", started.len());
        assert!(started[0].key);
        assert_eq!(nal_types(&started[0].data), [7, 8, 5]);
        assert!(asked.iter().any(|u| u.key), "no key frame on request");
        assert!(all.windows(2).all(|w| w[0].pts_us < w[1].pts_us));
        assert_eq!(stats.failed, 0);
        assert!(after_stop.is_empty(), "units after stopping");
        // The host's decoder takes every unit.
        let mut feed = Feed::decode_only();
        for unit in &all {
            assert_eq!(feed.push(&unit.data, unit.pts_us), Outcome::Decoded);
        }
    }

    #[test]
    #[ignore]
    fn lists_cameras_but_not_ours() {
        let cameras = list();
        for camera in &cameras {
            println!("camera: {} ({})", camera.name, camera.id);
        }
        assert!(!cameras.is_empty(), "no camera found");
        assert!(cameras
            .iter()
            .all(|c| !c.name.starts_with("Remote Display")));
    }

    #[test]
    #[ignore]
    fn nothing_without_camera_access() {
        assert_ne!(
            access(),
            Access::Allowed,
            "the probe already has camera access; run make revoke first"
        );
        let (tx, rx) = mpsc::channel();
        let result = Capture::start(
            &Config::default(),
            move |_, _, _| {
                let _ = tx.send(());
            },
            |_| {},
        );
        let error = result.err().expect("started without camera access");
        println!("refused: {}", error);
        assert_eq!(error.to_string(), "camera access not allowed");
        assert!(rx.recv_timeout(Duration::from_secs(2)).is_err());
    }

    #[test]
    #[ignore]
    fn asks_for_camera_access() {
        let (tx, rx) = mpsc::channel();
        request_access(move |granted| {
            let _ = tx.send(granted);
        });
        let granted = rx
            .recv_timeout(Duration::from_secs(300))
            .expect("no answer to the camera prompt within 5 minutes");
        assert!(granted, "camera access refused");
    }

    #[test]
    #[ignore]
    fn sends_the_camera_as_h264() {
        assert_eq!(
            access(),
            Access::Allowed,
            "allow camera access first (make ask)"
        );
        let (tx, rx) = mpsc::channel();
        let capture = Capture::start(
            &Config::default(),
            move |data, key, pts_us| {
                let _ = tx.send(Unit {
                    data: data.to_vec(),
                    key,
                    pts_us,
                });
            },
            |why| println!("camera lost: {}", why),
        )
        .unwrap();
        let info = capture.info().clone();
        println!("{:?}", info);

        // Four seconds as started, then a key frame on request.
        let started = collect(&rx, Duration::from_secs(4));
        capture.request_key_frame();
        let asked = collect(&rx, Duration::from_millis(500));
        // Skipping drops frames before encoding; at most the one already in the
        // encoder still comes out.
        capture.set_skipping(true);
        let before = capture.stats();
        let skipping = collect(&rx, Duration::from_secs(1));
        let during = capture.stats();
        capture.set_skipping(false);
        let resumed = collect(&rx, Duration::from_secs(1));
        capture.set_bitrate(500).unwrap();
        let lower = collect(&rx, Duration::from_secs(1));
        let stats = capture.stats();
        drop(capture);
        // What the encoder finished while stopping is already queued; nothing may follow.
        let while_stopping = rx.try_iter().count();
        let after_stop = collect(&rx, Duration::from_millis(500));

        let all: Vec<&Unit> = started
            .iter()
            .chain(&asked)
            .chain(&skipping)
            .chain(&resumed)
            .chain(&lower)
            .collect();
        dump(&all);
        let keys: Vec<i64> = all.iter().filter(|u| u.key).map(|u| u.pts_us).collect();
        let bytes: usize = started.iter().map(|u| u.data.len()).sum();
        let lower_bytes: usize = lower.iter().map(|u| u.data.len()).sum();
        println!(
            "{} units in the first 4 s ({:.1} fps, {} kbit/s), {} kbit/s in the second after \
             asking for 500, {} key frames in all, {} units while stopping, {:?}",
            started.len(),
            started.len() as f64 / 4.0,
            bytes * 8 / 4 / 1000,
            lower_bytes * 8 / 1000,
            keys.len(),
            while_stopping,
            stats
        );

        assert_eq!(
            (info.width, info.height),
            (1280, 720),
            "closest format to 720p"
        );
        assert!(info.fps > 0 && info.fps <= 30);
        assert!(started.len() >= 40, "under 10 fps: {}", started.len());
        // The first unit is a key frame with its parameter sets; every key frame has
        // them and every other unit is one P slice.
        assert!(started[0].key);
        for unit in &all {
            let types = nal_types(&unit.data);
            if unit.key {
                assert!(
                    types.starts_with(&[7, 8]) && types.contains(&5),
                    "{:?}",
                    types
                );
            } else {
                assert!(types.contains(&1) && !types.contains(&7), "{:?}", types);
            }
        }
        assert!(all.windows(2).all(|w| w[0].pts_us < w[1].pts_us));
        // A key frame at least every 2 s, and one within three frames of a request.
        assert!(
            keys.windows(2).all(|w| w[1] - w[0] <= 2_100_000),
            "{:?}",
            keys
        );
        assert!(
            asked.iter().take(3).any(|u| u.key),
            "no key frame after the request"
        );
        assert!(
            skipping.len() <= 1,
            "{} units while skipping",
            skipping.len()
        );
        assert!(during.skipped - before.skipped >= 5);
        assert!(resumed.len() >= 5 && lower.len() >= 5);
        assert_eq!((stats.mismatched, stats.failed), (0, 0));
        assert!(after_stop.is_empty(), "units after the capture was dropped");
    }
}
