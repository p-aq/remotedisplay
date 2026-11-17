// H.264 encode and decode for camera forwarding; see camera_codec.h.
// Same shape and flags as src/platform/macos.mm: extern "C" functions named Mac…,
// -std=c++17, no ARC.

#include "camera_codec.h"

#include <CoreMedia/CoreMedia.h>
#include <VideoToolbox/VideoToolbox.h>
#include <string.h>
#include <vector>

static const uint8_t kStartCode[4] = {0, 0, 0, 1};

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

// ---- Encoder ----

struct MacCameraEncoder {
    VTCompressionSessionRef session = NULL;
    MacCameraEncoded callback = NULL;
    void* ctx = NULL;
    int fps = 30;
    std::vector<uint8_t> scratch;  // reused Annex B output; VT calls back serially
};

static bool IsKeyFrame(CMSampleBufferRef sample) {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (!attachments || CFArrayGetCount(attachments) == 0) return true;
    CFDictionaryRef a = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    CFBooleanRef notSync = (CFBooleanRef)CFDictionaryGetValue(a, kCMSampleAttachmentKey_NotSync);
    return !(notSync && CFBooleanGetValue(notSync));
}

// VideoToolbox emits AVCC: length-prefixed NAL units, parameter sets in the format
// description. Rewrite as Annex B, with SPS and PPS in front of key frames.
static void EncodedFrame(void* refcon, void*, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    MacCameraEncoder* enc = (MacCameraEncoder*)refcon;
    if (status != noErr || !sample || (flags & kVTEncodeInfo_FrameDropped)) return;
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    if (!format || !block) return;
    bool key = IsKeyFrame(sample);
    std::vector<uint8_t>& out = enc->scratch;
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
    std::vector<uint8_t> avcc(total);
    if (CMBlockBufferCopyDataBytes(block, 0, total, avcc.data()) != kCMBlockBufferNoErr) return;
    for (size_t pos = 0; pos + lengthSize <= total;) {
        size_t nalSize = 0;
        for (int i = 0; i < lengthSize; i++) nalSize = (nalSize << 8) | avcc[pos + i];
        pos += lengthSize;
        if (nalSize == 0 || pos + nalSize > total) break;
        out.insert(out.end(), kStartCode, kStartCode + 4);
        out.insert(out.end(), avcc.begin() + pos, avcc.begin() + pos + nalSize);
        pos += nalSize;
    }
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    enc->callback(enc->ctx, out.data(), out.size(), key, (int64_t)(CMTimeGetSeconds(pts) * 1e6));
}

static OSStatus CreateSession(MacCameraEncoder* enc, int width, int height, bool lowLatency, bool requireHardware) {
    const void* keys[2];
    const void* values[2] = {kCFBooleanTrue, kCFBooleanTrue};
    CFIndex n = 0;
    if (lowLatency) keys[n++] = kVTVideoEncoderSpecification_EnableLowLatencyRateControl;
    if (requireHardware) keys[n++] = kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder;
    CFDictionaryRef spec = CFDictionaryCreate(NULL, keys, values, n, &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    OSStatus err = VTCompressionSessionCreate(NULL, width, height, kCMVideoCodecType_H264, spec, NULL, NULL,
                                              EncodedFrame, enc, &enc->session);
    CFRelease(spec);
    return err;
}

extern "C" MacCameraEncoder* MacCameraEncoderCreate(int width, int height, int fps, int bitrateKbps,
                                                    double keyIntervalSeconds, bool lowLatency,
                                                    MacCameraEncoded callback, void* ctx, MacCameraEncoderInfo* info,
                                                    OSStatus* status) {
    MacCameraEncoder* enc = new MacCameraEncoder();
    enc->callback = callback;
    enc->ctx = ctx;
    enc->fps = fps;

    // Low-latency rate control (macOS 11.3+) selects Apple's real-time video
    // conferencing encoder: one frame in, one frame out, key frames on demand. It doesn't
    // report UsingHardwareAcceleratedVideoEncoder, so require hardware up front instead,
    // which keeps VideoToolbox off its software variant. Fall back step by step.
    const bool tries[4][2] = {{lowLatency, true}, {lowLatency, false}, {false, true}, {false, false}};
    OSStatus err = kVTCouldNotFindVideoEncoderErr;
    int used = -1;
    for (int i = 0; i < 4 && err != noErr; i++)
        if ((err = CreateSession(enc, width, height, tries[i][0], tries[i][1])) == noErr) used = i;
    if (err != noErr) {
        if (status) *status = err;
        delete enc;
        return NULL;
    }
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    SetInt(enc->session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (int32_t)(keyIntervalSeconds * fps));
    SetDouble(enc->session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyIntervalSeconds);
    SetInt(enc->session, kVTCompressionPropertyKey_ExpectedFrameRate, fps);
    MacCameraEncoderSetBitrate(enc, bitrateKbps);
    VTCompressionSessionPrepareToEncodeFrames(enc->session);

    if (info) {
        info->lowLatency = tries[used][0];
        info->requiredHardware = tries[used][1];
        info->encoderID[0] = 0;
        CFStringRef id = NULL;
        if (VTSessionCopyProperty(enc->session, kVTCompressionPropertyKey_EncoderID, NULL, &id) == noErr && id) {
            CFStringGetCString(id, info->encoderID, sizeof(info->encoderID), kCFStringEncodingUTF8);
            CFRelease(id);
        }
    }
    if (status) *status = noErr;
    return enc;
}

extern "C" OSStatus MacCameraEncoderEncode(MacCameraEncoder* enc, CVPixelBufferRef frame, int64_t ptsUs,
                                           bool forceKeyFrame) {
    if (!enc || !frame) return kVTParameterErr;
    CFDictionaryRef props = NULL;
    if (forceKeyFrame) {
        const void* k[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
        const void* v[] = {kCFBooleanTrue};
        props = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    OSStatus err = VTCompressionSessionEncodeFrame(enc->session, frame, CMTimeMake(ptsUs, 1000000),
                                                   CMTimeMake(1, enc->fps), props, NULL, NULL);
    if (props) CFRelease(props);
    return err;
}

extern "C" OSStatus MacCameraEncoderSetBitrate(MacCameraEncoder* enc, int bitrateKbps) {
    if (!enc) return kVTParameterErr;
    SetInt(enc->session, kVTCompressionPropertyKey_AverageBitRate, bitrateKbps * 1000);
    // Cap one second of output at 1.5× the target, so a burst can't flood the link.
    int32_t bytes = (int32_t)(bitrateKbps * 1000 / 8 * 3 / 2);
    double seconds = 1.0;
    CFNumberRef nb = Int32(bytes);
    CFNumberRef ns = CFNumberCreate(NULL, kCFNumberDoubleType, &seconds);
    const void* values[] = {nb, ns};
    CFArrayRef limits = CFArrayCreate(NULL, values, 2, &kCFTypeArrayCallBacks);
    OSStatus err = VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_DataRateLimits, limits);
    CFRelease(limits);
    CFRelease(ns);
    CFRelease(nb);
    return err;
}

extern "C" void MacCameraEncoderDestroy(MacCameraEncoder* enc) {
    if (!enc) return;
    if (enc->session) {
        VTCompressionSessionCompleteFrames(enc->session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(enc->session);
        CFRelease(enc->session);
    }
    delete enc;
}

// ---- Decoder ----

struct MacCameraDecoder {
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
static std::vector<Nal> SplitAnnexB(const uint8_t* p, size_t n) {
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

static void ResetSession(MacCameraDecoder* dec) {
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
static int BuildSession(MacCameraDecoder* dec) {
    ResetSession(dec);
    const uint8_t* sets[] = {dec->sps.data(), dec->pps.data()};
    const size_t sizes[] = {dec->sps.size(), dec->pps.size()};
    if (CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, sets, sizes, 4, &dec->format) != noErr)
        return kMacCameraRejected;
    CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(dec->format);
    if (d.width < 16 || d.height < 16 || d.width > kMacCameraMaxWidth || d.height > kMacCameraMaxHeight) {
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

extern "C" MacCameraDecoder* MacCameraDecoderCreate(OSStatus* status) {
    if (status) *status = noErr;
    return new MacCameraDecoder();
}

extern "C" int MacCameraDecoderDecode(MacCameraDecoder* dec, const uint8_t* data, size_t length, int64_t ptsUs,
                                      CVPixelBufferRef* out) {
    if (out) *out = NULL;
    if (!dec || !data || length == 0 || length > kMacCameraMaxAccessUnitBytes) return kMacCameraRejected;

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
    MacCameraDecoder* d = dec;
    __block OSStatus decodeStatus = noErr;
    err = VTDecompressionSessionDecodeFrameWithOutputHandler(
        dec->session, sample, 0, NULL,
        ^(OSStatus s, VTDecodeInfoFlags, CVImageBufferRef image, CMTime, CMTime) {
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
    if (out) *out = image;
    else CVPixelBufferRelease(image);
    return kMacCameraDecoded;
}

extern "C" void MacCameraDecoderDestroy(MacCameraDecoder* dec) {
    if (!dec) return;
    ResetSession(dec);
    delete dec;
}
