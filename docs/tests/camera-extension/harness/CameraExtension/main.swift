// Phase 0 spike: the Remote Display Camera extension.
//
// One device with two streams:
// - source: what FaceTime, Zoom and other apps read;
// - sink: what a feeder process (spikes/phase0/camera/Feeder, later remotedisplayd)
//   writes into through the CoreMediaIO C API.
//
// The extension stays thin: no decoding, no networking. It forwards sink buffers to
// the source, drains the sink even when no app is reading (so the feeder never
// stalls), and shows a placeholder card on its own once the sink has been quiet for
// 500 ms, so a crashed feeder still leaves a card rather than a frozen frame.

import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os.log

let log = Logger(subsystem: "app.remotedisplay.spike.camera", category: "extension")

// Fixed IDs, so apps remember "Remote Display Camera" across restarts.
let kDeviceID = UUID(uuidString: "5B3D7E21-6C0A-4E7B-9D6F-2A1C8E4B7F10")!
let kSourceStreamID = UUID(uuidString: "5B3D7E21-6C0A-4E7B-9D6F-2A1C8E4B7F11")!
let kSinkStreamID = UUID(uuidString: "5B3D7E21-6C0A-4E7B-9D6F-2A1C8E4B7F12")!
let kDeviceName = "Remote Display Camera"
let kIdleTimeoutNs: UInt64 = 500_000_000
let kPlaceholderFPS = 5

func hostTimeNs() -> UInt64 {
    UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
}

final class CameraDevice: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: StreamSource!
    private var sinkStream: SinkSource!

    let format: CMVideoFormatDescription
    private let pool: CVPixelBufferPool
    private var placeholder: CVPixelBuffer?

    // Everything below runs on `queue`.
    private let queue = DispatchQueue(label: "app.remotedisplay.spike.camera.device", qos: .userInteractive)
    private var sourceClients = 0
    private var placeholderTimer: DispatchSourceTimer?
    private var sinkClient: CMIOExtensionClient?
    private var sinkRunning = false
    private var lastSinkNs: UInt64 = 0
    private var droppedMismatched = 0

    init(localizedName: String) {
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCameraPixelFormat,
            width: Int32(kCameraWidth), height: Int32(kCameraHeight),
            extensions: nil, formatDescriptionOut: &fd)
        format = fd!
        pool = makeNV12Pool()!
        super.init()

        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: kDeviceID,
                                     legacyDeviceID: nil, source: self)
        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: format,
            maxFrameDuration: CMTime(value: 1, timescale: kCameraFPS),
            minFrameDuration: CMTime(value: 1, timescale: kCameraFPS),
            validFrameDurations: nil)
        sourceStream = StreamSource(localizedName: "\(localizedName) Source", streamID: kSourceStreamID,
                                    direction: .source, format: streamFormat, device: self)
        sinkStream = SinkSource(localizedName: "\(localizedName) Sink", streamID: kSinkStreamID,
                                format: streamFormat, device: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error.localizedDescription)")
        }
    }

    // MARK: CMIOExtensionDeviceSource

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            p.transportType = 0x7669_7274 // kIOAudioDeviceTransportTypeVirtual, "virt"
        }
        if properties.contains(.deviceModel) {
            p.model = kDeviceName
        }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Source side (apps reading the camera)

    func sourceStarted() {
        queue.async {
            self.sourceClients += 1
            if self.placeholderTimer == nil { self.startPlaceholderTimer() }
        }
    }

    func sourceStopped() {
        queue.async {
            self.sourceClients = max(0, self.sourceClients - 1)
            if self.sourceClients == 0 {
                self.placeholderTimer?.cancel()
                self.placeholderTimer = nil
            }
        }
    }

    private func startPlaceholderTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(1000 / kPlaceholderFPS))
        t.setEventHandler { [weak self] in self?.placeholderTick() }
        t.resume()
        placeholderTimer = t
    }

    private func placeholderTick() {
        guard sourceClients > 0, hostTimeNs() &- lastSinkNs > kIdleTimeoutNs else { return }
        if placeholder == nil { placeholder = makePlaceholder() }
        if let pb = placeholder { send(pb) }
    }

    private func send(_ pixelBuffer: CVPixelBuffer) {
        let now = hostTimeNs()
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: kCameraFPS),
            presentationTimeStamp: CMTime(value: CMTimeValue(now), timescale: CMTimeScale(NSEC_PER_SEC)),
            decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        let err = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sbuf)
        guard err == noErr, let sbuf else {
            log.error("CMSampleBufferCreateReadyWithImageBuffer failed: \(err)")
            return
        }
        sourceStream.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: now)
    }

    private func makePlaceholder() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return nil }
        let canvas = NV12Canvas(buffer: pb)
        canvas.drawLuma { ctx in
            ctx.setFillColor(gray: 40.0 / 255, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            drawCentredText(ctx, kDeviceName, y: CGFloat(ctx.height) / 2 + 10, size: 56, gray: 230.0 / 255)
            drawCentredText(ctx, "No controller connected", y: CGFloat(ctx.height) / 2 - 60, size: 32,
                            gray: 170.0 / 255)
        }
        canvas.fillChroma(cb: 128, cr: 128)
        return pb
    }

    // MARK: Sink side (the feeder writing frames)

    func sinkAuthorized(_ client: CMIOExtensionClient) {
        queue.async { self.sinkClient = client }
    }

    func sinkStarted() {
        queue.async {
            guard !self.sinkRunning else { return }
            self.sinkRunning = true
            self.consumeNext()
        }
    }

    func sinkStopped() {
        queue.async { self.sinkRunning = false }
    }

    /// Pulls the next buffer from the sink. Runs whenever the sink is started, whether
    /// or not any app is reading the source, so the feeder's queue always drains.
    private func consumeNext() {
        guard sinkRunning, let client = sinkClient else { return }
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sbuf, seq, _, _, error in
            guard let self else { return }
            self.queue.async {
                if let sbuf {
                    self.handleSinkBuffer(sbuf, sequence: seq)
                    self.consumeNext()
                } else {
                    // Nothing queued (or an error): poll again shortly instead of spinning.
                    if let error { log.debug("consumeSampleBuffer: \(error.localizedDescription)") }
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.consumeNext() }
                }
            }
        }
    }

    private func handleSinkBuffer(_ sbuf: CMSampleBuffer, sequence: UInt64) {
        let now = hostTimeNs()
        sinkStream.stream.notifyScheduledOutputChanged(
            CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now))
        // Validate before use: only the advertised size and pixel format pass.
        guard let pb = CMSampleBufferGetImageBuffer(sbuf),
              CVPixelBufferGetWidth(pb) == kCameraWidth,
              CVPixelBufferGetHeight(pb) == kCameraHeight,
              CVPixelBufferGetPixelFormatType(pb) == kCameraPixelFormat
        else {
            droppedMismatched += 1
            if droppedMismatched == 1 || droppedMismatched % 300 == 0 {
                log.error("Dropped \(self.droppedMismatched) sink buffers with the wrong size or format")
            }
            return
        }
        lastSinkNs = now
        if sourceClients > 0 { send(pb) }
    }
}

final class StreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: CameraDevice

    init(localizedName: String, streamID: UUID, direction: CMIOExtensionStream.Direction,
         format: CMIOExtensionStreamFormat, device: CameraDevice) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: direction, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: kCameraFPS) }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        // One format only; nothing to change.
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { device.sourceStarted() }

    func stopStream() throws { device.sourceStopped() }
}

final class SinkSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: CameraDevice

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: CameraDevice) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: kCameraFPS) }
        // A short queue keeps latency low; the feeder drops frames when it is full.
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 2 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        // Phase 1 restricts this to remotedisplayd (by signing identity); the spike
        // accepts any local feeder.
        device.sinkAuthorized(client)
        return true
    }

    func startStream() throws { device.sinkStarted() }

    func stopStream() throws { device.sinkStopped() }
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var camera: CameraDevice!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        camera = CameraDevice(localizedName: kDeviceName)
        do {
            try provider.addDevice(camera.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "Remote Display" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
