// rd-camera-feeder: pushes a moving test card into Remote Display Camera from a
// background process, the half of the Phase 0 gate that stands in for remotedisplayd.
//
// usage: rd-camera-feeder [--list] [--snapshot FILE.png] [--seconds N] [--fps N] [--size WxH] [--device NAME]
//
// --size other than 1280x720 checks that the extension drops mismatched frames
// (decision 0011): the placeholder should stay up.

#include "camera_sink.h"
#include "test_card.h"

#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <dispatch/dispatch.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void Usage(int code) {
    fprintf(code ? stderr : stdout,
            "usage: rd-camera-feeder [--list] [--snapshot FILE.png] [--seconds N] [--fps N] [--size WxH] [--device NAME]\n");
    exit(code);
}

// Writes the luma plane of one frame as a grey PNG, to check the card without an extension.
static int Snapshot(const char* path, int width, int height) {
    CVPixelBufferPoolRef pool = TestCardMakePool(width, height);
    CVPixelBufferRef pb = pool ? TestCardRender(pool, 1) : NULL;
    if (!pb) return 1;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddressOfPlane(pb, 0), width, height, 8,
                                             CVPixelBufferGetBytesPerRowOfPlane(pb, 0), gray, kCGImageAlphaNone);
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)path, strlen(path), false);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dest, image, NULL);
    bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CFRelease(url);
    CGImageRelease(image);
    CGContextRelease(ctx);
    CGColorSpaceRelease(gray);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(pb);
    CVPixelBufferPoolRelease(pool);
    printf("%s %s\n", ok ? "wrote" : "failed to write", path);
    return ok ? 0 : 1;
}

int main(int argc, char** argv) {
    const char* deviceName = "Remote Display Camera";
    const char* snapshot = NULL;
    double seconds = 0;
    int fps = 30, width = 1280, height = 720;
    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];
        bool hasValue = i + 1 < argc;
        if (!strcmp(a, "--list")) {
            MacCameraSinkLogDevices();
            return 0;
        } else if (!strcmp(a, "--snapshot") && hasValue) {
            snapshot = argv[++i];
        } else if (!strcmp(a, "--seconds") && hasValue) {
            seconds = atof(argv[++i]);
        } else if (!strcmp(a, "--fps") && hasValue) {
            fps = atoi(argv[++i]);
            if (fps < 1) fps = 1;
        } else if (!strcmp(a, "--size") && hasValue) {
            if (sscanf(argv[++i], "%dx%d", &width, &height) != 2 || width < 16 || height < 16) Usage(1);
        } else if (!strcmp(a, "--device") && hasValue) {
            deviceName = argv[++i];
        } else if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
            Usage(0);
        } else {
            Usage(1);
        }
    }
    if (snapshot) return Snapshot(snapshot, width, height);

    OSStatus status = noErr;
    MacCameraSink* sink = MacCameraSinkOpen(deviceName, 5, &status);
    if (!sink) {
        fprintf(stderr, "rd-camera-feeder: can't open the sink of \"%s\" (OSStatus %d); is the extension activated? "
                        "Try --list.\n", deviceName, (int)status);
        return 1;
    }
    CVPixelBufferPoolRef pool = TestCardMakePool(width, height);
    if (!pool) {
        fprintf(stderr, "rd-camera-feeder: can't create pixel buffers\n");
        return 1;
    }
    printf("feeding %s at %d×%d, %d fps; queue capacity %u\n", deviceName, width, height, fps,
           MacCameraSinkQueueCapacity(sink));
    fflush(stdout);

    __block int frame = 0, sent = 0, dropped = 0;
    __block CFAbsoluteTime lastReport = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime start = lastReport;
    void (^stop)(void) = ^{
        MacCameraSinkClose(sink);
        printf("stopped after %d frames: sent %d, dropped %d\n", frame, sent, dropped);
        exit(0);
    };

    signal(SIGINT, SIG_IGN);
    dispatch_source_t sigint = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigint, stop);
    dispatch_resume(sigint);

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / fps, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (seconds > 0 && now - start >= seconds) stop();
        frame++;
        CVPixelBufferRef pb = TestCardRender(pool, frame);
        if (!pb) return;
        int r = MacCameraSinkPush(sink, pb, fps);
        CVPixelBufferRelease(pb);
        if (r == kMacCameraSinkQueued) sent++;
        else dropped++;
        if (now - lastReport >= 5) {
            lastReport = now;
            printf("frame %d: sent %d, dropped %d\n", frame, sent, dropped);
            fflush(stdout);
        }
    });
    dispatch_resume(timer);
    dispatch_main();
}
