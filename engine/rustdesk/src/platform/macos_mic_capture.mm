// remotedisplay: the controller's microphone for microphone forwarding
// (docs/specs/camera-audio-forwarding.md, Controller side; decision 0023). macOS's
// microphone access, asked the way macos_camera_capture.mm asks for the camera's.
// Capture itself goes through cpal (src/client/device_forward/mic.rs), which would block
// in the privacy check if access hadn't been answered, so the forward checks first.
// Same shape and flags as macos.mm: extern "C" functions named Mac…, -std=c++17, no ARC.

#import <AVFoundation/AVFoundation.h>

typedef void (*MacMicAccessDone)(void* ctx, bool granted);

// AVAuthorizationStatus: 0 not determined, 1 restricted, 2 denied, 3 authorized.
extern "C" int MacMicAuthorizationStatus(void) {
    @autoreleasepool {
        return (int)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    }
}

// Shows macOS's microphone prompt if the user hasn't answered it; `done` runs on another
// thread with the answer.
extern "C" void MacMicRequestAccess(MacMicAccessDone done, void* ctx) {
    @autoreleasepool {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                                 completionHandler:^(BOOL granted) {
                                   done(ctx, granted);
                                 }];
    }
}
