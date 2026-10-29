// remotedisplay: a microphone forward's audio on the host (camera & audio forwarding spec,
// Host side › Microphone; decision 0021). The controller's Opus is decoded on a thread of
// its own, converted to the device's format and written into a jitter buffer that Remote
// Display Microphone's render callback reads on Core Audio's real-time thread.
//
// The buffer is the spec's, not AudioHandler's (whose ring holds 3 s, shrinks only every
// 12 s and sleeps in the callback): it starts playing once 40 ms are buffered, drops the
// oldest audio back to 40 ms when more than 100 ms are waiting, and on running dry plays
// silence until 40 ms are buffered again. The callback side takes no lock and allocates
// nothing.

use super::MicFeed;
use hbb_common::{
    log,
    message_proto::{AudioFormat, AudioFrame},
    ResultType,
};
use magnum_opus::{Channels, Decoder};
use ringbuf::{HeapConsumer, HeapProducer, HeapRb};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    mpsc, Arc,
};

/// Buffered before playing starts, and what is left after dropping the oldest.
const TARGET_MS: usize = 40;
/// More than this waiting and the oldest is dropped.
const MAX_MS: usize = 100;
/// Room for a burst; only fills up if the device stops reading.
const CAPACITY_MS: usize = 500;
/// Frames waiting for the decode thread; beyond this, new ones are dropped.
const QUEUE: usize = 50;

/// What the jitter buffer did, for the log when the forward stops.
#[derive(Default)]
pub(super) struct Stats {
    /// Times it ran dry and went back to buffering.
    underruns: AtomicU64,
    /// Samples dropped: the oldest when too much was waiting, the newest when full.
    dropped: AtomicU64,
    /// Samples the device has played.
    played: AtomicU64,
}

/// The decode thread's side of the jitter buffer.
pub(super) struct Writer {
    producer: HeapProducer<f32>,
    channels: usize,
    stats: Arc<Stats>,
}

/// The render callback's side of the jitter buffer.
pub(super) struct Reader {
    consumer: HeapConsumer<f32>,
    channels: usize,
    target: usize,
    max: usize,
    playing: bool,
    stats: Arc<Stats>,
}

/// A jitter buffer for interleaved audio at `rate` Hz with `channels` channels.
pub(super) fn jitter(rate: u32, channels: u16) -> (Writer, Reader, Arc<Stats>) {
    let channels = channels.max(1) as usize;
    let samples = |ms: usize| rate as usize * ms / 1000 * channels;
    let (producer, consumer) = HeapRb::<f32>::new(samples(CAPACITY_MS).max(channels)).split();
    let stats = Arc::new(Stats::default());
    (
        Writer {
            producer,
            channels,
            stats: stats.clone(),
        },
        Reader {
            consumer,
            channels,
            target: samples(TARGET_MS),
            max: samples(MAX_MS),
            playing: false,
            stats: stats.clone(),
        },
        stats,
    )
}

impl Writer {
    /// Whole frames only, so the channels stay in step. When full, the newest is dropped.
    pub(super) fn write(&mut self, samples: &[f32]) {
        let whole = samples.len() / self.channels * self.channels;
        let room = self.producer.free_len() / self.channels * self.channels;
        let n = whole.min(room);
        self.producer.push_slice(&samples[..n]);
        if n < samples.len() {
            self.stats
                .dropped
                .fetch_add((samples.len() - n) as u64, Ordering::Relaxed);
        }
    }
}

impl Reader {
    /// Fills one I/O cycle. Real-time: no lock, no allocation.
    pub(super) fn read(&mut self, out: &mut [f32]) {
        let waiting = self.consumer.len();
        if !self.playing {
            if waiting < self.target.max(1) {
                out.fill(0.0);
                return;
            }
            self.playing = true;
        }
        if waiting > self.max {
            let excess = (waiting - self.target) / self.channels * self.channels;
            let skipped = self.consumer.skip(excess);
            self.stats
                .dropped
                .fetch_add(skipped as u64, Ordering::Relaxed);
        }
        let n = self.consumer.pop_slice(out);
        self.stats.played.fetch_add(n as u64, Ordering::Relaxed);
        if n < out.len() {
            out[n..].fill(0.0);
            self.playing = false;
            self.stats.underruns.fetch_add(1, Ordering::Relaxed);
        }
    }
}

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
/// Audio's time stamps) `tone` accepts carry a 1 kHz tone at 0.3; the rest are silence.
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
        let pcm: Vec<f32> = (0..RATE as u64 / 100)
            .map(|i| {
                let t = now + i * 1_000_000_000 / RATE as u64;
                if tone(t) {
                    let phase = (t % 1_000_000_000) as f64 / 1e9 * 1000.0;
                    (0.3 * (2.0 * std::f64::consts::PI * phase).sin()) as f32
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
    use std::{
        sync::Mutex,
        time::{Duration, Instant},
    };

    const RATE: u32 = 48000;
    /// One I/O cycle of 480 stereo frames: 10 ms.
    const CYCLE: usize = 960;

    fn ms(ms: usize) -> usize {
        RATE as usize * ms / 1000 * 2
    }

    /// `ms` of stereo audio whose samples count up from `from`.
    fn ramp(from: usize, ms: usize) -> Vec<f32> {
        (from..from + self::ms(ms)).map(|i| i as f32).collect()
    }

    #[test]
    fn plays_silence_until_40_ms_are_buffered() {
        let (mut w, mut r, stats) = jitter(RATE, 2);
        let mut out = vec![1.0; CYCLE];
        w.write(&ramp(1, 30));
        r.read(&mut out);
        assert!(out.iter().all(|&s| s == 0.0), "30 ms isn't enough");
        w.write(&ramp(1 + ms(30), 10));
        r.read(&mut out);
        assert_eq!(out[0], 1.0, "starts from the oldest sample");
        assert_eq!(out[CYCLE - 1], CYCLE as f32);
        assert_eq!(stats.underruns.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn drops_the_oldest_back_to_40_ms_when_more_than_100_ms_wait() {
        let (mut w, mut r, stats) = jitter(RATE, 2);
        let mut out = vec![0.0; CYCLE];
        w.write(&ramp(0, 150));
        r.read(&mut out);
        // 110 ms of the oldest went; the cycle starts 40 ms before the end.
        assert_eq!(out[0], ms(110) as f32);
        assert_eq!(stats.dropped.load(Ordering::Relaxed), ms(110) as u64);
        assert_eq!(r.consumer.len(), ms(30));
    }

    #[test]
    fn running_dry_plays_silence_then_buffers_again() {
        let (mut w, mut r, stats) = jitter(RATE, 2);
        let mut out = vec![0.0; CYCLE];
        w.write(&ramp(1, 45));
        for _ in 0..4 {
            r.read(&mut out);
        }
        r.read(&mut out);
        assert_eq!(out[ms(5) - 1], ms(45) as f32, "the last 5 ms");
        assert!(out[ms(5)..].iter().all(|&s| s == 0.0), "then silence");
        assert_eq!(stats.underruns.load(Ordering::Relaxed), 1);
        w.write(&ramp(1, 20));
        r.read(&mut out);
        assert!(out.iter().all(|&s| s == 0.0), "waits for 40 ms again");
        assert_eq!(stats.underruns.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn a_full_buffer_drops_the_newest_in_whole_frames() {
        let (mut w, _r, stats) = jitter(RATE, 2);
        w.write(&ramp(0, CAPACITY_MS));
        w.write(&[1.0, 2.0, 3.0]);
        assert_eq!(stats.dropped.load(Ordering::Relaxed), 3);
        let (mut w, r, _) = jitter(RATE, 2);
        w.write(&[1.0, 2.0, 3.0]);
        assert_eq!(r.consumer.len(), 2, "half a frame isn't kept");
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
        while reader.consumer.len() < samples && Instant::now() < until {
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
        assert_eq!(r.consumer.len(), ms(100), "100 ms, as stereo");
        let mut out = vec![0.0; ms(100)];
        let mut r = r;
        r.consumer.pop_slice(&mut out);
        let peak = out.iter().fold(0f32, |m, s| m.max(s.abs()));
        assert!(peak > 0.1, "the tone came through: peak {peak}");
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
        let got = r.consumer.len() as i64;
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
        assert_eq!(r.consumer.len(), ms(10), "only the last frame");
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
