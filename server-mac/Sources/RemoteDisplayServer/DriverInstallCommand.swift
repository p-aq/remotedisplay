import Foundation
import Security

/// The shell command that installs Remote Display Microphone as root (decision 0027).
/// The app's bundle belongs to the user, so anything running as the user can change the
/// driver inside it, and root would install that for every user. So root copies the
/// driver to a folder only root can write, checks the copy there, and only then swaps it
/// in. A copy that fails leaves the installed driver as it was.
enum DriverInstallCommand {
    static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// This app's team, from its own signature; nil when it's ad-hoc signed.
    static let ownTeam: String? = {
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

    /// What the driver's signature must say: its identifier and, in a build signed by a
    /// team, that team (the Makefile signs the driver with the app's identity). An ad-hoc
    /// build has no team to pin, so there the check only shows the driver is whole.
    static func requirement(identifier: String, team: String?) -> String {
        let id = "=identifier \"\(identifier)\""
        guard let team else { return id }
        return id + " and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// `staging` is a folder on `destination`'s volume that only root can write, outside
    /// the folder coreaudiod loads from. `restartAudio` is off in tests, and so is `owner`,
    /// as they don't run as root.
    static func install(source: String, destination: String, staging: String, requirement: String,
                        restartAudio: Bool = true, owner: String? = "root:wheel") -> String {
        var lines = [
            "set -e",
            "umask 022",
            "T=$(mktemp -d \(quoted(staging + "/.rd-mic.XXXXXX")))",
            "trap 'rm -rf \"$T\"' EXIT",
            "cp -RX \(quoted(source)) \"$T/driver\"",
            "if find \"$T\" -type l | grep -q .; then echo \"The driver inside this app contains links, so it wasn't installed.\" >&2; exit 1; fi",
        ]
        // The copy's modes would come from the bundle's and from the umask the app was
        // started with, and the user sets both: neither may make root's driver writable.
        if let owner { lines.append("chown -R \(quoted(owner)) \"$T/driver\"") }
        lines += [
            "chmod -R u=rwX,go=rX \"$T/driver\"",
            "codesign --verify --strict -R \(quoted(requirement)) \"$T/driver\" || { echo \"The driver inside this app isn't the one it was built with, so it wasn't installed.\" >&2; exit 1; }",
            "rm -rf \(quoted(destination))",
            "mv \"$T/driver\" \(quoted(destination))",
        ]
        // coreaudiod loads plug-ins only when it starts; `launchctl kickstart` is refused
        // while SIP is on (decision 0013).
        if restartAudio { lines.append("(killall coreaudiod || true)") }
        return lines.joined(separator: "\n")
    }
}
