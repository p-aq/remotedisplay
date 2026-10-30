// remotedisplay: camera and microphone forwarding on the host (camera & audio
// forwarding spec, Host side › Accepting requests).
//
// The owner's switch (decision 0009): off by default, and only the host owner turns it
// on, from the server app, which runs `remotedisplayd --set-device-forward on|off`.
//
// [`Forwards`] is each connection's side of forwarding (`connection.rs`, `HOOKS.md` E7):
// it advertises what this host can receive, answers `DeviceForwardRequest`, lets one
// controller at a time send a device, passes that controller's `CameraFrame`s to the
// camera sink, and stops a forward when the owner switches forwarding off or the sink
// goes away. Dropping it, with the connection, ends its forwards.

use hbb_common::{
    config::Config,
    log,
    message_proto::{
        device_forward_request::Kind, message, CameraControl, CameraFrame, DeviceForwardRequest,
        DeviceForwardResponse, DeviceStatus, Message,
    },
    ResultType,
};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

/// The engine option behind the owner's switch: "Y" when on, absent when off.
pub const OPTION: &str = "rd-allow-device-forward";

/// Whether the owner allows controllers to forward their camera and microphone.
pub fn is_allowed() -> bool {
    Config::get_option(OPTION) == "Y"
}

/// The option value for `--set-device-forward`'s argument; an empty value removes the
/// option, so "off" is the default state rather than a stored "N".
pub fn option_value(arg: &str) -> Option<&'static str> {
    match arg {
        "on" => Some("Y"),
        "off" => Some(""),
        _ => None,
    }
}

/// The protocol version in `rd_device_forward` (spec, Protocol changes › Capabilities).
const PROTOCOL: i32 = 1;
/// Device statuses (`DeviceStatus.status`, `rd_camera_sink`, `rd_mic_sink`) and the
/// reasons in a refusing `DeviceForwardResponse`.
pub const READY: &str = "ready";
pub const NOT_INSTALLED: &str = "not-installed";
pub const NOT_APPROVED: &str = "not-approved";
pub const NOT_ALLOWED: &str = "not-allowed";
pub const BUSY: &str = "busy";
/// A request whose format is outside what the host accepts (decision 0016).
pub const BAD_FORMAT: &str = "bad-format";
/// The camera formats the host accepts (decision 0016): 16×16 to 1920×1080 in either
/// orientation, so a portrait camera fits too.
const MIN_SIDE: i32 = 16;
const MAX_LONG_SIDE: i32 = 1920;
const MAX_SHORT_SIDE: i32 = 1080;
const MAX_FPS: i32 = 60;
/// Key frame requests to a controller, at most one per this (spec, Protocol changes › Rate).
const KEY_FRAME_INTERVAL: Duration = Duration::from_millis(500);

/// A running camera forward's way into Remote Display Camera. Dropping it stops
/// feeding; the camera extension then shows its card (decision 0011).
pub(crate) trait Feed: Send {
    /// One access unit in Annex B. Returns false when nothing can be shown until a
    /// key frame arrives, so the controller should send one.
    fn feed(&mut self, annex_b: &[u8], key: bool, capture_time_us: i64) -> bool;
}

/// Where camera forwards go: on a Mac, the camera extension's sink
/// (`platform/macos_camera_sink.mm`); elsewhere, nowhere.
pub(crate) struct Sinks {
    camera_status: Box<dyn Fn() -> &'static str + Send + Sync>,
    open_camera: Box<dyn Fn(i32, i32, i32) -> ResultType<Box<dyn Feed>> + Send + Sync>,
    allowed: Box<dyn Fn() -> bool + Send + Sync>,
}

#[cfg(target_os = "macos")]
impl Default for Sinks {
    fn default() -> Self {
        use crate::platform::macos_camera_sink::{self as sink, Outcome};
        Self {
            camera_status: Box::new(|| {
                if camera_sink_present() {
                    READY
                } else {
                    NOT_INSTALLED
                }
            }),
            open_camera: Box::new(|_, _, fps| {
                let mut sink = sink::Feed::open(fps)?;
                Ok(
                    Box::new(DecodeThread::spawn(move |annex_b, capture_time_us| {
                        sink.push(annex_b, capture_time_us) == Outcome::Decoded
                    })?) as Box<dyn Feed>,
                )
            }),
            allowed: Box::new(is_allowed),
        }
    }
}

#[cfg(not(target_os = "macos"))]
impl Default for Sinks {
    fn default() -> Self {
        Self {
            camera_status: Box::new(|| NOT_INSTALLED),
            open_camera: Box::new(|_, _, _| hbb_common::bail!("only a Mac host receives a camera")),
            allowed: Box::new(is_allowed),
        }
    }
}

/// Whether Remote Display Camera's sink exists, asked of CoreMediaIO at most once a
/// second for all connections. Only asked while the owner's switch is on.
#[cfg(target_os = "macos")]
fn camera_sink_present() -> bool {
    lazy_static::lazy_static! {
        static ref LAST: Mutex<Option<(Instant, bool)>> = Default::default();
    }
    let mut last = LAST.lock().unwrap();
    match *last {
        Some((at, present)) if at.elapsed() < Duration::from_secs(1) => present,
        _ => {
            let present = crate::platform::macos_camera_sink::sink_present();
            *last = Some((Instant::now(), present));
            present
        }
    }
}

/// Decoded frames waiting for the decode thread. When it's busy, the frame is dropped
/// and so is everything up to the next key frame.
const DECODE_QUEUE: usize = 2;

struct Unit {
    annex_b: Vec<u8>,
    key: bool,
    capture_time_us: i64,
    /// The first unit queued after one was dropped.
    after_gap: bool,
}

/// Decodes on a thread of its own (spec, Security: "decode on a guarded thread"), so a
/// slow or stuck decoder never holds up the connection. Dropping it ends the thread,
/// and with it the sink.
struct DecodeThread {
    tx: Option<std::sync::mpsc::SyncSender<Unit>>,
    thread: Option<std::thread::JoinHandle<()>>,
    /// Set by either side when the picture is broken until the next key frame.
    need_key: Arc<std::sync::atomic::AtomicBool>,
    /// A unit was dropped; the next one queued says so.
    gap: bool,
}

impl DecodeThread {
    /// `push(annex_b, capture_time_us)` decodes one unit and returns whether it showed.
    fn spawn(mut push: impl FnMut(&[u8], i64) -> bool + Send + 'static) -> ResultType<Self> {
        use std::sync::atomic::{AtomicBool, Ordering};
        let (tx, rx) = std::sync::mpsc::sync_channel::<Unit>(DECODE_QUEUE);
        let need_key = Arc::new(AtomicBool::new(false));
        let need = need_key.clone();
        let thread = std::thread::Builder::new()
            .name("camera-decode".to_owned())
            .spawn(move || {
                let mut waiting_for_key = false;
                while let Ok(unit) = rx.recv() {
                    if unit.after_gap {
                        waiting_for_key = true;
                    }
                    // Nothing after a gap or a failure decodes cleanly until a key frame.
                    if waiting_for_key && !unit.key {
                        continue;
                    }
                    if push(&unit.annex_b, unit.capture_time_us) {
                        waiting_for_key = false;
                    } else {
                        waiting_for_key = true;
                        need.store(true, Ordering::Release);
                    }
                }
            })?;
        Ok(Self {
            tx: Some(tx),
            thread: Some(thread),
            need_key,
            gap: false,
        })
    }
}

impl Feed for DecodeThread {
    fn feed(&mut self, annex_b: &[u8], key: bool, capture_time_us: i64) -> bool {
        use std::sync::atomic::Ordering;
        if let Some(tx) = &self.tx {
            let unit = Unit {
                annex_b: annex_b.to_vec(),
                key,
                capture_time_us,
                after_gap: self.gap,
            };
            if tx.try_send(unit).is_ok() {
                self.gap = false;
            } else {
                self.gap = true;
                self.need_key.store(true, Ordering::Release);
            }
        }
        !self.need_key.swap(false, Ordering::AcqRel)
    }
}

impl Drop for DecodeThread {
    fn drop(&mut self) {
        // Closing the queue ends the thread after the unit it's on.
        self.tx = None;
        if let Some(thread) = self.thread.take() {
            thread.join().ok();
        }
    }
}

/// Which connection sends each device, and that controller's name: one at a time,
/// across all connections.
type Senders = Arc<Mutex<HashMap<Kind, (i32, String)>>>;

lazy_static::lazy_static! {
    static ref SENDERS: Senders = Default::default();
}

/// The longest controller name shown in the server app's menu.
const MAX_NAME: usize = 64;

/// Who is sending what, for the server app (decision 0009): `{"camera": "<controller>"}`
/// while a controller sends its camera, `{}` otherwise. The `--server` writes it next to
/// remotedisplay-perms.json, which must stay booleans-only.
pub fn forwarding_json() -> String {
    forwarding_of(&SENDERS)
}

fn forwarding_of(senders: &Senders) -> String {
    let mut out = serde_json::Map::new();
    for (kind, (_, name)) in senders.lock().unwrap().iter() {
        let key = match kind {
            Kind::CAMERA => "camera",
            Kind::MICROPHONE => "microphone",
        };
        out.insert(key.to_owned(), name.clone().into());
    }
    serde_json::Value::Object(out).to_string()
}

pub struct Forwards {
    conn_id: i32,
    sinks: Sinks,
    senders: Senders,
    /// The controller's name, from its login.
    controller: String,
    camera: Option<Box<dyn Feed>>,
    /// What this controller last heard about each device; empty until the login
    /// response advertised it.
    told: HashMap<Kind, &'static str>,
    last_key_request: Option<Instant>,
    frames: u64,
    dropped: u64,
}

fn response(kind: Kind, accepted: bool, reason: &str) -> Message {
    let mut msg = Message::new();
    msg.set_device_forward_response(DeviceForwardResponse {
        kind: kind.into(),
        accepted,
        reason: reason.to_owned(),
        ..Default::default()
    });
    msg
}

fn status(kind: Kind, status: &str) -> Message {
    let mut msg = Message::new();
    msg.set_device_status(DeviceStatus {
        kind: kind.into(),
        status: status.to_owned(),
        ..Default::default()
    });
    msg
}

fn key_frame_request() -> Message {
    let mut msg = Message::new();
    msg.set_camera_control(CameraControl {
        key_frame_request: true,
        ..Default::default()
    });
    msg
}

fn valid_format(request: &DeviceForwardRequest) -> bool {
    let long = request.width.max(request.height);
    let short = request.width.min(request.height);
    short >= MIN_SIDE
        && long <= MAX_LONG_SIDE
        && short <= MAX_SHORT_SIDE
        && (1..=MAX_FPS).contains(&request.fps)
}

impl Forwards {
    pub fn new(conn_id: i32) -> Self {
        Self::with(conn_id, Sinks::default(), SENDERS.clone())
    }

    fn with(conn_id: i32, sinks: Sinks, senders: Senders) -> Self {
        Self {
            conn_id,
            sinks,
            senders,
            controller: String::new(),
            camera: None,
            told: HashMap::new(),
            last_key_request: None,
            frames: 0,
            dropped: 0,
        }
    }

    fn status_of(&self, kind: Kind) -> &'static str {
        if !(self.sinks.allowed)() {
            return NOT_ALLOWED;
        }
        match kind {
            Kind::CAMERA => (self.sinks.camera_status)(),
            // Phase 2.
            Kind::MICROPHONE => NOT_INSTALLED,
        }
    }

    /// The `PeerInfo.platform_additions` keys for the login response of `controller`
    /// (its name, for the server app's menu). Only a Mac host receives devices.
    pub fn capabilities(&mut self, controller: &str) -> Vec<(String, serde_json::Value)> {
        if !cfg!(target_os = "macos") {
            return Vec::new();
        }
        self.controller = controller.chars().take(MAX_NAME).collect();
        let camera = self.status_of(Kind::CAMERA);
        let mic = self.status_of(Kind::MICROPHONE);
        self.told.insert(Kind::CAMERA, camera);
        self.told.insert(Kind::MICROPHONE, mic);
        vec![
            ("rd_device_forward".to_owned(), PROTOCOL.into()),
            ("rd_camera_sink".to_owned(), camera.into()),
            ("rd_mic_sink".to_owned(), mic.into()),
        ]
    }

    /// The controller's `DeviceForwardRequest` and `CameraFrame`; returns what to send
    /// back.
    pub fn on_message(&mut self, union: message::Union) -> Option<Message> {
        match union {
            message::Union::DeviceForwardRequest(request) => self.on_request(request),
            message::Union::CameraFrame(frame) => self.on_frame(frame),
            _ => None,
        }
    }

    fn on_request(&mut self, request: DeviceForwardRequest) -> Option<Message> {
        let kind = request.kind.enum_value().ok()?;
        if !request.on {
            if kind == Kind::CAMERA {
                self.stop_camera("switched off by the controller");
            }
            return None;
        }
        let status = self.status_of(kind);
        if status != READY {
            return Some(response(kind, false, status));
        }
        // Only the camera can be READY until Phase 2.
        if !valid_format(&request) {
            log::warn!(
                "Camera request refused: {}x{} at {} fps",
                request.width,
                request.height,
                request.fps
            );
            return Some(response(kind, false, BAD_FORMAT));
        }
        {
            let mut senders = self.senders.lock().unwrap();
            match senders.get(&kind) {
                Some(&(other, _)) if other != self.conn_id => {
                    return Some(response(kind, false, BUSY));
                }
                _ => {
                    senders.insert(kind, (self.conn_id, self.controller.clone()));
                }
            }
        }
        // A new request from the same controller (another camera) reopens the feed.
        self.camera = None;
        match (self.sinks.open_camera)(request.width, request.height, request.fps) {
            Ok(feed) => {
                log::info!(
                    "Camera forward from connection {} started: {}x{} at {} fps",
                    self.conn_id,
                    request.width,
                    request.height,
                    request.fps
                );
                self.camera = Some(feed);
                self.last_key_request = None;
                Some(response(kind, true, ""))
            }
            Err(err) => {
                log::warn!("Camera sink not opened: {}", err);
                self.release(kind);
                Some(response(kind, false, NOT_INSTALLED))
            }
        }
    }

    fn on_frame(&mut self, frame: CameraFrame) -> Option<Message> {
        let Some(feed) = self.camera.as_mut() else {
            // Not ours to show: no accepted camera forward on this connection.
            self.dropped += 1;
            return None;
        };
        let shown = match frame.frame.h264s().frames.first() {
            Some(unit) => feed.feed(&unit.data, unit.key, frame.capture_time_us),
            // Only H.264 is forwarded (decision 0005).
            None => false,
        };
        self.frames += 1;
        if shown {
            return None;
        }
        let now = Instant::now();
        if self
            .last_key_request
            .map_or(false, |last| now.duration_since(last) < KEY_FRAME_INTERVAL)
        {
            return None;
        }
        self.last_key_request = Some(now);
        Some(key_frame_request())
    }

    /// Once a second: tells the controller when a device's status changed, and ends
    /// the camera forward when the owner switched forwarding off or the sink went away.
    pub fn on_tick(&mut self) -> Vec<Message> {
        let mut out = Vec::new();
        if self.told.is_empty() {
            return out;
        }
        for kind in [Kind::CAMERA, Kind::MICROPHONE] {
            let now = self.status_of(kind);
            if self.told.get(&kind) != Some(&now) {
                self.told.insert(kind, now);
                out.push(status(kind, now));
            }
        }
        let camera = self.status_of(Kind::CAMERA);
        if self.camera.is_some() && camera != READY {
            self.stop_camera(camera);
            out.push(response(Kind::CAMERA, false, camera));
        }
        out
    }

    fn stop_camera(&mut self, why: &str) {
        if self.camera.take().is_some() {
            log::info!(
                "Camera forward from connection {} stopped ({}): {} frames, {} dropped",
                self.conn_id,
                why,
                self.frames,
                self.dropped
            );
        }
        self.release(Kind::CAMERA);
        self.frames = 0;
        self.dropped = 0;
    }

    fn release(&self, kind: Kind) {
        let mut senders = self.senders.lock().unwrap();
        if senders.get(&kind).map(|s| s.0) == Some(self.conn_id) {
            senders.remove(&kind);
        }
    }
}

impl Drop for Forwards {
    fn drop(&mut self) {
        self.stop_camera("the connection closed");
        self.release(Kind::MICROPHONE);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    #[test]
    fn on_and_off_only() {
        assert_eq!(option_value("on"), Some("Y"));
        assert_eq!(option_value("off"), Some(""));
        for arg in ["", "ON", "yes", "true", "1", "Y"] {
            assert_eq!(option_value(arg), None, "{arg:?}");
        }
    }

    /// The owner's switch, the sink's status and what reached the sink.
    struct Host {
        allowed: AtomicBool,
        camera: Mutex<&'static str>,
        opened: Mutex<Vec<(i32, i32, i32)>>,
        open_feeds: AtomicUsize,
        fed: Mutex<Vec<(bool, i64)>>,
        shows: AtomicBool,
    }

    struct FakeFeed(Arc<Host>);

    impl Feed for FakeFeed {
        fn feed(&mut self, _: &[u8], key: bool, capture_time_us: i64) -> bool {
            self.0.fed.lock().unwrap().push((key, capture_time_us));
            self.0.shows.load(Ordering::SeqCst)
        }
    }

    impl Drop for FakeFeed {
        fn drop(&mut self) {
            self.0.open_feeds.fetch_sub(1, Ordering::SeqCst);
        }
    }

    fn host(allowed: bool, camera: &'static str) -> Arc<Host> {
        Arc::new(Host {
            allowed: AtomicBool::new(allowed),
            camera: Mutex::new(camera),
            opened: Default::default(),
            open_feeds: AtomicUsize::new(0),
            fed: Default::default(),
            shows: AtomicBool::new(true),
        })
    }

    fn connection(id: i32, host: &Arc<Host>, senders: &Senders) -> Forwards {
        let (a, b, c) = (host.clone(), host.clone(), host.clone());
        let sinks = Sinks {
            camera_status: Box::new(move || *a.camera.lock().unwrap()),
            open_camera: Box::new(move |w, h, fps| {
                b.opened.lock().unwrap().push((w, h, fps));
                b.open_feeds.fetch_add(1, Ordering::SeqCst);
                Ok(Box::new(FakeFeed(b.clone())) as Box<dyn Feed>)
            }),
            allowed: Box::new(move || c.allowed.load(Ordering::SeqCst)),
        };
        Forwards::with(id, sinks, senders.clone())
    }

    fn ask(kind: Kind, on: bool, width: i32, height: i32, fps: i32) -> message::Union {
        message::Union::DeviceForwardRequest(DeviceForwardRequest {
            kind: kind.into(),
            on,
            width,
            height,
            fps,
            device_name: "FaceTime HD Camera".into(),
            ..Default::default()
        })
    }

    fn camera_on() -> message::Union {
        ask(Kind::CAMERA, true, 1280, 720, 30)
    }

    fn frame(key: bool, capture_time_us: i64) -> message::Union {
        let mut frames = hbb_common::message_proto::EncodedVideoFrames::new();
        frames
            .frames
            .push(hbb_common::message_proto::EncodedVideoFrame {
                data: vec![0, 0, 0, 1, if key { 0x65 } else { 0x41 }].into(),
                key,
                ..Default::default()
            });
        let mut video = hbb_common::message_proto::VideoFrame::new();
        video.set_h264s(frames);
        message::Union::CameraFrame(CameraFrame {
            frame: hbb_common::protobuf::MessageField::some(video),
            capture_time_us,
            ..Default::default()
        })
    }

    /// (accepted, reason) of a DeviceForwardResponse.
    fn answer(msg: Option<Message>) -> (bool, String) {
        let msg = msg.expect("a response");
        let r = msg.device_forward_response();
        (r.accepted, r.reason.clone())
    }

    #[test]
    fn advertises_what_it_can_receive() {
        let senders = Senders::default();
        let off = host(false, READY);
        let caps = connection(1, &off, &senders).capabilities("Test Controller");
        let caps: HashMap<String, serde_json::Value> = caps.into_iter().collect();
        assert_eq!(caps["rd_device_forward"], 1);
        assert_eq!(caps["rd_camera_sink"], NOT_ALLOWED);
        assert_eq!(caps["rd_mic_sink"], NOT_ALLOWED);
        let on = host(true, NOT_INSTALLED);
        let caps: HashMap<_, _> = connection(2, &on, &senders)
            .capabilities("Test Controller")
            .into_iter()
            .collect();
        assert_eq!(caps["rd_camera_sink"], NOT_INSTALLED);
        assert_eq!(caps["rd_mic_sink"], NOT_INSTALLED);
    }

    #[test]
    fn says_who_is_sending_for_the_server_app() {
        let senders = Senders::default();
        let h = host(true, READY);
        let mut conn = connection(1, &h, &senders);
        assert_eq!(forwarding_of(&senders), "{}");
        let long_name = format!("{}\"evil", "x".repeat(100));
        conn.capabilities(&long_name);
        conn.on_message(camera_on());
        let json: serde_json::Value = serde_json::from_str(&forwarding_of(&senders)).unwrap();
        let name = json["camera"].as_str().unwrap();
        assert_eq!(name.chars().count(), MAX_NAME, "cut to the menu's length");
        assert!(name.starts_with("xxx"));
        drop(conn);
        assert_eq!(forwarding_of(&senders), "{}");
    }

    #[test]
    fn refuses_unless_allowed_and_ready() {
        let senders = Senders::default();
        let off = host(false, READY);
        let mut conn = connection(1, &off, &senders);
        assert_eq!(
            answer(conn.on_message(camera_on())),
            (false, NOT_ALLOWED.into())
        );
        let missing = host(true, NOT_INSTALLED);
        let mut conn = connection(2, &missing, &senders);
        assert_eq!(
            answer(conn.on_message(camera_on())),
            (false, NOT_INSTALLED.into())
        );
        let unapproved = host(true, NOT_APPROVED);
        let mut conn = connection(3, &unapproved, &senders);
        assert_eq!(
            answer(conn.on_message(camera_on())),
            (false, NOT_APPROVED.into())
        );
        assert!(senders.lock().unwrap().is_empty());
        assert_eq!(off.open_feeds.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn accepts_and_opens_the_sink_at_the_requested_format() {
        let senders = Senders::default();
        let h = host(true, READY);
        let mut conn = connection(1, &h, &senders);
        assert_eq!(answer(conn.on_message(camera_on())), (true, String::new()));
        assert_eq!(*h.opened.lock().unwrap(), [(1280, 720, 30)]);
        assert_eq!(
            senders.lock().unwrap().get(&Kind::CAMERA).map(|s| s.0),
            Some(1)
        );
    }

    #[test]
    fn one_controller_at_a_time() {
        let senders = Senders::default();
        let h = host(true, READY);
        let mut first = connection(1, &h, &senders);
        let mut second = connection(2, &h, &senders);
        assert!(answer(first.on_message(camera_on())).0);
        assert_eq!(answer(second.on_message(camera_on())), (false, BUSY.into()));
        drop(first);
        assert_eq!(
            h.open_feeds.load(Ordering::SeqCst),
            0,
            "the first's feed ended"
        );
        assert!(
            answer(second.on_message(camera_on())).0,
            "free once the first left"
        );
    }

    #[test]
    fn refuses_formats_outside_the_limits() {
        let senders = Senders::default();
        let h = host(true, READY);
        let mut conn = connection(1, &h, &senders);
        for (w, h_, fps) in [
            (0, 0, 30),
            (3840, 2160, 30),
            (1280, 720, 0),
            (1280, 720, 1000),
            (8, 720, 30),
            (1080, 2000, 30),
        ] {
            let reply = conn.on_message(ask(Kind::CAMERA, true, w, h_, fps));
            assert_eq!(answer(reply), (false, BAD_FORMAT.into()), "{w}x{h_} {fps}");
        }
        assert!(h.opened.lock().unwrap().is_empty());
        assert!(senders.lock().unwrap().is_empty());
    }

    #[test]
    fn accepts_a_portrait_camera_within_the_same_bound() {
        let senders = Senders::default();
        let h = host(true, READY);
        let mut conn = connection(1, &h, &senders);
        assert!(answer(conn.on_message(ask(Kind::CAMERA, true, 1080, 1920, 30))).0);
    }

    #[test]
    fn frames_reach_the_sink_only_from_the_accepted_controller() {
        let senders = Senders::default();
        let h = host(true, READY);
        let mut sender = connection(1, &h, &senders);
        let mut other = connection(2, &h, &senders);
        assert!(other.on_message(frame(true, 1)).is_none());
        assert!(h.fed.lock().unwrap().is_empty(), "nothing accepted yet");
        sender.on_message(camera_on());
        assert!(sender.on_message(frame(true, 10)).is_none());
        assert!(other.on_message(frame(true, 20)).is_none());
        assert_eq!(*h.fed.lock().unwrap(), [(true, 10)]);
    }

    #[test]
    fn asks_for_key_frames_at_most_every_500_ms() {
        let senders = Senders::default();
        let h = host(true, READY);
        let mut conn = connection(1, &h, &senders);
        conn.on_message(camera_on());
        h.shows.store(false, Ordering::SeqCst);
        let first = conn
            .on_message(frame(false, 1))
            .expect("a key frame request");
        assert!(first.camera_control().key_frame_request);
        assert!(conn.on_message(frame(false, 2)).is_none(), "within 500 ms");
        std::thread::sleep(KEY_FRAME_INTERVAL + Duration::from_millis(20));
        assert!(conn.on_message(frame(false, 3)).is_some());
    }

    #[test]
    fn the_controller_switching_off_frees_the_camera() {
        let senders = Senders::default();
        let h = host(true, READY);
        let mut conn = connection(1, &h, &senders);
        conn.on_message(camera_on());
        assert!(conn.on_message(ask(Kind::CAMERA, false, 0, 0, 0)).is_none());
        assert_eq!(h.open_feeds.load(Ordering::SeqCst), 0);
        assert!(senders.lock().unwrap().is_empty());
        conn.on_message(frame(true, 1));
        assert!(h.fed.lock().unwrap().is_empty());
    }

    #[test]
    fn switching_forwarding_off_stops_live_forwards_and_says_why() {
        let senders = Senders::default();
        let h = host(true, READY);
        let mut conn = connection(1, &h, &senders);
        assert!(
            conn.on_tick().is_empty(),
            "nothing before the login response"
        );
        conn.capabilities("Test Controller");
        conn.on_message(camera_on());
        assert!(conn.on_tick().is_empty(), "nothing changed");
        h.allowed.store(false, Ordering::SeqCst);
        let out = conn.on_tick();
        let statuses: Vec<(Kind, String)> = out
            .iter()
            .filter(|m| m.has_device_status())
            .map(|m| {
                (
                    m.device_status().kind.enum_value().unwrap(),
                    m.device_status().status.clone(),
                )
            })
            .collect();
        assert_eq!(
            statuses,
            [
                (Kind::CAMERA, NOT_ALLOWED.into()),
                (Kind::MICROPHONE, NOT_ALLOWED.into())
            ]
        );
        let stop = out
            .iter()
            .find(|m| m.has_device_forward_response())
            .expect("a stop");
        assert!(!stop.device_forward_response().accepted);
        assert_eq!(stop.device_forward_response().reason, NOT_ALLOWED);
        assert_eq!(h.open_feeds.load(Ordering::SeqCst), 0);
        assert!(senders.lock().unwrap().is_empty());
        assert!(conn.on_tick().is_empty(), "said once");
    }

    #[test]
    fn a_sink_that_goes_away_ends_the_forward() {
        let senders = Senders::default();
        let h = host(true, READY);
        let mut conn = connection(1, &h, &senders);
        conn.capabilities("Test Controller");
        conn.on_message(camera_on());
        *h.camera.lock().unwrap() = NOT_APPROVED;
        let out = conn.on_tick();
        assert!(out
            .iter()
            .any(|m| m.has_device_status() && m.device_status().status == NOT_APPROVED));
        assert!(out.iter().any(|m| m.has_device_forward_response()
            && m.device_forward_response().reason == NOT_APPROVED));
        assert_eq!(h.open_feeds.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn the_microphone_waits_for_phase_2() {
        let senders = Senders::default();
        let h = host(true, READY);
        let mut conn = connection(1, &h, &senders);
        assert_eq!(
            answer(conn.on_message(ask(Kind::MICROPHONE, true, 0, 0, 0))),
            (false, NOT_INSTALLED.into())
        );
        assert!(conn
            .on_message(ask(Kind::MICROPHONE, false, 0, 0, 0))
            .is_none());
    }

    #[test]
    fn another_camera_from_the_same_controller_reopens_the_sink() {
        let senders = Senders::default();
        let h = host(true, READY);
        let mut conn = connection(1, &h, &senders);
        conn.on_message(camera_on());
        assert!(answer(conn.on_message(ask(Kind::CAMERA, true, 1920, 1080, 30))).0);
        assert_eq!(
            *h.opened.lock().unwrap(),
            [(1280, 720, 30), (1920, 1080, 30)]
        );
        assert_eq!(h.open_feeds.load(Ordering::SeqCst), 1);
        assert_eq!(
            senders.lock().unwrap().get(&Kind::CAMERA).map(|s| s.0),
            Some(1)
        );
    }

    /// A decoder that records what it was given, shows key frames and whatever
    /// `shows` says, and can be held up.
    fn decode_thread(
        shows: Arc<AtomicBool>,
        hold: Arc<Mutex<()>>,
    ) -> (DecodeThread, Arc<Mutex<Vec<i64>>>) {
        let seen: Arc<Mutex<Vec<i64>>> = Default::default();
        let record = seen.clone();
        let thread = DecodeThread::spawn(move |_, capture_time_us| {
            let _held = hold.lock().unwrap();
            record.lock().unwrap().push(capture_time_us);
            shows.load(Ordering::SeqCst)
        })
        .unwrap();
        (thread, seen)
    }

    fn settle(seen: &Arc<Mutex<Vec<i64>>>, count: usize) {
        let until = Instant::now() + Duration::from_secs(2);
        while seen.lock().unwrap().len() < count && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(5));
        }
        std::thread::sleep(Duration::from_millis(20));
    }

    #[test]
    fn the_decode_thread_decodes_in_order() {
        let (mut thread, seen) = decode_thread(Arc::new(AtomicBool::new(true)), Default::default());
        for t in 1..=5 {
            assert!(thread.feed(&[0, 0, 0, 1, 0x41], t == 1, t));
            settle(&seen, t as usize);
        }
        assert_eq!(*seen.lock().unwrap(), [1, 2, 3, 4, 5]);
    }

    #[test]
    fn a_busy_decoder_drops_to_the_next_key_frame_and_asks_for_one() {
        let hold: Arc<Mutex<()>> = Default::default();
        let (mut thread, seen) = decode_thread(Arc::new(AtomicBool::new(true)), hold.clone());
        let held = hold.lock().unwrap();
        // One unit is being decoded and two wait; the next one doesn't fit.
        thread.feed(&[], true, 1);
        settle(&seen, 0);
        thread.feed(&[], false, 2);
        thread.feed(&[], false, 3);
        assert!(!thread.feed(&[], false, 4), "dropped: asks for a key frame");
        thread.feed(&[], false, 5);
        drop(held);
        settle(&seen, 3);
        // 5 is after the gap and isn't a key frame; 6 is.
        assert!(thread.feed(&[], true, 6));
        settle(&seen, 4);
        assert_eq!(*seen.lock().unwrap(), [1, 2, 3, 6]);
    }

    #[test]
    fn a_failed_decode_asks_for_a_key_frame_and_waits_for_it() {
        let shows = Arc::new(AtomicBool::new(false));
        let (mut thread, seen) = decode_thread(shows.clone(), Default::default());
        assert!(thread.feed(&[], false, 1));
        settle(&seen, 1);
        assert!(
            !thread.feed(&[], false, 2),
            "the failure is reported on the next unit"
        );
        settle(&seen, 1);
        shows.store(true, Ordering::SeqCst);
        thread.feed(&[], true, 3);
        settle(&seen, 2);
        assert_eq!(*seen.lock().unwrap(), [1, 3], "2 waited for the key frame");
    }

    #[test]
    fn dropping_the_feed_ends_the_decode_thread() {
        let (mut thread, seen) = decode_thread(Arc::new(AtomicBool::new(true)), Default::default());
        thread.feed(&[], true, 1);
        drop(thread);
        assert_eq!(
            *seen.lock().unwrap(),
            [1],
            "finished the unit it had, then stopped"
        );
    }
}
