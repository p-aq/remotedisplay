// rd-mic-install-test: the command Remote Display Server runs as root to install Remote
// Display Microphone (server-mac/Sources/RemoteDisplayServer/DriverInstallCommand.swift),
// run here without root on scratch folders, with the audio restart left out. Needs no
// admin, driver or permission: `make install-test`.

import Foundation

@main
enum InstallTest {
    static var failures = 0
    static let fm = FileManager.default
    static let root = NSTemporaryDirectory() + "rd-mic-install-test-\(getpid())"
    static let id = "app.remotedisplay.test.mic"

    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = pipe
        try! p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A driver-shaped bundle holding `marker`, signed ad hoc as `identifier`.
    static func makeDriver(_ name: String, marker: String, identifier: String = id) -> String {
        let bundle = root + "/" + name
        try! fm.createDirectory(atPath: bundle + "/Contents/MacOS", withIntermediateDirectories: true)
        try! fm.copyItem(atPath: "/usr/bin/true", toPath: bundle + "/Contents/MacOS/driver")
        let plist = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "driver", "CFBundleVersion": marker,
                     "CFBundlePackageType": "BNDL"]
        (plist as NSDictionary).write(toFile: bundle + "/Contents/Info.plist", atomically: true)
        let signed = run("/usr/bin/codesign", ["--sign", "-", "--identifier", identifier, "--force", bundle])
        precondition(signed.status == 0, signed.output)
        return bundle
    }

    static func installed(_ destination: String) -> String {
        (NSDictionary(contentsOfFile: destination + "/Contents/Info.plist")?["CFBundleVersion"] as? String) ?? "nothing"
    }

    /// Installs `source` over a driver marked "old" and reports what is there afterwards.
    static func check(_ name: String, source: String, requirement: String? = nil, expect: String, saying: String = "") {
        let hal = root + "/hal-" + name.replacingOccurrences(of: " ", with: "-"), staging = hal + "-staging"
        try! fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        try! fm.createDirectory(atPath: hal, withIntermediateDirectories: true)
        let destination = hal + "/RemoteDisplayMicrophone.driver"
        try! fm.copyItem(atPath: makeDriver("old-" + name.replacingOccurrences(of: " ", with: "-"), marker: "old"), toPath: destination)
        let command = DriverInstallCommand.install(
            source: source, destination: destination, staging: staging,
            requirement: requirement ?? DriverInstallCommand.requirement(identifier: id, team: nil), restartAudio: false)
        let r = run("/bin/sh", ["-c", command])
        let now = installed(destination)
        let left = (try? fm.contentsOfDirectory(atPath: staging)) ?? []
        let pass = now == expect && (r.status == 0) == (expect == "new") && left.isEmpty && (saying.isEmpty || r.output.contains(saying))
        print(name.padding(toLength: 30, withPad: " ", startingAt: 0) + " " + (pass ? "PASS" : "FAIL")
            + "  installed: \(now)" + (r.status == 0 ? "" : "; refused") + (left.isEmpty ? "" : "; staging not empty"))
        if !pass {
            failures += 1
            print(r.output)
        }
    }

    static func main() {
        try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        check("a whole driver", source: makeDriver("good", marker: "new"), expect: "new")
        check("a path with quotes and spaces", source: makeDriver("it's a \"good\" one", marker: "new"), expect: "new")

        let changed = makeDriver("changed", marker: "new")
        try! Data("payload".utf8).write(to: URL(fileURLWithPath: changed + "/Contents/MacOS/driver"))
        check("code changed after signing", source: changed, expect: "old", saying: "isn't the one it was built with")

        let linked = makeDriver("linked", marker: "new")
        try! fm.removeItem(atPath: linked + "/Contents/MacOS/driver")
        try! fm.createSymbolicLink(atPath: linked + "/Contents/MacOS/driver", withDestinationPath: "/usr/bin/true")
        check("code replaced by a link", source: linked, expect: "old", saying: "contains links")

        check("another program's signature", source: makeDriver("other", marker: "new", identifier: "com.example.other"),
              expect: "old", saying: "isn't the one it was built with")
        check("no team where one is required", source: makeDriver("adhoc", marker: "new"),
              requirement: DriverInstallCommand.requirement(identifier: id, team: "ABCDE12345"), expect: "old",
              saying: "isn't the one it was built with")
        check("the app's driver is missing", source: root + "/nowhere.driver", expect: "old")

        let pinned = DriverInstallCommand.requirement(identifier: "app.remotedisplay.server.mic", team: "ABCDE12345")
        let expected = "=identifier \"app.remotedisplay.server.mic\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\""
        print("the requirement for a team".padding(toLength: 30, withPad: " ", startingAt: 0) + " " + (pinned == expected ? "PASS" : "FAIL"))
        if pinned != expected { failures += 1 }

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
