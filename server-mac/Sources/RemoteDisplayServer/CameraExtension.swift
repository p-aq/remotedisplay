import Foundation
import SystemExtensions

/// Installs and removes Remote Display Camera, the camera extension that builds signed
/// with its provisioning profiles bundle (spec, Packaging; decision 0019). macOS
/// activates it only for the app that embeds it, and only from /Applications; an admin
/// then allows it in System Settings. First written as the Phase 0 harness's container
/// app (docs/tests/camera-extension/harness/ContainerApp/).
final class CameraExtension: NSObject, OSSystemExtensionRequestDelegate {
    static let identifier = "app.remotedisplay.server.camera"

    enum State: Equatable {
        /// Left out of this build: it had no provisioning profiles.
        case notBundled
        /// Bundled, but the app runs from outside /Applications.
        case notInApplications
        case notInstalled
        /// Activated; an admin still has to allow it in System Settings.
        case awaitingApproval
        case installed
        /// Removed; macOS finishes after a restart.
        case removing
        /// A request is with macOS.
        case working
    }

    static let bundled = FileManager.default.fileExists(atPath: Bundle.main.bundlePath
        + "/Contents/Library/SystemExtensions/\(identifier).systemextension")

    /// Each new state on the main queue, with a message when an install or removal fails.
    var onChange: (State, String?) -> Void = { _, _ in }
    /// The install or removal under way; state checks wait for it.
    private var pending: OSSystemExtensionRequest?
    private var pendingRemoval = false
    /// A state check is with macOS; the next waits for its answer.
    private var checking = false

    /// Asks macOS for the extension's state. Cheap: the app calls it on every refresh.
    func refresh() {
        guard Self.bundled else { return onChange(.notBundled, nil) }
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return onChange(.notInApplications, nil) }
        guard pending == nil, !checking else { return }
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.identifier,
                                                                 queue: .main)
        request.delegate = self
        checking = true
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func install() {
        submit(.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main), removal: false)
    }

    func remove() {
        submit(.deactivationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main), removal: true)
    }

    private func submit(_ request: OSSystemExtensionRequest, removal: Bool) {
        guard Self.bundled, pending == nil else { return }
        pending = request
        pendingRemoval = removal
        request.delegate = self
        onChange(.working, nil)
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        checking = false
        guard pending == nil else { return }
        // One entry per version macOS holds for this app.
        if properties.contains(where: { $0.isEnabled && !$0.isUninstalling }) {
            onChange(.installed, nil)
        } else if properties.contains(where: { $0.isAwaitingUserApproval }) {
            onChange(.awaitingApproval, nil)
        } else if properties.contains(where: { $0.isUninstalling }) {
            onChange(.removing, nil)
        } else {
            onChange(.notInstalled, nil)
        }
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        NSLog("[remotedisplay] camera extension %@ (%@) replaces %@ (%@)", ext.bundleShortVersion,
              ext.bundleVersion, existing.bundleShortVersion, existing.bundleVersion)
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard request === pending else { return }
        pending = nil
        onChange(.awaitingApproval, nil)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard request === pending else { checking = false; return }
        pending = nil
        if result == .willCompleteAfterReboot && pendingRemoval {
            onChange(.removing, nil)
        } else {
            refresh()
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        guard request === pending else { checking = false; return }
        pending = nil
        let e = error as NSError
        NSLog("[remotedisplay] camera extension request failed: %@ (%@ %ld)", e.localizedDescription, e.domain, e.code)
        onChange(.notInstalled, e.localizedDescription)
        refresh()
    }
}
