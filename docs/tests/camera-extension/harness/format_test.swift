// rd-camera-format-test: Remote Display Camera's source stream can send both the frames
// remotedisplayd feeds its sink and its own placeholder
// (server-mac/CameraExtension/SourceFormat.swift). Needs no camera, extension, signing
// or permission: `make format-test`.

import CoreMedia
import CoreVideo
import Foundation

// The colour tags VideoToolbox's decoder attached to every frame of the engine's decoder
// (src/platform/macos_camera_sink.mm), measured with this harness's encoder and test card
// (../README.md, Runtime findings): BT.709 at 1280×720, and BT.601, guessed, for a
// 640×360 stream, which the letterbox to 1280×720 keeps.
let hdTags: [CFString: CFString] = [
    kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
    kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
    kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
    kCVImageBufferChromaLocationTopFieldKey: kCVImageBufferChromaLocation_Left,
    kCVImageBufferChromaLocationBottomFieldKey: kCVImageBufferChromaLocation_Left,
]
let sdTags = hdTags.merging([
    kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_SMPTE_C,
    kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
]) { $1 }

@main
enum FormatTest {
    static var failures = 0
    static let pool = makeNV12Pool()!
    // Held until the end, so the pool never hands back a buffer that still has tags.
    static var frames: [CVPixelBuffer] = []

    static func report(_ name: String, _ pass: Bool, _ detail: String) {
        print(name.padding(toLength: 22, withPad: " ", startingAt: 0) + " " + (pass ? "PASS" : "FAIL") + "  " + detail)
        if !pass { failures += 1 }
    }

    /// A buffer from the extension's own pool, as the placeholder is, with `tags` attached.
    static func frame(_ tags: [CFString: CFString] = [:]) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        for (key, value) in tags { CVBufferSetAttachment(pb!, key, value, .shouldPropagate) }
        frames.append(pb!)
        return pb!
    }

    static func matrix(_ sbuf: CMSampleBuffer) -> String {
        guard let desc = CMSampleBufferGetFormatDescription(sbuf),
              let value = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix)
        else { return "none" }
        return value as? String ?? "?"
    }

    static func main() {
        // What CameraDevice.send() did before: the stream's advertised format, made with no
        // extensions, for every frame.
        var advertised: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCameraPixelFormat, width: Int32(kCameraWidth), height: Int32(kCameraHeight),
            extensions: nil, formatDescriptionOut: &advertised)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: kCameraFPS),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var plain: CMSampleBuffer?
        let plainErr = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: frame(hdTags), formatDescription: advertised!,
            sampleTiming: &timing, sampleBufferOut: &plain)
        report("advertised-format", plainErr == kCMSampleBufferError_InvalidMediaFormat,
               "CoreMedia refuses a decoded frame with the stream's own format: \(plainErr)")

        var source = SourceFormat()
        let at: UInt64 = 1_234_567_890_123
        let placeholder = frame()
        do {
            let sbuf = try source.sampleBuffer(for: placeholder, hostTimeNs: at)
            let pts = CMSampleBufferGetPresentationTimeStamp(sbuf), duration = CMSampleBufferGetDuration(sbuf)
            let ok = pts == CMTime(value: CMTimeValue(at), timescale: 1_000_000_000)
                && duration == CMTime(value: 1, timescale: kCameraFPS)
                && CMSampleBufferGetImageBuffer(sbuf) === placeholder
            report("placeholder", ok, "wrapped, stamped \(pts.value) ns, \(duration.value)/\(duration.timescale) s")
        } catch {
            report("placeholder", false, error.localizedDescription)
        }

        for (name, tags, expected) in [("decoded-720p", hdTags, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
                                       ("decoded-sd-letterboxed", sdTags, kCVImageBufferYCbCrMatrix_ITU_R_601_4)] {
            do {
                let sbuf = try source.sampleBuffer(for: frame(tags), hostTimeNs: at)
                report(name, matrix(sbuf) == expected as String, "wrapped; apps get matrix \(matrix(sbuf))")
            } catch {
                report(name, false, error.localizedDescription)
            }
        }

        // A new description only when the tags change; the same one while they don't.
        let sequence: [(String, [CFString: CFString])] = [
            ("placeholder", [:]), ("hd", hdTags), ("hd", hdTags), ("hd", hdTags),
            ("placeholder", [:]), ("sd", sdTags), ("sd", sdTags), ("hd", hdTags),
        ]
        var switching = SourceFormat()
        var wrapped = 0, made = 0, reusedRight = true
        var previous: CMVideoFormatDescription?, previousKind = ""
        for (kind, tags) in sequence {
            guard (try? switching.sampleBuffer(for: frame(tags), hostTimeNs: at)) != nil else { continue }
            wrapped += 1
            let desc = switching.formatDescription
            if desc !== previous { made += 1 }
            if (desc === previous) != (kind == previousKind) { reusedRight = false }
            previous = desc
            previousKind = kind
        }
        report("switching", wrapped == sequence.count && made == 5 && reusedRight,
               "\(wrapped)/\(sequence.count) wrapped, \(made) descriptions for 5 changes of tags")

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
