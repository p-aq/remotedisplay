import Foundation

/// Installs and removes Remote Display Microphone, the virtual mic's HAL plug-in, which
/// every build bundles (spec, Packaging; decisions 0013, 0027). Installing copies it to
/// /Library/Audio/Plug-Ins/HAL and restarts coreaudiod, which loads plug-ins only when it
/// starts, in one admin step. Admin steps go the way upstream RustDesk runs its own
/// (src/platform/privileges_scripts/): an AppleScript `do shell script … with
/// administrator privileges` through osascript, with the paths as its arguments.
final class MicrophoneDriver {
    static let bundleName = "RemoteDisplayMicrophone.driver"
    static let installedPath = "/Library/Audio/Plug-Ins/HAL/" + bundleName
    static let bundledPath = Bundle.main.bundlePath + "/Contents/Library/Audio/Plug-Ins/HAL/" + bundleName

    enum State: Equatable {
        /// Left out of this build.
        case notBundled
        case notInstalled
        /// Another driver by this name is installed: an older version, or the Phase 0
        /// harness's.
        case outdated
        case installed
        /// The admin prompt or the copy is under way.
        case working
    }

    /// Each new state on the main queue, with a message when an install or removal fails.
    var onChange: (State, String?) -> Void = { _, _ in }
    private var working = false

    /// From the two bundles' Info.plist: cheap, so the app calls it on every refresh.
    func refresh() {
        guard !working else { return }
        onChange(Self.state(bundled: Self.bundledPath, installed: Self.installedPath), nil)
    }

    static func state(bundled: String, installed: String) -> State {
        guard let ours = identity(of: bundled) else { return .notBundled }
        guard let theirs = identity(of: installed) else { return .notInstalled }
        return theirs == ours ? .installed : .outdated
    }

    /// The bundle's identifier and build, which together say which driver it is.
    private static func identity(of bundle: String) -> String? {
        guard let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist"),
              let id = info["CFBundleIdentifier"] as? String,
              let build = info["CFBundleVersion"] as? String else { return nil }
        return id + " " + build
    }

    func install() {
        guard Self.state(bundled: Self.bundledPath, installed: Self.installedPath) != .notBundled else { return }
        run(Self.installScript, [Self.bundledPath, Self.installedPath], doing: "installed")
    }

    func remove() {
        run(Self.removeScript, [Self.installedPath], doing: "removed")
    }

    private func run(_ script: String, _ args: [String], doing: String) {
        guard !working else { return }
        working = true
        onChange(.working, nil)
        DispatchQueue.global().async {
            // The admin prompt waits for a person; give up after ten minutes.
            let r = ServerController.runProcess("/usr/bin/osascript", ["-e", script] + args,
                                                timeout: 600, mergeStderr: true)
            DispatchQueue.main.async {
                self.working = false
                var error: String?
                // -128: the person cancelled the admin prompt, which isn't a failure.
                if r.status != 0 && !r.output.contains("(-128)") {
                    let why = r.failure ?? r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    NSLog("[remotedisplay] microphone driver not %@: %@", doing, why)
                    error = "Remote Display Microphone wasn't \(doing): \(why)"
                }
                self.onChange(Self.state(bundled: Self.bundledPath, installed: Self.installedPath), error)
            }
        }
    }

    /// Replaces any installed copy, then restarts coreaudiod the way BlackHole's own
    /// installer does: `launchctl kickstart` is refused while SIP is on (decision 0013).
    /// `cp -X` leaves extended attributes such as quarantine behind.
    static let installScript = """
    on run {source, destination}
      set sh to "rm -rf " & quoted form of destination & " && cp -RX " & quoted form of source & " " & quoted form of destination & " && (killall coreaudiod || true)"
      do shell script sh with prompt "Remote Display Server wants to install Remote Display Microphone. This Mac's sound stops for a moment." with administrator privileges
    end run
    """

    static let removeScript = """
    on run {destination}
      set sh to "rm -rf " & quoted form of destination & " && (killall coreaudiod || true)"
      do shell script sh with prompt "Remote Display Server wants to remove Remote Display Microphone. This Mac's sound stops for a moment." with administrator privileges
    end run
    """
}
