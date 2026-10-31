// Remote Display Camera: wraps pixel buffers in the sample buffers the source stream
// sends, each with a format description that matches it.
//
// Frames that VideoToolbox decodes, as remotedisplayd's are, carry colour tags: the
// decoder attaches them to every frame, and guesses them when the controller's stream
// has none. CoreMedia refuses a sample buffer whose format description doesn't carry
// the same tags (kCMSampleBufferError_InvalidMediaFormat, -12743), so the stream's
// advertised format, which has none, fits only the placeholder.

import CoreMedia
import CoreVideo
import Foundation

struct SourceFormat {
    /// The description of the last buffer wrapped, kept while the next ones match it.
    private(set) var formatDescription: CMVideoFormatDescription?

    /// A ready sample buffer for `pixelBuffer`, one frame long, stamped `hostTimeNs`.
    /// Throws CoreMedia's status as an NSOSStatusErrorDomain error.
    mutating func sampleBuffer(for pixelBuffer: CVPixelBuffer, hostTimeNs: UInt64) throws -> CMSampleBuffer {
        if formatDescription.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) }) ?? true {
            var made: CMVideoFormatDescription?
            let err = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &made)
            guard err == noErr, let made else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }
            formatDescription = made
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: kCameraFPS),
            presentationTimeStamp: CMTime(value: CMTimeValue(hostTimeNs), timescale: CMTimeScale(NSEC_PER_SEC)),
            decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        let err = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: formatDescription!,
            sampleTiming: &timing, sampleBufferOut: &sbuf)
        guard err == noErr, let sbuf else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }
        return sbuf
    }
}
