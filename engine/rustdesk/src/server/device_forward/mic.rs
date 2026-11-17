// remotedisplay: a microphone forward's audio on the host (camera & audio forwarding spec,
// Host side › Microphone; decision 0021). The controller's Opus is decoded on a thread of
// its own, converted to the device's format and written into a jitter buffer that Remote
// Display Microphone's render callback reads on Core Audio's real-time thread. The buffer
// is the spec's, shared with the client's playback (src/client/jitter.rs).

use super::MicFeed;
use crate::client::jitter::{jitter, Stats, Writer};
use base::message_proto::{AudioFormat, AudioFrame};
use hbb_common::{log, ResultType};
use magnum_opus::{Channels, Decoder};
use std::sync::{atomic::Ordering, mpsc, Arc};

/// Frames waiting for the decode thread; beyond this, new ones are dropped.
const QUEUE: usize = 50;

enum Audio {
    Format(AudioFormat),
    Frame(AudioFrame),
}

/// Remote Display Microphone, played from a jitter buffer in its feeder's format.
#[cfg(target_os = "macos")]
pub(crate) fn open() -> ResultType<MicThread<crate::platform::macos_mic_sink::Sink>> {
    use crate::platform::macos_mic_sink as sink;
    let Some((rate, channels)) = sink::feeder_format() else {
        hbb_common::bail!("Remote Display Microphone isn't installed");
    };
    let (writer, mut reader, stats) = jitter(rate, channels);
    let output = sink::Sink::open(move |out| reader.read(out))?;
    MicThread::spawn(rate, channels, writer, stats, output)
}

/// Decodes a controller's microphone on a thread of its own and writes it into the
/// jitter buffer. Dropping it ends the thread, then `output`.
pub(crate) struct MicThread<O: Send> {
    tx: Option<mpsc::SyncSender<Audio>>,
    thread: Option<std::thread::JoinHandle<()>>,
    stats: Arc<Stats>,
    /// Frames the thread was too busy to take.
    queue_drops: u64,
    output: Option<O>,
}

impl<O: Send> MicThread<O> {
    /// `rate` and `channels` are the device's, which `writer` is for; `output` is what
    /// plays the buffer, kept until the thread has ended.
    pub(super) fn spawn(
        rate: u32,
        channels: u16,
        mut writer: Writer,
        stats: Arc<Stats>,
        output: O,
    ) -> ResultType<Self> {
        let (tx, rx) = mpsc::sync_channel::<Audio>(QUEUE);
        let thread = std::thread::Builder::new()
            .name("mic-forward".to_owned())
            .spawn(move || {
                // The decoder, its rate and channels, and room for a decoded frame.
                let mut decoder: Option<(Decoder, u32, u16, Vec<f32>)> = None;
                let mut warned = false;
                while let Ok(audio) = rx.recv() {
                    match audio {
                        Audio::Format(f) => {
                            let stereo = f.channels > 1;
                            let opus = if stereo {
                                Channels::Stereo
                            } else {
                                Channels::Mono
                            };
                            decoder = match Decoder::new(f.sample_rate, opus) {
                                Ok(d) => {
                                    let ch = if stereo { 2 } else { 1 };
                                    // A second at most: Opus frames are 120 ms or less.
                                    let room = vec![0.; f.sample_rate as usize * ch as usize];
                                    Some((d, f.sample_rate, ch, room))
                                }
                                Err(err) => {
                                    log::warn!(
                                        "Microphone forward: no decoder for {} Hz: {}",
                                        f.sample_rate,
                                        err
                                    );
                                    None
                                }
                            };
                            warned = false;
                        }
                        Audio::Frame(frame) => {
                            let Some((d, rate0, ch, room)) = decoder.as_mut() else {
                                continue;
                            };
                            let n = match d.decode_float(&frame.data, room, false) {
                                Ok(n) => n * *ch as usize,
                                Err(err) => {
                                    if !warned {
                                        warned = true;
                                        log::warn!(
                                            "Microphone forward: undecodable audio: {}",
                                            err
                                        );
                                    }
                                    continue;
                                }
                            };
                            let mut pcm = room[..n].to_vec();
                            if *rate0 != rate {
                                pcm = crate::audio_resample(&pcm, *rate0, rate, *ch);
                            }
                            let pcm = crate::audio_rechannel(pcm, rate, rate, *ch, channels);
                            writer.write(&pcm);
                        }
                    }
                }
            })?;
        Ok(Self {
            tx: Some(tx),
            thread: Some(thread),
            stats,
            queue_drops: 0,
            output: Some(output),
        })
    }

    fn send(&mut self, audio: Audio) {
        if let Some(tx) = &self.tx {
            if tx.try_send(audio).is_err() {
                self.queue_drops += 1;
            }
        }
    }

    /// Samples the device has played so far.
    #[cfg(test)]
    pub(crate) fn played(&self) -> u64 {
        self.stats.played.load(Ordering::Relaxed)
    }
}

impl<O: Send> MicFeed for MicThread<O> {
    fn format(&mut self, format: AudioFormat) {
        self.send(Audio::Format(format));
    }

    fn frame(&mut self, frame: AudioFrame) {
        self.send(Audio::Frame(frame));
    }
}

impl<O: Send> Drop for MicThread<O> {
    fn drop(&mut self) {
        // Closing the queue ends the thread once it has emptied it.
        self.tx = None;
        if let Some(thread) = self.thread.take() {
            thread.join().ok();
        }
        self.output = None;
        log::info!(
            "Microphone feed ended: {} samples played, {} underruns, {} samples dropped, {} frames not taken",
            self.stats.played.load(Ordering::Relaxed),
            self.stats.underruns.load(Ordering::Relaxed),
            self.stats.dropped.load(Ordering::Relaxed),
            self.queue_drops
        );
    }
}

/// Sends `seconds` of microphone as a controller does: 10 ms Opus frames at 48 kHz
/// mono, each when its time comes. Samples whose host time (ns, the clock of Core
/// Audio's time stamps) `tone` accepts carry a 1 kHz tone at 0.3, continuous across
/// frames; the rest are silence.
#[cfg(all(test, target_os = "macos"))]
pub(crate) fn send_tone(feed: &mut dyn MicFeed, seconds: f64, tone: impl Fn(u64) -> bool) {
    use std::time::{Duration, Instant};
    extern "C" {
        fn clock_gettime_nsec_np(clock: u32) -> u64;
    }
    const CLOCK_UPTIME_RAW: u32 = 8;
    const RATE: u32 = 48000;
    feed.format(AudioFormat {
        sample_rate: RATE,
        channels: 1,
        ..Default::default()
    });
    let mut encoder =
        magnum_opus::Encoder::new(RATE, Channels::Mono, magnum_opus::Application::Voip).unwrap();
    let start = Instant::now();
    let mut sent = 0u32;
    while start.elapsed().as_secs_f64() < seconds {
        let now = unsafe { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) };
        let first = sent as u64 * RATE as u64 / 100;
        let pcm: Vec<f32> = (0..RATE as u64 / 100)
            .map(|i| {
                if tone(now + i * 1_000_000_000 / RATE as u64) {
                    let cycles = (first + i) as f64 * 1000.0 / RATE as f64;
                    (0.3 * (2.0 * std::f64::consts::PI * cycles).sin()) as f32
                } else {
                    0.0
                }
            })
            .collect();
        feed.frame(AudioFrame {
            data: encoder.encode_vec_float(&pcm, 4000).unwrap().into(),
            ..Default::default()
        });
        sent += 1;
        let next = start + Duration::from_millis(10) * sent;
        if let Some(wait) = next.checked_duration_since(Instant::now()) {
            std::thread::sleep(wait);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::jitter::Reader;
    use std::{
        sync::Mutex,
        time::{Duration, Instant},
    };

    const RATE: u32 = 48000;

    fn ms(ms: usize) -> usize {
        RATE as usize * ms / 1000 * 2
    }

    /// Encodes `ms` of a stereo tone at `rate` as 10 ms Opus frames.
    fn opus_frames(rate: u32, channels: u16, ms: usize) -> Vec<AudioFrame> {
        let opus = if channels > 1 {
            Channels::Stereo
        } else {
            Channels::Mono
        };
        let mut encoder =
            magnum_opus::Encoder::new(rate, opus, magnum_opus::Application::Voip).unwrap();
        let per_frame = rate as usize / 100 * channels as usize;
        let mut out = Vec::new();
        for i in 0..ms / 10 {
            let pcm: Vec<f32> = (0..per_frame)
                .map(|n| {
                    let t = (i * per_frame + n) / channels as usize;
                    0.3 * (2.0 * std::f32::consts::PI * 440.0 * t as f32 / rate as f32).sin()
                })
                .collect();
            let data = encoder.encode_vec_float(&pcm, 4000).unwrap();
            out.push(AudioFrame {
                data: data.into(),
                ..Default::default()
            });
        }
        out
    }

    fn format(rate: u32, channels: u16) -> AudioFormat {
        AudioFormat {
            sample_rate: rate,
            channels: channels as u32,
            ..Default::default()
        }
    }

    fn wait_for(reader: &Reader, samples: usize) {
        let until = Instant::now() + Duration::from_secs(2);
        while reader.waiting() < samples && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn decodes_a_mono_controller_into_the_stereo_device() {
        let (w, r, stats) = jitter(RATE, 2);
        let mut feed = MicThread::spawn(RATE, 2, w, stats, ()).unwrap();
        feed.format(format(RATE, 1));
        for f in opus_frames(RATE, 1, 100) {
            feed.frame(f);
        }
        wait_for(&r, ms(100));
        assert_eq!(r.waiting(), ms(100), "100 ms, as stereo");
        let mut out = vec![0.0; ms(100)];
        let mut r = r;
        // Exactly 100 ms waiting: nothing is dropped.
        r.read(&mut out);
        let peak = out.iter().fold(0f32, |m, s| m.max(s.abs()));
        // The tone was 0.3: Opus and the move to stereo keep the level.
        assert!((0.25..0.35).contains(&peak), "peak {peak}");
        assert!(out.chunks(2).all(|lr| lr[0] == lr[1]), "both channels");
    }

    #[test]
    fn resamples_a_controller_at_another_rate() {
        let (w, r, stats) = jitter(RATE, 2);
        let mut feed = MicThread::spawn(RATE, 2, w, stats, ()).unwrap();
        feed.format(format(24000, 2));
        for f in opus_frames(24000, 2, 100) {
            feed.frame(f);
        }
        wait_for(&r, ms(100));
        let got = r.waiting() as i64;
        assert!(
            (got - ms(100) as i64).abs() <= 40,
            "about 100 ms at 48 kHz: {got}"
        );
    }

    #[test]
    fn ignores_frames_before_a_format_and_garbage() {
        let (w, r, stats) = jitter(RATE, 2);
        let mut feed = MicThread::spawn(RATE, 2, w, stats, ()).unwrap();
        feed.frame(opus_frames(RATE, 2, 10).remove(0));
        feed.format(format(44100, 2));
        feed.frame(opus_frames(RATE, 2, 10).remove(0));
        feed.format(format(RATE, 2));
        feed.frame(AudioFrame {
            data: vec![0xff; 3].into(),
            ..Default::default()
        });
        feed.frame(opus_frames(RATE, 2, 10).remove(0));
        wait_for(&r, ms(10));
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(r.waiting(), ms(10), "only the last frame");
    }

    #[test]
    fn dropping_the_feed_ends_the_thread_then_the_output() {
        struct Output(Arc<Mutex<bool>>);
        impl Drop for Output {
            fn drop(&mut self) {
                *self.0.lock().unwrap() = true;
            }
        }
        let closed = Arc::new(Mutex::new(false));
        let (w, _r, stats) = jitter(RATE, 2);
        let feed = MicThread::spawn(RATE, 2, w, stats, Output(closed.clone())).unwrap();
        assert!(!*closed.lock().unwrap());
        drop(feed);
        assert!(*closed.lock().unwrap());
    }

    /// With the driver installed (`make engine` in docs/tests/virtual-mic/harness, which
    /// runs rd-mic-probe meanwhile): a controller's tone bursts through the host's real
    /// path. Bursts start at every whole second of host time as frames arrive, so the
    /// probe's onsets modulo one second are the delay from a frame reaching the host to
    /// its sound in Remote Display Microphone.
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "needs the Remote Display Microphone driver (docs/tests/virtual-mic/)"]
    fn plays_a_controllers_bursts_into_remote_display_microphone() {
        let seconds = std::env::var("RD_MIC_SECONDS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(14.0);
        let mut feed = open().expect("Remote Display Microphone isn't installed");
        send_tone(&mut feed, seconds, |t| t % 1_000_000_000 < 250_000_000);
        // Let the buffer drain.
        std::thread::sleep(Duration::from_millis(200));
        let played = feed.played() as f64 / ms(1000) as f64;
        let underruns = feed.stats.underruns.load(Ordering::Relaxed);
        let dropped = feed.stats.dropped.load(Ordering::Relaxed);
        eprintln!(
            "sent {seconds:.0} s; played {played:.2} s, {underruns} underruns, {dropped} samples dropped, {} frames not taken",
            feed.queue_drops
        );
        assert!(played > seconds - 0.5, "the device didn't play it all");
        assert_eq!(feed.queue_drops, 0);
        assert_eq!(dropped, 0);
        assert_eq!(underruns, 1, "only when the frames stopped");
    }
}
