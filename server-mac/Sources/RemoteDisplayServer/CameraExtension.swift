import Foundation
import SystemExtensions

/// Installs and removes Remote Display Camera, the camera extension that builds signed
/// with its provisioning profiles bundle (spec, Packaging; decision 0019). macOS
/// activates it only for the app that embeds it, and only from /Applications; an admin
/// then allows it in System Settings. macOS also replaces an installed extension only
/// when the app asks, so a state check that finds another version than the bundled one
/// asks once per launch (spec, Packaging › Updates). First written as the Phase 0
/// harness's container app (docs/tests/camera-extension/harness/ContainerApp/).
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

    /// CFBundleShortVersionString and CFBundleVersion. macOS replaces an installed
    /// extension only with one whose pair differs.
    struct Version: Equatable {
        var short: String
        var build: String
    }

    /// One version of the extension that macOS holds, as a state check lists it.
    struct Held: Equatable {
        var version: Version
        var enabled = false
        var awaitingApproval = false
        var uninstalling = false
    }

    private static let bundlePath = Bundle.main.bundlePath
        + "/Contents/Library/SystemExtensions/\(identifier).systemextension"
    static let bundled = FileManager.default.fileExists(atPath: bundlePath)
    /// The bundled extension's version; the Makefile gives it the app's.
    static let bundledVersion: Version? = {
        guard let info = Bundle(path: bundlePath)?.infoDictionary,
              let short = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { return nil }
        return Version(short: short, build: build)
    }()

    /// What a state check's answer means: the state to show, and whether the extension in
    /// use is another version than `bundled`, older or newer, so macOS should replace it.
    static func evaluate(_ held: [Held], bundled: Version?) -> (state: State, outdated: Bool) {
        if let active = held.first(where: { $0.enabled && !$0.uninstalling }) {
            return (.installed, bundled != nil && active.version != bundled)
        }
        if held.contains(where: { $0.awaitingApproval }) { return (.awaitingApproval, false) }
        if held.contains(where: { $0.uninstalling }) { return (.removing, false) }
        return (.notInstalled, false)
    }

    /// What a request asks macOS to do.
    enum Action { case install, update, remove }

    /// What the Camera row says when macOS refuses a request: what to do, in a plain
    /// sentence, for the errors an owner can act on. The log keeps macOS's own message.
    static func failureMessage(_ error: Error, _ action: Action) -> String {
        let verb = switch action {
        case .install: "install"
        case .update: "update"
        case .remove: "remove"
        }
        let general = "macOS couldn't \(verb) Remote Display Camera. Restart this Mac and try again."
        let e = error as NSError
        guard e.domain == OSSystemExtensionError.errorDomain,
              let code = OSSystemExtensionError.Code(rawValue: e.code) else { return general }
        switch code {
        case .missingEntitlement:
            return "This copy of Remote Display Server isn't allowed to \(verb) Remote Display Camera. Download the app again."
        case .unsupportedParentBundleLocation:
            return "Move Remote Display Server to the Applications folder, open it from there and try again."
        case .extensionNotFound where action == .remove:
            return "macOS has no Remote Display Camera to remove."
        case .extensionNotFound:
            return "Remote Display Camera is missing from this copy of the app. Download Remote Display Server again."
        case .codeSignatureInvalid:
            return "This copy of Remote Display Server is damaged. Download the app again."
        case .validationFailed:
            return "macOS couldn't verify Remote Display Camera. Download Remote Display Server again."
        case .forbiddenBySystemPolicy:
            return "This Mac's settings don't allow Remote Display Camera. If an organization manages this Mac, ask its administrator."
        case .requestCanceled:
            return "Cancelled, so nothing changed. Try again when you're ready."
        case .authorizationRequired:
            return "This needs an admin's name and password. Try again and enter them when macOS asks."
        default:
            return general
        }
    }

    /// Each new state on the main queue, with a message when an install, update or removal
    /// fails.
    var onChange: (State, String?) -> Void = { _, _ in }
    /// On the main queue once macOS has replaced another version with the bundled one.
    var onReplaced: () -> Void = {}
    /// The request under way replaces another version.
    private var replacing = false
    /// A replacement that macOS asked an admin to allow: `onReplaced` waits for the state
    /// check that shows the bundled version enabled.
    private var replacementAwaitingApproval = false
    /// The install, update or removal under way; state checks wait for it.
    private var pending: OSSystemExtensionRequest?
    private var pendingAction = Action.install
    /// A state check is with macOS; the next waits for its answer.
    private var checking = false
    /// The state last reported, and the one before the request under way, which a failed
    /// request goes back to until macOS says more.
    private var last: State?
    private var beforeRequest: State = .notInstalled
    /// This launch already asked macOS to replace another version. Once only: if macOS
    /// refuses, the installed one stays and the row says why.
    private var updateTried = false

    private func report(_ state: State, _ error: String? = nil) {
        last = state
        onChange(state, error)
    }

    /// Asks macOS for the extension's state. Cheap: the app calls it on every refresh.
    func refresh() {
        guard Self.bundled else { return report(.notBundled) }
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return report(.notInApplications) }
        guard pending == nil, !checking else { return }
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.identifier,
                                                                 queue: .main)
        request.delegate = self
        checking = true
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func install() {
        submit(.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main), .install)
    }

    func remove() {
        submit(.deactivationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main), .remove)
    }

    private func submit(_ request: OSSystemExtensionRequest, _ action: Action) {
        guard Self.bundled, pending == nil else { return }
        pending = request
        pendingAction = action
        replacing = false
        request.delegate = self
        beforeRequest = last ?? .notInstalled
        report(.working)
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        checking = false
        guard pending == nil else { return }
        // One entry per version macOS holds for this app.
        let held = properties.map {
            Held(version: Version(short: $0.bundleShortVersion, build: $0.bundleVersion), enabled: $0.isEnabled,
                 awaitingApproval: $0.isAwaitingUserApproval, uninstalling: $0.isUninstalling)
        }
        let (state, outdated) = Self.evaluate(held, bundled: Self.bundledVersion)
        if replacementAwaitingApproval {
            // The old version still runs until an admin allows the new one.
            guard state == .installed, !outdated else { return report(state == .installed ? .awaitingApproval : state) }
            replacementAwaitingApproval = false
            onReplaced()
            return report(state)
        }
        if outdated && !updateTried {
            updateTried = true
            last = state  // what a refused update goes back to
            NSLog("[remotedisplay] camera extension: another version is installed; asking macOS to replace it")
            submit(.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main), .update)
        } else {
            report(state)
        }
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        NSLog("[remotedisplay] camera extension %@ (%@) replaces %@ (%@)", ext.bundleShortVersion,
              ext.bundleVersion, existing.bundleShortVersion, existing.bundleVersion)
        if request === pending { replacing = true }
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard request === pending else { return }
        pending = nil
        if replacing { replacementAwaitingApproval = true }
        replacing = false
        report(.awaitingApproval)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard request === pending else { checking = false; return }
        pending = nil
        if replacing && result == .completed { onReplaced() }
        replacing = false
        if result == .willCompleteAfterReboot && pendingAction == .remove {
            report(.removing)
        } else {
            refresh()
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        guard request === pending else { checking = false; return }
        pending = nil
        let e = error as NSError
        NSLog("[remotedisplay] camera extension request failed: %@ (%@ %ld)", e.localizedDescription, e.domain, e.code)
        // Back to what it was, with what to do; the state check then says what macOS has.
        report(beforeRequest, Self.failureMessage(e, pendingAction))
        refresh()
    }
}
