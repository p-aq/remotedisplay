// Checks the engine's host-side camera code (engine/rustdesk/src/platform/macos_camera_sink.mm):
// decoding, letterboxing to the sink's 1280×720, joining mid-stream, limits, the sink's
// status, and a fuzz pass. Streams come from the measured encoder and test card in
// ../../camera-extension/harness. See ../README.md.
//
// usage: rd-camera-sink-test [--fuzz N]

#include "../../camera-extension/harness/camera_codec.h"
#include "../../camera-extension/harness/test_card.h"

#include <CoreMediaIO/CMIOHardware.h>
#include <dispatch/dispatch.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <algorithm>
#include <mutex>
#include <vector>

// The engine's exports (macos_camera_sink.mm); outcomes are camera_codec.h's 0, 1, 2.
extern "C" {
typedef struct MacCameraFeed MacCameraFeed;
int MacCameraSinkStatus(void);
MacCameraFeed* MacCameraFeedOpen(int fps, bool sink, OSStatus* status);
int MacCameraFeedPush(MacCameraFeed* feed, const uint8_t* data, size_t length, int64_t ptsUs,
                      CVPixelBufferRef* shown);
void MacCameraFeedClose(MacCameraFeed* feed);
}

static int gFailures = 0;

static void Report(const char* name, bool pass, const char* fmt, ...) {
    printf("%s  %-20s ", pass ? "PASS" : "FAIL", name);
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    if (!pass) gFailures++;
}

struct Au {
    std::vector<uint8_t> data;
    bool key;
    int64_t pts;
};

struct Collect {
    std::mutex lock;
    std::vector<Au> aus;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
};

static void OnEncoded(void* ctx, const uint8_t* data, size_t n, bool key, int64_t pts) {
    Collect* c = (Collect*)ctx;
    {
        std::lock_guard<std::mutex> g(c->lock);
        c->aus.push_back({std::vector<uint8_t>(data, data + n), key, pts});
    }
    dispatch_semaphore_signal(c->ready);
}

// `frames` test-card frames at width×height through the controller's encoder settings;
// `sources` keeps the input frames when given.
static std::vector<Au> Encode(int width, int height, int frames, std::vector<CVPixelBufferRef>* sources = NULL) {
    Collect c;
    MacCameraEncoderInfo info;
    OSStatus status = noErr;
    MacCameraEncoder* enc = MacCameraEncoderCreate(width, height, 30, 2000, 2.0, true, OnEncoded, &c, &info, &status);
    if (!enc) {
        printf("can't create a %dx%d encoder: OSStatus %d\n", width, height, (int)status);
        exit(1);
    }
    CVPixelBufferPoolRef pool = TestCardMakePool(width, height);
    for (int i = 0; i < frames; i++) {
        CVPixelBufferRef pb = TestCardRender(pool, i);
        MacCameraEncoderEncode(enc, pb, (int64_t)i * 1000000 / 30, false);
        dispatch_semaphore_wait(c.ready, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC));
        if (sources)
            sources->push_back(pb);
        else
            CVPixelBufferRelease(pb);
    }
    MacCameraEncoderDestroy(enc);
    CVPixelBufferPoolRelease(pool);
    std::lock_guard<std::mutex> g(c.lock);
    return c.aus;
}

static MacCameraFeed* DecodeOnly() {
    OSStatus status = noErr;
    return MacCameraFeedOpen(30, false, &status);
}

static int Push(MacCameraFeed* feed, const Au& au, CVPixelBufferRef* shown = NULL) {
    return MacCameraFeedPush(feed, au.data.data(), au.data.size(), au.pts, shown);
}

static int Luma(CVPixelBufferRef pb, int x, int y) {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const uint8_t* p = (const uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    int v = p[y * CVPixelBufferGetBytesPerRowOfPlane(pb, 0) + x];
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return v;
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

struct Shape {
    int decoded = 0, width = 0, height = 0, bar = -1, middle = -1;
};

// Decodes a whole stream; measures the last shown frame: its size, the luma 40 px in from
// the left edge (a letterbox bar when the stream isn't 16:9) and in the middle.
static Shape Show(const std::vector<Au>& aus) {
    Shape s;
    MacCameraFeed* feed = DecodeOnly();
    for (const Au& au : aus) {
        CVPixelBufferRef shown = NULL;
        if (Push(feed, au, &shown) == kMacCameraDecoded && shown) {
            s.decoded++;
            s.width = (int)CVPixelBufferGetWidth(shown);
            s.height = (int)CVPixelBufferGetHeight(shown);
            s.bar = Luma(shown, 40, s.height / 2);
            s.middle = Luma(shown, s.width / 2, s.height / 3);
        }
        if (shown) CVPixelBufferRelease(shown);
    }
    MacCameraFeedClose(feed);
    return s;
}

static uint32_t gRng = 1;
static uint32_t Rand() {
    gRng ^= gRng << 13;
    gRng ^= gRng >> 17;
    gRng ^= gRng << 5;
    return gRng;
}

int main(int argc, char** argv) {
    int fuzzIterations = 3000;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--fuzz") && i + 1 < argc) {
            fuzzIterations = atoi(argv[++i]);
        } else {
            fprintf(stderr, "usage: rd-camera-sink-test [--fuzz N]\n");
            return 2;
        }
    }

    // ---- 720p decodes unchanged ----
    std::vector<CVPixelBufferRef> sources;
    std::vector<Au> aus = Encode(1280, 720, 60, &sources);
    {
        MacCameraFeed* feed = DecodeOnly();
        int decoded = 0;
        std::vector<double> psnr;
        for (size_t i = 0; i < aus.size(); i++) {
            CVPixelBufferRef shown = NULL;
            if (Push(feed, aus[i], &shown) == kMacCameraDecoded && shown) {
                decoded++;
                if (i < sources.size()) psnr.push_back(LumaPsnr(sources[i], shown));
            }
            if (shown) CVPixelBufferRelease(shown);
        }
        MacCameraFeedClose(feed);
        std::sort(psnr.begin(), psnr.end());
        double median = psnr.empty() ? 0 : psnr[psnr.size() / 2];
        Report("720p", decoded == (int)aus.size() && median >= 35,
               "%d/%zu decoded at the sink's size, median luma PSNR %.1f dB", decoded, aus.size(), median);
    }
    for (CVPixelBufferRef pb : sources) CVPixelBufferRelease(pb);

    // ---- Other sizes are letterboxed to 1280×720 ----
    struct {
        const char* name;
        int width, height;
        bool bars;
    } sizes[] = {{"letterbox-4:3", 640, 480, true}, {"scale-1080p", 1920, 1080, false}, {"pillarbox-portrait", 720, 1280, true}};
    for (auto& size : sizes) {
        std::vector<Au> stream = Encode(size.width, size.height, 30);
        Shape s = Show(stream);
        bool barsOk = size.bars ? s.bar <= 20 : s.bar > 20;
        Report(size.name, s.decoded == (int)stream.size() && s.width == 1280 && s.height == 720 && barsOk && s.middle > 20,
               "%dx%d: %d/%zu shown at %dx%d; luma %d at the left edge (%s), %d in the middle", size.width, size.height,
               s.decoded, stream.size(), s.width, s.height, s.bar, size.bars ? "black bar" : "picture", s.middle);
    }

    // ---- Joining mid-stream waits for a key frame ----
    {
        MacCameraFeed* feed = DecodeOnly();
        int waiting = 0;
        for (int i = 1; i <= 5; i++) waiting += Push(feed, aus[i]) == kMacCameraNeedKeyFrame;
        int key = Push(feed, aus[0]);
        int next = Push(feed, aus[1]);
        MacCameraFeedClose(feed);
        Report("join-mid-stream", waiting == 5 && key == kMacCameraDecoded && next == kMacCameraDecoded,
               "%d/5 P frames before a key frame asked for one; then key %d, P %d (0 = decoded)", waiting, key, next);
    }

    // ---- Limits (decision 0016) ----
    {
        MacCameraFeed* feed = DecodeOnly();
        int empty = MacCameraFeedPush(feed, NULL, 0, 0, NULL);
        std::vector<uint8_t> huge(4 * 1024 * 1024 + 1, 0);
        memcpy(huge.data(), "\0\0\0\1\x65", 5);
        int big = MacCameraFeedPush(feed, huge.data(), huge.size(), 0, NULL);
        std::vector<Au> qhd = Encode(2560, 1440, 1);
        int large = qhd.empty() ? -1 : Push(feed, qhd[0]);
        int after = Push(feed, aus[0]);
        MacCameraFeedClose(feed);
        Report("limits", empty == kMacCameraRejected && big == kMacCameraRejected && large == kMacCameraRejected &&
                             after == kMacCameraDecoded,
               "empty %d, over 4 MB %d, 2560x1440 %d (2 = rejected); then 720p %d", empty, big, large, after);
    }

    // ---- The sink: Remote Display Camera's sink stream, if the extension is there ----
    {
        int status = MacCameraSinkStatus();
        OSStatus err = noErr;
        MacCameraFeed* feed = MacCameraFeedOpen(30, true, &err);
        bool consistent = status == 0 ? feed != NULL : (feed == NULL && err == kCMIOHardwareBadDeviceError);
        if (feed) MacCameraFeedClose(feed);
        Report("sink-status", consistent, "Remote Display Camera %s; opening its sink %s (OSStatus %d)",
               status == 0 ? "present" : "not installed", feed ? "worked" : "failed", (int)err);
    }

    // ---- Fuzz: corrupted access units never crash, and a clean key frame recovers ----
    {
        std::vector<Au> small = Encode(640, 480, 30);
        std::vector<const Au*> pool;
        for (const Au& au : aus) pool.push_back(&au);
        for (const Au& au : small) pool.push_back(&au);
        MacCameraFeed* feed = DecodeOnly();
        int counts[3] = {0, 0, 0}, recoveries = 0, recoveryChecks = 0;
        for (int it = 0; it < fuzzIterations; it++) {
            std::vector<uint8_t> m = pool[Rand() % pool.size()]->data;
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
                    const std::vector<uint8_t>& other = pool[Rand() % pool.size()]->data;
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
            CVPixelBufferRef shown = NULL;
            int r = MacCameraFeedPush(feed, m.data(), m.size(), it, &shown);
            if (shown) CVPixelBufferRelease(shown);
            if (r >= 0 && r <= 2) counts[r]++;
            if (it % 100 == 99) {
                recoveryChecks++;
                if (Push(feed, aus[0]) == kMacCameraDecoded) recoveries++;
            }
        }
        MacCameraFeedClose(feed);
        Report("fuzz", recoveries == recoveryChecks,
               "%d corrupted access units: %d decoded anyway, %d asked for a key frame, %d rejected; recovered on a "
               "clean key frame %d/%d times",
               fuzzIterations, counts[0], counts[1], counts[2], recoveries, recoveryChecks);
    }

    printf("%s\n", gFailures ? "FAILED" : "ALL PASSED");
    return gFailures ? 1 : 0;
}
