// Phase 0 spike: draws into NV12 (420v) pixel buffers without a BGRA round trip.
// Luma is drawn with Core Graphics on plane 0 as an 8-bit gray bitmap; chroma
// (plane 1, interleaved CbCr at half resolution) is filled directly.

import CoreGraphics
import CoreText
import CoreVideo
import Foundation

let kCameraWidth = 1280
let kCameraHeight = 720
let kCameraFPS: Int32 = 30
let kCameraPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

func makeNV12Pool(width: Int = kCameraWidth, height: Int = kCameraHeight) -> CVPixelBufferPool? {
    let attrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCameraPixelFormat,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        // IOSurface backing is what lets the buffer cross into the extension without a copy.
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    return pool
}

struct NV12Canvas {
    let buffer: CVPixelBuffer

    /// Locks the buffer, runs `body` with a gray context on the luma plane, unlocks.
    /// Video range: keep gray levels within 16...235.
    func drawLuma(_ body: (CGContext) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let ctx = CGContext(
                  data: base,
                  width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                  height: CVPixelBufferGetHeightOfPlane(buffer, 0),
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return }
        body(ctx)
    }

    /// Fills a rectangle of the chroma plane (coordinates in full-resolution pixels,
    /// origin top-left). 128/128 is neutral gray.
    func fillChroma(x: Int, y: Int, width: Int, height: Int, cb: UInt8, cr: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let planeW = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let planeH = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let x0 = max(0, x / 2), x1 = min(planeW, (x + width) / 2)
        let y0 = max(0, y / 2), y1 = min(planeH, (y + height) / 2)
        guard x0 < x1, y0 < y1 else { return }
        let p = base.assumingMemoryBound(to: UInt8.self)
        for row in y0..<y1 {
            let line = p + row * stride
            for col in x0..<x1 {
                line[col * 2] = cb
                line[col * 2 + 1] = cr
            }
        }
    }

    func fillChroma(cb: UInt8, cr: UInt8) {
        fillChroma(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer),
                   height: CVPixelBufferGetHeight(buffer), cb: cb, cr: cr)
    }
}

/// Draws `text` centred horizontally at baseline `y` (CG coordinates, origin bottom-left).
func drawCentredText(_ ctx: CGContext, _ text: String, y: CGFloat, size: CGFloat, gray: CGFloat) {
    let font = CTFontCreateUIFontForLanguage(.system, size, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String):
            CGColor(gray: gray, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: (CGFloat(ctx.width) - CGFloat(width)) / 2, y: y)
    CTLineDraw(line, ctx)
}
