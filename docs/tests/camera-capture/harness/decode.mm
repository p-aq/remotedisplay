// Decodes what the engine's camera test sent (sends_the_camera_as_h264 in
// src/platform/macos_camera_capture.rs) with the host's decoder from the camera-extension
// harness, checks that the picture is a picture, and saves the last frame as a PNG.
//
//   rd-camera-decode <stream.bin> <frame.png>
//
// stream.bin: per access unit, u32 length, u8 key, i64 pts (µs), then the Annex B bytes.

#include "../../camera-extension/harness/camera_codec.h"

#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include <vector>

// Mean and spread of the luma plane, mean of the chroma plane. A decoder that "succeeds"
// with garbage tends to give flat luma or chroma near 0 (green).
static void Measure(CVPixelBufferRef frame, double* lumaMean, double* lumaSpread, double* chromaMean) {
    CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
    const size_t w = CVPixelBufferGetWidthOfPlane(frame, 0), h = CVPixelBufferGetHeightOfPlane(frame, 0);
    const size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0);
    const size_t cStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 1);
    const uint8_t* y = (const uint8_t*)CVPixelBufferGetBaseAddressOfPlane(frame, 0);
    const uint8_t* c = (const uint8_t*)CVPixelBufferGetBaseAddressOfPlane(frame, 1);
    double sum = 0, sq = 0, csum = 0;
    size_t n = 0, cn = 0;
    for (size_t row = 0; row < h; row += 2)
        for (size_t col = 0; col < w; col += 2) {
            double v = y[row * yStride + col];
            sum += v;
            sq += v * v;
            n++;
        }
    for (size_t row = 0; row < h / 2; row += 2)
        for (size_t col = 0; col < w; col += 2) {
            csum += c[row * cStride + col];
            cn++;
        }
    CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
    *lumaMean = sum / n;
    *lumaSpread = sqrt(fmax(0, sq / n - *lumaMean * *lumaMean));
    *chromaMean = csum / cn;
}

int main(int argc, char** argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <stream.bin> <frame.png>\n", argv[0]);
        return 2;
    }
    FILE* in = fopen(argv[1], "rb");
    if (!in) {
        perror(argv[1]);
        return 1;
    }
    MacCameraDecoder* decoder = MacCameraDecoderCreate(NULL);
    int units = 0, decoded = 0, needKey = 0, rejected = 0;
    CVPixelBufferRef last = NULL;
    for (;;) {
        uint32_t length;
        uint8_t key;
        int64_t pts;
        if (fread(&length, 4, 1, in) != 1) break;
        std::vector<uint8_t> unit(length);
        if (fread(&key, 1, 1, in) != 1 || fread(&pts, 8, 1, in) != 1 || fread(unit.data(), 1, length, in) != length) {
            fprintf(stderr, "truncated after %d units\n", units);
            return 1;
        }
        units++;
        CVPixelBufferRef frame = NULL;
        switch (MacCameraDecoderDecode(decoder, unit.data(), unit.size(), pts, &frame)) {
            case kMacCameraDecoded:
                decoded++;
                if (last) CVPixelBufferRelease(last);
                last = frame;
                break;
            case kMacCameraNeedKeyFrame: needKey++; break;
            default: rejected++; break;
        }
    }
    fclose(in);
    MacCameraDecoderDestroy(decoder);
    printf("units %d, decoded %d, need key frame %d, rejected %d\n", units, decoded, needKey, rejected);
    if (!last) return 1;

    double lumaMean, lumaSpread, chromaMean;
    Measure(last, &lumaMean, &lumaSpread, &chromaMean);
    printf("last frame %zux%zu, luma mean %.0f spread %.1f, chroma mean %.0f\n", CVPixelBufferGetWidth(last),
           CVPixelBufferGetHeight(last), lumaMean, lumaSpread, chromaMean);
    bool picture = lumaSpread > 2 && chromaMean > 64 && chromaMean < 192;
    @autoreleasepool {
        CIImage* image = [CIImage imageWithCVPixelBuffer:last];
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        NSError* error = nil;
        if (![[CIContext context] writePNGRepresentationOfImage:image
                                                           toURL:[NSURL fileURLWithPath:@(argv[2])]
                                                          format:kCIFormatRGBA8
                                                      colorSpace:srgb
                                                         options:@{}
                                                           error:&error])
            fprintf(stderr, "PNG not written: %s\n", error.localizedDescription.UTF8String);
        CGColorSpaceRelease(srgb);
    }
    CVPixelBufferRelease(last);
    if (!picture) fprintf(stderr, "the last frame doesn't look like a picture (lens covered?)\n");
    return decoded == units && picture ? 0 : 1;
}
