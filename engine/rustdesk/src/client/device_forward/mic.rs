// remotedisplay: the controller's microphone for a microphone forward (camera & audio
// forwarding spec, Controller side › Microphone capture; decision 0023).
//
// Each forward opens its own capture of the input it asked for, so the device belongs to
// that session, not to the process-wide setting a voice call shares through the client's
// audio service. It captures through cpal and encodes the way a voice call does (Opus, low
// delay, 10 ms frames), always at 48 kHz mono, so the AudioFormat is known before the
// device opens. cpal's stream can't leave the thread that made it, so capture runs on a
// thread of its own; that also keeps opening the device off the io loop.

use super::{OnAudio, OnLost};
use hbb_common::{log, ResultType};
use magnum_opus::{Application, Channels, Encoder};

/// What a microphone forward sends: Opus at this rate, in one channel.
pub(crate) const SAMPLE_RATE: u32 = 48000;
pub(crate) const CHANNELS: u16 = 1;
/// 10 ms at [`SAMPLE_RATE`].
const FRAME: usize = SAMPLE_RATE as usize / 100;

/// A running microphone. Dropping it stops capture, and the Mac's microphone indicator goes
/// off with it; it doesn't wait for a device that is still opening.
pub(crate) struct Capture {
    _stop: std::sync::mpsc::Sender<()>,
}

/// Starts capturing `device` (an input's name; `None` for the default). Fails at once when
/// the microphone can't be used: no access yet, or no such input. Each encoded frame goes
/// to `on_audio`. A microphone that doesn't open, or goes away while it runs, is reported
/// once through `on_lost`.
#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "ios")))]
pub(crate) fn start(
    device: Option<&str>,
    on_audio: OnAudio,
    on_lost: OnLost,
) -> ResultType<Capture> {
    let (device, config) = find(device)?;
    let (stop, stopped) = std::sync::mpsc::channel::<()>();
    std::thread::Builder::new()
        .name("mic-capture".to_owned())
        .spawn(move || {
            let lost = Lost::new(on_lost);
            match open(&device, &config, on_audio, lost.clone()) {
                // Until the forward drops its end.
                Ok(stream) => {
                    stopped.recv().ok();
                    drop(stream);
                }
                Err(err) => lost.report(&format!("didn't open: {}", err)),
            }
        })?;
    Ok(Capture { _stop: stop })
}

/// Only a desktop controller forwards its microphone; cpal isn't built on Linux.
#[cfg(any(target_os = "linux", target_os = "android", target_os = "ios"))]
pub(crate) fn start(_: Option<&str>, _: OnAudio, _: OnLost) -> ResultType<Capture> {
    hbb_common::bail!("microphone forwarding needs a Mac or Windows controller")
}

/// The host's own virtual microphone, never forwarded: on a Mac that is also a host it
/// would send the host's audio back into itself.
const REMOTE_DISPLAY_MICROPHONE: &str = "Remote Display Microphone";

/// The inputs a forward can capture, by name, without Remote Display Microphone. Needs no
/// microphone access. Only the Devices menu (`ui`) lists them.
#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "ios")))]
#[cfg(any(feature = "flutter", test))]
pub(crate) fn list() -> Vec<String> {
    use cpal::traits::{DeviceTrait, HostTrait};
    let Ok(devices) = cpal::default_host().input_devices() else {
        return Vec::new();
    };
    devices
        .filter_map(|d| d.name().ok())
        .filter(|name| name != REMOTE_DISPLAY_MICROPHONE)
        .collect()
}

#[cfg(any(target_os = "linux", target_os = "android", target_os = "ios"))]
#[cfg(any(target_os = "android", target_os = "ios", feature = "flutter", test))]
pub(crate) fn list() -> Vec<String> {
    Vec::new()
}

/// `on_lost`, called at most once from whichever thread notices first.
#[derive(Clone)]
struct Lost(std::sync::Arc<std::sync::Mutex<Option<OnLost>>>);

impl Lost {
    fn new(on_lost: OnLost) -> Self {
        Self(std::sync::Arc::new(std::sync::Mutex::new(Some(on_lost))))
    }

    fn report(&self, why: &str) {
        if let Some(on_lost) = self.0.lock().unwrap().take() {
            on_lost(why);
        }
    }
}

/// The input and its format. Quick: listing inputs needs no microphone access.
#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "ios")))]
fn find(name: Option<&str>) -> ResultType<(cpal::Device, cpal::SupportedStreamConfig)> {
    use cpal::traits::{DeviceTrait, HostTrait};
    use hbb_common::anyhow::Context;
    // Opening an input before macOS has answered blocks in its privacy check, so the
    // Devices menu asks first.
    #[cfg(target_os = "macos")]
    if crate::platform::macos_mic_capture::access()
        != crate::platform::macos_camera_capture::Access::Allowed
    {
        hbb_common::bail!("microphone access isn't allowed");
    }
    if name == Some(REMOTE_DISPLAY_MICROPHONE) {
        hbb_common::bail!("{} is never forwarded", REMOTE_DISPLAY_MICROPHONE);
    }
    let host = cpal::default_host();
    // The default is looked up by name too: cpal tells only a listed input's stream that
    // the device went away, not the default's, so a default that went away would go
    // quiet unnoticed. The forward stays on the input that was the default.
    let name = match name {
        Some(name) => name.to_owned(),
        None => host
            .default_input_device()
            .context("no default input")?
            .name()?,
    };
    let device = host
        .input_devices()?
        .find(|d| d.name().map_or(false, |n| n == name))
        .with_context(|| format!("no input named \"{}\"", name))?;
    let config = device.default_input_config()?;
    Ok((device, config))
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "ios")))]
fn open(
    device: &cpal::Device,
    config: &cpal::SupportedStreamConfig,
    on_audio: OnAudio,
    lost: Lost,
) -> ResultType<cpal::Stream> {
    use cpal::{
        traits::{DeviceTrait, StreamTrait},
        SampleFormat,
    };
    log::info!(
        "Microphone \"{}\" at {} Hz, {} channels, {:?}",
        device.name().unwrap_or_default(),
        config.sample_rate().0,
        config.channels(),
        config.sample_format()
    );
    let frames = Frames::new(config.sample_rate().0, config.channels(), on_audio)?;
    let stream_config: cpal::StreamConfig = config.clone().into();
    let stream = match config.sample_format() {
        SampleFormat::I8 => build::<i8>(device, &stream_config, frames, lost)?,
        SampleFormat::I16 => build::<i16>(device, &stream_config, frames, lost)?,
        SampleFormat::I32 => build::<i32>(device, &stream_config, frames, lost)?,
        SampleFormat::U8 => build::<u8>(device, &stream_config, frames, lost)?,
        SampleFormat::U16 => build::<u16>(device, &stream_config, frames, lost)?,
        SampleFormat::U32 => build::<u32>(device, &stream_config, frames, lost)?,
        SampleFormat::F32 => build::<f32>(device, &stream_config, frames, lost)?,
        SampleFormat::F64 => build::<f64>(device, &stream_config, frames, lost)?,
        f => hbb_common::bail!("unsupported sample format {:?}", f),
    };
    stream.play()?;
    Ok(stream)
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "ios")))]
fn build<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    mut frames: Frames,
    lost: Lost,
) -> ResultType<cpal::Stream>
where
    T: cpal::SizedSample,
    f32: cpal::FromSample<T>,
{
    use cpal::{traits::DeviceTrait, Sample};
    let mut samples = Vec::new();
    let stream = device.build_input_stream(
        config,
        move |data: &[T], _: &cpal::InputCallbackInfo| {
            samples.clear();
            samples.extend(data.iter().map(|&s| f32::from_sample(s)));
            frames.push(&samples);
        },
        move |err| match err {
            cpal::StreamError::DeviceNotAvailable => lost.report("disconnected"),
            err => log::warn!("Microphone: {}", err),
        },
        None,
    )?;
    Ok(stream)
}

/// Turns the device's interleaved samples into 10 ms Opus frames at 48 kHz mono.
pub(super) struct Frames {
    rate: u32,
    channels: usize,
    /// Device samples, mixed to mono, not yet a whole 10 ms.
    mono: Vec<f32>,
    encoder: Encoder,
    on_audio: OnAudio,
}

impl Frames {
    pub(super) fn new(rate: u32, channels: u16, on_audio: OnAudio) -> ResultType<Self> {
        Ok(Self {
            rate: rate.max(1),
            channels: channels.max(1) as usize,
            mono: Vec::new(),
            encoder: Encoder::new(SAMPLE_RATE, Channels::Mono, Application::LowDelay)?,
            on_audio,
        })
    }

    pub(super) fn push(&mut self, interleaved: &[f32]) {
        self.mix(interleaved);
        while let Some(pcm) = self.next_frame() {
            match self.encoder.encode_vec_float(&pcm, FRAME * 6) {
                Ok(data) => (self.on_audio)(data),
                Err(err) => log::warn!("Microphone frame not encoded: {}", err),
            }
        }
    }

    fn mix(&mut self, interleaved: &[f32]) {
        let channels = self.channels as f32;
        self.mono.extend(
            interleaved
                .chunks_exact(self.channels)
                .map(|frame| frame.iter().sum::<f32>() / channels),
        );
    }

    /// The next 10 ms at 48 kHz, once the device has given enough.
    fn next_frame(&mut self) -> Option<Vec<f32>> {
        // 10 ms at the device's rate.
        let per_frame = self.rate as usize / 100;
        if self.rate == SAMPLE_RATE {
            return (self.mono.len() >= FRAME).then(|| self.mono.drain(..FRAME).collect());
        }
        // The last samples at 48 kHz fall between this 10 ms and the next, so the next's
        // first sample goes in too. Without it they'd fall toward zero every 10 ms.
        if per_frame == 0 || self.mono.len() <= per_frame {
            return None;
        }
        let mut pcm = crate::audio_resample(&self.mono[..=per_frame], self.rate, SAMPLE_RATE, 1);
        self.mono.drain(..per_frame);
        pcm.resize(FRAME, 0.0);
        Some(pcm)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    /// `ms` of a 440 Hz tone at `rate` with `channels` channels, amplitude 0.3.
    fn tone(rate: u32, channels: u16, ms: usize) -> Vec<f32> {
        (0..rate as usize * ms / 1000)
            .flat_map(|i| {
                let s = 0.3 * (2.0 * std::f32::consts::PI * 440.0 * i as f32 / rate as f32).sin();
                std::iter::repeat(s).take(channels as usize)
            })
            .collect()
    }

    fn frames(rate: u32, channels: u16) -> (Frames, Arc<Mutex<Vec<Vec<u8>>>>) {
        let sent: Arc<Mutex<Vec<Vec<u8>>>> = Default::default();
        let s = sent.clone();
        let frames = Frames::new(rate, channels, Box::new(move |f| s.lock().unwrap().push(f)));
        (frames.unwrap(), sent)
    }

    /// Decodes what was sent, as the host does, and returns the samples.
    fn decode(sent: &[Vec<u8>]) -> Vec<f32> {
        let mut decoder = magnum_opus::Decoder::new(SAMPLE_RATE, Channels::Mono).unwrap();
        let mut out = Vec::new();
        let mut room = vec![0f32; FRAME * 12];
        for frame in sent {
            let n = decoder.decode_float(frame, &mut room, false).unwrap();
            assert_eq!(n, FRAME, "10 ms per frame");
            out.extend_from_slice(&room[..n]);
        }
        out
    }

    fn peak(pcm: &[f32]) -> f32 {
        pcm.iter().fold(0f32, |m, s| m.max(s.abs()))
    }

    #[test]
    fn a_48_khz_mono_mic_becomes_10_ms_frames() {
        let (mut frames, sent) = frames(48000, 1);
        frames.push(&tone(48000, 1, 105));
        assert_eq!(sent.lock().unwrap().len(), 10, "the last 5 ms waits");
        let pcm = decode(&sent.lock().unwrap());
        assert!(
            (0.25..0.35).contains(&peak(&pcm[FRAME..])),
            "the level is kept"
        );
    }

    #[test]
    fn a_44_1_khz_stereo_mic_is_mixed_and_resampled() {
        let (mut frames, sent) = frames(44100, 2);
        // Delivered in uneven pieces, as a device does.
        let input = tone(44100, 2, 200);
        for piece in input.chunks(2 * 333) {
            frames.push(piece);
        }
        assert_eq!(
            sent.lock().unwrap().len(),
            19,
            "the last 10 ms waits for the next one's first sample"
        );
        let pcm = decode(&sent.lock().unwrap());
        assert!(
            (0.25..0.35).contains(&peak(&pcm[FRAME..])),
            "peak {}",
            peak(&pcm)
        );
    }

    /// The largest gap between what reached the encoder and the tone itself at 48 kHz.
    fn worst_error(rate: u32, piece: usize) -> f32 {
        let mut frames = Frames::new(rate, 1, Box::new(|_| {})).unwrap();
        let mut pcm = Vec::new();
        for piece in tone(rate, 1, 300).chunks(piece) {
            frames.mix(piece);
            while let Some(frame) = frames.next_frame() {
                pcm.extend(frame);
            }
        }
        assert!(pcm.len() >= FRAME * 29, "{} samples", pcm.len());
        pcm.iter()
            .enumerate()
            .map(|(i, s)| {
                let t = i as f32 / SAMPLE_RATE as f32;
                (s - 0.3 * (2.0 * std::f32::consts::PI * 440.0 * t).sin()).abs()
            })
            .fold(0f32, f32::max)
    }

    // Each 10 ms is resampled on its own, so its last samples need the next 10 ms's first.
    // Without it they fall toward zero every 10 ms: a 100 Hz buzz on a 16 kHz headset.
    #[test]
    fn resampling_runs_on_across_frames() {
        for (rate, piece) in [(16000, 137), (44100, 512), (24000, 240)] {
            let error = worst_error(rate, piece);
            assert!(error < 0.01, "{} Hz: off by {}", rate, error);
        }
    }

    #[test]
    fn a_microphone_that_cant_be_used_fails_at_once() {
        let called: Arc<Mutex<usize>> = Default::default();
        let (a, l) = (called.clone(), called.clone());
        // No such input, or (on a Mac that hasn't allowed this process) no access.
        let started = start(
            Some("No such microphone"),
            Box::new(move |_| *a.lock().unwrap() += 1),
            Box::new(move |_| *l.lock().unwrap() += 1),
        );
        assert!(started.is_err());
        assert_eq!(*called.lock().unwrap(), 0, "nothing sent, nothing reported");
    }

    // The vendored cpal reads a device's buffer sizes from the device, not by opening it
    // (decision 0025): every output has a default config, built-in speakers too, and
    // reading an input's doesn't wait on the microphone prompt.
    #[cfg(target_os = "macos")]
    #[test]
    fn cpal_reads_each_device_without_opening_it() {
        use cpal::traits::{DeviceTrait, HostTrait};
        for device in cpal::default_host().devices().unwrap() {
            let name = device.name().unwrap_or_default();
            let outputs = device.supported_output_configs().map(|c| c.count());
            let inputs = device.supported_input_configs().map(|c| c.count());
            assert!(outputs.is_ok() && inputs.is_ok(), "{}: no configs", name);
            if outputs.unwrap() > 0 {
                let config = device.default_output_config();
                assert!(config.is_ok(), "{}: no output config", name);
            }
            if inputs.unwrap() > 0 {
                let config = device.default_input_config();
                assert!(config.is_ok(), "{}: no input config", name);
            }
        }
    }

    #[test]
    fn remote_display_microphone_is_never_listed() {
        assert!(!list().iter().any(|m| m == REMOTE_DISPLAY_MICROPHONE));
    }
}

/// With the Mac's own microphone, from the harness's app bundle (docs/tests/mic-capture), so
/// macOS asks about the microphone for the bundle, not the terminal. `RD_MIC` names the
/// input and `RD_SPEAKER` the output the test tone plays through; the defaults otherwise.
#[cfg(all(test, target_os = "macos"))]
mod capture {
    use super::*;
    use crate::platform::{
        macos_camera_capture::Access,
        macos_mic_capture::{access, request_access},
    };
    use std::{
        sync::mpsc,
        time::{Duration, Instant},
    };

    fn named(var: &str) -> Option<String> {
        std::env::var(var).ok().filter(|name| !name.is_empty())
    }

    #[test]
    #[ignore]
    fn lists_microphones_but_not_ours() {
        let asked = Instant::now();
        let microphones = list();
        println!("listed in {:?}", asked.elapsed());
        for microphone in &microphones {
            println!("microphone: {}", microphone);
        }
        assert!(!microphones.is_empty(), "no microphone found");
        assert!(
            asked.elapsed() < Duration::from_secs(1),
            "waited for the microphone prompt"
        );
    }

    #[test]
    #[ignore]
    fn nothing_without_microphone_access() {
        assert_ne!(
            access(),
            Access::Allowed,
            "the probe already has microphone access; run make revoke first"
        );
        let (tx, rx) = mpsc::channel();
        let asked = Instant::now();
        let error = start(
            named("RD_MIC").as_deref(),
            Box::new(move |_| {
                let _ = tx.send(());
            }),
            Box::new(|_| {}),
        )
        .err()
        .expect("started without microphone access");
        println!("refused in {:?}: {}", asked.elapsed(), error);
        assert_eq!(error.to_string(), "microphone access isn't allowed");
        assert!(asked.elapsed() < Duration::from_secs(1), "not at once");
        assert!(rx.recv_timeout(Duration::from_secs(2)).is_err());
    }

    #[test]
    #[ignore]
    fn asks_for_microphone_access() {
        let (tx, rx) = mpsc::channel();
        request_access(move |granted| {
            let _ = tx.send(granted);
        });
        let granted = rx
            .recv_timeout(Duration::from_secs(300))
            .expect("no answer to the microphone prompt within 5 minutes");
        assert!(granted, "microphone access refused");
    }

    /// A 1 kHz tone at a fifth of full scale through `speaker` (the default output when
    /// `None`), until the stream is dropped.
    fn tone_through(speaker: Option<&str>) -> cpal::Stream {
        use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
        let host = cpal::default_host();
        let device = match speaker {
            Some(name) => host
                .output_devices()
                .unwrap()
                .find(|d| d.name().map_or(false, |n| n == name))
                .unwrap_or_else(|| panic!("no output named \"{}\"", name)),
            None => host.default_output_device().expect("no default output"),
        };
        let config: cpal::StreamConfig = device.default_output_config().unwrap().into();
        let step = 2.0 * std::f64::consts::PI * 1000.0 / config.sample_rate.0 as f64;
        let channels = config.channels as usize;
        let mut phase = 0f64;
        let stream = device
            .build_output_stream(
                &config,
                move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    for frame in data.chunks_mut(channels) {
                        frame.fill(0.2 * phase.sin() as f32);
                        phase = (phase + step) % (2.0 * std::f64::consts::PI);
                    }
                },
                |err| println!("speaker: {}", err),
                None,
            )
            .unwrap();
        stream.play().unwrap();
        println!("tone through \"{}\"", device.name().unwrap_or_default());
        stream
    }

    /// The amplitude of `hz` in `pcm` (Goertzel), and the whole signal's RMS.
    fn levels(pcm: &[f32], hz: f64) -> (f64, f64) {
        let coeff = 2.0 * (2.0 * std::f64::consts::PI * hz / SAMPLE_RATE as f64).cos();
        let (mut s1, mut s2) = (0f64, 0f64);
        for &x in pcm {
            let s0 = x as f64 + coeff * s1 - s2;
            s2 = s1;
            s1 = s0;
        }
        let n = pcm.len().max(1) as f64;
        let tone = 2.0 * (s1 * s1 + s2 * s2 - coeff * s1 * s2).max(0.0).sqrt() / n;
        let rms = (pcm.iter().map(|&x| (x as f64).powi(2)).sum::<f64>() / n).sqrt();
        (tone, rms)
    }

    fn db(amplitude: f64) -> f64 {
        20.0 * amplitude.max(1e-9).log10()
    }

    /// A second of the room, a second of tone through the speaker, half a second of the
    /// room, then stop: the frames are 10 ms of Opus at 48 kHz mono, about 100 a second;
    /// the room isn't digital silence (which is what a refused microphone gives); the tone
    /// is heard; nothing arrives once the capture is dropped.
    #[test]
    #[ignore]
    fn sends_the_microphone_as_opus() {
        assert_eq!(
            access(),
            Access::Allowed,
            "allow microphone access first (make ask)"
        );
        let (tx, rx) = mpsc::channel::<(Instant, Vec<u8>)>();
        let (lost_tx, lost) = mpsc::channel::<String>();
        let started = Instant::now();
        let capture = start(
            named("RD_MIC").as_deref(),
            Box::new(move |frame| {
                let _ = tx.send((Instant::now(), frame));
            }),
            Box::new(move |why| {
                let _ = lost_tx.send(why.to_owned());
            }),
        )
        .unwrap();
        let (first_at, first) = rx
            .recv_timeout(Duration::from_secs(3))
            .expect("no frame within 3 s");
        println!("first frame {:?} after starting", first_at - started);
        let mut frames = vec![(first_at, first)];
        let take = |until: Instant, frames: &mut Vec<(Instant, Vec<u8>)>| {
            while let Some(left) = until.checked_duration_since(Instant::now()) {
                match rx.recv_timeout(left) {
                    Ok(frame) => frames.push(frame),
                    Err(_) => break,
                }
            }
        };
        take(first_at + Duration::from_secs(1), &mut frames);
        let tone_on = Instant::now();
        let speaker = tone_through(named("RD_SPEAKER").as_deref());
        take(tone_on + Duration::from_secs(1), &mut frames);
        drop(speaker);
        let tone_off = Instant::now();
        take(tone_off + Duration::from_millis(500), &mut frames);
        drop(capture);
        let stopped = Instant::now();
        let mut after = Vec::new();
        take(stopped + Duration::from_millis(500), &mut after);
        assert!(lost.try_recv().is_err(), "the microphone went away");

        let mut decoder = magnum_opus::Decoder::new(SAMPLE_RATE, Channels::Mono).unwrap();
        let mut room = vec![0f32; FRAME * 12];
        let (mut quiet, mut toned) = (Vec::new(), Vec::new());
        for (at, frame) in &frames {
            let n = decoder.decode_float(frame, &mut room, false).unwrap();
            assert_eq!(n, FRAME, "10 ms per frame");
            // The speaker takes a moment to start; leave out its first 300 ms.
            if *at < tone_on {
                quiet.extend_from_slice(&room[..n]);
            } else if *at > tone_on + Duration::from_millis(300) && *at < tone_off {
                toned.extend_from_slice(&room[..n]);
            }
        }
        let span = (frames.last().unwrap().0 - first_at).as_secs_f64();
        let rate = (frames.len() - 1) as f64 / span;
        let (quiet_tone, quiet_rms) = levels(&quiet, 1000.0);
        let (heard_tone, heard_rms) = levels(&toned, 1000.0);
        println!(
            "{} frames in {:.2} s ({:.1} a second), {} after stopping",
            frames.len(),
            span,
            rate,
            after.len()
        );
        println!(
            "room: {:.1} dBFS RMS, 1 kHz at {:.1} dBFS; tone: {:.1} dBFS RMS, 1 kHz at {:.1} dBFS",
            db(quiet_rms),
            db(quiet_tone),
            db(heard_rms),
            db(heard_tone)
        );
        assert!((95.0..105.0).contains(&rate), "{:.1} frames a second", rate);
        assert!(
            quiet_rms > 1e-6,
            "digital silence: no sound reaches the capture"
        );
        assert!(
            db(heard_tone) > db(quiet_tone) + 10.0,
            "the tone wasn't heard"
        );
        assert!(after.len() <= 1, "frames after the capture stopped");
    }
}
