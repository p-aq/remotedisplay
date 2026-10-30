//! remotedisplay: device forwarding on the controller (docs/specs/camera-audio-forwarding.md,
//! Controller side › Sending; decisions 0003, 0006 and 0012).
//!
//! [`DeviceForward`] lives in the session's io loop (`io_loop.rs`, `HOOKS.md` E6). Turning
//! the camera on starts it and asks the host; frames go out only once the host accepts,
//! wrapped in `CameraFrame`. They reach the io loop through a small bounded channel of
//! their own, which the loop serves after any input it already has, so mouse and
//! keyboard never wait behind video. The camera stops when the user switches it off,
//! when the host refuses or stops it, when the session ends, and when the camera goes
//! away, which the host is told about (decision 0020).
//!
//! The microphone follows the same rules (decision 0023). Its capture is its own, not the
//! voice call's (`mic.rs`); once the host accepts, an `AudioFormat` goes first, then the
//! Opus `AudioFrame`s, through a queue of their own.
//!
//! Every change of what the Devices menu shows is reported to the UI as JSON
//! ([`DeviceForward::state`], decision 0018). The functions at the end back the menu's
//! FFI calls in `flutter_ffi.rs`.

use crate::ui_session_interface::{InvokeUiSession, Session};
use hbb_common::{
    bytes::Bytes,
    log,
    message_proto::{
        device_forward_request::Kind, message, AudioFormat, AudioFrame, CameraControl, CameraFrame,
        DeviceForwardRequest, DeviceForwardResponse, DeviceStatus, EncodedVideoFrame,
        EncodedVideoFrames, Message, Misc, VideoFrame,
    },
    protobuf::MessageField,
    tokio::{self, sync::mpsc},
    ResultType,
};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

mod mic;

/// Encoded frames waiting for the io loop (decision 0006: 2–4).
const QUEUE: usize = 3;
/// Microphone frames waiting for the io loop: half a second of 10 ms frames. Beyond that
/// the newest are dropped.
const MIC_QUEUE: usize = 50;
/// Once a frame has waited this long, skip camera frames until the queue drains.
const BACKLOG: Duration = Duration::from_millis(150);
/// A 1.0.x host never answers.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(10);
/// The spec's starting bitrate is also the cap; the host can only lower it.
const MAX_BITRATE_KBPS: i32 = 2000;
const MIN_BITRATE_KBPS: i32 = 100;
/// The host asks for key frames at most this often; a faster one is ignored.
const KEY_FRAME_INTERVAL: Duration = Duration::from_millis(500);

/// What the Devices menu asks for, through `Data::DeviceForward`.
#[derive(Debug, Clone)]
pub struct Switch {
    pub kind: Kind,
    pub on: bool,
    /// The camera's unique ID, or the microphone's name; `None` for the default one.
    pub device: Option<String>,
}

/// A running camera. Dropping it stops the camera and turns its light off.
pub(crate) trait Source: Send {
    fn request_key_frame(&self);
    fn set_bitrate(&self, kbps: i32);
    fn set_skipping(&self, skip: bool);
}

/// What a started camera runs at, for `DeviceForwardRequest`.
#[derive(Debug, Clone, Default)]
pub(crate) struct Format {
    pub width: i32,
    pub height: i32,
    pub fps: i32,
    pub name: String,
}

/// Called with each access unit (Annex B, key frame, presentation time in µs).
pub(crate) type OnUnit = Box<dyn FnMut(&[u8], bool, i64) + Send>;
/// Called at most once if the camera or microphone goes away while it runs, with why.
pub(crate) type OnLost = Box<dyn FnOnce(&str) + Send>;
type Start = Box<
    dyn Fn(Option<&str>, OnUnit, OnLost) -> ResultType<(Box<dyn Source>, Format)> + Send + Sync,
>;
/// Called with each encoded microphone frame (Opus, 10 ms).
pub(crate) type OnAudio = Box<dyn FnMut(Vec<u8>) + Send>;
/// Starts a microphone; dropping what it returns stops it.
type StartMic =
    Box<dyn Fn(Option<&str>, OnAudio, OnLost) -> ResultType<Box<dyn Send>> + Send + Sync>;
/// Hands the UI the new [`DeviceForward::state`].
type Notify = Box<dyn Fn(&str) + Send>;

/// What the Devices menu shows for the camera or the microphone (decision 0018).
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
struct DeviceState {
    /// "off", "asking" (waiting for the host's answer) or "on".
    forward: &'static str,
    /// The device being forwarded: the camera's unique ID or the microphone's name, ""
    /// for the default one or when off.
    device: String,
    /// Why it stopped without being switched off, "" otherwise: the host's reason
    /// ("not-allowed", "not-installed", "not-approved", "busy", "bad-format", or
    /// "refused" when it gave none), "no-answer", "camera-failed" or "microphone-failed"
    /// when it didn't start, or "camera-lost" or "microphone-lost" when it went away
    /// (decisions 0020 and 0023).
    reason: String,
    /// The host's status for the device from its latest `DeviceStatus`, "" before one
    /// arrives; the menu then uses `rd_camera_sink` or `rd_mic_sink` from the login
    /// response.
    host: String,
}

#[cfg(target_os = "macos")]
impl Source for crate::platform::macos_camera_capture::Capture {
    fn request_key_frame(&self) {
        crate::platform::macos_camera_capture::Capture::request_key_frame(self)
    }

    fn set_bitrate(&self, kbps: i32) {
        if let Err(err) = crate::platform::macos_camera_capture::Capture::set_bitrate(self, kbps) {
            log::warn!("Camera bitrate not changed: {}", err);
        }
    }

    fn set_skipping(&self, skip: bool) {
        crate::platform::macos_camera_capture::Capture::set_skipping(self, skip)
    }
}

#[cfg(target_os = "macos")]
fn start_camera(
    device: Option<&str>,
    on_unit: OnUnit,
    on_lost: OnLost,
) -> ResultType<(Box<dyn Source>, Format)> {
    use crate::platform::macos_camera_capture::{Capture, Config};
    let config = Config {
        device_id: device.map(str::to_owned),
        bitrate_kbps: MAX_BITRATE_KBPS,
        ..Default::default()
    };
    let capture = Capture::start(&config, on_unit, on_lost)?;
    let info = capture.info();
    log::info!(
        "Camera {} at {}x{}, {} fps, encoder {}",
        info.device_name,
        info.width,
        info.height,
        info.fps,
        info.encoder_id
    );
    let format = Format {
        width: info.width,
        height: info.height,
        fps: info.fps,
        name: info.device_name.clone(),
    };
    Ok((Box::new(capture), format))
}

#[cfg(not(target_os = "macos"))]
fn start_camera(_: Option<&str>, _: OnUnit, _: OnLost) -> ResultType<(Box<dyn Source>, Format)> {
    hbb_common::bail!("camera forwarding needs macOS on the controller")
}

fn start_mic(
    device: Option<&str>,
    on_audio: OnAudio,
    on_lost: OnLost,
) -> ResultType<Box<dyn Send>> {
    Ok(Box::new(mic::start(device, on_audio, on_lost)?))
}

/// Shared between the encoder's or microphone's thread and the io loop, one per forward.
#[derive(Default)]
struct Shared {
    /// The host accepted: units go into the queue.
    sending: AtomicBool,
    /// A unit was dropped after encoding: nothing decodes until the next key frame.
    broken: AtomicBool,
    /// Ask the camera for a key frame at the next chance.
    key_needed: AtomicBool,
    queued: AtomicUsize,
    dropped: AtomicU64,
    /// The device went away; `wake` tells the io loop.
    lost: AtomicBool,
    wake: tokio::sync::Notify,
}

impl Shared {
    /// Resolves once the device has gone away. Cancel-safe: the flag stays set, and a
    /// wake-up with no one waiting is kept for the next wait.
    async fn lost(&self) {
        while !self.lost.load(Ordering::Acquire) {
            self.wake.notified().await;
        }
    }
}

/// An encoded camera frame waiting for the io loop.
pub struct Unit {
    msg: Message,
    at: Instant,
    shared: Arc<Shared>,
}

/// A microphone message waiting for the io loop: the `AudioFormat`, then frames.
pub struct AudioUnit {
    msg: Message,
    shared: Arc<Shared>,
}

pub enum Event {
    Unit(Unit),
    Audio(AudioUnit),
    /// The host didn't answer the request for this device in time.
    NoAnswer(Kind),
    /// The device went away: unplugged, or it stopped on an error.
    Lost(Kind),
}

enum Camera {
    Off,
    Asking {
        source: Box<dyn Source>,
        until: Instant,
    },
    Sending {
        source: Box<dyn Source>,
    },
}

enum Mic {
    Off,
    Asking {
        _capture: Box<dyn Send>,
        until: Instant,
    },
    Sending {
        _capture: Box<dyn Send>,
    },
}

/// The menu's word for each device, also in the reasons ("camera-lost").
fn noun(kind: Kind) -> &'static str {
    match kind {
        Kind::CAMERA => "camera",
        Kind::MICROPHONE => "microphone",
    }
}

pub struct DeviceForward {
    camera: Camera,
    /// The camera asked for, "" for the default one.
    device: String,
    /// Why the last forward ended without being switched off ([`CameraState::reason`]).
    reason: String,
    notify: Notify,
    /// The state the UI last heard.
    reported: String,
    shared: Arc<Shared>,
    tx: mpsc::Sender<Unit>,
    rx: mpsc::Receiver<Unit>,
    start: Start,
    answer_timeout: Duration,
    skipping: bool,
    last_key_request: Option<Instant>,
    sent: u64,
    host_status: HashMap<Kind, String>,
    mic: Mic,
    /// The microphone asked for, "" for the default one.
    mic_device: String,
    mic_reason: String,
    mic_shared: Arc<Shared>,
    mic_tx: mpsc::Sender<AudioUnit>,
    mic_rx: mpsc::Receiver<AudioUnit>,
    start_mic: StartMic,
    mic_sent: u64,
}

impl Drop for DeviceForward {
    fn drop(&mut self) {
        self.stop_camera();
        self.stop_mic();
        // The session's next connection starts afresh: off, and the host's status from
        // its new login response.
        self.reason.clear();
        self.mic_reason.clear();
        self.host_status.clear();
        self.report();
    }
}

fn request(kind: Kind, on: bool, format: Option<&Format>) -> Message {
    let mut request = DeviceForwardRequest {
        kind: kind.into(),
        on,
        ..Default::default()
    };
    if let Some(format) = format {
        request.width = format.width;
        request.height = format.height;
        request.fps = format.fps;
        request.device_name = format.name.clone();
    }
    let mut msg = Message::new();
    msg.set_device_forward_request(request);
    msg
}

/// One access unit as `CameraFrame` (decisions 0003 and 0005): H.264 Annex B in `h264s`,
/// one `EncodedVideoFrame`, `pts` in ms like the screen's, the capture time in µs.
fn camera_frame(data: &[u8], key: bool, pts_us: i64) -> Message {
    let frames = EncodedVideoFrames {
        frames: vec![EncodedVideoFrame {
            data: Bytes::copy_from_slice(data),
            key,
            pts: pts_us / 1000,
            ..Default::default()
        }],
        ..Default::default()
    };
    let mut frame = VideoFrame::new();
    frame.set_h264s(frames);
    let mut msg = Message::new();
    msg.set_camera_frame(CameraFrame {
        frame: MessageField::some(frame),
        capture_time_us: pts_us,
        ..Default::default()
    });
    msg
}

/// Runs on the encoder's thread: queues each unit, or drops it when the queue is full
/// and then drops everything up to the next key frame, which it asks for.
fn unit_sink(shared: Arc<Shared>, tx: mpsc::Sender<Unit>) -> OnUnit {
    Box::new(move |data, key, pts_us| {
        if !shared.sending.load(Ordering::Acquire)
            || (!key && shared.broken.load(Ordering::Acquire))
        {
            return;
        }
        let unit = Unit {
            msg: camera_frame(data, key, pts_us),
            at: Instant::now(),
            shared: shared.clone(),
        };
        // Counted before it's sent, so the io loop never takes it below zero.
        shared.queued.fetch_add(1, Ordering::AcqRel);
        if tx.try_send(unit).is_ok() {
            shared.broken.store(false, Ordering::Release);
        } else {
            shared.queued.fetch_sub(1, Ordering::AcqRel);
            shared.broken.store(true, Ordering::Release);
            shared.key_needed.store(true, Ordering::Release);
            shared.dropped.fetch_add(1, Ordering::Relaxed);
        }
    })
}

/// Runs on the microphone's thread: queues each frame once the host has accepted, or
/// drops it when the io loop is that far behind.
fn audio_sink(shared: Arc<Shared>, tx: mpsc::Sender<AudioUnit>) -> OnAudio {
    Box::new(move |data| {
        if !shared.sending.load(Ordering::Acquire) {
            return;
        }
        let mut msg = Message::new();
        msg.set_audio_frame(AudioFrame {
            data: data.into(),
            ..Default::default()
        });
        let unit = AudioUnit {
            msg,
            shared: shared.clone(),
        };
        if tx.try_send(unit).is_err() {
            shared.dropped.fetch_add(1, Ordering::Relaxed);
        }
    })
}

/// The `AudioFormat` a microphone forward sends before its frames ([`mic::SAMPLE_RATE`],
/// [`mic::CHANNELS`]), as a voice call does.
fn audio_format() -> Message {
    let mut misc = Misc::new();
    misc.set_audio_format(AudioFormat {
        sample_rate: mic::SAMPLE_RATE,
        channels: mic::CHANNELS as u32,
        ..Default::default()
    });
    let mut msg = Message::new();
    msg.set_misc(misc);
    msg
}

/// Runs on the device's thread if the camera or microphone goes away; the io loop takes
/// it from there.
fn lost_sink(shared: Arc<Shared>, kind: Kind) -> OnLost {
    Box::new(move |why| {
        log::warn!("The {} went away: {}", noun(kind), why);
        shared.lost.store(true, Ordering::Release);
        shared.wake.notify_one();
    })
}

impl DeviceForward {
    /// The session's forwarder, telling `ui` about every change.
    pub fn new<T: InvokeUiSession>(ui: Session<T>) -> Self {
        Self::with(
            Box::new(start_camera),
            Box::new(start_mic),
            ANSWER_TIMEOUT,
            Box::new(move |state| ui.on_device_forward(state)),
        )
    }

    fn with(start: Start, start_mic: StartMic, answer_timeout: Duration, notify: Notify) -> Self {
        let (tx, rx) = mpsc::channel(QUEUE);
        let (mic_tx, mic_rx) = mpsc::channel(MIC_QUEUE);
        Self {
            camera: Camera::Off,
            device: String::new(),
            reason: String::new(),
            notify,
            reported: String::new(),
            shared: Default::default(),
            tx,
            rx,
            start,
            answer_timeout,
            skipping: false,
            last_key_request: None,
            sent: 0,
            host_status: Default::default(),
            mic: Mic::Off,
            mic_device: String::new(),
            mic_reason: String::new(),
            mic_shared: Default::default(),
            mic_tx,
            mic_rx,
            start_mic,
            mic_sent: 0,
        }
    }

    /// What the Devices menu shows, as JSON: `{"camera": {"forward", "device", "reason",
    /// "host"}, "microphone": {…}}` ([`DeviceState`]).
    pub fn state(&self) -> String {
        let camera = DeviceState {
            forward: match self.camera {
                Camera::Off => "off",
                Camera::Asking { .. } => "asking",
                Camera::Sending { .. } => "on",
            },
            device: self.device.clone(),
            reason: self.reason.clone(),
            host: self
                .host_status
                .get(&Kind::CAMERA)
                .cloned()
                .unwrap_or_default(),
        };
        let microphone = DeviceState {
            forward: match self.mic {
                Mic::Off => "off",
                Mic::Asking { .. } => "asking",
                Mic::Sending { .. } => "on",
            },
            device: self.mic_device.clone(),
            reason: self.mic_reason.clone(),
            host: self
                .host_status
                .get(&Kind::MICROPHONE)
                .cloned()
                .unwrap_or_default(),
        };
        serde_json::json!({ "camera": camera, "microphone": microphone }).to_string()
    }

    /// Tells the UI if the state changed since it last heard.
    fn report(&mut self) {
        let state = self.state();
        if state != self.reported {
            (self.notify)(&state);
            self.reported = state;
        }
    }

    /// Turns a device on or off; returns the request to send to the host.
    pub fn switch(&mut self, switch: Switch) -> Option<Message> {
        let msg = match (switch.kind, switch.on) {
            (Kind::CAMERA, true) => self.camera_on(switch.device.as_deref()),
            (Kind::CAMERA, false) => {
                self.reason.clear();
                self.stop_camera()
                    .then(|| request(Kind::CAMERA, false, None))
            }
            (Kind::MICROPHONE, true) => self.mic_on(switch.device.as_deref()),
            (Kind::MICROPHONE, false) => {
                self.mic_reason.clear();
                self.stop_mic()
                    .then(|| request(Kind::MICROPHONE, false, None))
            }
        };
        self.report();
        msg
    }

    fn camera_on(&mut self, device: Option<&str>) -> Option<Message> {
        // A different camera replaces the running one.
        self.stop_camera();
        self.reason.clear();
        let shared = Arc::new(Shared::default());
        match (self.start)(
            device,
            unit_sink(shared.clone(), self.tx.clone()),
            lost_sink(shared.clone(), Kind::CAMERA),
        ) {
            Ok((source, format)) => {
                // Nothing to encode until the host accepts.
                source.set_skipping(true);
                self.skipping = true;
                self.shared = shared;
                self.device = device.unwrap_or_default().to_owned();
                self.camera = Camera::Asking {
                    source,
                    until: Instant::now() + self.answer_timeout,
                };
                Some(request(Kind::CAMERA, true, Some(&format)))
            }
            Err(err) => {
                log::warn!("Camera not started: {}", err);
                self.reason = "camera-failed".to_owned();
                None
            }
        }
    }

    /// Stops the camera; returns whether it was on.
    fn stop_camera(&mut self) -> bool {
        // Units the encoder flushes while stopping are dropped.
        self.shared.sending.store(false, Ordering::Release);
        let was_on = !matches!(self.camera, Camera::Off);
        self.camera = Camera::Off;
        self.device.clear();
        while self.rx.try_recv().is_ok() {}
        if was_on {
            log::info!(
                "Camera forward stopped: {} frames sent, {} dropped after encoding",
                self.sent,
                self.shared.dropped.load(Ordering::Relaxed)
            );
        }
        self.skipping = false;
        self.last_key_request = None;
        self.sent = 0;
        was_on
    }

    fn mic_on(&mut self, device: Option<&str>) -> Option<Message> {
        // Another microphone replaces the running one.
        self.stop_mic();
        self.mic_reason.clear();
        let shared = Arc::new(Shared::default());
        match (self.start_mic)(
            device,
            audio_sink(shared.clone(), self.mic_tx.clone()),
            lost_sink(shared.clone(), Kind::MICROPHONE),
        ) {
            Ok(capture) => {
                self.mic_shared = shared;
                self.mic_device = device.unwrap_or_default().to_owned();
                self.mic = Mic::Asking {
                    _capture: capture,
                    until: Instant::now() + self.answer_timeout,
                };
                let named = Format {
                    name: self.mic_device.clone(),
                    ..Default::default()
                };
                Some(request(Kind::MICROPHONE, true, Some(&named)))
            }
            Err(err) => {
                log::warn!("Microphone not started: {}", err);
                self.mic_reason = "microphone-failed".to_owned();
                None
            }
        }
    }

    /// Stops the microphone; returns whether it was on.
    fn stop_mic(&mut self) -> bool {
        self.mic_shared.sending.store(false, Ordering::Release);
        let was_on = !matches!(self.mic, Mic::Off);
        self.mic = Mic::Off;
        self.mic_device.clear();
        while self.mic_rx.try_recv().is_ok() {}
        if was_on {
            log::info!(
                "Microphone forward stopped: {} frames sent, {} dropped",
                self.mic_sent,
                self.mic_shared.dropped.load(Ordering::Relaxed)
            );
        }
        self.mic_sent = 0;
        was_on
    }

    fn stop(&mut self, kind: Kind) -> bool {
        match kind {
            Kind::CAMERA => self.stop_camera(),
            Kind::MICROPHONE => self.stop_mic(),
        }
    }

    fn reason_mut(&mut self, kind: Kind) -> &mut String {
        match kind {
            Kind::CAMERA => &mut self.reason,
            Kind::MICROPHONE => &mut self.mic_reason,
        }
    }

    /// The host's `DeviceForwardResponse`, `CameraControl` and `DeviceStatus`.
    pub fn on_message(&mut self, union: message::Union) {
        match union {
            message::Union::DeviceForwardResponse(response) => self.on_response(response),
            message::Union::CameraControl(control) => self.on_control(control),
            message::Union::DeviceStatus(status) => self.on_status(status),
            _ => {}
        }
        self.report();
    }

    fn on_response(&mut self, response: DeviceForwardResponse) {
        match response.kind.enum_value() {
            Ok(Kind::CAMERA) => self.on_camera_response(response),
            Ok(Kind::MICROPHONE) => self.on_mic_response(response),
            Err(_) => {}
        }
    }

    fn on_mic_response(&mut self, response: DeviceForwardResponse) {
        match std::mem::replace(&mut self.mic, Mic::Off) {
            Mic::Asking { _capture, .. } if response.accepted => {
                log::info!("The host accepted the microphone");
                // The format goes first; the queue is empty until frames are let in.
                let format = AudioUnit {
                    msg: audio_format(),
                    shared: self.mic_shared.clone(),
                };
                self.mic_tx.try_send(format).ok();
                self.mic_shared.sending.store(true, Ordering::Release);
                self.mic = Mic::Sending { _capture };
            }
            Mic::Off => {}
            // A repeated accept while sending.
            mic if response.accepted => self.mic = mic,
            mic => {
                log::info!("The host stopped the microphone: {}", response.reason);
                self.mic = mic;
                self.stop_mic();
                self.mic_reason = if response.reason.is_empty() {
                    "refused".to_owned()
                } else {
                    response.reason
                };
            }
        }
    }

    fn on_camera_response(&mut self, response: DeviceForwardResponse) {
        match std::mem::replace(&mut self.camera, Camera::Off) {
            Camera::Asking { source, .. } if response.accepted => {
                log::info!("The host accepted the camera");
                self.shared.sending.store(true, Ordering::Release);
                source.request_key_frame();
                source.set_skipping(false);
                self.skipping = false;
                self.camera = Camera::Sending { source };
            }
            Camera::Off => {}
            // A repeated accept while sending.
            camera if response.accepted => self.camera = camera,
            camera => {
                log::info!("The host stopped the camera: {}", response.reason);
                self.camera = camera;
                self.stop_camera();
                self.reason = if response.reason.is_empty() {
                    "refused".to_owned()
                } else {
                    response.reason
                };
            }
        }
    }

    fn on_control(&mut self, control: CameraControl) {
        let Camera::Sending { source } = &self.camera else {
            return;
        };
        if control.key_frame_request {
            let now = Instant::now();
            if self
                .last_key_request
                .map_or(true, |last| now.duration_since(last) >= KEY_FRAME_INTERVAL)
            {
                self.last_key_request = Some(now);
                source.request_key_frame();
            }
        }
        if control.target_bitrate_kbps > 0 {
            source.set_bitrate(
                control
                    .target_bitrate_kbps
                    .clamp(MIN_BITRATE_KBPS, MAX_BITRATE_KBPS),
            );
        }
    }

    fn on_status(&mut self, status: DeviceStatus) {
        if let Ok(kind) = status.kind.enum_value() {
            if self.host_status.get(&kind) != Some(&status.status) {
                log::info!("Host's {:?}: {}", kind, status.status);
                self.host_status.insert(kind, status.status);
            }
        }
    }

    /// The next camera frame or microphone message to send, the end of a wait for the
    /// host's answer, or a device going away. Pending while there is none. Cancel-safe,
    /// for the io loop's `select!`.
    pub async fn next(&mut self) -> Event {
        let until = match &self.camera {
            Camera::Asking { until, .. } => Some(*until),
            _ => None,
        };
        let on = !matches!(self.camera, Camera::Off);
        let shared = self.shared.clone();
        let mic_until = match &self.mic {
            Mic::Asking { until, .. } => Some(*until),
            _ => None,
        };
        let mic_on = !matches!(self.mic, Mic::Off);
        let mic_shared = self.mic_shared.clone();
        let deadline = |until: Option<Instant>| {
            tokio::time::Instant::from_std(until.unwrap_or_else(Instant::now))
        };
        // `self.tx` and `self.mic_tx` keep the channels open, so `recv` never returns `None`.
        tokio::select! {
            Some(unit) = self.rx.recv() => Event::Unit(unit),
            Some(unit) = self.mic_rx.recv() => Event::Audio(unit),
            _ = shared.lost(), if on => Event::Lost(Kind::CAMERA),
            _ = mic_shared.lost(), if mic_on => Event::Lost(Kind::MICROPHONE),
            _ = tokio::time::sleep_until(deadline(until)), if until.is_some() => {
                Event::NoAnswer(Kind::CAMERA)
            }
            _ = tokio::time::sleep_until(deadline(mic_until)), if mic_until.is_some() => {
                Event::NoAnswer(Kind::MICROPHONE)
            }
            else => std::future::pending().await,
        }
    }

    fn asking(&self, kind: Kind) -> bool {
        match kind {
            Kind::CAMERA => matches!(self.camera, Camera::Asking { .. }),
            Kind::MICROPHONE => matches!(self.mic, Mic::Asking { .. }),
        }
    }

    fn running(&self, kind: Kind) -> bool {
        match kind {
            Kind::CAMERA => !matches!(self.camera, Camera::Off),
            Kind::MICROPHONE => !matches!(self.mic, Mic::Off),
        }
    }

    /// What to send for an event from [`next`](Self::next), if anything.
    pub fn on_event(&mut self, event: Event) -> Option<Message> {
        match event {
            Event::NoAnswer(kind) => {
                if !self.asking(kind) {
                    return None;
                }
                log::warn!(
                    "No answer from the host about the {}; stopping it",
                    noun(kind)
                );
                self.stop(kind);
                *self.reason_mut(kind) = "no-answer".to_owned();
                self.report();
                Some(request(kind, false, None))
            }
            Event::Lost(kind) => {
                if !self.running(kind) {
                    return None;
                }
                // The host stops its sink now instead of waiting for frames that won't
                // come; the user switches the device on again, this one or another.
                log::warn!("{} lost; stopping the forward", noun(kind));
                self.stop(kind);
                *self.reason_mut(kind) = format!("{}-lost", noun(kind));
                self.report();
                Some(request(kind, false, None))
            }
            Event::Audio(unit) => {
                if !matches!(self.mic, Mic::Sending { .. })
                    || !Arc::ptr_eq(&unit.shared, &self.mic_shared)
                {
                    return None;
                }
                self.mic_sent += 1;
                Some(unit.msg)
            }
            Event::Unit(unit) => {
                let left = unit
                    .shared
                    .queued
                    .fetch_sub(1, Ordering::AcqRel)
                    .saturating_sub(1);
                let Camera::Sending { source } = &self.camera else {
                    return None;
                };
                if !Arc::ptr_eq(&unit.shared, &self.shared) {
                    return None;
                }
                if self.shared.key_needed.swap(false, Ordering::AcqRel) {
                    source.request_key_frame();
                }
                // Skip camera frames while units wait too long, until the queue drains.
                let backlog = left > 0 && unit.at.elapsed() > BACKLOG;
                if backlog != self.skipping {
                    source.set_skipping(backlog);
                    self.skipping = backlog;
                }
                self.sent += 1;
                Some(unit.msg)
            }
        }
    }
}

/// The Devices menu's FFI calls (`flutter_ffi.rs`, decision 0018).
#[cfg(any(target_os = "android", target_os = "ios", feature = "flutter", test))]
pub mod ui {
    use super::*;

    fn kind(name: &str) -> Option<Kind> {
        match name {
            "camera" => Some(Kind::CAMERA),
            "microphone" => Some(Kind::MICROPHONE),
            _ => None,
        }
    }

    /// The menu's switch: `kind` is "camera" or "microphone", `device` a unique ID or ""
    /// for the default one.
    pub fn switch(kind: &str, on: bool, device: &str) -> Option<Switch> {
        Some(Switch {
            kind: self::kind(kind)?,
            on,
            device: (!device.is_empty()).then(|| device.to_owned()),
        })
    }

    /// The cameras the menu offers, as JSON `[{"id", "name"}]`: none but a Mac's.
    pub fn cameras() -> String {
        #[cfg(target_os = "macos")]
        let cameras: Vec<_> = crate::platform::macos_camera_capture::list()
            .into_iter()
            .map(|c| serde_json::json!({ "id": c.id, "name": c.name }))
            .collect();
        #[cfg(not(target_os = "macos"))]
        let cameras: Vec<serde_json::Value> = vec![];
        serde_json::Value::from(cameras).to_string()
    }

    /// The controller's own access to `kind`: "allowed", "denied", "restricted",
    /// "not-determined", or "unsupported" anywhere but a Mac.
    pub fn permission(kind: &str) -> String {
        #[cfg(target_os = "macos")]
        if let Some(kind) = self::kind(kind) {
            use crate::platform::macos_camera_capture::Access;
            let access = match kind {
                Kind::CAMERA => crate::platform::macos_camera_capture::access(),
                Kind::MICROPHONE => crate::platform::macos_mic_capture::access(),
            };
            return match access {
                Access::Allowed => "allowed",
                Access::Denied => "denied",
                Access::Restricted => "restricted",
                Access::NotDetermined => "not-determined",
            }
            .to_owned();
        }
        let _ = kind;
        "unsupported".to_owned()
    }

    /// Shows macOS's prompt for `kind` if the user hasn't answered it yet, and waits for
    /// the answer; true when access is allowed.
    pub fn request_permission(kind: &str) -> bool {
        #[cfg(target_os = "macos")]
        if let Some(kind) = self::kind(kind) {
            let (tx, rx) = std::sync::mpsc::channel();
            let done = move |granted| {
                tx.send(granted).ok();
            };
            match kind {
                Kind::CAMERA => crate::platform::macos_camera_capture::request_access(done),
                Kind::MICROPHONE => crate::platform::macos_mic_capture::request_access(done),
            }
            return rx.recv().unwrap_or(false);
        }
        let _ = kind;
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// A camera that sends what the test tells it to and records what it's asked.
    #[derive(Default)]
    struct Fake {
        on_unit: Mutex<Option<OnUnit>>,
        on_lost: Mutex<Option<OnLost>>,
        running: AtomicBool,
        skipping: AtomicBool,
        key_frames: AtomicUsize,
        bitrates: Mutex<Vec<i32>>,
        /// What the UI heard.
        states: Mutex<Vec<serde_json::Value>>,
        on_audio: Mutex<Option<OnAudio>>,
        mic_on_lost: Mutex<Option<OnLost>>,
        mic_running: AtomicBool,
        /// The microphone asked for.
        mic_device: Mutex<Option<String>>,
    }

    struct FakeSource(Arc<Fake>);

    struct FakeMic(Arc<Fake>);

    impl Drop for FakeMic {
        fn drop(&mut self) {
            self.0.mic_running.store(false, Ordering::SeqCst);
        }
    }

    impl Source for FakeSource {
        fn request_key_frame(&self) {
            self.0.key_frames.fetch_add(1, Ordering::SeqCst);
        }
        fn set_bitrate(&self, kbps: i32) {
            self.0.bitrates.lock().unwrap().push(kbps);
        }
        fn set_skipping(&self, skip: bool) {
            self.0.skipping.store(skip, Ordering::SeqCst);
        }
    }

    impl Drop for FakeSource {
        fn drop(&mut self) {
            self.0.running.store(false, Ordering::SeqCst);
        }
    }

    impl Fake {
        fn emit(&self, key: bool, pts_us: i64) {
            let nal = if key { 0x65 } else { 0x41 };
            if let Some(on_unit) = self.on_unit.lock().unwrap().as_mut() {
                on_unit(&[0, 0, 0, 1, nal, 0x88], key, pts_us);
            }
        }
        /// The running camera goes away.
        fn lose(&self, why: &str) {
            if let Some(on_lost) = self.on_lost.lock().unwrap().take() {
                on_lost(why);
            }
        }
        fn running(&self) -> bool {
            self.running.load(Ordering::SeqCst)
        }
        fn skipping(&self) -> bool {
            self.skipping.load(Ordering::SeqCst)
        }
        fn key_frames(&self) -> usize {
            self.key_frames.load(Ordering::SeqCst)
        }
        /// The camera states the UI heard since the last call, as (forward, reason, host).
        fn heard(&self) -> Vec<(String, String, String)> {
            self.heard_of("camera")
        }
        /// The same for the microphone.
        fn heard_mic(&self) -> Vec<(String, String, String)> {
            self.heard_of("microphone")
        }
        fn heard_of(&self, device: &str) -> Vec<(String, String, String)> {
            let field = |v: &serde_json::Value, k: &str| v[device][k].as_str().unwrap().to_owned();
            self.states
                .lock()
                .unwrap()
                .drain(..)
                .map(|v| (field(&v, "forward"), field(&v, "reason"), field(&v, "host")))
                .collect()
        }
        /// The microphone sends one encoded frame.
        fn speak(&self, first: u8) {
            if let Some(on_audio) = self.on_audio.lock().unwrap().as_mut() {
                on_audio(vec![first, 1, 2]);
            }
        }
        fn lose_mic(&self, why: &str) {
            if let Some(on_lost) = self.mic_on_lost.lock().unwrap().take() {
                on_lost(why);
            }
        }
        fn mic_running(&self) -> bool {
            self.mic_running.load(Ordering::SeqCst)
        }
    }

    fn fake_mic(fake: &Arc<Fake>) -> StartMic {
        let mic = fake.clone();
        Box::new(move |device, on_audio, on_lost| {
            *mic.on_audio.lock().unwrap() = Some(on_audio);
            *mic.mic_on_lost.lock().unwrap() = Some(on_lost);
            *mic.mic_device.lock().unwrap() = device.map(str::to_owned);
            mic.mic_running.store(true, Ordering::SeqCst);
            Ok(Box::new(FakeMic(mic.clone())) as Box<dyn Send>)
        })
    }

    fn forward(answer_timeout: Duration) -> (DeviceForward, Arc<Fake>) {
        let fake = Arc::new(Fake::default());
        let camera = fake.clone();
        let start: Start = Box::new(move |_, on_unit, on_lost| {
            *camera.on_unit.lock().unwrap() = Some(on_unit);
            *camera.on_lost.lock().unwrap() = Some(on_lost);
            camera.running.store(true, Ordering::SeqCst);
            let format = Format {
                width: 1280,
                height: 720,
                fps: 30,
                name: "Test Camera".into(),
            };
            Ok((
                Box::new(FakeSource(camera.clone())) as Box<dyn Source>,
                format,
            ))
        });
        let ui = fake.clone();
        let notify: Notify = Box::new(move |state| {
            ui.states
                .lock()
                .unwrap()
                .push(serde_json::from_str(state).unwrap());
        });
        let start_mic = fake_mic(&fake);
        (
            DeviceForward::with(start, start_mic, answer_timeout, notify),
            fake,
        )
    }

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap()
    }

    /// The next message to send, if an event comes within `wait`.
    fn next(rt: &tokio::runtime::Runtime, fwd: &mut DeviceForward, wait: u64) -> Option<Message> {
        let event = rt.block_on(async {
            tokio::time::timeout(Duration::from_millis(wait), fwd.next())
                .await
                .ok()
        })?;
        fwd.on_event(event)
    }

    fn camera(on: bool) -> Switch {
        Switch {
            kind: Kind::CAMERA,
            on,
            device: None,
        }
    }

    fn response(kind: Kind, accepted: bool, reason: &str) -> message::Union {
        message::Union::DeviceForwardResponse(DeviceForwardResponse {
            kind: kind.into(),
            accepted,
            reason: reason.into(),
            ..Default::default()
        })
    }

    fn control(key_frame_request: bool, target_bitrate_kbps: i32) -> message::Union {
        message::Union::CameraControl(CameraControl {
            key_frame_request,
            target_bitrate_kbps,
            ..Default::default()
        })
    }

    fn pts(msg: &Message) -> i64 {
        msg.camera_frame().capture_time_us
    }

    #[test]
    fn asks_first_and_sends_only_once_accepted() {
        let rt = runtime();
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        let ask = fwd.switch(camera(true)).unwrap();
        let request = ask.device_forward_request();
        assert_eq!(request.kind.enum_value(), Ok(Kind::CAMERA));
        assert!(request.on);
        assert_eq!(
            (request.width, request.height, request.fps),
            (1280, 720, 30)
        );
        assert_eq!(request.device_name, "Test Camera");
        assert!(fake.running() && fake.skipping());

        fake.emit(true, 1_000);
        assert!(
            next(&rt, &mut fwd, 50).is_none(),
            "sent before the host accepted"
        );

        fwd.on_message(response(Kind::CAMERA, true, ""));
        assert!(!fake.skipping());
        assert_eq!(fake.key_frames(), 1, "starts with a key frame");
        fake.emit(true, 33_000);
        let msg = next(&rt, &mut fwd, 50).unwrap();
        let frame = msg.camera_frame();
        assert_eq!(frame.capture_time_us, 33_000);
        let units = &frame.frame.h264s().frames;
        assert_eq!(units.len(), 1);
        assert!(units[0].key);
        assert_eq!(units[0].pts, 33);
        assert_eq!(&units[0].data[..], &[0, 0, 0, 1, 0x65, 0x88]);
    }

    #[test]
    fn a_refusal_stops_the_camera() {
        let rt = runtime();
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(camera(true)).unwrap();
        fwd.on_message(response(Kind::CAMERA, false, "busy"));
        assert!(!fake.running());
        // A late accept doesn't bring it back.
        fwd.on_message(response(Kind::CAMERA, true, ""));
        fake.emit(true, 1_000);
        assert!(next(&rt, &mut fwd, 50).is_none());
    }

    #[test]
    fn the_host_can_stop_a_running_camera() {
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(camera(true)).unwrap();
        fwd.on_message(response(Kind::CAMERA, true, ""));
        fwd.on_message(response(Kind::CAMERA, false, "not-allowed"));
        assert!(!fake.running());
    }

    #[test]
    fn switching_off_tells_the_host() {
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(camera(true)).unwrap();
        fwd.on_message(response(Kind::CAMERA, true, ""));
        let off = fwd.switch(camera(false)).unwrap();
        assert!(!off.device_forward_request().on);
        assert!(!fake.running());
        assert!(fwd.switch(camera(false)).is_none(), "already off");
    }

    #[test]
    fn no_answer_gives_up() {
        let rt = runtime();
        let (mut fwd, fake) = forward(Duration::from_millis(30));
        fwd.switch(camera(true)).unwrap();
        let off = next(&rt, &mut fwd, 1_000).unwrap();
        assert!(!off.device_forward_request().on);
        assert!(!fake.running());
    }

    #[test]
    fn key_frames_and_bitrate_follow_the_host_within_limits() {
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(camera(true)).unwrap();
        fwd.on_message(control(true, 800));
        assert_eq!(fake.key_frames(), 0, "ignored before the host accepts");
        fwd.on_message(response(Kind::CAMERA, true, ""));
        fwd.on_message(control(true, 800));
        fwd.on_message(control(true, 0));
        assert_eq!(fake.key_frames(), 2, "the start's, then one per 500 ms");
        fwd.on_message(control(false, 9_000));
        fwd.on_message(control(false, 10));
        assert_eq!(*fake.bitrates.lock().unwrap(), [800, 2_000, 100]);
    }

    #[test]
    fn a_full_queue_drops_until_the_next_key_frame() {
        let rt = runtime();
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(camera(true)).unwrap();
        fwd.on_message(response(Kind::CAMERA, true, ""));
        fake.emit(true, 1_000);
        fake.emit(false, 2_000);
        fake.emit(false, 3_000);
        // The queue holds three; these two are dropped.
        fake.emit(false, 4_000);
        fake.emit(false, 5_000);
        assert_eq!(pts(&next(&rt, &mut fwd, 50).unwrap()), 1_000);
        assert_eq!(fake.key_frames(), 2, "asked for a key frame");
        // Room again, but a P frame can't follow the gap.
        fake.emit(false, 6_000);
        fake.emit(true, 7_000);
        let sent: Vec<i64> = std::iter::from_fn(|| next(&rt, &mut fwd, 50))
            .map(|msg| pts(&msg))
            .collect();
        assert_eq!(sent, [2_000, 3_000, 7_000]);
    }

    #[test]
    fn units_that_wait_turn_skipping_on_until_the_queue_drains() {
        let rt = runtime();
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(camera(true)).unwrap();
        fwd.on_message(response(Kind::CAMERA, true, ""));
        fake.emit(true, 1_000);
        fake.emit(false, 2_000);
        std::thread::sleep(BACKLOG + Duration::from_millis(50));
        next(&rt, &mut fwd, 50).unwrap();
        assert!(
            fake.skipping(),
            "a unit waited over 150 ms with another behind it"
        );
        next(&rt, &mut fwd, 50).unwrap();
        assert!(!fake.skipping(), "drained");
    }

    #[test]
    fn other_devices_and_kinds_are_left_alone() {
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(microphone(true)).unwrap();
        assert!(!fake.running(), "the microphone doesn't start the camera");
        fwd.switch(camera(true)).unwrap();
        fwd.on_message(response(Kind::MICROPHONE, false, "busy"));
        assert!(
            fake.running(),
            "a microphone answer doesn't stop the camera"
        );
        assert!(!fake.mic_running());
        fwd.switch(microphone(true)).unwrap();
        fwd.on_message(response(Kind::CAMERA, false, "busy"));
        assert!(
            fake.mic_running(),
            "a camera answer doesn't stop the microphone"
        );
        fwd.on_message(message::Union::DeviceStatus(DeviceStatus {
            kind: Kind::CAMERA.into(),
            status: "not-approved".into(),
            ..Default::default()
        }));
        assert_eq!(
            fwd.host_status.get(&Kind::CAMERA).map(String::as_str),
            Some("not-approved")
        );
    }

    #[test]
    fn ending_the_session_stops_the_camera() {
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(camera(true)).unwrap();
        fwd.on_message(response(Kind::CAMERA, true, ""));
        drop(fwd);
        assert!(!fake.running());
    }

    fn status(kind: Kind, status: &str) -> message::Union {
        message::Union::DeviceStatus(DeviceStatus {
            kind: kind.into(),
            status: status.into(),
            ..Default::default()
        })
    }

    fn heard(forward: &str, reason: &str, host: &str) -> (String, String, String) {
        (forward.into(), reason.into(), host.into())
    }

    #[test]
    fn the_menu_hears_each_change_once() {
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(camera(true)).unwrap();
        fwd.on_message(response(Kind::CAMERA, true, ""));
        // A repeated accept and the host's controls change nothing the menu shows.
        fwd.on_message(response(Kind::CAMERA, true, ""));
        fwd.on_message(control(true, 500));
        fwd.on_message(status(Kind::CAMERA, "not-allowed"));
        fwd.on_message(response(Kind::CAMERA, false, "not-allowed"));
        // Switching off clears the reason.
        fwd.switch(camera(false));
        assert_eq!(
            fake.heard(),
            vec![
                heard("asking", "", ""),
                heard("on", "", ""),
                heard("on", "", "not-allowed"),
                heard("off", "not-allowed", "not-allowed"),
                heard("off", "", "not-allowed"),
            ]
        );
    }

    #[test]
    fn the_menu_hears_why_the_camera_stopped() {
        let rt = runtime();
        let (mut fwd, fake) = forward(Duration::from_millis(20));
        fwd.switch(camera(true)).unwrap();
        assert!(next(&rt, &mut fwd, 200).is_some());
        assert_eq!(fake.heard().pop(), Some(heard("off", "no-answer", "")));
        fwd.switch(camera(true)).unwrap();
        fwd.on_message(response(Kind::CAMERA, false, ""));
        assert_eq!(fake.heard().pop(), Some(heard("off", "refused", "")));

        let states = Arc::new(Mutex::new(Vec::<String>::new()));
        let ui = states.clone();
        let start: Start = Box::new(|_, _, _| Err(hbb_common::anyhow::anyhow!("no camera")));
        let mut fwd = DeviceForward::with(
            start,
            fake_mic(&fake),
            ANSWER_TIMEOUT,
            Box::new(move |state| ui.lock().unwrap().push(state.to_owned())),
        );
        assert!(fwd.switch(camera(true)).is_none());
        assert!(states.lock().unwrap()[0].contains(r#""reason":"camera-failed""#));
    }

    #[test]
    fn a_lost_camera_stops_and_tells_the_host() {
        let rt = runtime();
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(camera(true)).unwrap();
        fwd.on_message(response(Kind::CAMERA, true, ""));
        fake.emit(true, 1_000);
        assert_eq!(pts(&next(&rt, &mut fwd, 50).unwrap()), 1_000);
        fake.heard();
        fake.lose("disconnected");
        let off = next(&rt, &mut fwd, 50).expect("the io loop wasn't told");
        let off = off.device_forward_request();
        assert_eq!((off.kind.enum_value(), off.on), (Ok(Kind::CAMERA), false));
        assert!(!fake.running());
        assert_eq!(fake.heard(), vec![heard("off", "camera-lost", "")]);
        // A late answer from the host doesn't bring it back.
        fwd.on_message(response(Kind::CAMERA, true, ""));
        assert!(next(&rt, &mut fwd, 50).is_none());
        // Switching on again starts afresh.
        fwd.switch(camera(true)).unwrap();
        assert!(fake.running());
        assert_eq!(fake.heard(), vec![heard("asking", "", "")]);
    }

    #[test]
    fn a_camera_lost_while_asking_withdraws_the_request() {
        let rt = runtime();
        let (mut fwd, fake) = forward(Duration::from_millis(100));
        fwd.switch(camera(true)).unwrap();
        // Before the io loop waits: the flag keeps it.
        fake.lose("disconnected");
        let off = next(&rt, &mut fwd, 50).expect("the io loop wasn't told");
        assert!(!off.device_forward_request().on);
        assert!(!fake.running());
        assert!(
            next(&rt, &mut fwd, 300).is_none(),
            "the wait for the host's answer ended with it"
        );
        assert_eq!(fake.heard().pop(), Some(heard("off", "camera-lost", "")));
    }

    #[test]
    fn only_the_running_camera_can_be_lost() {
        let rt = runtime();
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(camera(true)).unwrap();
        let first = fake.on_lost.lock().unwrap().take().unwrap();
        // Another camera replaces the first, then the first goes away.
        fwd.switch(camera(true)).unwrap();
        fwd.on_message(response(Kind::CAMERA, true, ""));
        first("disconnected");
        assert!(next(&rt, &mut fwd, 100).is_none());
        assert!(fake.running());
        // Switched off, then gone: nothing to tell.
        fwd.switch(camera(false)).unwrap();
        fake.lose("disconnected");
        assert!(next(&rt, &mut fwd, 50).is_none());
        assert_eq!(fake.heard().pop(), Some(heard("off", "", "")));
    }

    #[test]
    fn the_menu_sees_which_camera_is_on() {
        let (mut fwd, _fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(Switch {
            device: Some("cam-1".into()),
            ..camera(true)
        })
        .unwrap();
        assert!(fwd.state().contains(r#""device":"cam-1""#));
        fwd.switch(camera(false));
        assert!(fwd.state().contains(r#""device":"""#));
    }

    #[test]
    fn a_new_connection_starts_afresh() {
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(camera(true)).unwrap();
        fwd.on_message(response(Kind::CAMERA, true, ""));
        fwd.on_message(status(Kind::CAMERA, "ready"));
        fake.heard();
        drop(fwd);
        assert_eq!(fake.heard(), vec![heard("off", "", "")]);
    }

    #[test]
    fn the_menus_names_for_devices() {
        let on = ui::switch("camera", true, "").unwrap();
        assert_eq!((on.kind, on.on, on.device), (Kind::CAMERA, true, None));
        let mic = ui::switch("microphone", false, "mic-2").unwrap();
        assert_eq!(
            (mic.kind, mic.device.as_deref()),
            (Kind::MICROPHONE, Some("mic-2"))
        );
        assert!(ui::switch("speaker", true, "").is_none());
        assert_eq!(ui::permission("speaker"), "unsupported");
        assert!(!ui::request_permission("speaker"));
        #[cfg(target_os = "macos")]
        assert!(
            ["allowed", "denied", "restricted", "not-determined"]
                .contains(&ui::permission("microphone").as_str()),
            "{}",
            ui::permission("microphone")
        );
    }

    fn microphone(on: bool) -> Switch {
        Switch {
            kind: Kind::MICROPHONE,
            on,
            device: None,
        }
    }

    /// The first byte of a microphone frame, or None for anything else.
    fn spoken(msg: &Message) -> Option<u8> {
        msg.has_audio_frame().then(|| msg.audio_frame().data[0])
    }

    #[test]
    fn the_microphone_asks_first_then_sends_its_format_and_frames() {
        let rt = runtime();
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        let ask = fwd
            .switch(Switch {
                device: Some("USB Mic".into()),
                ..microphone(true)
            })
            .expect("a request");
        let ask = ask.device_forward_request();
        assert_eq!(
            (ask.kind.enum_value(), ask.on),
            (Ok(Kind::MICROPHONE), true)
        );
        assert_eq!(ask.device_name, "USB Mic");
        assert_eq!(fake.mic_device.lock().unwrap().as_deref(), Some("USB Mic"));
        fake.speak(1);
        assert!(
            next(&rt, &mut fwd, 50).is_none(),
            "nothing before the answer"
        );
        fwd.on_message(response(Kind::MICROPHONE, true, ""));
        fake.speak(2);
        fake.speak(3);
        let format = next(&rt, &mut fwd, 50).expect("the format");
        let format = format.misc().audio_format();
        assert_eq!((format.sample_rate, format.channels), (48000, 1));
        assert_eq!(spoken(&next(&rt, &mut fwd, 50).unwrap()), Some(2));
        assert_eq!(spoken(&next(&rt, &mut fwd, 50).unwrap()), Some(3));
        assert_eq!(
            fake.heard_mic(),
            vec![heard("asking", "", ""), heard("on", "", "")]
        );
        assert!(fwd.state().contains(r#""device":"USB Mic""#));
    }

    #[test]
    fn a_refusal_stops_the_microphone() {
        let rt = runtime();
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(microphone(true)).unwrap();
        fwd.on_message(response(Kind::MICROPHONE, false, "busy"));
        assert!(!fake.mic_running());
        fake.speak(1);
        assert!(next(&rt, &mut fwd, 50).is_none());
        assert_eq!(fake.heard_mic().pop(), Some(heard("off", "busy", "")));
        // The host can also stop it once it runs.
        fwd.switch(microphone(true)).unwrap();
        fwd.on_message(response(Kind::MICROPHONE, true, ""));
        fwd.on_message(response(Kind::MICROPHONE, false, "not-allowed"));
        assert!(!fake.mic_running());
        assert_eq!(
            fake.heard_mic().pop(),
            Some(heard("off", "not-allowed", ""))
        );
    }

    #[test]
    fn no_answer_gives_up_on_the_microphone() {
        let rt = runtime();
        let (mut fwd, fake) = forward(Duration::from_millis(20));
        fwd.switch(microphone(true)).unwrap();
        let off = next(&rt, &mut fwd, 200).expect("a withdrawal");
        let off = off.device_forward_request();
        assert_eq!(
            (off.kind.enum_value(), off.on),
            (Ok(Kind::MICROPHONE), false)
        );
        assert!(!fake.mic_running());
        assert_eq!(fake.heard_mic().pop(), Some(heard("off", "no-answer", "")));
    }

    #[test]
    fn switching_the_microphone_off_tells_the_host() {
        let rt = runtime();
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(microphone(true)).unwrap();
        fwd.on_message(response(Kind::MICROPHONE, true, ""));
        fake.speak(1);
        let off = fwd.switch(microphone(false)).expect("tells the host");
        assert!(!off.device_forward_request().on);
        assert!(!fake.mic_running());
        assert!(next(&rt, &mut fwd, 50).is_none(), "queued audio is dropped");
        assert!(fwd.switch(microphone(false)).is_none(), "already off");
    }

    #[test]
    fn a_lost_microphone_stops_and_tells_the_host() {
        let rt = runtime();
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(microphone(true)).unwrap();
        fwd.on_message(response(Kind::MICROPHONE, true, ""));
        next(&rt, &mut fwd, 50).expect("the format");
        fake.heard_mic();
        fake.lose_mic("disconnected");
        let off = next(&rt, &mut fwd, 50).expect("the io loop wasn't told");
        let off = off.device_forward_request();
        assert_eq!(
            (off.kind.enum_value(), off.on),
            (Ok(Kind::MICROPHONE), false)
        );
        assert!(!fake.mic_running());
        assert_eq!(fake.heard_mic(), vec![heard("off", "microphone-lost", "")]);
    }

    #[test]
    fn a_microphone_that_doesnt_start_says_so() {
        let fake = Arc::new(Fake::default());
        let ui = fake.clone();
        let start: Start = Box::new(|_, _, _| Err(hbb_common::anyhow::anyhow!("unused")));
        let start_mic: StartMic = Box::new(|_, _, _| Err(hbb_common::anyhow::anyhow!("no access")));
        let mut fwd = DeviceForward::with(
            start,
            start_mic,
            ANSWER_TIMEOUT,
            Box::new(move |state| {
                ui.states
                    .lock()
                    .unwrap()
                    .push(serde_json::from_str(state).unwrap())
            }),
        );
        assert!(
            fwd.switch(microphone(true)).is_none(),
            "the host isn't asked"
        );
        assert_eq!(
            fake.heard_mic(),
            vec![heard("off", "microphone-failed", "")]
        );
    }

    #[test]
    fn a_full_microphone_queue_drops_the_newest() {
        let rt = runtime();
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(microphone(true)).unwrap();
        fwd.on_message(response(Kind::MICROPHONE, true, ""));
        // The format holds one place.
        for n in 0..MIC_QUEUE as u8 + 5 {
            fake.speak(n);
        }
        assert!(
            next(&rt, &mut fwd, 50).unwrap().has_misc(),
            "the format first"
        );
        let mut got = Vec::new();
        while let Some(msg) = next(&rt, &mut fwd, 20) {
            got.push(spoken(&msg).unwrap());
        }
        assert_eq!(got, (0..MIC_QUEUE as u8 - 1).collect::<Vec<_>>());
        assert_eq!(fwd.mic_shared.dropped.load(Ordering::Relaxed), 6);
    }

    #[test]
    fn only_the_running_microphone_is_heard() {
        let rt = runtime();
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(microphone(true)).unwrap();
        let first = fake.on_audio.lock().unwrap().take().unwrap();
        let first_lost = fake.mic_on_lost.lock().unwrap().take().unwrap();
        // Another microphone replaces the first, then the first speaks and goes away.
        fwd.switch(microphone(true)).unwrap();
        fwd.on_message(response(Kind::MICROPHONE, true, ""));
        let mut first = first;
        first(vec![9]);
        first_lost("disconnected");
        assert!(next(&rt, &mut fwd, 50).unwrap().has_misc());
        assert!(next(&rt, &mut fwd, 50).is_none());
        assert!(fake.mic_running());
    }

    #[test]
    fn ending_the_session_stops_the_microphone() {
        let (mut fwd, fake) = forward(ANSWER_TIMEOUT);
        fwd.switch(microphone(true)).unwrap();
        fwd.on_message(response(Kind::MICROPHONE, true, ""));
        drop(fwd);
        assert!(!fake.mic_running());
        assert_eq!(fake.heard_mic().pop(), Some(heard("off", "", "")));
    }
}

/// The real camera through the forward. Needs a camera and macOS's camera prompt, so
/// it's ignored by default; docs/tests/camera-capture/ runs it from its app bundle.
#[cfg(all(test, target_os = "macos"))]
mod capture {
    use super::*;

    #[test]
    #[ignore]
    fn the_menu_lists_the_macs_cameras() {
        let cameras: Vec<serde_json::Value> = serde_json::from_str(&ui::cameras()).unwrap();
        assert!(!cameras.is_empty(), "no camera");
        for camera in &cameras {
            assert!(!camera["id"].as_str().unwrap().is_empty());
            assert_ne!(camera["name"], "Remote Display Camera");
        }
    }

    fn next(
        rt: &tokio::runtime::Runtime,
        fwd: &mut DeviceForward,
        wait: Duration,
    ) -> Option<Message> {
        let event = rt.block_on(async { tokio::time::timeout(wait, fwd.next()).await.ok() })?;
        fwd.on_event(event)
    }

    fn collect(
        rt: &tokio::runtime::Runtime,
        fwd: &mut DeviceForward,
        wait: Duration,
    ) -> Vec<Message> {
        let until = Instant::now() + wait;
        let mut sent = Vec::new();
        while let Some(left) = until.checked_duration_since(Instant::now()) {
            match next(rt, fwd, left) {
                Some(msg) => sent.push(msg),
                None => break,
            }
        }
        sent
    }

    fn answer(accepted: bool, reason: &str) -> message::Union {
        message::Union::DeviceForwardResponse(DeviceForwardResponse {
            kind: Kind::CAMERA.into(),
            accepted,
            reason: reason.into(),
            ..Default::default()
        })
    }

    #[test]
    #[ignore]
    fn forwards_the_camera() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        let mut fwd = DeviceForward::with(
            Box::new(start_camera),
            Box::new(start_mic),
            ANSWER_TIMEOUT,
            Box::new(|_| {}),
        );
        let ask = fwd
            .switch(Switch {
                kind: Kind::CAMERA,
                on: true,
                device: None,
            })
            .expect("camera started (is camera access allowed? make ask)");
        let request = ask.device_forward_request();
        println!(
            "request: {}x{} {} fps, {:?}",
            request.width, request.height, request.fps, request.device_name
        );
        assert!(request.on && request.width == 1280 && request.height == 720);
        assert!(!request.device_name.is_empty());

        assert!(
            collect(&rt, &mut fwd, Duration::from_secs(1)).is_empty(),
            "frames before the host accepted"
        );
        fwd.on_message(answer(true, ""));
        let sent = collect(&rt, &mut fwd, Duration::from_secs(3));
        fwd.on_message(message::Union::CameraControl(CameraControl {
            key_frame_request: true,
            target_bitrate_kbps: 800,
            ..Default::default()
        }));
        let asked = collect(&rt, &mut fwd, Duration::from_millis(500));
        fwd.on_message(answer(false, "not-allowed"));
        let after = collect(&rt, &mut fwd, Duration::from_secs(1));

        let frames: Vec<&CameraFrame> = sent.iter().map(|m| m.camera_frame()).collect();
        let keys = frames
            .iter()
            .filter(|f| f.frame.h264s().frames[0].key)
            .count();
        println!(
            "{} CameraFrames in 3 s, {} key frames, {} after the key frame request, {} after the host stopped it",
            frames.len(),
            keys,
            asked.len(),
            after.len()
        );
        assert!(frames.len() >= 30, "under 10 fps: {}", frames.len());
        assert!(
            frames[0].frame.h264s().frames[0].key,
            "starts with a key frame"
        );
        for frame in &frames {
            let units = &frame.frame.h264s().frames;
            assert_eq!(units.len(), 1);
            assert!(units[0].data.starts_with(&[0, 0, 0, 1]));
            assert_eq!(units[0].pts, frame.capture_time_us / 1000);
        }
        assert!(frames
            .windows(2)
            .all(|w| w[0].capture_time_us < w[1].capture_time_us));
        assert!(asked
            .iter()
            .take(3)
            .any(|m| m.camera_frame().frame.h264s().frames[0].key));
        assert!(after.is_empty(), "frames after the host stopped the camera");
    }

    /// Unplug the camera within a minute of the start (`make unplug`).
    #[test]
    #[ignore]
    fn tells_the_host_when_the_camera_is_unplugged() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        let states = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let ui = states.clone();
        let mut fwd = DeviceForward::with(
            Box::new(start_camera),
            Box::new(start_mic),
            ANSWER_TIMEOUT,
            Box::new(move |state| ui.lock().unwrap().push(state.to_owned())),
        );
        let ask = fwd
            .switch(Switch {
                kind: Kind::CAMERA,
                on: true,
                device: None,
            })
            .expect("camera started (is camera access allowed? make ask)");
        println!(
            "{}: unplug it now",
            ask.device_forward_request().device_name
        );
        fwd.on_message(answer(true, ""));
        let until = Instant::now() + Duration::from_secs(60);
        let mut frames = 0;
        let off = loop {
            let left = until
                .checked_duration_since(Instant::now())
                .expect("not told within a minute");
            match next(&rt, &mut fwd, left) {
                Some(msg) if msg.has_camera_frame() => frames += 1,
                Some(msg) => break msg,
                None => panic!("not told within a minute"),
            }
        };
        let after = collect(&rt, &mut fwd, Duration::from_secs(1));
        println!(
            "{} CameraFrames, then {:?}, {} after; the menu heard {:?}",
            frames,
            off,
            after.len(),
            states.lock().unwrap().last()
        );
        assert!(frames >= 10, "the camera was unplugged before it sent");
        assert!(off.has_device_forward_request() && !off.device_forward_request().on);
        assert!(after.is_empty(), "frames after the camera went away");
        assert!(states
            .lock()
            .unwrap()
            .last()
            .unwrap()
            .contains(r#""reason":"camera-lost""#));
    }
}
