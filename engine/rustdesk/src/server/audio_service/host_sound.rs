// remotedisplay: where a Mac host's sound comes from (decision 0008, issue #4).
//
// With the `screencapturekit` feature, host sound is the Mac's system audio. It must
// never silently become the host's microphone: upstream falls back to the default input
// device when ScreenCaptureKit is unavailable or a named device is missing, which would
// send the room's audio to the controller. A voice call is the one case where a
// microphone is the point, and it keeps upstream's behaviour.

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Source {
    /// A voice call: the call's input device, or the default input if none is named.
    VoiceCall(String),
    /// The owner chose this input device (`audio-input`): that device or nothing.
    Named(String),
    /// The Mac's system audio.
    ScreenCaptureKit,
    /// No system audio available: send nothing rather than the microphone.
    Unavailable,
}

pub(super) fn source(voice_call: bool, audio_input: &str, screen_capture_kit: bool) -> Source {
    if voice_call {
        Source::VoiceCall(audio_input.to_owned())
    } else if !audio_input.is_empty() {
        Source::Named(audio_input.to_owned())
    } else if screen_capture_kit {
        Source::ScreenCaptureKit
    } else {
        Source::Unavailable
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_audio_by_default() {
        assert_eq!(source(false, "", true), Source::ScreenCaptureKit);
    }

    #[test]
    fn never_the_microphone_without_screen_capture_kit() {
        assert_eq!(source(false, "", false), Source::Unavailable);
    }

    #[test]
    fn owner_choice_is_kept_and_not_widened() {
        assert_eq!(
            source(false, "BlackHole 2ch", true),
            Source::Named("BlackHole 2ch".into())
        );
        assert_eq!(
            source(false, "BlackHole 2ch", false),
            Source::Named("BlackHole 2ch".into())
        );
    }

    #[test]
    fn voice_call_keeps_its_microphone() {
        assert_eq!(
            source(true, "MacBook Pro Microphone", true),
            Source::VoiceCall("MacBook Pro Microphone".into())
        );
        assert_eq!(source(true, "", false), Source::VoiceCall(String::new()));
    }
}

// The Phase 3 gate tests (docs/tests/system-sound). They need Screen Recording, so the
// harness runs them from their own app bundle rather than from `cargo test`.
#[cfg(all(test, feature = "screencapturekit"))]
mod capture {
    use crate::server::{connection::ConnInner, service::Service};
    use hbb_common::{
        message_proto::{message, misc},
        tokio::sync::mpsc,
    };
    use magnum_opus::{Channels, Decoder};
    use std::{
        f64::consts::PI,
        process::Command,
        sync::{
            atomic::{AtomicU64, Ordering},
            Arc,
        },
        time::{Duration, Instant},
    };

    const TONE_HZ: f64 = 1000.0;

    struct Heard {
        format: Option<(u32, u16)>,
        frames: usize,
        pcm: Vec<f32>,
    }

    /// Plays a 2 s tone through the default output.
    fn afplay() {
        let tone = std::env::temp_dir().join("rd-sound-probe-tone.wav");
        write_tone(&tone, 2.0).unwrap();
        Command::new("afplay").arg(&tone).status().ok();
        std::fs::remove_file(&tone).ok();
    }

    /// Subscribes the way a controller's connection does, runs `play` on a thread of its
    /// own after 1 s, and decodes what the controller would receive to mono.
    fn listen(play: impl FnOnce() + Send + 'static) -> Heard {
        let svc = super::super::new();
        let (tx, mut rx) = mpsc::unbounded_channel();
        svc.on_subscribe(ConnInner::new(1, Some(tx), None));

        let start = Instant::now();
        let mut play = Some(play);
        let mut player = None;
        let mut decoder = None;
        let mut heard = Heard {
            format: None,
            frames: 0,
            pcm: Vec::new(),
        };
        while start.elapsed() < Duration::from_secs(4) {
            if start.elapsed() > Duration::from_secs(1) {
                if let Some(play) = play.take() {
                    player = Some(std::thread::spawn(play));
                }
            }
            while let Ok((_, msg)) = rx.try_recv() {
                match &msg.union {
                    Some(message::Union::Misc(m)) => {
                        if let Some(misc::Union::AudioFormat(f)) = &m.union {
                            let channels = if f.channels > 1 {
                                Channels::Stereo
                            } else {
                                Channels::Mono
                            };
                            decoder = Some(Decoder::new(f.sample_rate, channels).unwrap());
                            heard.format = Some((f.sample_rate, f.channels as u16));
                        }
                    }
                    Some(message::Union::AudioFrame(frame)) => {
                        heard.frames += 1;
                        if let (Some(d), Some((_, ch))) = (decoder.as_mut(), heard.format) {
                            let ch = ch as usize;
                            let mut buffer = vec![0f32; 5760 * ch];
                            let n = d.decode_float(&frame.data, &mut buffer, false).unwrap();
                            heard.pcm.extend(
                                buffer[..n * ch]
                                    .chunks(ch)
                                    .map(|s| s.iter().sum::<f32>() / ch as f32),
                            );
                        }
                    }
                    _ => {}
                }
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        if let Some(player) = player {
            player.join().ok();
        }
        svc.join();
        heard
    }

    /// 48 kHz mono 16-bit PCM at a third of full scale.
    fn write_tone(path: &std::path::Path, seconds: f64) -> std::io::Result<()> {
        let rate = 48000u32;
        let samples = (rate as f64 * seconds) as u32;
        let mut wav = Vec::with_capacity(44 + samples as usize * 2);
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + samples * 2).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        for field in [
            16u32.to_le_bytes(),
            [1, 0, 1, 0],
            rate.to_le_bytes(),
            (rate * 2).to_le_bytes(),
            [2, 0, 16, 0],
        ] {
            wav.extend_from_slice(&field);
        }
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&(samples * 2).to_le_bytes());
        for i in 0..samples {
            let s = 0.33 * (2.0 * PI * TONE_HZ * i as f64 / rate as f64).sin();
            wav.extend_from_slice(&((s * i16::MAX as f64) as i16).to_le_bytes());
        }
        std::fs::write(path, wav)
    }

    /// 20 ms windows that are mostly the tone: Goertzel power at TONE_HZ against the
    /// window's energy (1.0 for a pure tone, near 0 for silence or speech).
    fn tone_windows(pcm: &[f32], rate: u32) -> usize {
        let n = rate as usize / 50;
        let k = 2.0 * (2.0 * PI * TONE_HZ / rate as f64).cos();
        pcm.chunks_exact(n)
            .filter(|w| {
                let (mut s1, mut s2, mut energy) = (0f64, 0f64, 0f64);
                for &x in w.iter() {
                    let s0 = x as f64 + k * s1 - s2;
                    s2 = s1;
                    s1 = s0;
                    energy += (x as f64).powi(2);
                }
                let power = s1 * s1 + s2 * s2 - k * s1 * s2;
                energy / n as f64 > 1e-6 && power / (energy * n as f64 / 2.0) > 0.5
            })
            .count()
    }

    #[test]
    #[ignore]
    fn controller_hears_system_sound() {
        let heard = listen(afplay);
        let tone = heard
            .format
            .map_or(0, |(rate, _)| tone_windows(&heard.pcm, rate));
        let peak = heard.pcm.iter().fold(0f32, |m, s| m.max(s.abs()));
        eprintln!(
            "format {:?}, {} frames, peak {:.3}, {} of 100 tone windows (20 ms)",
            heard.format, heard.frames, peak, tone
        );
        assert!(tone >= 50, "the controller would not hear the tone");
    }

    #[test]
    #[ignore]
    fn nothing_without_screen_recording() {
        let heard = listen(afplay);
        eprintln!("format {:?}, {} frames", heard.format, heard.frames);
        assert_eq!(heard.frames, 0, "audio was sent without ScreenCaptureKit");
    }

    /// A controller's microphone, played into Remote Display Microphone from this process
    /// as `remotedisplayd` plays it (decision 0021), must not come back in the host's
    /// sound, or the controller hears itself. Needs the driver (docs/tests/virtual-mic/)
    /// as well as Screen Recording.
    #[test]
    #[ignore]
    fn controller_never_hears_its_own_microphone() {
        use crate::server::device_forward::mic;
        let played = Arc::new(AtomicU64::new(0));
        let p = played.clone();
        let heard = listen(move || {
            let mut feed = mic::open().expect("Remote Display Microphone isn't installed");
            mic::send_tone(&mut feed, 2.0, |_| true);
            std::thread::sleep(Duration::from_millis(200));
            p.store(feed.played(), Ordering::Relaxed);
        });
        // The driver's format: 48 kHz stereo.
        let played = played.load(Ordering::Relaxed) as f64 / 96000.0;
        let tone = heard
            .format
            .map_or(0, |(rate, _)| tone_windows(&heard.pcm, rate));
        let peak = heard.pcm.iter().fold(0f32, |m, s| m.max(s.abs()));
        eprintln!(
            "played {:.2} s into Remote Display Microphone; format {:?}, {} frames, peak {:.3}, {} of 100 tone windows (20 ms)",
            played, heard.format, heard.frames, peak, tone
        );
        assert!(
            played > 1.5,
            "the tone didn't play into Remote Display Microphone"
        );
        assert!(
            heard.frames > 0,
            "nothing captured: is Screen Recording allowed?"
        );
        assert!(tone < 5, "the controller would hear its own microphone");
    }
}
