//! remotedisplay: the controller's microphone access for microphone forwarding
//! (docs/specs/camera-audio-forwarding.md, Controller side; decision 0023). The work is in
//! `macos_mic_capture.mm`; this file wraps it, the way `macos_camera_capture.rs` wraps the
//! camera's.

use super::macos_camera_capture::Access;
use std::ffi::c_void;

extern "C" {
    fn MacMicAuthorizationStatus() -> i32;
    fn MacMicRequestAccess(done: extern "C" fn(*mut c_void, bool), ctx: *mut c_void);
}

/// The controller's microphone access, as macOS last answered.
pub fn access() -> Access {
    match unsafe { MacMicAuthorizationStatus() } {
        1 => Access::Restricted,
        2 => Access::Denied,
        3 => Access::Allowed,
        _ => Access::NotDetermined,
    }
}

/// Shows macOS's microphone prompt if the user hasn't answered it yet. `done` runs on
/// another thread with the answer.
pub fn request_access(done: impl FnOnce(bool) + Send + 'static) {
    extern "C" fn answered(ctx: *mut c_void, granted: bool) {
        let done = unsafe { Box::from_raw(ctx as *mut Box<dyn FnOnce(bool) + Send>) };
        done(granted);
    }
    let done: Box<Box<dyn FnOnce(bool) + Send>> = Box::new(Box::new(done));
    unsafe { MacMicRequestAccess(answered, Box::into_raw(done) as *mut c_void) };
}
