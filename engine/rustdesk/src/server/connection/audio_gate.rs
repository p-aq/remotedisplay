// remotedisplay: when the host plays a controller's audio (decision 0007).
//
// Upstream plays any AudioFormat and AudioFrame a controller sends while that
// controller's `disable_audio` is off. Nobody has to accept anything, so any connected
// controller can play sound through the host, and turning the host's sound off on the
// controller also silences its microphone. The host accepts controller audio only during
// a voice call it accepted; Phase 2 adds an accepted microphone forward. `disable_audio`
// plays no part: it is about the host's sound going to the controller.

use hbb_common::log;

#[derive(Default)]
pub(super) struct AudioGate {
    /// The current stretch of dropped audio has been logged.
    warned: bool,
}

impl AudioGate {
    /// Whether to accept a controller's AudioFormat or AudioFrame now. Drops are logged
    /// once per stretch, not once per frame.
    pub(super) fn accepts(&mut self, voice_calling: bool) -> bool {
        if voice_calling {
            self.warned = false;
            return true;
        }
        if !self.warned {
            self.warned = true;
            log::warn!("Dropping the controller's audio: no voice call is active");
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drops_audio_nobody_accepted() {
        let mut gate = AudioGate::default();
        assert!(!gate.accepts(false));
        assert!(!gate.accepts(false));
    }

    #[test]
    fn plays_audio_during_an_accepted_call() {
        let mut gate = AudioGate::default();
        assert!(gate.accepts(true));
        assert!(gate.accepts(true));
    }

    #[test]
    fn stops_when_the_call_ends() {
        let mut gate = AudioGate::default();
        assert!(gate.accepts(true));
        assert!(!gate.accepts(false));
    }

    #[test]
    fn logs_once_per_stretch_of_dropped_audio() {
        let mut gate = AudioGate::default();
        gate.accepts(false);
        assert!(gate.warned);
        gate.accepts(true);
        assert!(!gate.warned, "a call in between starts a new stretch");
        gate.accepts(false);
        assert!(gate.warned);
    }
}
