// remotedisplay: the host's side of camera forwarding (docs/specs/camera-audio-forwarding.md,
// Host side; decisions 0005, 0011 and 0016). Decodes a controller's H.264 Annex B,
// letterboxes it to the format Remote Display Camera advertises and enqueues it on the
// camera extension's sink stream through the CoreMediaIO C API (sinks have no
// AVFoundation API).
//
// The decoder is the one measured and fuzzed in docs/tests/camera-extension/harness
// (camera_codec.mm), the sink code is that harness's camera_sink.mm; both are moved here
// unchanged in behaviour and kept internal, so only the MacCameraFeed… and
// MacCameraSink… functions below are exported. Same shape and flags as macos.mm:
// extern "C" functions named Mac…, -std=c++17, no ARC. Called from macos_camera_sink.rs.

#include <CoreMedia/CoreMedia.h>
#include <CoreMediaIO/CMIOHardware.h>
#include <VideoToolbox/VideoToolbox.h>
#include <string.h>
#include <string>
#include <vector>

enum {
    kMacCameraDecoded = 0,       // a new frame went to the sink
    kMacCameraNeedKeyFrame = 1,  // nothing to show until a key frame arrives; ask for one
    kMacCameraRejected = 2,      // malformed or out of limits; dropped, ask for a key frame
};

// Limits checked before anything reaches VideoToolbox (decision 0016): 16×16 to
// 1920×1080, in either orientation, so a portrait camera fits too.
static const size_t kMaxAccessUnitBytes = 4 * 1024 * 1024;
static const int kMinSide = 16, kMaxLongSide = 1920, kMaxShortSide = 1080;
// What the camera extension advertises (docs/tests/camera-extension/harness/CameraExtension).
static const char* const kDeviceName = "Remote Display Camera";
static const int kSinkWidth = 1280, kSinkHeight = 720;

namespace {

CFNumberRef Int32(int32_t v) { return CFNumberCreate(NULL, kCFNumberSInt32Type, &v); }

// ---- Decoder (camera_codec.mm) ----

struct Decoder {
    VTDecompressionSessionRef session = NULL;
    CMVideoFormatDescriptionRef format = NULL;
    std::vector<uint8_t> sps, pps;
    CVPixelBufferRef decoded = NULL;  // set by the output handler during a synchronous decode
};

struct Nal {
    const uint8_t* data;
    size_t size;
};

// Splits an Annex B buffer at 3- or 4-byte start codes. Empty NAL units are skipped.
std::vector<Nal> SplitAnnexB(const uint8_t* p, size_t n) {
    std::vector<Nal> nals;
    size_t i = 0, start = SIZE_MAX;
    while (i + 3 <= n) {
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) {
            if (start != SIZE_MAX) {
                size_t end = i;
                if (end > start && p[end - 1] == 0) end--;  // 4-byte start code
                if (end > start) nals.push_back({p + start, end - start});
            }
            i += 3;
            start = i;
        } else {
            i++;
        }
    }
    if (start != SIZE_MAX && start < n) nals.push_back({p + start, n - start});
    return nals;
}

void ResetSession(Decoder* dec) {
    if (dec->session) {
        VTDecompressionSessionInvalidate(dec->session);
        CFRelease(dec->session);
        dec->session = NULL;
    }
    if (dec->format) {
        CFRelease(dec->format);
        dec->format = NULL;
    }
}

// (Re)builds the format description and session from the current SPS and PPS, and
// checks the stream's size against the limits before any frame is decoded.
int BuildSession(Decoder* dec) {
    ResetSession(dec);
    const uint8_t* sets[] = {dec->sps.data(), dec->pps.data()};
    const size_t sizes[] = {dec->sps.size(), dec->pps.size()};
    if (CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, sets, sizes, 4, &dec->format) != noErr)
        return kMacCameraRejected;
    CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(dec->format);
    int longSide = d.width > d.height ? d.width : d.height, shortSide = d.width > d.height ? d.height : d.width;
    if (shortSide < kMinSide || longSide > kMaxLongSide || shortSide > kMaxShortSide) {
        ResetSession(dec);
        return kMacCameraRejected;
    }
    int32_t pixfmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef npf = Int32(pixfmt);
    CFDictionaryRef surface = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    const void* k[] = {kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferIOSurfacePropertiesKey};
    const void* v[] = {npf, surface};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    OSStatus err = VTDecompressionSessionCreate(NULL, dec->format, NULL, attrs, NULL, &dec->session);
    CFRelease(attrs);
    CFRelease(surface);
    CFRelease(npf);
    if (err != noErr) {
        ResetSession(dec);
        return kMacCameraRejected;
    }
    return kMacCameraDecoded;
}

// Decodes one Annex B access unit into an NV12 IOSurface-backed pixel buffer (+1).
int Decode(Decoder* dec, const uint8_t* data, size_t length, int64_t ptsUs, CVPixelBufferRef* out) {
    *out = NULL;
    if (!data || length == 0 || length > kMaxAccessUnitBytes) return kMacCameraRejected;

    std::vector<Nal> nals = SplitAnnexB(data, length);
    if (nals.empty()) return kMacCameraRejected;
    const Nal *sps = NULL, *pps = NULL;
    std::vector<const Nal*> slices;
    for (const Nal& n : nals) {
        switch (n.data[0] & 0x1f) {
            case 7: sps = &n; break;
            case 8: pps = &n; break;
            case 1:
            case 5: slices.push_back(&n); break;
            default: break;  // SEI, AUD, filler: not needed to decode
        }
    }
    // New or changed parameter sets come with key frames (decision 0005).
    if (sps && pps) {
        bool changed = dec->sps.size() != sps->size || memcmp(dec->sps.data(), sps->data, sps->size) != 0 ||
                       dec->pps.size() != pps->size || memcmp(dec->pps.data(), pps->data, pps->size) != 0;
        if (changed || !dec->session) {
            dec->sps.assign(sps->data, sps->data + sps->size);
            dec->pps.assign(pps->data, pps->data + pps->size);
            if (BuildSession(dec) != kMacCameraDecoded) {
                dec->sps.clear();
                dec->pps.clear();
                return kMacCameraRejected;
            }
        }
    }
    if (!dec->session) return kMacCameraNeedKeyFrame;
    if (slices.empty()) return kMacCameraRejected;

    // AVCC for VideoToolbox: each slice NAL behind a 4-byte big-endian length.
    size_t avccSize = 0;
    for (const Nal* n : slices) avccSize += 4 + n->size;
    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, avccSize, NULL, NULL, 0, avccSize,
                                           kCMBlockBufferAssureMemoryNowFlag, &block) != kCMBlockBufferNoErr)
        return kMacCameraRejected;
    size_t offset = 0;
    for (const Nal* n : slices) {
        uint8_t len[4] = {(uint8_t)(n->size >> 24), (uint8_t)(n->size >> 16), (uint8_t)(n->size >> 8),
                          (uint8_t)n->size};
        CMBlockBufferReplaceDataBytes(len, block, offset, 4);
        CMBlockBufferReplaceDataBytes(n->data, block, offset + 4, n->size);
        offset += 4 + n->size;
    }
    CMSampleBufferRef sample = NULL;
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake(ptsUs, 1000000), kCMTimeInvalid};
    OSStatus err = CMSampleBufferCreateReady(NULL, block, dec->format, 1, 1, &timing, 1, &avccSize, &sample);
    CFRelease(block);
    if (err != noErr) return kMacCameraRejected;

    // Synchronous: without kVTDecodeFrame_EnableAsynchronousDecompression the handler
    // runs before DecodeFrame returns.
    Decoder* d = dec;
    __block OSStatus decodeStatus = noErr;
    err = VTDecompressionSessionDecodeFrameWithOutputHandler(
        dec->session, sample, 0, NULL, ^(OSStatus s, VTDecodeInfoFlags, CVImageBufferRef image, CMTime, CMTime) {
          decodeStatus = s;
          if (s == noErr && image) d->decoded = CVPixelBufferRetain(image);
        });
    CFRelease(sample);
    CVPixelBufferRef image = dec->decoded;
    dec->decoded = NULL;
    if (err != noErr || decodeStatus != noErr || !image) {
        if (image) CVPixelBufferRelease(image);
        // A broken reference chain only heals at the next key frame.
        return err == kVTVideoDecoderBadDataErr || decodeStatus == kVTVideoDecoderBadDataErr ? kMacCameraRejected
                                                                                               : kMacCameraNeedKeyFrame;
    }
    *out = image;
    return kMacCameraDecoded;
}

// ---- Sink (camera_sink.mm) ----

CMIOObjectPropertyAddress Address(CMIOObjectPropertySelector selector) {
    return {selector, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
}

std::vector<CMIOObjectID> ObjectList(CMIOObjectID object, CMIOObjectPropertySelector selector) {
    CMIOObjectPropertyAddress addr = Address(selector);
    UInt32 size = 0;
    if (CMIOObjectGetPropertyDataSize(object, &addr, 0, NULL, &size) != noErr || size == 0) return {};
    std::vector<CMIOObjectID> ids(size / sizeof(CMIOObjectID));
    UInt32 used = 0;
    if (CMIOObjectGetPropertyData(object, &addr, 0, NULL, size, &used, ids.data()) != noErr) return {};
    ids.resize(used / sizeof(CMIOObjectID));
    return ids;
}

std::string StringProperty(CMIOObjectID object, CMIOObjectPropertySelector selector) {
    CMIOObjectPropertyAddress addr = Address(selector);
    CFStringRef value = NULL;
    UInt32 used = 0;
    if (CMIOObjectGetPropertyData(object, &addr, 0, NULL, sizeof(value), &used, &value) != noErr || !value)
        return "";
    char buf[512];
    std::string out;
    if (CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8)) out = buf;
    CFRelease(value);
    return out;
}

bool HasSuffix(const std::string& s, const char* suffix) {
    size_t n = strlen(suffix);
    return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

bool FindSink(CMIOObjectID* device, CMIOStreamID* stream) {
    for (CMIOObjectID d : ObjectList(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices)) {
        if (StringProperty(d, kCMIOObjectPropertyName) != kDeviceName) continue;
        std::vector<CMIOObjectID> streams = ObjectList(d, kCMIODevicePropertyStreams);
        // The extension names its sink "<device> Sink"; fall back to the second
        // stream, the order the extension adds them in.
        for (CMIOObjectID s : streams) {
            if (HasSuffix(StringProperty(s, kCMIOObjectPropertyName), " Sink")) {
                *device = d;
                *stream = s;
                return true;
            }
        }
        if (streams.size() > 1) {
            *device = d;
            *stream = streams[1];
            return true;
        }
    }
    return false;
}

void QueueAltered(CMIOStreamID, void*, void*) {}

}  // namespace

struct MacCameraFeed {
    Decoder decoder;
    VTPixelTransferSessionRef transfer = NULL;
    CVPixelBufferPoolRef pool = NULL;  // sink-sized NV12 buffers for letterboxed frames
    int fps = 30;
    // The sink; none when decoding only (the harness's tests).
    CMIOObjectID device = 0;
    CMIOStreamID stream = 0;
    CMSimpleQueueRef queue = NULL;
    uint64_t dropped = 0;  // decoded, but the extension hadn't drained the sink yet
};

static CVPixelBufferPoolRef MakePool(int width, int height) {
    CFNumberRef w = Int32(width), h = Int32(height), f = Int32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    CFDictionaryRef surface = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    const void* k[] = {kCVPixelBufferWidthKey, kCVPixelBufferHeightKey, kCVPixelBufferPixelFormatTypeKey,
                       kCVPixelBufferIOSurfacePropertiesKey};
    const void* v[] = {w, h, f, surface};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, k, v, 4, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, attrs, &pool);
    CFRelease(attrs);
    CFRelease(surface);
    CFRelease(f);
    CFRelease(h);
    CFRelease(w);
    return pool;
}

// Scales a frame of any other size into the sink's format, keeping its aspect ratio
// (spec: a 1080p or portrait camera never breaks the stream). +1, or NULL.
static CVPixelBufferRef Letterbox(MacCameraFeed* feed, CVPixelBufferRef frame) {
    if ((int)CVPixelBufferGetWidth(frame) == kSinkWidth && (int)CVPixelBufferGetHeight(frame) == kSinkHeight)
        return CVPixelBufferRetain(frame);
    if (!feed->transfer) {
        if (VTPixelTransferSessionCreate(NULL, &feed->transfer) != noErr) return NULL;
        VTSessionSetProperty(feed->transfer, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Letterbox);
    }
    if (!feed->pool && !(feed->pool = MakePool(kSinkWidth, kSinkHeight))) return NULL;
    CVPixelBufferRef out = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, feed->pool, &out) != kCVReturnSuccess) return NULL;
    if (VTPixelTransferSessionTransferImage(feed->transfer, frame, out) != noErr) {
        CVPixelBufferRelease(out);
        return NULL;
    }
    return out;
}

static void Enqueue(MacCameraFeed* feed, CVPixelBufferRef frame) {
    // Drop rather than queue latency: the extension drains the sink continuously.
    if (CMSimpleQueueGetCount(feed->queue) >= CMSimpleQueueGetCapacity(feed->queue)) {
        feed->dropped++;
        return;
    }
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, frame, &format) != noErr) return;
    CMSampleTimingInfo timing = {CMTimeMake(1, feed->fps), CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
    CMSampleBufferRef sample = NULL;
    OSStatus err = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, frame, format, &timing, &sample);
    CFRelease(format);
    if (err != noErr || !sample) return;
    // The queue takes this reference; CoreMediaIO releases it once the extension consumes it.
    if (CMSimpleQueueEnqueue(feed->queue, sample) != noErr) {
        CFRelease(sample);
        feed->dropped++;
    }
}

// 0 when Remote Display Camera and its sink stream exist, 1 when they don't.
extern "C" int MacCameraSinkStatus(void) {
    CMIOObjectID device = 0;
    CMIOStreamID stream = 0;
    return FindSink(&device, &stream) ? 0 : 1;
}

// Opens a feed for a controller's camera at fps. With `sink`, starts the camera
// extension's sink stream and fails when it isn't there; without, only decodes (tests).
extern "C" MacCameraFeed* MacCameraFeedOpen(int fps, bool sink, OSStatus* status) {
    MacCameraFeed* feed = new MacCameraFeed();
    feed->fps = fps > 0 && fps <= 60 ? fps : 30;
    *status = noErr;
    if (!sink) return feed;
    if (!FindSink(&feed->device, &feed->stream)) {
        *status = kCMIOHardwareBadDeviceError;
        delete feed;
        return NULL;
    }
    OSStatus err = CMIOStreamCopyBufferQueue(feed->stream, QueueAltered, NULL, &feed->queue);
    if (err == noErr && feed->queue) err = CMIODeviceStartStream(feed->device, feed->stream);
    if (err != noErr || !feed->queue) {
        if (feed->queue) CFRelease(feed->queue);
        *status = err ? err : kCMIOHardwareUnspecifiedError;
        delete feed;
        return NULL;
    }
    return feed;
}

// Decodes one Annex B access unit and, with a sink, enqueues it letterboxed to the
// sink's format; never blocks. Returns kMacCameraDecoded, kMacCameraNeedKeyFrame or
// kMacCameraRejected (decision 0016). `shown`, if not NULL, gets the frame the sink
// would get (+1), for tests.
extern "C" int MacCameraFeedPush(MacCameraFeed* feed, const uint8_t* data, size_t length, int64_t ptsUs,
                                 CVPixelBufferRef* shown) {
    if (shown) *shown = NULL;
    if (!feed) return kMacCameraRejected;
    CVPixelBufferRef decoded = NULL;
    int outcome = Decode(&feed->decoder, data, length, ptsUs, &decoded);
    if (outcome != kMacCameraDecoded) return outcome;
    CVPixelBufferRef frame = Letterbox(feed, decoded);
    CVPixelBufferRelease(decoded);
    if (!frame) return kMacCameraDecoded;
    if (feed->queue) Enqueue(feed, frame);
    if (shown)
        *shown = frame;
    else
        CVPixelBufferRelease(frame);
    return kMacCameraDecoded;
}

extern "C" uint64_t MacCameraFeedDropped(MacCameraFeed* feed) { return feed ? feed->dropped : 0; }

// Stops the sink stream (the extension then shows its card, decision 0011) and frees
// the decoder.
extern "C" void MacCameraFeedClose(MacCameraFeed* feed) {
    if (!feed) return;
    if (feed->queue) {
        CMIODeviceStopStream(feed->device, feed->stream);
        CFRelease(feed->queue);
    }
    ResetSession(&feed->decoder);
    if (feed->transfer) {
        VTPixelTransferSessionInvalidate(feed->transfer);
        CFRelease(feed->transfer);
    }
    if (feed->pool) CVPixelBufferPoolRelease(feed->pool);
    delete feed;
}
