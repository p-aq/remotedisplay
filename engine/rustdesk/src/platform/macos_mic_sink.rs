//! remotedisplay: the host's side of microphone forwarding (docs/specs/camera-audio-forwarding.md,
//! Host side › Microphone; decisions 0013, 0015 and 0021): plays audio into Remote Display
//! Microphone through its driver's hidden feeder device. The work is in
//! `macos_mic_sink.mm`; this file wraps it. `src/server/device_forward/mic.rs` supplies the
//! audio from its jitter buffer.

use hbb_common::{bail, ResultType};
use std::{
    ffi::{c_void, CString},
    os::raw::c_char,
};

/// The driver's hidden, output-only device: BlackHole's `kDriver_Name "_2_UID"`, with the
/// driver name of `docs/tests/virtual-mic/harness/Makefile` (decision 0013).
pub const FEEDER_UID: &str = "RemoteDisplayMicrophone_2_UID";

type Render = Box<dyn FnMut(&mut [f32]) + Send>;

extern "C" {
    fn MacMicFeederFormat(uid: *const c_char, rate: *mut f64, channels: *mut u32) -> bool;
    fn MacMicSinkOpenDriver(
        uid: *const c_char,
        render: extern "C" fn(*mut c_void, *mut f32, u32, u32, f64, u64),
        ctx: *mut c_void,
        status: *mut i32,
    ) -> *mut c_void;
    fn MacMicSinkClose(sink: *mut c_void);
}

/// The feeder's sample rate and channel count, or None when the driver isn't installed.
pub fn feeder_format() -> Option<(u32, u16)> {
    let uid = CString::new(FEEDER_UID).ok()?;
    let (mut rate, mut channels) = (0f64, 0u32);
    if !unsafe { MacMicFeederFormat(uid.as_ptr(), &mut rate, &mut channels) } {
        return None;
    }
    if rate < 1.0 || channels == 0 {
        return None;
    }
    Some((rate as u32, channels.min(u16::MAX as u32) as u16))
}

/// On Core Audio's real-time thread: must not block or allocate.
extern "C" fn render(
    ctx: *mut c_void,
    out: *mut f32,
    frames: u32,
    channels: u32,
    _rate: f64,
    _host_time_ns: u64,
) {
    if ctx.is_null() || out.is_null() {
        return;
    }
    let render = unsafe { &mut *(ctx as *mut Render) };
    let out = unsafe { std::slice::from_raw_parts_mut(out, frames as usize * channels as usize) };
    render(out);
}

/// Playing into the feeder. `render` fills each I/O cycle's interleaved samples, in the
/// format [`feeder_format`] gave. Dropping it stops playing; Remote Display Microphone
/// then reads silence.
pub struct Sink {
    sink: *mut c_void,
    render: *mut Render,
}

// The sink is only closed, from whichever thread drops it.
unsafe impl Send for Sink {}

impl Sink {
    pub fn open(render: impl FnMut(&mut [f32]) + Send + 'static) -> ResultType<Sink> {
        let uid = CString::new(FEEDER_UID)?;
        let ctx: *mut Render = Box::into_raw(Box::new(Box::new(render)));
        let mut status = 0;
        let sink =
            unsafe { MacMicSinkOpenDriver(uid.as_ptr(), self::render, ctx as _, &mut status) };
        if sink.is_null() {
            drop(unsafe { Box::from_raw(ctx) });
            bail!(
                "Remote Display Microphone's feeder not available ({})",
                status
            );
        }
        Ok(Sink { sink, render: ctx })
    }
}

impl Drop for Sink {
    fn drop(&mut self) {
        unsafe {
            // The callback isn't called once this returns, so its state can go.
            MacMicSinkClose(self.sink);
            drop(Box::from_raw(self.render));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opening_fails_cleanly_without_the_driver() {
        if feeder_format().is_some() {
            return;
        }
        assert!(Sink::open(|out| out.fill(0.0)).is_err());
    }
}
