// remotedisplay: the jitter buffer for real-time audio playback (camera & audio forwarding
// spec, Host side › "The virtual-mic and speaker paths use a separate jitter buffer";
// decisions 0021 and 0029). The host plays a controller's microphone through it into Remote
// Display Microphone (src/server/device_forward/mic.rs). Every client's AudioHandler, which
// plays the audio it receives such as a Mac host's sound, keeps to its limits on upstream's
// own playback buffer (AudioBuffer::keep_short in src/client.rs, the refill in
// audio_playback.rs).
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
pub(crate) const TARGET_MS: usize = 40;
/// More than this waiting and the oldest is dropped.
pub(crate) const MAX_MS: usize = 100;
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

    /// The speaker path keeps 40–100 ms on upstream's buffer (decision 0029).
    #[cfg(not(target_os = "linux"))]
    #[test]
    fn the_speaker_path_keeps_40_to_100_ms() {
        use ringbuf::ring_buffer::RbBase;
        let mut buffer = crate::client::AudioBuffer::default();
        buffer.resize(RATE as usize, 2);
        buffer.append_pcm(&ramp(0, 150));
        buffer.keep_short(2);
        assert_eq!(buffer.0.lock().unwrap().occupied_len(), ms(40));
        assert_eq!(buffer.3.load(Ordering::Relaxed), 1, "faded across the jump");
        buffer.append_pcm(&ramp(0, 50));
        buffer.keep_short(2);
        assert_eq!(buffer.0.lock().unwrap().occupied_len(), ms(90), "90 ms stays");
        assert_eq!(buffer.3.load(Ordering::Relaxed), 1);
    }

    /// Upstream's playback writer waits for 40 ms at the start and after running dry.
    #[cfg(not(target_os = "linux"))]
    #[test]
    fn the_speaker_path_waits_for_40_ms_after_running_dry() {
        use crate::client::audio_playback::{AudioPlaybackConfig, AudioPlaybackWriter};
        use ringbuf::Rb;
        use std::sync::{atomic::AtomicUsize, Mutex};
        let ring = Arc::new(Mutex::new(ringbuf::HeapRb::<f32>::new(ms(1000))));
        let config = AudioPlaybackConfig {
            sample_rate: RATE,
            channels: 2,
        };
        let mut writer =
            AudioPlaybackWriter::new(config, ring.clone(), Arc::new(AtomicUsize::new(0))).unwrap();
        writer.refill_after_running_dry(ms(TARGET_MS));
        let push = |ms: usize| ring.lock().unwrap().push_slice(&vec![0.5; self::ms(ms)]);
        let mut out = vec![1.0f32; CYCLE];
        push(30);
        writer.write_output(&mut out);
        assert!(out.iter().all(|&s| s == 0.0), "30 ms isn't enough");
        push(10);
        writer.write_output(&mut out);
        assert_eq!(out[CYCLE - 1], 0.5, "plays once 40 ms are there");
        for _ in 0..4 {
            writer.write_output(&mut out);
        }
        push(20);
        writer.write_output(&mut out);
        assert!(out.iter().all(|&s| s == 0.0), "ran dry: waits for 40 ms again");
        push(20);
        writer.write_output(&mut out);
        assert_eq!(out[CYCLE - 1], 0.5);
    }
}
