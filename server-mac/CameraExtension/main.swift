// Remote Display Camera: the camera extension that Remote Display Server installs
// (spec, Host side; first written as the Phase 0 harness in
// docs/tests/camera-extension/harness/).
//
// One device with two streams:
// - source: what FaceTime, Zoom and other apps read;
// - sink: what remotedisplayd (src/platform/macos_camera_sink.mm) writes into
//   through the CoreMediaIO C API. One program at a time feeds it, and the device
//   publishes which (decision 0033, option 2), so the app can say when it isn't ours.
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
import Security

let log = Logger(subsystem: "app.remotedisplay.server.camera", category: "extension")

// Fixed IDs, so apps remember "Remote Display Camera" across restarts.
let kDeviceID = UUID(uuidString: "5B3D7E21-6C0A-4E7B-9D6F-2A1C8E4B7F10")!
let kSourceStreamID = UUID(uuidString: "5B3D7E21-6C0A-4E7B-9D6F-2A1C8E4B7F11")!
let kSinkStreamID = UUID(uuidString: "5B3D7E21-6C0A-4E7B-9D6F-2A1C8E4B7F12")!
let kDeviceName = "Remote Display Camera"
let kIdleTimeoutNs: UInt64 = 500_000_000
let kPlaceholderFPS = 5
/// remotedisplayd's signing identifier (server-mac/Makefile, CODE_ID).
let kFeederSigningID = "app.remotedisplay.server"
/// A custom device property: the pid of the program feeding the sink, as a string, empty
/// when none is. Read through CoreMediaIO as selector 'feed' (server-mac's CameraFeeder).
let kFeederProperty = CMIOExtensionProperty(rawValue: "4cc_feed_glob_0000")

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
    private let queue = DispatchQueue(label: "app.remotedisplay.server.camera.device", qos: .userInteractive)
    private var sourceClients = 0
    private var placeholderTimer: DispatchSourceTimer?
    /// The one program feeding the sink, from authorization until it stops or disconnects.
    private var sinkClient: CMIOExtensionClient?
    /// Its pid, for the device property; behind a lock, as CoreMediaIO reads it on its own queue.
    private let feederLock = NSLock()
    private var feederPid: pid_t?
    private var sinkRunning = false
    private var lastSinkNs: UInt64 = 0
    private var droppedMismatched = 0
    private var sourceFormat = SourceFormat()

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

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel, kFeederProperty] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            p.transportType = 0x7669_7274 // kIOAudioDeviceTransportTypeVirtual, "virt"
        }
        if properties.contains(.deviceModel) {
            p.model = kDeviceName
        }
        if properties.contains(kFeederProperty) {
            let pid = feederLock.withLock { feederPid }
            p.setPropertyState(feederState(pid), forProperty: kFeederProperty)
        }
        return p
    }

    private func feederState(_ pid: pid_t?) -> CMIOExtensionPropertyState<AnyObject> {
        CMIOExtensionPropertyState(value: (pid.map { String($0) } ?? "") as NSString)
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

    /// Sends a placeholder or sink frame to the apps reading the camera. Sink frames keep
    /// their colour tags, so each gets a format description of its own (SourceFormat.swift).
    private func send(_ pixelBuffer: CVPixelBuffer) {
        let now = hostTimeNs()
        do {
            let sbuf = try sourceFormat.sampleBuffer(for: pixelBuffer, hostTimeNs: now)
            sourceStream.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: now)
        } catch {
            log.error("Couldn't wrap a frame for the source stream: \(error.localizedDescription)")
        }
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

    /// Lets `client` feed the sink unless another program still does: any feeder, but one
    /// at a time (decision 0033, option 2). Called on CoreMediaIO's queue, never on `queue`.
    func claimSink(_ client: CMIOExtensionClient) -> Bool {
        queue.sync {
            if let holder = sinkClient, holder.clientID != client.clientID {
                if isRunning(holder.pid) {
                    log.error("Refused sink client \(client.pid): \(holder.pid) is feeding the camera")
                    return false
                }
                log.info("Sink client \(holder.pid) is gone; \(client.pid) takes over")
            }
            setSinkClient(client)
            return true
        }
    }

    /// The feeder went away without stopping the sink, as when it crashes.
    func clientDisconnected(_ client: CMIOExtensionClient) {
        queue.async {
            guard self.sinkClient?.clientID == client.clientID else { return }
            log.info("Sink client \(client.pid) disconnected")
            self.sinkRunning = false
            self.setSinkClient(nil)
        }
    }

    /// On `queue`. Tells the app who feeds the camera now.
    private func setSinkClient(_ client: CMIOExtensionClient?) {
        guard sinkClient?.clientID != client?.clientID else { return }
        sinkClient = client
        feederLock.withLock { feederPid = client?.pid }
        device.notifyPropertiesChanged([kFeederProperty: feederState(client?.pid)])
    }

    func sinkStarted() {
        queue.async {
            guard !self.sinkRunning else { return }
            self.sinkRunning = true
            self.consumeNext()
        }
    }

    func sinkStopped() {
        queue.async {
            self.sinkRunning = false
            self.setSinkClient(nil)
        }
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
        // Any feeder the check doesn't refuse outright, one at a time; the app shows a
        // feeder other than its engine (decision 0033, option 2).
        guard checkFeeder(client) != .refused else { return false }
        return device.claimSink(client)
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

    func disconnect(from client: CMIOExtensionClient) { camera.clientDisconnected(client) }

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "Remote Display" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Who may feed the sink

/// This extension's team, from its own signature; nil when it is ad-hoc signed.
let ownTeamID: String? = {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                        &info) == errSecSuccess
    else { return nil }
    return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
}()

enum FeederCheck {
    /// remotedisplayd, signed by this extension's own team.
    case verified
    /// Not shown to be remotedisplayd: accepted, and the app shows it (decision 0033, option 2).
    case unverified
    /// CoreMediaIO names another program.
    case refused
}

/// Whether the client is remotedisplayd signed by this extension's own team: its running
/// code, looked up by pid, checked against the Makefile's designated requirement, or,
/// where the sandbox refuses that lookup, the program it runs from, checked on disk.
/// CoreMediaIO's signing identifier only refuses: it reports "unknown" for remotedisplayd
/// and every other feeder tried (live session, 2026-11-19).
func checkFeeder(_ client: CMIOExtensionClient) -> FeederCheck {
    let reported = client.signingID ?? "nothing"
    if reported != kFeederSigningID && reported != "unknown" && reported != "nothing" {
        log.error("Refused sink client \(client.pid): signed as \(reported, privacy: .public)")
        return .refused
    }
    guard let team = ownTeamID else {
        log.error("Sink client \(client.pid) not verified: this extension has no team")
        return .unverified
    }
    let text = "identifier \"\(kFeederSigningID)\" and anchor apple generic"
        + " and certificate leaf[subject.OU] = \"\(team)\""
    var requirement: SecRequirement?
    var code: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: client.pid)] as CFDictionary
    var status = SecRequirementCreateWithString(text as CFString, [], &requirement)
    if status == errSecSuccess { status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) }
    if status == errSecSuccess, let code, let requirement {
        status = SecCodeCheckValidity(code, [], requirement)
    }
    // The sandbox refuses looking up another process's code: EPERM for remotedisplayd,
    // EACCES for other feeders (live session, 2026-11-19).
    var path = ""
    if status == 100001 || status == 100013, let requirement {
        (status, path) = checkOnDisk(client.pid, requirement)
    }
    if status != errSecSuccess {
        log.error("Sink client \(client.pid) \(path, privacy: .public) not verified: code check failed (\(status))")
        return .unverified
    }
    log.info("Verified sink client \(client.pid) \(path, privacy: .public) (CoreMediaIO reports \(reported, privacy: .public))")
    return .verified
}

/// False once `pid` has exited. The sandbox may refuse signalling it, which still means it runs.
func isRunning(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}

/// The program `pid` runs from, checked on disk against `requirement`, and its path.
func checkOnDisk(_ pid: pid_t, _ requirement: SecRequirement) -> (OSStatus, String) {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
        return (OSStatus(100000 + errno), "(no path)")  // kPOSIXErrorBase + errno
    }
    let path = String(cString: buffer)
    var staticCode: SecStaticCode?
    var status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
    if status == errSecSuccess, let staticCode {
        status = SecStaticCodeCheckValidity(staticCode, [], requirement)
    }
    return (status, path)
}

let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
