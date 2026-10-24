// rd-camera-feeder: pushes a moving test card into Remote Display Camera from a
// background process, the half of the Phase 0 gate that stands in for remotedisplayd.
//
// usage: rd-camera-feeder [--list] [--snapshot FILE.png] [--seconds N] [--fps N] [--size WxH] [--device NAME]
//
// --size other than 1280x720 checks that the extension drops mismatched frames
// (decision 0011): the placeholder should stay up.

#include "camera_sink.h"

#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <ImageIO/ImageIO.h>
#include <dispatch/dispatch.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

static void Usage(int code) {
    fprintf(code ? stderr : stdout,
            "usage: rd-camera-feeder [--list] [--snapshot FILE.png] [--seconds N] [--fps N] [--size WxH] [--device NAME]\n");
    exit(code);
}

static CVPixelBufferPoolRef MakePool(int width, int height) {
    int32_t format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, w = width, h = height;
    CFNumberRef nf = CFNumberCreate(NULL, kCFNumberSInt32Type, &format);
    CFNumberRef nw = CFNumberCreate(NULL, kCFNumberSInt32Type, &w);
    CFNumberRef nh = CFNumberCreate(NULL, kCFNumberSInt32Type, &h);
    CFDictionaryRef surface = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    const void* keys[] = {kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferWidthKey, kCVPixelBufferHeightKey,
                          kCVPixelBufferIOSurfacePropertiesKey};
    const void* values[] = {nf, nw, nh, surface};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, attrs, &pool);
    CFRelease(attrs);
    CFRelease(surface);
    CFRelease(nh);
    CFRelease(nw);
    CFRelease(nf);
    return pool;
}

// Text centred horizontally at baseline y (origin bottom-left). `gray` in 0…1.
static void DrawText(CGContextRef ctx, const char* text, CGFloat y, CGFloat size, CGFloat gray) {
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, NULL);
    CGColorRef color = CGColorCreateGenericGray(gray, 1);
    const void* keys[] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
    const void* values[] = {font, color};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFStringRef str = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    CFAttributedStringRef astr = CFAttributedStringCreate(NULL, str, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(astr);
    double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CGContextSetTextPosition(ctx, (CGBitmapContextGetWidth(ctx) - width) / 2, y);
    CTLineDraw(line, ctx);
    CFRelease(line);
    CFRelease(astr);
    CFRelease(str);
    CFRelease(attrs);
    CFRelease(color);
    CFRelease(font);
}

// Fills chroma (interleaved CbCr, half resolution) for a rectangle given in luma pixels, origin top-left.
static void FillChroma(CVPixelBufferRef pb, int x, int y, int w, int h, uint8_t cb, uint8_t cr) {
    uint8_t* base = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    int pw = (int)CVPixelBufferGetWidthOfPlane(pb, 1), ph = (int)CVPixelBufferGetHeightOfPlane(pb, 1);
    for (int row = y / 2; row < (y + h) / 2 && row < ph; row++) {
        uint8_t* line = base + row * stride;
        for (int col = x / 2; col < (x + w) / 2 && col < pw; col++) {
            line[col * 2] = cb;
            line[col * 2 + 1] = cr;
        }
    }
}

// One frame: grey background, a moving bar (smooth motion shows dropped or repeated
// frames), a millisecond clock (for glass-to-glass latency), and red/green/blue bands
// (to check chroma survives). Video range, so grey levels stay within 16…235.
static CVPixelBufferRef RenderCard(CVPixelBufferPoolRef pool, int frame) {
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pb) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    int width = (int)CVPixelBufferGetWidth(pb), height = (int)CVPixelBufferGetHeight(pb);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddressOfPlane(pb, 0), width, height, 8,
                                             CVPixelBufferGetBytesPerRowOfPlane(pb, 0), gray, kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (ctx) {
        CGFloat h = height;
        CGContextSetGrayFillColor(ctx, 60.0 / 255, 1);
        CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
        CGContextSetGrayFillColor(ctx, 235.0 / 255, 1);
        CGContextFillRect(ctx, CGRectMake((frame * 8) % width, 0, 24, height));
        CGContextSetGrayFillColor(ctx, 120.0 / 255, 1);
        CGContextFillRect(ctx, CGRectMake(0, 0, width, h * 0.15));

        struct timeval tv;
        gettimeofday(&tv, NULL);
        struct tm tm;
        localtime_r(&tv.tv_sec, &tm);
        char clock[32], info[64];
        snprintf(clock, sizeof(clock), "%02d:%02d:%02d.%03d", tm.tm_hour, tm.tm_min, tm.tm_sec,
                 (int)(tv.tv_usec / 1000));
        snprintf(info, sizeof(info), "frame %d  ·  %d×%d", frame, width, height);
        DrawText(ctx, "Remote Display test card", h * 0.70, h * 0.07, 220.0 / 255);
        DrawText(ctx, clock, h * 0.50, h * 0.12, 235.0 / 255);
        DrawText(ctx, info, h * 0.36, h * 0.05, 190.0 / 255);
        CGContextRelease(ctx);
    }
    FillChroma(pb, 0, 0, width, height, 128, 128);
    int band = (int)(height * 0.15), third = width / 3;
    FillChroma(pb, 0, height - band, third, band, 90, 240);                      // red
    FillChroma(pb, third, height - band, third, band, 54, 34);                   // green
    FillChroma(pb, 2 * third, height - band, width - 2 * third, band, 240, 110);  // blue
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

// Writes the luma plane of one frame as a grey PNG, to check the card without an extension.
static int Snapshot(const char* path, int width, int height) {
    CVPixelBufferPoolRef pool = MakePool(width, height);
    CVPixelBufferRef pb = pool ? RenderCard(pool, 1) : NULL;
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
    CVPixelBufferPoolRef pool = MakePool(width, height);
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
        CVPixelBufferRef pb = RenderCard(pool, frame);
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
