// Phase 0 harness: the container app that activates and removes the camera extension.
//
// macOS activates a system extension only for the app that embeds it, and only when
// that app runs from /Applications. In Phase 1 this becomes the Camera row's
// Install… and Remove buttons in Remote Display Server.
//
// Run it normally for a small window, or headless from a terminal:
//   ".../Contents/MacOS/RDCameraSpike" --activate | --deactivate

import AppKit
import SystemExtensions

let extensionID = "app.remotedisplay.spike.camera"
let headlessAction = CommandLine.arguments.dropFirst().first

final class AppDelegate: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {
    private var window: NSWindow?
    private let status = NSTextField(wrappingLabelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch headlessAction {
        case "--activate": submit(activate: true)
        case "--deactivate": submit(activate: false)
        default: showWindow()
        }
        if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
            report("Move this app to /Applications first: macOS only activates extensions from there.")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func showWindow() {
        let activate = NSButton(title: "Install camera", target: self, action: #selector(activateClicked))
        let remove = NSButton(title: "Remove camera", target: self, action: #selector(deactivateClicked))
        status.stringValue = "Remote Display Camera (Phase 0 harness)"
        let stack = NSStackView(views: [status, NSStackView(views: [activate, remove])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 140),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Remote Display Camera Spike"
        w.contentView = stack
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    @objc private func activateClicked() { submit(activate: true) }
    @objc private func deactivateClicked() { submit(activate: false) }

    private func submit(activate: Bool) {
        let request = activate
            ? OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
            : OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
        request.delegate = self
        report(activate ? "Installing \(extensionID)…" : "Removing \(extensionID)…")
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func report(_ message: String) {
        print(message)
        status.stringValue = message
    }

    private func finish(_ code: Int32) {
        if headlessAction != nil { exit(code) }
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        report("Replacing \(existing.bundleShortVersion) (\(existing.bundleVersion)) with \(ext.bundleShortVersion) (\(ext.bundleVersion))")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        // macOS 15+: General › Login Items & Extensions › Camera Extensions; macOS 14: Privacy & Security.
        report("Waiting for approval: an admin must allow it in System Settings › General › Login Items & Extensions › Camera Extensions (Privacy & Security on macOS 14).")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed: report("Done.")
        case .willCompleteAfterReboot: report("Done; takes effect after a restart.")
        @unknown default: report("Finished with result \(result.rawValue).")
        }
        finish(0)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let e = error as NSError
        report("Failed: \(e.localizedDescription) (\(e.domain) \(e.code))")
        finish(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(headlessAction == nil ? .regular : .accessory)
app.run()
