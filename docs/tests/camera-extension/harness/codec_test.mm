// rd-camera-codec-test: checks the camera codec path that decisions 0004 and 0005 rely
// on, entirely in one process (no camera, extension or permission needed):
//
//   VTCompressionSession → Annex B (the wire) → AVCC → VTDecompressionSession
//
// usage: rd-camera-codec-test [--fuzz N] [--seed N] [--no-low-latency]
// Exit status 0 when every test passes.

#include "camera_codec.h"
#include "test_card.h"

#include <algorithm>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <mutex>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>

static const int kW = 1280, kH = 720, kFps = 30, kKbps = 2000;
static const double kKeyInterval = 2.0;

static int gFailures = 0;
static bool gLowLatency = true;

static void Report(const char* name, bool pass, const char* fmt, ...) {
    printf("%-22s %s  ", name, pass ? "PASS" : "FAIL");
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    fflush(stdout);
    if (!pass) gFailures++;
}

static double NowMs() {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return mach_absolute_time() * (double)tb.numer / tb.denom / 1e6;
}

static double Percentile(std::vector<double> v, double p) {
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    return v[std::min(v.size() - 1, (size_t)(p * (v.size() - 1) + 0.5))];
}

struct Au {
    std::vector<uint8_t> data;
    bool key;
    int64_t pts;
};

struct Sink {
    std::mutex lock;
    std::vector<Au> aus;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    double arrivedMs = 0;
};

static void OnEncoded(void* ctx, const uint8_t* data, size_t n, bool key, int64_t pts) {
    Sink* s = (Sink*)ctx;
    {
        std::lock_guard<std::mutex> g(s->lock);
        s->aus.push_back({std::vector<uint8_t>(data, data + n), key, pts});
        s->arrivedMs = NowMs();
    }
    dispatch_semaphore_signal(s->ready);
}

static std::vector<int> NalTypes(const std::vector<uint8_t>& au) {
    std::vector<int> types;
    for (size_t i = 0; i + 4 < au.size(); i++)
        if (au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1) types.push_back(au[i + 3] & 0x1f);
    return types;
}

static double LumaPsnr(CVPixelBufferRef a, CVPixelBufferRef b) {
    if (CVPixelBufferGetWidth(a) != CVPixelBufferGetWidth(b) || CVPixelBufferGetHeight(a) != CVPixelBufferGetHeight(b))
        return 0;
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    const uint8_t* pa = (const uint8_t*)CVPixelBufferGetBaseAddressOfPlane(a, 0);
    const uint8_t* pb = (const uint8_t*)CVPixelBufferGetBaseAddressOfPlane(b, 0);
    size_t sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0), sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0);
    size_t w = CVPixelBufferGetWidthOfPlane(a, 0), h = CVPixelBufferGetHeightOfPlane(a, 0);
    double sum = 0;
    for (size_t y = 0; y < h; y++)
        for (size_t x = 0; x < w; x++) {
            double d = (double)pa[y * sa + x] - pb[y * sb + x];
            sum += d * d;
        }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    double mse = sum / (w * h);
    return mse == 0 ? 99 : 10 * log10(255.0 * 255.0 / mse);
}

static uint32_t gRng = 1;
static uint32_t Rand() {
    gRng ^= gRng << 13;
    gRng ^= gRng >> 17;
    gRng ^= gRng << 5;
    return gRng;
}

// Adds ±16 of noise to the luma plane, so the encoder has to spend its whole budget.
static void AddNoise(CVPixelBufferRef pb) {
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t* p = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    size_t w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0);
    for (size_t y = 0; y < h; y++)
        for (size_t x = 0; x < w; x++) {
            int v = p[y * stride + x] + (int)(Rand() % 33) - 16;
            p[y * stride + x] = (uint8_t)std::min(235, std::max(16, v));
        }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

// Encodes `frames` frames and waits for each one, recording per-frame encode latency.
static void EncodeRun(MacCameraEncoder* enc, Sink* sink, CVPixelBufferPoolRef pool, int frames, int firstFrame,
                      bool noise, std::vector<int> forceAt, std::vector<double>* latencies, int* late,
                      MacCameraDecoder* dec = NULL, std::vector<double>* psnr = NULL,
                      std::vector<double>* decodeMs = NULL, int* decodeFailures = NULL) {
    for (int i = 0; i < frames; i++) {
        CVPixelBufferRef pb = TestCardRender(pool, firstFrame + i);
        if (noise) AddNoise(pb);
        bool force = std::find(forceAt.begin(), forceAt.end(), i) != forceAt.end();
        double t0 = NowMs();
        MacCameraEncoderEncode(enc, pb, (int64_t)(firstFrame + i) * 1000000 / kFps, force);
        if (dispatch_semaphore_wait(sink->ready, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC)) != 0) {
            if (late) (*late)++;
        } else if (latencies) {
            std::lock_guard<std::mutex> g(sink->lock);
            latencies->push_back(sink->arrivedMs - t0);
        }
        if (dec) {
            Au au;
            {
                std::lock_guard<std::mutex> g(sink->lock);
                au = sink->aus.back();
            }
            CVPixelBufferRef out = NULL;
            double d0 = NowMs();
            int r = MacCameraDecoderDecode(dec, au.data.data(), au.data.size(), au.pts, &out);
            if (decodeMs) decodeMs->push_back(NowMs() - d0);
            if (r == kMacCameraDecoded && out) {
                if (psnr) psnr->push_back(LumaPsnr(pb, out));
                CVPixelBufferRelease(out);
            } else if (decodeFailures) {
                (*decodeFailures)++;
            }
        }
        CVPixelBufferRelease(pb);
    }
}

static MacCameraEncoder* MakeEncoder(int w, int h, int kbps, Sink* sink, MacCameraEncoderInfo* info) {
    OSStatus status = noErr;
    MacCameraEncoder* enc = MacCameraEncoderCreate(w, h, kFps, kbps, kKeyInterval, gLowLatency, OnEncoded, sink, info, &status);
    if (!enc) {
        printf("can't create a %dx%d encoder: OSStatus %d\n", w, h, (int)status);
        exit(1);
    }
    return enc;
}

static int Decode(MacCameraDecoder* dec, const Au& au, int* width = NULL) {
    CVPixelBufferRef out = NULL;
    int r = MacCameraDecoderDecode(dec, au.data.data(), au.data.size(), au.pts, &out);
    if (out) {
        if (width) *width = (int)CVPixelBufferGetWidth(out);
        CVPixelBufferRelease(out);
    }
    return r;
}

int main(int argc, char** argv) {
    int fuzzIterations = 3000;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--fuzz") && i + 1 < argc) fuzzIterations = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-low-latency")) gLowLatency = false;
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) gRng = (uint32_t)strtoul(argv[++i], NULL, 10) | 1;
        else {
            fprintf(stderr, "usage: rd-camera-codec-test [--fuzz N] [--seed N] [--no-low-latency]\n");
            return 1;
        }
    }
    CVPixelBufferPoolRef pool720 = TestCardMakePool(kW, kH);

    // ---- Main stream: 10 s of the test card, one forced key frame, decoded as it goes ----
    Sink main;
    MacCameraEncoderInfo info = {};
    MacCameraEncoder* enc = MakeEncoder(kW, kH, kKbps, &main, &info);
    printf("encoder: %s, %dx%d, %d fps, %d kbps, low-latency=%s, hardware required=%s\n", info.encoderID, kW, kH,
           kFps, kKbps, info.lowLatency ? "yes" : "no", info.requiredHardware ? "yes" : "no");
    MacCameraDecoder* dec = MacCameraDecoderCreate(NULL);
    std::vector<double> encMs, decMs, psnr;
    int late = 0, decodeFailures = 0;
    const int frames = 300, forced = 100;
    EncodeRun(enc, &main, pool720, frames, 0, false, {forced}, &encMs, &late, dec, &psnr, &decMs, &decodeFailures);
    MacCameraEncoderDestroy(enc);
    std::vector<Au> aus = main.aus;

    // Annex B framing, and parameter sets exactly on key frames.
    bool framing = !aus.empty() && aus[0].key;
    int keyWithoutParams = 0, deltaWithParams = 0;
    for (const Au& au : aus) {
        if (au.data.size() < 5 || memcmp(au.data.data(), "\0\0\0\1", 4) != 0) framing = false;
        std::vector<int> t = NalTypes(au.data);
        bool hasSps = std::count(t.begin(), t.end(), 7) > 0, hasPps = std::count(t.begin(), t.end(), 8) > 0;
        if (au.key && !(hasSps && hasPps)) keyWithoutParams++;
        if (!au.key && (hasSps || hasPps)) deltaWithParams++;
    }
    Report("annex-b-framing", framing && keyWithoutParams == 0 && deltaWithParams == 0,
           "%zu access units; first is a key frame; key frames without SPS/PPS: %d; delta frames with them: %d",
           aus.size(), keyWithoutParams, deltaWithParams);

    // Key frames: at the start, when forced, and never more than 2 s apart.
    std::vector<int> keys;
    for (size_t i = 0; i < aus.size(); i++)
        if (aus[i].key) keys.push_back((int)i);
    int maxGap = 0;
    for (size_t i = 1; i < keys.size(); i++) maxGap = std::max(maxGap, keys[i] - keys[i - 1]);
    maxGap = std::max(maxGap, (int)aus.size() - keys.back());
    bool forcedKey = (size_t)forced < aus.size() && aus[forced].key;
    std::string keyList;
    for (int k : keys) keyList += std::to_string(k) + " ";
    Report("key-frames", !keys.empty() && keys[0] == 0 && forcedKey && maxGap <= (int)(kKeyInterval * kFps),
           "at frames %s(forced at %d: %s); longest gap %d frames", keyList.c_str(), forced, forcedKey ? "yes" : "no",
           maxGap);

    // One frame out per frame in, in presentation order (no B-frames).
    bool ordered = aus.size() == (size_t)frames;
    for (size_t i = 1; i < aus.size(); i++)
        if (aus[i].pts <= aus[i - 1].pts) ordered = false;
    Report("no-reordering", ordered && late == 0, "%zu out for %d in; %d waited over 500 ms", aus.size(), frames, late);

    Report("encode-latency", Percentile(encMs, 0.95) < 1000.0 / kFps,
           "median %.1f ms, p95 %.1f ms, max %.1f ms (budget: one frame, %.1f ms)", Percentile(encMs, 0.5),
           Percentile(encMs, 0.95), Percentile(encMs, 1), 1000.0 / kFps);

    double minPsnr = psnr.empty() ? 0 : *std::min_element(psnr.begin(), psnr.end());
    Report("round-trip", decodeFailures == 0 && psnr.size() == (size_t)frames && minPsnr > 30,
           "%zu/%d decoded, luma PSNR min %.1f dB, median %.1f dB; decode median %.1f ms, p95 %.1f ms", psnr.size(),
           frames, minPsnr, Percentile(psnr, 0.5), Percentile(decMs, 0.5), Percentile(decMs, 0.95));

    // ---- A decoder that joins mid-stream waits for the next key frame ----
    {
        MacCameraDecoder* late_dec = MacCameraDecoderCreate(NULL);
        int start = 10, nextKey = -1, needKey = 0, decodedBefore = 0, decodedAfter = 0;
        for (int k : keys)
            if (k > start) {
                nextKey = k;
                break;
            }
        for (int i = start; i < (int)aus.size(); i++) {
            int r = Decode(late_dec, aus[i]);
            if (i < nextKey) {
                if (r == kMacCameraNeedKeyFrame) needKey++;
                else if (r == kMacCameraDecoded) decodedBefore++;
            } else if (r == kMacCameraDecoded) {
                decodedAfter++;
            }
        }
        Report("join-mid-stream", needKey == nextKey - start && decodedBefore == 0 &&
                                      decodedAfter == (int)aus.size() - nextKey,
               "frames %d-%d: %d asked for a key frame; from key frame %d: %d/%d decoded", start, nextKey - 1, needKey,
               nextKey, decodedAfter, (int)aus.size() - nextKey);
        MacCameraDecoderDestroy(late_dec);
    }

    // ---- Resolution change: new SPS/PPS rebuild the session, and back again ----
    {
        Sink small;
        CVPixelBufferPoolRef pool360 = TestCardMakePool(640, 360);
        MacCameraEncoder* enc360 = MakeEncoder(640, 360, 800, &small, NULL);
        EncodeRun(enc360, &small, pool360, 10, 0, false, {}, NULL, NULL);
        MacCameraEncoderDestroy(enc360);
        CVPixelBufferPoolRelease(pool360);
        int w360 = 0, w720 = 0, ok360 = 0;
        for (const Au& au : small.aus)
            if (Decode(dec, au, &w360) == kMacCameraDecoded) ok360++;
        int back = Decode(dec, aus[keys.back()], &w720);
        Report("resolution-change", ok360 == (int)small.aus.size() && w360 == 640 && back == kMacCameraDecoded &&
                                        w720 == kW,
               "640x360 stream: %d/%zu decoded at width %d; back to 1280x720 key frame: width %d", ok360,
               small.aus.size(), w360, w720);
    }

    // ---- Limits: oversize streams and access units never reach VideoToolbox ----
    {
        Sink big;
        CVPixelBufferPoolRef pool1440 = TestCardMakePool(2560, 1440);
        MacCameraEncoder* enc1440 = MakeEncoder(2560, 1440, 4000, &big, NULL);
        EncodeRun(enc1440, &big, pool1440, 1, 0, false, {}, NULL, NULL);
        MacCameraEncoderDestroy(enc1440);
        CVPixelBufferPoolRelease(pool1440);
        MacCameraDecoder* lim = MacCameraDecoderCreate(NULL);
        int r1440 = big.aus.empty() ? -1 : Decode(lim, big.aus[0]);
        std::vector<uint8_t> huge(kMacCameraMaxAccessUnitBytes + 1, 0);
        huge[3] = 1;
        huge[4] = 0x65;
        int rHuge = MacCameraDecoderDecode(lim, huge.data(), huge.size(), 0, NULL);
        int rEmpty = MacCameraDecoderDecode(lim, huge.data(), 0, 0, NULL);
        int rRecover = Decode(lim, aus[0]);
        Report("limits", r1440 == kMacCameraRejected && rHuge == kMacCameraRejected && rEmpty == kMacCameraRejected &&
                             rRecover == kMacCameraDecoded,
               "2560x1440 key frame rejected: %s; 4 MB+1 AU rejected: %s; empty rejected: %s; then a valid key frame "
               "decodes: %s",
               r1440 == kMacCameraRejected ? "yes" : "no", rHuge == kMacCameraRejected ? "yes" : "no",
               rEmpty == kMacCameraRejected ? "yes" : "no", rRecover == kMacCameraDecoded ? "yes" : "no");
        MacCameraDecoderDestroy(lim);
    }

    // ---- Live bitrate change on noisy content (CameraControl.target_bitrate_kbps) ----
    {
        Sink noisy;
        MacCameraEncoder* encN = MakeEncoder(kW, kH, kKbps, &noisy, NULL);
        EncodeRun(encN, &noisy, pool720, 150, 0, true, {}, NULL, NULL);
        MacCameraEncoderSetBitrate(encN, 500);
        EncodeRun(encN, &noisy, pool720, 150, 150, true, {}, NULL, NULL);
        MacCameraEncoderDestroy(encN);
        auto kbps = [&](int from, int to) {
            size_t bytes = 0;
            for (int i = from; i < to && i < (int)noisy.aus.size(); i++) bytes += noisy.aus[i].data.size();
            return bytes * 8.0 / ((to - from) / (double)kFps) / 1000;
        };
        double before = kbps(30, 150), after = kbps(180, 300);
        Report("bitrate-change", before > kKbps * 0.5 && before < kKbps * 1.6 && after < 500 * 1.6 && after < before / 2,
               "target 2000 then 500 kbps: measured %.0f kbps before, %.0f kbps after (frames 180-299)", before, after);
    }

    // ---- Fuzz: corrupted access units never crash, and a clean key frame recovers ----
    {
        MacCameraDecoder* fz = MacCameraDecoderCreate(NULL);
        int counts[3] = {0, 0, 0}, recoveries = 0, recoveryChecks = 0;
        for (int it = 0; it < fuzzIterations; it++) {
            const Au& src = aus[Rand() % aus.size()];
            std::vector<uint8_t> m = src.data;
            switch (Rand() % 6) {
                case 0:  // flip random bytes
                    for (int k = 0, n = 1 + Rand() % 16; k < n && !m.empty(); k++) m[Rand() % m.size()] ^= 1 + Rand() % 255;
                    break;
                case 1:  // truncate
                    m.resize(Rand() % (m.size() + 1));
                    break;
                case 2:  // random garbage, sometimes behind a start code
                    m.assign(1 + Rand() % 4096, 0);
                    for (auto& b : m) b = (uint8_t)Rand();
                    if (Rand() % 2 && m.size() > 5) memcpy(m.data(), "\0\0\0\1\x67", 5);
                    break;
                case 3: {  // splice two access units
                    const std::vector<uint8_t>& other = aus[Rand() % aus.size()].data;
                    m.insert(m.end(), other.begin(), other.end());
                    break;
                }
                case 4:  // start codes everywhere
                    for (int k = 0, n = 1 + Rand() % 8; k < n && m.size() > 4; k++) {
                        size_t at = Rand() % (m.size() - 3);
                        m[at] = 0, m[at + 1] = 0, m[at + 2] = 1;
                    }
                    break;
                case 5:  // corrupt the SPS/PPS area of a key frame
                    for (int k = 0; k < 8 && m.size() > 40; k++) m[5 + Rand() % 30] = (uint8_t)Rand();
                    break;
            }
            int r = MacCameraDecoderDecode(fz, m.data(), m.size(), it, NULL);
            if (r >= 0 && r <= 2) counts[r]++;
            if (it % 100 == 99) {
                recoveryChecks++;
                if (Decode(fz, aus[keys[0]]) == kMacCameraDecoded) recoveries++;
            }
        }
        MacCameraDecoderDestroy(fz);
        Report("fuzz", recoveries == recoveryChecks,
               "%d corrupted access units: %d decoded anyway, %d asked for a key frame, %d rejected; recovered on a "
               "clean key frame %d/%d times",
               fuzzIterations, counts[0], counts[1], counts[2], recoveries, recoveryChecks);
    }

    MacCameraDecoderDestroy(dec);
    CVPixelBufferPoolRelease(pool720);
    printf("%s\n", gFailures ? "FAILED" : "ALL PASSED");
    return gFailures ? 1 : 0;
}
