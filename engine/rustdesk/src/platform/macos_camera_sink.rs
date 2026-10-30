//! remotedisplay: the host's side of camera forwarding (docs/specs/camera-audio-forwarding.md,
//! Host side; decisions 0005, 0011 and 0016): decodes a controller's H.264, letterboxes
//! it to Remote Display Camera's format and feeds the camera extension's sink. The work
//! is in `macos_camera_sink.mm`; this file wraps it. `src/server/device_forward.rs` runs
//! it on a thread of its own.

use hbb_common::{bail, ResultType};
use std::{ffi::c_void, os::raw::c_int, ptr};

/// What became of one access unit (decision 0016).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// A new frame went to the sink.
    Decoded,
    /// Nothing to show until a key frame arrives.
    NeedKeyFrame,
    /// Malformed or outside the limits; dropped.
    Rejected,
}

extern "C" {
    fn MacCameraSinkStatus() -> c_int;
    fn MacCameraFeedOpen(fps: c_int, sink: bool, status: *mut i32) -> *mut c_void;
    fn MacCameraFeedPush(
        feed: *mut c_void,
        data: *const u8,
        length: usize,
        pts_us: i64,
        shown: *mut *mut c_void,
    ) -> c_int;
    fn MacCameraFeedDropped(feed: *mut c_void) -> u64;
    fn MacCameraFeedClose(feed: *mut c_void);
}

/// Whether Remote Display Camera and its sink stream exist, i.e. the camera extension
/// is installed and approved.
pub fn sink_present() -> bool {
    unsafe { MacCameraSinkStatus() == 0 }
}

/// A decoder feeding the sink. Dropping it stops the sink stream; the extension then
/// shows its card.
pub struct Feed(*mut c_void);

// Used from one thread at a time: the decode thread owns it.
unsafe impl Send for Feed {}

impl Feed {
    /// Starts the camera extension's sink stream; fails when the extension isn't there.
    pub fn open(fps: i32) -> ResultType<Feed> {
        Self::new(fps, true)
    }

    /// Decodes without a sink, for tests.
    #[cfg(test)]
    pub fn decode_only() -> Feed {
        Self::new(30, false).unwrap()
    }

    fn new(fps: i32, sink: bool) -> ResultType<Feed> {
        let mut status = 0;
        let feed = unsafe { MacCameraFeedOpen(fps, sink, &mut status) };
        if feed.is_null() {
            bail!("Remote Display Camera's sink not available ({})", status);
        }
        Ok(Feed(feed))
    }

    /// Decodes one Annex B access unit and enqueues it on the sink; never blocks.
    pub fn push(&mut self, annex_b: &[u8], pts_us: i64) -> Outcome {
        let outcome = unsafe {
            MacCameraFeedPush(
                self.0,
                annex_b.as_ptr(),
                annex_b.len(),
                pts_us,
                ptr::null_mut(),
            )
        };
        match outcome {
            0 => Outcome::Decoded,
            1 => Outcome::NeedKeyFrame,
            _ => Outcome::Rejected,
        }
    }

    /// Frames decoded but dropped because the extension hadn't drained the sink.
    pub fn dropped(&self) -> u64 {
        unsafe { MacCameraFeedDropped(self.0) }
    }
}

impl Drop for Feed {
    fn drop(&mut self) {
        unsafe { MacCameraFeedClose(self.0) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn waits_for_a_key_frame_and_rejects_garbage() {
        let mut feed = Feed::decode_only();
        assert_eq!(feed.push(&[], 0), Outcome::Rejected);
        assert_eq!(feed.push(&[1, 2, 3, 4, 5], 0), Outcome::Rejected);
        // A P slice before any parameter sets.
        assert_eq!(
            feed.push(&[0, 0, 0, 1, 0x41, 0x9a, 0x02], 0),
            Outcome::NeedKeyFrame
        );
        // Parameter sets that don't parse.
        assert_eq!(
            feed.push(
                &[0, 0, 0, 1, 0x67, 0xff, 0, 0, 0, 1, 0x68, 0xff, 0, 0, 0, 1, 0x65, 0x88],
                0
            ),
            Outcome::Rejected
        );
        assert_eq!(feed.dropped(), 0);
    }

    #[test]
    fn opening_the_sink_fails_cleanly_without_the_extension() {
        if sink_present() {
            return;
        }
        assert!(Feed::open(30).is_err());
    }
}
