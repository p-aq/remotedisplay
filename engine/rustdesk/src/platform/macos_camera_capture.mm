// remotedisplay: the controller's camera for camera forwarding
// (docs/specs/camera-audio-forwarding.md, decisions 0004, 0005, 0006 and 0016).
// Captures with AVCaptureSession in NV12, encodes with VTCompressionSession and hands
// out H.264 Annex B, one access unit per call, with SPS and PPS in front of key frames.
// The encoder is the one measured in docs/tests/camera-extension/harness/camera_codec.mm.
// With --camera-test-pattern, a generated test card takes the camera's place (spec,
// Controller side › Testing without a camera): same encoder, same rules, no camera.
// Same shape and flags as macos.mm: extern "C" functions named Mac…, -std=c++17, no ARC.
// Called from macos_camera_capture.rs.

#import <AVFoundation/AVFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreText/CoreText.h>
#include <VideoToolbox/VideoToolbox.h>
#include <atomic>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <vector>

enum {
    kMacCameraOK = 0,
    kMacCameraNotAuthorized = 1,  // the user hasn't allowed camera access
    kMacCameraNoDevice = 2,       // no camera, or not the one asked for
    kMacCameraNoFormat = 3,       // no format within the host's limits
    kMacCameraSessionFailed = 4,  // AVCaptureSession refused the camera
    kMacCameraEncoderFailed = 5,  // no H.264 encoder
};

// The host rejects streams outside 16×16…1920×1080, in either orientation (decision 0016).
static bool WithinLimits(int width, int height) {
    int longSide = width > height ? width : height, shortSide = width > height ? height : width;
    return shortSide >= 16 && longSide <= 1920 && shortSide <= 1080;
}
// The camera extension's device (docs/tests/camera-extension/harness/CameraExtension):
// never offered for forwarding, or a host that is also a controller would loop.
static NSString* const kOurManufacturer = @"Remote Display";
static NSString* const kOurModel = @"Remote Display Camera";
static const uint8_t kStartCode[4] = {0, 0, 0, 1};
// The test card's camera ID and name; TEST_PATTERN_ID in macos_camera_capture.rs.
static const char* const kTestPatternID = "remotedisplay-test-pattern";
static const char* const kTestPatternName = "Test pattern";

typedef void (*MacCameraEncoded)(void* ctx, const uint8_t* annexB, size_t length, bool keyFrame, int64_t ptsUs);
typedef void (*MacCameraAccessDone)(void* ctx, bool granted);
typedef void (*MacCameraEach)(void* ctx, const char* uniqueID, const char* name);

typedef struct {
    int width, height, fps;  // what the encoder sends
    bool lowLatency;         // created with low-latency rate control
    bool requiredHardware;   // created with the hardware encoder required
    char encoderID[128];     // e.g. com.apple.videotoolbox.videoencoder.h264.rtvc
    char deviceID[256];
    char deviceName[256];
} MacCameraCaptureInfo;

typedef struct {
    uint64_t captured;    // frames the camera delivered
    uint64_t encoded;     // access units handed out
    uint64_t busy;        // dropped before encoding: the encoder still had a frame
    uint64_t skipped;     // dropped before encoding: starting, or the sender asked to skip
    uint64_t mismatched;  // dropped: not the size the encoder was made for
    uint64_t failed;      // the encoder refused or dropped a frame
} MacCameraCaptureStats;

struct MacCameraCapture;

@interface RemoteDisplayCameraOutput : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, assign) MacCameraCapture* capture;
@end

struct MacCameraCapture {
    AVCaptureSession* session = nil;
    dispatch_source_t timer = NULL;      // the test card's frame clock, instead of a session
    CVPixelBufferPoolRef pool = NULL;    // the test card's frames
    uint64_t cardFrames = 0;             // the test card's frame counter
    AVCaptureVideoDataOutput* output = nil;
    RemoteDisplayCameraOutput* delegate = nil;
    dispatch_queue_t queue = NULL;  // serial: frames, encode calls and bitrate changes
    VTCompressionSessionRef encoder = NULL;
    int width = 0, height = 0, fps = 30;
    MacCameraEncoded callback = NULL;
    void* ctx = NULL;
    std::atomic<bool> ready{false};      // set once the encoder exists
    std::atomic<bool> skipping{false};   // the sender's backlog is over 150 ms (decision 0006)
    std::atomic<bool> keyFrame{false};   // force one on the next encode
    std::atomic<int> inEncoder{0};       // the one-frame slot between capture and encoder
    std::atomic<uint64_t> captured{0}, encoded{0}, busy{0}, skipped{0}, mismatched{0}, failed{0};
    std::vector<uint8_t> avcc, annexB;   // reused; VideoToolbox calls back serially
};

static void CopyString(NSString* s, char* out, size_t size) {
    out[0] = 0;
    if (s) strlcpy(out, s.UTF8String ?: "", size);
}

static bool IsOurs(AVCaptureDevice* d) {
    return [d.manufacturer isEqualToString:kOurManufacturer] || [d.modelID isEqualToString:kOurModel];
}

// The Mac's cameras, built-in and external (USB, Continuity Camera, other apps' virtual
// cameras), without Remote Display Camera.
static NSArray<AVCaptureDevice*>* Cameras() {
    NSMutableArray* types = [NSMutableArray arrayWithObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
    if (@available(macOS 14.0, *)) {
        [types addObject:AVCaptureDeviceTypeExternal];
        [types addObject:AVCaptureDeviceTypeContinuityCamera];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [types addObject:AVCaptureDeviceTypeExternalUnknown];
#pragma clang diagnostic pop
    }
    AVCaptureDeviceDiscoverySession* discovery =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];
    NSMutableArray* cameras = [NSMutableArray array];
    for (AVCaptureDevice* d in discovery.devices)
        if (!IsOurs(d)) [cameras addObject:d];
    return cameras;
}

// The system's default camera unless that is ours, then the first other one.
static AVCaptureDevice* FindCamera(const char* uniqueID) {
    NSArray<AVCaptureDevice*>* cameras = Cameras();
    if (uniqueID && uniqueID[0]) {
        NSString* wanted = [NSString stringWithUTF8String:uniqueID];
        for (AVCaptureDevice* d in cameras)
            if ([d.uniqueID isEqualToString:wanted]) return d;
        return nil;
    }
    AVCaptureDevice* d = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (d && !IsOurs(d)) return d;
    return cameras.firstObject;
}

// The format closest in size to the request, within the host's limits, preferring one
// that reaches the requested frame rate. `duration` gets a frame duration the format
// supports (USB cameras often list fixed rates, and any other value throws), `rate` the
// frame rate it gives.
static AVCaptureDeviceFormat* PickFormat(AVCaptureDevice* d, int width, int height, int fps, CMTime* duration,
                                         double* rate) {
    AVCaptureDeviceFormat* best = nil;
    long bestArea = LONG_MAX;
    double bestShort = 1e9;
    for (AVCaptureDeviceFormat* f in d.formats) {
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
        if (!WithinLimits(dims.width, dims.height)) continue;
        // The range that comes closest to fps without going over it.
        AVFrameRateRange* range = nil;
        double reach = 0;
        for (AVFrameRateRange* r in f.videoSupportedFrameRateRanges) {
            double v = MIN((double)fps, r.maxFrameRate);
            if (!range || v > reach) {
                range = r;
                reach = v;
            }
        }
        if (!range || reach <= 0) continue;
        long area = labs((long)dims.width * dims.height - (long)width * height);
        double shortfall = fps - reach;
        if (area < bestArea || (area == bestArea && shortfall < bestShort)) {
            best = f;
            bestArea = area;
            bestShort = shortfall;
            if (range.maxFrameRate <= fps) {
                *duration = range.minFrameDuration;
                *rate = range.maxFrameRate;
            } else if (fps >= range.minFrameRate) {
                *duration = CMTimeMake(1, fps);
                *rate = fps;
            } else {
                *duration = range.maxFrameDuration;
                *rate = range.minFrameRate;
            }
        }
    }
    return best;
}

static CFNumberRef Int32(int32_t v) { return CFNumberCreate(NULL, kCFNumberSInt32Type, &v); }

static void SetInt(VTCompressionSessionRef session, CFStringRef key, int32_t v) {
    CFNumberRef n = Int32(v);
    VTSessionSetProperty(session, key, n);
    CFRelease(n);
}

static void SetDouble(VTCompressionSessionRef session, CFStringRef key, double v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &v);
    VTSessionSetProperty(session, key, n);
    CFRelease(n);
}

static OSStatus SetBitrate(VTCompressionSessionRef session, int bitrateKbps) {
    SetInt(session, kVTCompressionPropertyKey_AverageBitRate, bitrateKbps * 1000);
    // Cap one second of output at 1.5× the target, so a burst can't flood the link.
    int32_t bytes = (int32_t)(bitrateKbps * 1000 / 8 * 3 / 2);
    double seconds = 1.0;
    CFNumberRef nb = Int32(bytes);
    CFNumberRef ns = CFNumberCreate(NULL, kCFNumberDoubleType, &seconds);
    const void* values[] = {nb, ns};
    CFArrayRef limits = CFArrayCreate(NULL, values, 2, &kCFTypeArrayCallBacks);
    OSStatus err = VTSessionSetProperty(session, kVTCompressionPropertyKey_DataRateLimits, limits);
    CFRelease(limits);
    CFRelease(ns);
    CFRelease(nb);
    return err;
}

static bool IsKeyFrame(CMSampleBufferRef sample) {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (!attachments || CFArrayGetCount(attachments) == 0) return true;
    CFDictionaryRef a = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    CFBooleanRef notSync = (CFBooleanRef)CFDictionaryGetValue(a, kCMSampleAttachmentKey_NotSync);
    return !(notSync && CFBooleanGetValue(notSync));
}

// VideoToolbox emits AVCC: length-prefixed NAL units, parameter sets in the format
// description. Rewrite as Annex B, with SPS and PPS in front of key frames (decision 0005).
static void Encoded(void* refcon, void*, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    MacCameraCapture* c = (MacCameraCapture*)refcon;
    c->inEncoder--;
    if (status != noErr || !sample || (flags & kVTEncodeInfo_FrameDropped)) {
        c->failed++;
        return;
    }
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    if (!format || !block) {
        c->failed++;
        return;
    }
    bool key = IsKeyFrame(sample);
    std::vector<uint8_t>& out = c->annexB;
    out.clear();

    size_t paramCount = 0;
    int lengthSize = 4;
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, NULL, NULL, &paramCount, &lengthSize);
    if (key) {
        for (size_t i = 0; i < paramCount; i++) {
            const uint8_t* ps = NULL;
            size_t psSize = 0;
            if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &ps, &psSize, NULL, NULL) != noErr) continue;
            out.insert(out.end(), kStartCode, kStartCode + 4);
            out.insert(out.end(), ps, ps + psSize);
        }
    }

    size_t total = CMBlockBufferGetDataLength(block);
    std::vector<uint8_t>& avcc = c->avcc;
    avcc.resize(total);
    if (CMBlockBufferCopyDataBytes(block, 0, total, avcc.data()) != kCMBlockBufferNoErr) {
        c->failed++;
        return;
    }
    for (size_t pos = 0; pos + lengthSize <= total;) {
        size_t nalSize = 0;
        for (int i = 0; i < lengthSize; i++) nalSize = (nalSize << 8) | avcc[pos + i];
        pos += lengthSize;
        if (nalSize == 0 || pos + nalSize > total) break;
        out.insert(out.end(), kStartCode, kStartCode + 4);
        out.insert(out.end(), avcc.begin() + pos, avcc.begin() + pos + nalSize);
        pos += nalSize;
    }
    CMTime pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), 1000000,
                                    kCMTimeRoundingMethod_RoundHalfAwayFromZero);
    c->encoded++;
    c->callback(c->ctx, out.data(), out.size(), key, pts.value);
}

static OSStatus CreateSession(MacCameraCapture* c, bool lowLatency, bool requireHardware) {
    const void* keys[2];
    const void* values[2] = {kCFBooleanTrue, kCFBooleanTrue};
    CFIndex n = 0;
    if (lowLatency) {
        if (@available(macOS 11.3, *)) keys[n++] = kVTVideoEncoderSpecification_EnableLowLatencyRateControl;
        else return kVTCouldNotFindVideoEncoderErr;
    }
    if (requireHardware) keys[n++] = kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder;
    CFDictionaryRef spec = CFDictionaryCreate(NULL, keys, values, n, &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    OSStatus err = VTCompressionSessionCreate(NULL, c->width, c->height, kCMVideoCodecType_H264, spec, NULL, NULL,
                                              Encoded, c, &c->encoder);
    CFRelease(spec);
    return err;
}

// Decision 0016: low-latency rate control (Apple's real-time conferencing encoder) with
// the hardware encoder required, falling back step by step; real time, no frame
// reordering, a key frame at least every 2 s, bitrate capped at 1.5× per second.
static bool CreateEncoder(MacCameraCapture* c, int bitrateKbps, MacCameraCaptureInfo* info) {
    const bool tries[4][2] = {{true, true}, {true, false}, {false, true}, {false, false}};
    int used = -1;
    for (int i = 0; i < 4 && used < 0; i++)
        if (CreateSession(c, tries[i][0], tries[i][1]) == noErr) used = i;
    if (used < 0) return false;
    VTSessionSetProperty(c->encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(c->encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    SetInt(c->encoder, kVTCompressionPropertyKey_MaxKeyFrameInterval, 2 * c->fps);
    SetDouble(c->encoder, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2.0);
    SetInt(c->encoder, kVTCompressionPropertyKey_ExpectedFrameRate, c->fps);
    SetBitrate(c->encoder, bitrateKbps);
    VTCompressionSessionPrepareToEncodeFrames(c->encoder);
    info->lowLatency = tries[used][0];
    info->requiredHardware = tries[used][1];
    info->encoderID[0] = 0;
    CFStringRef id = NULL;
    if (VTSessionCopyProperty(c->encoder, kVTCompressionPropertyKey_EncoderID, NULL, &id) == noErr && id) {
        CFStringGetCString(id, info->encoderID, sizeof(info->encoderID), kCFStringEncodingUTF8);
        CFRelease(id);
    }
    return true;
}

// On the capture queue, for each frame. Frames are dropped here, before encoding, never
// after (decision 0006): while starting, while the sender skips, and while the encoder
// still has the previous frame.
static bool Admit(MacCameraCapture* c) {
    c->captured++;
    if (!c->ready.load(std::memory_order_acquire) || c->skipping) {
        c->skipped++;
        return false;
    }
    if (c->inEncoder > 0) {
        c->busy++;
        return false;
    }
    return true;
}

static void Encode(MacCameraCapture* c, CVPixelBufferRef frame, CMTime pts) {
    bool key = c->keyFrame.exchange(false);
    CFDictionaryRef props = NULL;
    if (key) {
        const void* k[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
        const void* v[] = {kCFBooleanTrue};
        props = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    c->inEncoder++;
    OSStatus err = VTCompressionSessionEncodeFrame(c->encoder, frame, pts, CMTimeMake(1, c->fps), props, NULL, NULL);
    if (props) CFRelease(props);
    if (err != noErr) {
        c->inEncoder--;
        c->failed++;
        if (key) c->keyFrame = true;
    }
}

static void OnFrame(MacCameraCapture* c, CMSampleBufferRef sample) {
    if (!Admit(c)) return;
    CVPixelBufferRef frame = CMSampleBufferGetImageBuffer(sample);
    if (!frame || (int)CVPixelBufferGetWidth(frame) != c->width || (int)CVPixelBufferGetHeight(frame) != c->height) {
        c->mismatched++;
        return;
    }
    Encode(c, frame, CMSampleBufferGetPresentationTimeStamp(sample));
}

// The test card: 75% colour bars, a box that sweeps across and back every 4 seconds, and
// a clock with milliseconds and a frame counter, so a frozen, late or jerky picture shows
// on the host at a glance.
static void DrawText(CGContextRef cg, const char* text, CGFloat size, CGFloat x, CGFloat y) {
    CTFontRef font = CTFontCreateWithName(CFSTR("Menlo"), size, NULL);
    CFStringRef string = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    const void* keys[] = {kCTFontAttributeName, kCTForegroundColorFromContextAttributeName};
    const void* values[] = {font, kCFBooleanTrue};
    CFDictionaryRef attributes =
        CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attributed = CFAttributedStringCreate(NULL, string, attributes);
    CTLineRef line = CTLineCreateWithAttributedString(attributed);
    // Centred on x.
    CGContextSetTextPosition(cg, x - CTLineGetTypographicBounds(line, NULL, NULL, NULL) / 2, y);
    CTLineDraw(line, cg);
    CFRelease(line);
    CFRelease(attributed);
    CFRelease(attributes);
    CFRelease(string);
    CFRelease(font);
}

static void DrawCard(CVPixelBufferRef buffer, uint64_t frame, int fps) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    const CGFloat w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), w, h, 8,
                                            CVPixelBufferGetBytesPerRow(buffer), space,
                                            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    if (cg) {
        // Bars over the top two thirds (Core Graphics counts from the bottom).
        static const CGFloat bars[7][3] = {{.75, .75, .75}, {.75, .75, 0}, {0, .75, .75}, {0, .75, 0},
                                           {.75, 0, .75},   {.75, 0, 0},   {0, 0, .75}};
        for (int i = 0; i < 7; i++) {
            CGContextSetRGBFillColor(cg, bars[i][0], bars[i][1], bars[i][2], 1);
            CGContextFillRect(cg, CGRectMake(floor(w * i / 7), h / 3, ceil(w / 7), h * 2 / 3));
        }
        // The bottom third: near black, with the sweeping box.
        CGContextSetRGBFillColor(cg, .06, .06, .06, 1);
        CGContextFillRect(cg, CGRectMake(0, 0, w, h / 3));
        const CGFloat box = h / 9, period = 4.0 * fps;
        const CGFloat phase = fmod((CGFloat)frame, period) / period;  // 0…1 over 4 s
        const CGFloat travel = (phase < .5 ? phase * 2 : (1 - phase) * 2) * (w - box);
        CGContextSetRGBFillColor(cg, 1, 1, 1, 1);
        CGContextFillRect(cg, CGRectMake(travel, h / 3 - box * 1.5, box, box));

        // The clock on a dark panel in the middle of the bars.
        struct timeval now;
        gettimeofday(&now, NULL);
        struct tm local;
        localtime_r(&now.tv_sec, &local);
        char clock[32], caption[96];
        snprintf(clock, sizeof(clock), "%02d:%02d:%02d.%03d", local.tm_hour, local.tm_min, local.tm_sec,
                 (int)(now.tv_usec / 1000));
        snprintf(caption, sizeof(caption), "Remote Display test pattern  ·  frame %llu  ·  %dx%d at %d fps",
                 (unsigned long long)frame, (int)w, (int)h, fps);
        CGContextSetRGBFillColor(cg, 0, 0, 0, .85);
        CGContextFillRect(cg, CGRectMake(w * .15, h * .5, w * .7, h * .3));
        CGContextSetRGBFillColor(cg, 1, 1, 1, 1);
        DrawText(cg, clock, h / 8, w / 2, h * .6);
        DrawText(cg, caption, h / 36, w / 2, h * .53);
        CGContextRelease(cg);
    }
    CGColorSpaceRelease(space);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

// On the capture queue, at the card's frame rate.
static void OnCardFrame(MacCameraCapture* c) {
    @autoreleasepool {
        uint64_t frame = c->cardFrames++;
        if (!Admit(c)) return;
        CVPixelBufferRef buffer = NULL;
        if (CVPixelBufferPoolCreatePixelBuffer(NULL, c->pool, &buffer) != kCVReturnSuccess) {
            c->failed++;
            return;
        }
        DrawCard(buffer, frame, c->fps);
        // Host time, like the camera's own timestamps.
        Encode(c, buffer, CMClockGetTime(CMClockGetHostTimeClock()));
        CVPixelBufferRelease(buffer);
    }
}

@implementation RemoteDisplayCameraOutput
- (void)captureOutput:(AVCaptureOutput*)output
    didOutputSampleBuffer:(CMSampleBufferRef)sample
           fromConnection:(AVCaptureConnection*)connection {
    OnFrame(self.capture, sample);
}
@end

// AVAuthorizationStatus: 0 not determined, 1 restricted, 2 denied, 3 authorized.
extern "C" int MacCameraAuthorizationStatus(void) {
    @autoreleasepool {
        return (int)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    }
}

// Shows macOS's camera prompt if the user hasn't answered yet; `done` runs on another
// thread with the answer.
extern "C" void MacCameraRequestAccess(MacCameraAccessDone done, void* ctx) {
    @autoreleasepool {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                 completionHandler:^(BOOL granted) {
                                   done(ctx, granted);
                                 }];
    }
}

// Calls `each` for every camera that can be forwarded, during this call.
extern "C" void MacCameraList(MacCameraEach each, void* ctx) {
    @autoreleasepool {
        for (AVCaptureDevice* d in Cameras()) each(ctx, d.uniqueID.UTF8String, d.localizedName.UTF8String);
    }
}

static void Release(MacCameraCapture* c) {
    if (c->session) {
        [c->session stopRunning];
        // The last frame callback has returned and no more are queued.
        dispatch_sync(c->queue, ^{});
    }
    if (c->timer) {
        dispatch_source_cancel(c->timer);
        dispatch_sync(c->queue, ^{});
        dispatch_release(c->timer);
    }
    c->ready = false;
    if (c->encoder) {
        VTCompressionSessionCompleteFrames(c->encoder, kCMTimeInvalid);
        VTCompressionSessionInvalidate(c->encoder);
        CFRelease(c->encoder);
    }
    [c->output setSampleBufferDelegate:nil queue:NULL];
    [c->output release];
    [c->delegate release];
    [c->session release];
    if (c->pool) CVPixelBufferPoolRelease(c->pool);
    if (c->queue) dispatch_release(c->queue);
    delete c;
}

// The test card at width×height (1280×720 outside the host's limits) and fps (30 outside
// 1–60). Needs no camera and no camera access.
static MacCameraCapture* StartTestPattern(int width, int height, int fps, int bitrateKbps, MacCameraEncoded callback,
                                          void* ctx, MacCameraCaptureInfo* info, int* error) {
    MacCameraCapture* c = new MacCameraCapture();
    c->callback = callback;
    c->ctx = ctx;
    bool fits = WithinLimits(width, height);
    c->width = fits ? width & ~1 : 1280;
    c->height = fits ? height & ~1 : 720;
    c->fps = fps >= 1 && fps <= 60 ? fps : 30;
    c->queue = dispatch_queue_create("app.remotedisplay.camera", DISPATCH_QUEUE_SERIAL);
    NSDictionary* attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey : @(c->width),
        (id)kCVPixelBufferHeightKey : @(c->height),
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    if (CVPixelBufferPoolCreate(NULL, NULL, (CFDictionaryRef)attributes, &c->pool) != kCVReturnSuccess) {
        Release(c);
        *error = kMacCameraSessionFailed;
        return NULL;
    }
    if (!CreateEncoder(c, bitrateKbps, info)) {
        Release(c);
        *error = kMacCameraEncoderFailed;
        return NULL;
    }
    strlcpy(info->deviceID, kTestPatternID, sizeof(info->deviceID));
    strlcpy(info->deviceName, kTestPatternName, sizeof(info->deviceName));
    info->width = c->width;
    info->height = c->height;
    info->fps = c->fps;
    c->keyFrame = true;
    c->ready.store(true, std::memory_order_release);
    c->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, c->queue);
    dispatch_source_set_timer(c->timer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / c->fps, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(c->timer, ^{
      OnCardFrame(c);
    });
    dispatch_resume(c->timer);
    return c;
}

// Opens the camera (`uniqueID`, or the default one when NULL or empty; kTestPatternID for
// the test card) as close as it offers to width×height at fps, and encodes it at bitrateKbps. `callback` runs on a
// VideoToolbox thread, one access unit at a time, until MacCameraCaptureStop returns;
// its buffer is valid only during the call. The first frame is a key frame. Returns
// NULL with `error` set on failure.
extern "C" MacCameraCapture* MacCameraCaptureStart(const char* uniqueID, int width, int height, int fps,
                                                   int bitrateKbps, MacCameraEncoded callback, void* ctx,
                                                   MacCameraCaptureInfo* info, int* error) {
    @autoreleasepool {
        memset(info, 0, sizeof(*info));
        *error = kMacCameraOK;
        if (uniqueID && strcmp(uniqueID, kTestPatternID) == 0)
            return StartTestPattern(width, height, fps, bitrateKbps, callback, ctx, info, error);
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] != AVAuthorizationStatusAuthorized) {
            *error = kMacCameraNotAuthorized;
            return NULL;
        }
        AVCaptureDevice* device = FindCamera(uniqueID);
        if (!device) {
            *error = kMacCameraNoDevice;
            return NULL;
        }
        CMTime duration = kCMTimeInvalid;
        double rate = 0;
        AVCaptureDeviceFormat* format = PickFormat(device, width, height, fps, &duration, &rate);
        if (!format) {
            *error = kMacCameraNoFormat;
            return NULL;
        }
        CopyString(device.uniqueID, info->deviceID, sizeof(info->deviceID));
        CopyString(device.localizedName, info->deviceName, sizeof(info->deviceName));

        MacCameraCapture* c = new MacCameraCapture();
        c->callback = callback;
        c->ctx = ctx;
        c->queue = dispatch_queue_create("app.remotedisplay.camera", DISPATCH_QUEUE_SERIAL);
        c->session = [[AVCaptureSession alloc] init];
        c->output = [[AVCaptureVideoDataOutput alloc] init];
        c->delegate = [[RemoteDisplayCameraOutput alloc] init];
        c->delegate.capture = c;
        c->output.alwaysDiscardsLateVideoFrames = YES;
        c->output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
        [c->output setSampleBufferDelegate:c->delegate queue:c->queue];

        NSError* inputError = nil;
        AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&inputError];
        bool started = false;
        @try {
            [c->session beginConfiguration];
            if (input && [c->session canAddInput:input] && [c->session canAddOutput:c->output]) {
                [c->session addInput:input];
                [c->session addOutput:c->output];
                started = true;
            }
            [c->session commitConfiguration];
            // macOS applies the session preset when it starts unless the device stays
            // locked for configuration until then.
            if (started && [device lockForConfiguration:nil]) {
                device.activeFormat = format;
                device.activeVideoMinFrameDuration = duration;
                [c->session startRunning];
                [device unlockForConfiguration];
            } else {
                started = false;
            }
        } @catch (NSException*) {
            started = false;
        }
        if (!started || !c->session.running) {
            Release(c);
            *error = kMacCameraSessionFailed;
            return NULL;
        }

        // Encode exactly what the camera now delivers.
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription);
        c->width = dims.width;
        c->height = dims.height;
        c->fps = MAX(1, (int)(rate + 0.5));
        if (!WithinLimits(c->width, c->height)) {
            Release(c);
            *error = kMacCameraNoFormat;
            return NULL;
        }
        if (!CreateEncoder(c, bitrateKbps, info)) {
            Release(c);
            *error = kMacCameraEncoderFailed;
            return NULL;
        }
        info->width = c->width;
        info->height = c->height;
        info->fps = c->fps;
        c->keyFrame = true;
        c->ready.store(true, std::memory_order_release);
        return c;
    }
}

// The next frame is a key frame (CameraControl.key_frame_request, or a frame the
// sender had to drop after encoding).
extern "C" void MacCameraCaptureRequestKeyFrame(MacCameraCapture* c) {
    if (c) c->keyFrame = true;
}

// Changes the running encoder's bitrate (CameraControl.target_bitrate_kbps).
extern "C" OSStatus MacCameraCaptureSetBitrate(MacCameraCapture* c, int bitrateKbps) {
    if (!c || bitrateKbps <= 0) return kVTParameterErr;
    __block OSStatus err = noErr;
    dispatch_sync(c->queue, ^{
      err = SetBitrate(c->encoder, bitrateKbps);
    });
    return err;
}

// While true, frames are dropped before encoding (the sender's backlog, decision 0006).
extern "C" void MacCameraCaptureSetSkipping(MacCameraCapture* c, bool skip) {
    if (c) c->skipping = skip;
}

extern "C" void MacCameraCaptureGetStats(MacCameraCapture* c, MacCameraCaptureStats* s) {
    memset(s, 0, sizeof(*s));
    if (!c) return;
    s->captured = c->captured;
    s->encoded = c->encoded;
    s->busy = c->busy;
    s->skipped = c->skipped;
    s->mismatched = c->mismatched;
    s->failed = c->failed;
}

// Closes the camera (its light goes off) and the encoder. No callback runs after this
// returns.
extern "C" void MacCameraCaptureStop(MacCameraCapture* c) {
    if (!c) return;
    @autoreleasepool {
        Release(c);
    }
}
