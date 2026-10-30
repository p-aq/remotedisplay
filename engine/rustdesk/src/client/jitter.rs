// remotedisplay: the jitter buffer for real-time audio playback (camera & audio forwarding
// spec, Host side › "The virtual-mic and speaker paths use a separate jitter buffer";
// decisions 0021 and 0029). The host plays a controller's microphone through it into Remote
// Display Microphone (src/server/device_forward/mic.rs), and every client plays the audio
// it receives through it (AudioHandler in src/client.rs), such as a Mac host's sound.
//
// It's the spec's, not upstream AudioHandler's (whose ring held 3 s, shrank only every 12 s
// and slept in the callback): it starts playing once 40 ms are buffered, drops the oldest
// audio back to 40 ms when more than 100 ms are waiting, and on running dry plays silence
// until 40 ms are buffered again. The reading side takes no lock and allocates nothing.

use ringbuf::{HeapConsumer, HeapProducer, HeapRb};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};

/// Buffered before playing starts, and what is left after dropping the oldest.
const TARGET_MS: usize = 40;
/// More than this waiting and the oldest is dropped.
const MAX_MS: usize = 100;
/// Room for a burst; only fills up if the device stops reading.
const CAPACITY_MS: usize = 500;

/// What the jitter buffer did, for the log when the forward stops.
#[derive(Default)]
pub(crate) struct Stats {
    /// Times it ran dry and went back to buffering.
    pub(crate) underruns: AtomicU64,
    /// Samples dropped: the oldest when too much was waiting, the newest when full.
    pub(crate) dropped: AtomicU64,
    /// Samples the device has played.
    pub(crate) played: AtomicU64,
}

/// The decode thread's side of the jitter buffer.
pub(crate) struct Writer {
    producer: HeapProducer<f32>,
    channels: usize,
    stats: Arc<Stats>,
}

/// The render callback's side of the jitter buffer.
pub(crate) struct Reader {
    consumer: HeapConsumer<f32>,
    channels: usize,
    target: usize,
    max: usize,
    playing: bool,
    stats: Arc<Stats>,
}

/// A jitter buffer for interleaved audio at `rate` Hz with `channels` channels.
pub(crate) fn jitter(rate: u32, channels: u16) -> (Writer, Reader, Arc<Stats>) {
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
    pub(crate) fn write(&mut self, samples: &[f32]) {
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
    pub(crate) fn read(&mut self, out: &mut [f32]) {
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

    /// Samples waiting to be played.
    #[cfg(test)]
    pub(crate) fn waiting(&self) -> usize {
        self.consumer.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        assert_eq!(r.waiting(), ms(30));
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
        assert_eq!(r.waiting(), 2, "half a frame isn't kept");
    }

    /// The client's playback through the Mac's default output: 3 s of silent 48 kHz
    /// stereo Opus, 10 ms at a time in real time, as a host's sound arrives. Silent, so
    /// nothing is heard. Needs an output device, so it's ignored by default.
    #[cfg(not(target_os = "linux"))]
    #[test]
    #[ignore]
    fn plays_received_audio_without_running_dry() {
        use crate::client::AudioHandler;
        use hbb_common::message_proto::{AudioFormat, AudioFrame};
        use std::time::{Duration, Instant};
        let mut handler = AudioHandler::default();
        handler.handle_format(AudioFormat {
            sample_rate: RATE,
            channels: 2,
            ..Default::default()
        });
        // Frames are dropped until the device's first cycle.
        std::thread::sleep(Duration::from_millis(300));
        let stats = handler.jitter_stats().expect("no output device");
        let mut encoder = magnum_opus::Encoder::new(
            RATE,
            magnum_opus::Channels::Stereo,
            magnum_opus::Application::LowDelay,
        )
        .unwrap();
        let frame = encoder.encode_vec_float(&vec![0f32; ms(10)], 4000).unwrap();
        let start = Instant::now();
        for i in 0..300u64 {
            let due = start + Duration::from_millis(10 * i);
            if let Some(wait) = due.checked_duration_since(Instant::now()) {
                std::thread::sleep(wait);
            }
            handler.handle_frame(AudioFrame {
                data: frame.clone().into(),
                ..Default::default()
            });
        }
        let underruns = stats.underruns.load(Ordering::Relaxed);
        let dropped = stats.dropped.load(Ordering::Relaxed);
        let played = stats.played.load(Ordering::Relaxed);
        println!(
            "{} samples played in {:?}, {} underruns, {} dropped",
            played,
            start.elapsed(),
            underruns,
            dropped
        );
        assert!(played > 0, "the device never played");
        assert_eq!(underruns, 0, "ran dry while fed in real time");
        assert_eq!(dropped, 0, "dropped while fed in real time");
    }
}
