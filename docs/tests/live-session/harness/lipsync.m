// Remote Display live-session test 10 (../README.md): lip sync. Reads a QuickTime recording
// of Remote Display Camera and Remote Display Microphone and says how far the sound is
// from the picture.
//
//   rd-lipsync clip OUT.mov         writes a 20 s flash-and-beep clip (1280×720, 30 fps): a
//                                   white frame and a 1 kHz beep start together every second.
//                                   Play it on a phone in front of the controller's camera and
//                                   microphone while the host records.
//   rd-lipsync measure MOVIE        finds each flash (the picture's brightness jumps) and each
//                                   beep or clap (the sound's onset), pairs them and prints
//                                   each offset and the median; positive means the sound is
//                                   late. Also writes, for each sound onset, a contact sheet of
//                                   the frames from 300 ms before to 300 ms after it
//                                   (MOVIE-clapN.png), for reading claps by eye.
//   rd-lipsync --self-test          writes a clip whose beeps are 120 ms late, measures it and
//                                   checks the result is within one frame.
//
// Sound onsets use rd-clap's rule (clap.m): the first 1 ms window above 10× the median
// window peak after 150 ms of quiet. The picture is watched in the part of the frame where
// the flash is: of a 16×9 grid, the cell with the biggest jump in brightness from one frame
// to the next, so a clip played in a small window on a phone counts as well as a full
// screen. A flash starts at the first frame whose brightness there crosses halfway between
// its darkest and brightest, so the picture's times are good to about one frame (33 ms at
// 30 fps).

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <math.h>

static const int kW = 1280, kH = 720, kFPS = 30, kRate = 48000;
static const double kQuietMs = 150, kWindowMs = 1;

// MARK: - The clip

static CVPixelBufferRef Frame(CVPixelBufferPoolRef pool, uint8_t luma) {
    CVPixelBufferRef pb = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t* y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    memset(y, luma, CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * kH);
    uint8_t* uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * kH / 2);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

// Waits up to 5 s for `input` to take more data.
static BOOL WaitReady(AVAssetWriterInput* input) {
    for (int i = 0; i < 2500 && !input.readyForMoreMediaData; i++) [NSThread sleepForTimeInterval:0.002];
    return input.readyForMoreMediaData;
}

// A clip of `seconds`, a flash every second from 1 s, each beep `beepLateMs` after its flash.
static BOOL WriteClip(NSString* path, double seconds, double beepLateMs) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSError* err = nil;
    AVAssetWriter* w = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:path] fileType:AVFileTypeQuickTimeMovie error:&err];
    if (!w) { fprintf(stderr, "can't write %s: %s\n", path.UTF8String, err.localizedDescription.UTF8String); return NO; }
    AVAssetWriterInput* v = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @(kW), AVVideoHeightKey: @(kH)}];
    AudioChannelLayout layout = {.mChannelLayoutTag = kAudioChannelLayoutTag_Mono};
    AVAssetWriterInput* a = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:@{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @(kRate), AVNumberOfChannelsKey: @1,
        AVEncoderBitRateKey: @128000, AVChannelLayoutKey: [NSData dataWithBytes:&layout length:sizeof(layout)]}];
    v.expectsMediaDataInRealTime = NO;
    a.expectsMediaDataInRealTime = NO;
    AVAssetWriterInputPixelBufferAdaptor* ad = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:v sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(kW), (id)kCVPixelBufferHeightKey: @(kH)}];
    [w addInput:v];
    [w addInput:a];
    [w startWriting];
    [w startSessionAtSourceTime:kCMTimeZero];
    // Picture and sound in step, one frame at a time: the writer stops taking either
    // when it runs far ahead of the other.
    AudioStreamBasicDescription asbd = {.mSampleRate = kRate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, .mBytesPerPacket = 4,
        .mFramesPerPacket = 1, .mBytesPerFrame = 4, .mChannelsPerFrame = 1, .mBitsPerChannel = 32};
    CMAudioFormatDescriptionRef fmt = NULL;
    CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &fmt);
    int frames = (int)(seconds * kFPS);
    size_t sample = 0;
    BOOL ok = YES;
    for (int f = 0; f < frames && ok; f++) {
        if (!(ok = WaitReady(v))) break;
        // White for the first two frames of each second from 1 s, else dark grey.
        BOOL flash = f >= kFPS && (f % kFPS) < 2;
        CVPixelBufferRef pb = Frame(ad.pixelBufferPool, flash ? 235 : 32);
        [ad appendPixelBuffer:pb withPresentationTime:CMTimeMake(f, kFPS)];
        CVPixelBufferRelease(pb);
        // The sound up to the next frame: a 1 kHz beep of 100 ms each second from 1 s,
        // beepLateMs after its flash.
        size_t until = (size_t)((f + 1) * (double)kRate / kFPS);
        while (sample < until && ok) {
            size_t n = MIN((size_t)1024, until - sample);
            float* buf = malloc(n * 4);
            for (size_t i = 0; i < n; i++) {
                double t = (double)(sample + i) / kRate, into = fmod(t, 1.0) - beepLateMs / 1000;
                buf[i] = (t >= 1.0 && into >= 0 && into < 0.1) ? 0.5f * sinf(2 * M_PI * 1000 * t) : 0;
            }
            CMBlockBufferRef block = NULL;
            CMBlockBufferCreateWithMemoryBlock(NULL, buf, n * 4, kCFAllocatorMalloc, NULL, 0, n * 4, 0, &block);
            CMSampleBufferRef sb = NULL;
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, block, fmt, (CMItemCount)n,
                                                                 CMTimeMake((int64_t)sample, kRate), NULL, &sb);
            if ((ok = WaitReady(a))) [a appendSampleBuffer:sb];
            CFRelease(sb);
            CFRelease(block);
            sample += n;
        }
    }
    CFRelease(fmt);
    [v markAsFinished];
    [a markAsFinished];
    if (!ok) {
        fprintf(stderr, "the writer stopped taking data: %s\n", w.error.localizedDescription.UTF8String);
        [w cancelWriting];
        return NO;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [w finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (w.status != AVAssetWriterStatusCompleted) {
        fprintf(stderr, "writing failed: %s\n", w.error.localizedDescription.UTF8String);
        return NO;
    }
    return YES;
}

// MARK: - Reading a recording

typedef struct { double* t; double* v; size_t n, cap; } Series;
static void push(Series* s, double t, double v) {
    if (s->n == s->cap) {
        s->cap = s->cap ? s->cap * 2 : 1024;
        s->t = realloc(s->t, s->cap * sizeof(double));
        s->v = realloc(s->v, s->cap * sizeof(double));
    }
    s->t[s->n] = t;
    s->v[s->n++] = v;
}

// Each 1 ms window's peak of the first audio channel, stamped with its time in the movie.
static Series AudioPeaks(AVAsset* asset) {
    Series s = {0};
    AVAssetTrack* track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track) return s;
    AVAssetReader* r = [AVAssetReader assetReaderWithAsset:asset error:nil];
    AVAssetReaderTrackOutput* out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
        AVFormatIDKey: @(kAudioFormatLinearPCM), AVLinearPCMIsFloatKey: @YES, AVLinearPCMBitDepthKey: @32,
        AVLinearPCMIsNonInterleaved: @NO, AVLinearPCMIsBigEndianKey: @NO}];
    [r addOutput:out];
    [r startReading];
    double rate = 0, windowStart = -1, peak = 0;
    int channels = 1;
    CMSampleBufferRef sb;
    while ((sb = [out copyNextSampleBuffer])) {
        const AudioStreamBasicDescription* d =
            CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sb));
        rate = d->mSampleRate;
        channels = MAX(1, (int)d->mChannelsPerFrame);
        double t0 = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb));
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sb);
        size_t len = 0;
        char* data = NULL;
        CMBlockBufferGetDataPointer(block, 0, NULL, &len, &data);
        const float* f = (const float*)data;
        size_t frames = len / (4 * channels);
        for (size_t i = 0; i < frames; i++) {
            double t = t0 + i / rate;
            if (windowStart < 0) windowStart = t;
            if (t - windowStart >= kWindowMs / 1000) {
                push(&s, windowStart, peak);
                windowStart = t;
                peak = 0;
            }
            peak = fmax(peak, fabsf(f[i * channels]));
        }
        CFRelease(sb);
    }
    return s;
}

static int byValue(const void* a, const void* b) {
    double x = *(const double*)a, y = *(const double*)b;
    return x < y ? -1 : x > y;
}

// rd-clap's onset rule over the windows.
static size_t SoundOnsets(Series w, double* out, size_t max) {
    if (!w.n) return 0;
    double* sorted = malloc(w.n * sizeof(double));
    memcpy(sorted, w.v, w.n * sizeof(double));
    qsort(sorted, w.n, sizeof(double), byValue);
    double threshold = fmax(sorted[w.n / 2] * 10, 0.02);
    free(sorted);
    size_t n = 0;
    double lastLoud = -1e9;
    for (size_t i = 0; i < w.n && n < max; i++) {
        if (w.v[i] <= threshold) continue;
        if ((w.t[i] - lastLoud) * 1000 >= kQuietMs) out[n++] = w.t[i];
        lastLoud = w.t[i];
    }
    return n;
}

enum { kCellsX = 16, kCellsY = 9, kCells = kCellsX * kCellsY };

// Each frame's mean brightness, every 8th pixel of the luma plane, in the grid cell whose
// brightness jumps most from one frame to the next (where the flash is), and its time.
static Series FrameBrightness(AVAsset* asset) {
    Series s = {0};
    double* cells = NULL;  // frames × kCells
    size_t frames = 0, capacity = 0;
    AVAssetTrack* track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) return s;
    AVAssetReader* r = [AVAssetReader assetReaderWithAsset:asset error:nil];
    AVAssetReaderTrackOutput* out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
    [r addOutput:out];
    [r startReading];
    CMSampleBufferRef sb;
    while ((sb = [out copyNextSampleBuffer])) {
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
        if (pb) {
            CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            const uint8_t* y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
            size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0),
                   wd = CVPixelBufferGetWidthOfPlane(pb, 0);
            double sum[kCells] = {0};
            size_t count[kCells] = {0};
            for (size_t row = 0; row < h; row += 8)
                for (size_t col = 0; col < wd; col += 8) {
                    size_t c = (row * kCellsY / h) * kCellsX + col * kCellsX / wd;
                    sum[c] += y[row * stride + col];
                    count[c]++;
                }
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            if (frames == capacity) {
                capacity = capacity ? capacity * 2 : 1024;
                cells = realloc(cells, capacity * kCells * sizeof(double));
            }
            for (size_t c = 0; c < kCells; c++) cells[frames * kCells + c] = count[c] ? sum[c] / count[c] : 0;
            frames++;
            push(&s, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)), 0);
        }
        CFRelease(sb);
    }
    size_t best = 0;
    double bestJump = -1;
    for (size_t c = 0; c < kCells; c++)
        for (size_t f = 1; f < frames; f++) {
            double jump = cells[f * kCells + c] - cells[(f - 1) * kCells + c];
            if (jump > bestJump) { bestJump = jump; best = c; }
        }
    for (size_t f = 0; f < frames; f++) s.v[f] = cells[f * kCells + best];
    free(cells);
    return s;
}

// Frames where the brightness crosses upward halfway between its darkest and brightest,
// at least 400 ms apart.
static size_t Flashes(Series f, double* out, size_t max) {
    if (f.n < 2) return 0;
    double lo = 1e9, hi = -1e9;
    for (size_t i = 0; i < f.n; i++) { lo = fmin(lo, f.v[i]); hi = fmax(hi, f.v[i]); }
    if (hi - lo < 20) return 0;  // no flash bright enough to tell apart
    double mid = (lo + hi) / 2, last = -1e9;
    size_t n = 0;
    for (size_t i = 1; i < f.n && n < max; i++)
        if (f.v[i - 1] < mid && f.v[i] >= mid && f.t[i] - last > 0.4) out[n++] = last = f.t[i];
    return n;
}

// The frames from 300 ms before `t` to 300 ms after, in a grid, each labelled with its
// time from `t` (a 30 fps recording; another rate shows every frame for a shorter span).
static void ContactSheet(AVAsset* asset, double t, NSString* path) {
    AVAssetImageGenerator* g = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    g.requestedTimeToleranceBefore = kCMTimeZero;
    g.requestedTimeToleranceAfter = kCMTimeZero;
    g.maximumSize = CGSizeMake(320, 180);
    const int cols = 6, rows = 3, tw = 320, th = 180;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, cols * tw, rows * (th + 24), 8, 0, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CTFontRef font = CTFontCreateWithName(CFSTR("Menlo"), 16, NULL);
    CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, cols * tw, rows * (th + 24)));
    for (int k = 0; k < cols * rows; k++) {
        // On frame times, so each cell is one frame: from the first at or after t - 300 ms.
        double at = (ceil((t - 0.3) * kFPS) + k) / kFPS;
        if (at < 0) continue;
        CGImageRef img = [g copyCGImageAtTime:CMTimeMakeWithSeconds(at, 600) actualTime:NULL error:nil];
        int col = k % cols, row = rows - 1 - k / cols;
        if (img) {
            CGContextDrawImage(ctx, CGRectMake(col * tw, row * (th + 24) + 24, tw, th), img);
            CGImageRelease(img);
        }
        NSString* label = [NSString stringWithFormat:@"%+.0f ms", (at - t) * 1000];
        NSAttributedString* text = [[NSAttributedString alloc]
            initWithString:label attributes:@{(id)kCTFontAttributeName: (__bridge id)font,
                                              (id)kCTForegroundColorAttributeName: (__bridge id)CGColorGetConstantColor(kCGColorWhite)}];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
        CGContextSetTextPosition(ctx, col * tw + 8, row * (th + 24) + 6);
        CTLineDraw(line, ctx);
        CFRelease(line);
    }
    CFRelease(font);
    CGImageRef sheet = CGBitmapContextCreateImage(ctx);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                                 (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(dest, sheet, NULL);
    CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(sheet);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
}

// Prints each flash's offset to the nearest sound onset within 500 ms; returns the median
// (NAN when nothing pairs) and writes the contact sheets when `sheets`.
static double Measure(NSString* path, BOOL sheets) {
    AVAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    Series peaks = AudioPeaks(asset), bright = FrameBrightness(asset);
    double sounds[512], flashes[512], offsets[512];
    size_t ns = SoundOnsets(peaks, sounds, 512), nf = Flashes(bright, flashes, 512), n = 0;
    printf("%s: %zu frames, %zu sound onsets, %zu flashes\n", path.lastPathComponent.UTF8String, bright.n, ns, nf);
    for (size_t i = 0; i < nf; i++) {
        double best = NAN;
        for (size_t j = 0; j < ns; j++)
            if (fabs(sounds[j] - flashes[i]) < 0.5 && (isnan(best) || fabs(sounds[j] - flashes[i]) < fabs(best)))
                best = sounds[j] - flashes[i];
        if (isnan(best)) continue;
        printf("  flash at %7.3f s: sound %+5.0f ms\n", flashes[i], best * 1000);
        offsets[n++] = best;
    }
    if (sheets) {
        NSString* base = path.stringByDeletingPathExtension;
        for (size_t j = 0; j < ns && j < 12; j++) {
            NSString* sheet = [NSString stringWithFormat:@"%@-clap%zu.png", base, j + 1];
            ContactSheet(asset, sounds[j], sheet);
            printf("  sound onset %zu at %7.3f s: frames around it in %s\n", j + 1, sounds[j], sheet.lastPathComponent.UTF8String);
        }
    }
    if (!n) {
        printf("No flash paired with a sound: read the contact sheets by eye.\n");
        return NAN;
    }
    qsort(offsets, n, sizeof(double), byValue);
    double median = offsets[n / 2];
    printf("Median of %zu: sound %+.0f ms (positive: the sound is late)\n", n, median * 1000);
    return median;
}

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "clip")) return WriteClip(@(argv[2]), 20, 0) ? 0 : 1;
        if (argc == 3 && !strcmp(argv[1], "measure")) return isnan(Measure(@(argv[2]), YES)) ? 1 : 0;
        if (argc == 2 && !strcmp(argv[1], "--self-test")) {
            NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rd-lipsync-self-test.mov"];
            if (!WriteClip(path, 6, 120)) return 1;
            double m = Measure(path, NO);
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            BOOL ok = !isnan(m) && fabs(m * 1000 - 120) <= 1000.0 / kFPS;
            printf("%s: measured %+.0f ms for beeps 120 ms late\n", ok ? "PASS" : "FAIL", m * 1000);
            return ok ? 0 : 1;
        }
        fprintf(stderr, "usage: rd-lipsync clip OUT.mov | measure MOVIE | --self-test\n");
        return 2;
    }
}
