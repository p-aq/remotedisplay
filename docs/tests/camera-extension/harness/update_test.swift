// rd-camera-update-test: what Remote Display Server makes of macOS's answer about the
// camera extension, above all when it asks macOS to replace another version
// (server-mac/Sources/RemoteDisplayServer/CameraExtension.swift, `evaluate`). Needs no
// extension, signing or permission: `make update-test`.

import Foundation

typealias Held = CameraExtension.Held
typealias Version = CameraExtension.Version

@main
enum UpdateTest {
    static var failures = 0

    static func check(_ name: String, _ held: [Held], bundled: Version?, _ state: CameraExtension.State, outdated: Bool) {
        let got = CameraExtension.evaluate(held, bundled: bundled)
        let pass = got.state == state && got.outdated == outdated
        print(name.padding(toLength: 34, withPad: " ", startingAt: 0) + " " + (pass ? "PASS" : "FAIL")
            + "  \(got.state)\(got.outdated ? ", replace it" : "")")
        if !pass { failures += 1 }
    }

    static func main() {
        let v17 = Version(short: "1.0.16", build: "17"), v18 = Version(short: "1.0.16", build: "18")
        let v2 = Version(short: "1.1.0", build: "18")
        check("nothing held", [], bundled: v18, .notInstalled, outdated: false)
        check("this version", [Held(version: v18, enabled: true)], bundled: v18, .installed, outdated: false)
        check("an older build", [Held(version: v17, enabled: true)], bundled: v18, .installed, outdated: true)
        check("a newer build", [Held(version: v18, enabled: true)], bundled: v17, .installed, outdated: true)
        check("another short version", [Held(version: v18, enabled: true)], bundled: v2, .installed, outdated: true)
        check("waiting for approval", [Held(version: v18, awaitingApproval: true)], bundled: v18, .awaitingApproval,
              outdated: false)
        check("old in use, new waiting", [Held(version: v17, enabled: true), Held(version: v18, awaitingApproval: true)],
              bundled: v18, .installed, outdated: true)
        check("new in use, old leaving", [Held(version: v17, enabled: true, uninstalling: true),
                                           Held(version: v18, enabled: true)], bundled: v18, .installed, outdated: false)
        check("leaving at a restart", [Held(version: v18, enabled: true, uninstalling: true)], bundled: v18, .removing,
              outdated: false)
        check("no bundled version", [Held(version: v17, enabled: true)], bundled: nil, .installed, outdated: false)
        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
