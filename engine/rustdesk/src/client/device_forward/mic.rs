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
    let host = cpal::default_host();
    let device = match name {
        Some(name) => host
            .input_devices()?
            .find(|d| d.name().map_or(false, |n| n == name))
            .with_context(|| format!("no input named \"{}\"", name))?,
        None => host.default_input_device().context("no default input")?,
    };
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
        let channels = self.channels as f32;
        self.mono.extend(
            interleaved
                .chunks_exact(self.channels)
                .map(|frame| frame.iter().sum::<f32>() / channels),
        );
        // 10 ms at the device's rate, then at 48 kHz.
        let per_frame = self.rate as usize / 100;
        while per_frame > 0 && self.mono.len() >= per_frame {
            let ten_ms: Vec<f32> = self.mono.drain(..per_frame).collect();
            let mut pcm = if self.rate == SAMPLE_RATE {
                ten_ms
            } else {
                crate::audio_resample(&ten_ms, self.rate, SAMPLE_RATE, 1)
            };
            pcm.resize(FRAME, 0.0);
            match self.encoder.encode_vec_float(&pcm, FRAME * 6) {
                Ok(data) => (self.on_audio)(data),
                Err(err) => log::warn!("Microphone frame not encoded: {}", err),
            }
        }
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
        assert_eq!(sent.lock().unwrap().len(), 20);
        let pcm = decode(&sent.lock().unwrap());
        assert!(
            (0.25..0.35).contains(&peak(&pcm[FRAME..])),
            "peak {}",
            peak(&pcm)
        );
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
}
