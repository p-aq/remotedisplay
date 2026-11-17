// The Remote Display test card, shared by rd-camera-feeder and rd-camera-codec-test.
// Same build rules as camera_sink.mm: -std=c++17, no ARC.

#include "test_card.h"

#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <stdio.h>
#include <sys/time.h>
#include <time.h>

extern "C" CVPixelBufferPoolRef TestCardMakePool(int width, int height) {
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
extern "C" CVPixelBufferRef TestCardRender(CVPixelBufferPoolRef pool, int frame) {
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
