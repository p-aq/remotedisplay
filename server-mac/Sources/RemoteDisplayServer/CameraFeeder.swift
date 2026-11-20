import CoreMediaIO
import Foundation

/// Which program feeds Remote Display Camera, from the extension's custom device property
/// 'feed' (server-mac/CameraExtension/main.swift). The extension lets any program feed it,
/// one at a time, so the app shows a feeder other than its engine (decision 0033, option 2).
enum CameraFeeder {
    /// The pid feeding the sink, or nil: none does, or this app doesn't see the device.
    static func pid() -> pid_t? {
        guard let device = device(named: "Remote Display Camera") else { return nil }
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(fourCC("feed")),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        guard CMIOObjectHasProperty(device, &address),
              let text = string(device, &address) else { return nil }
        return pid_t(text)
    }

    /// The name of the program `pid` runs, or "pid N" when macOS won't say.
    static func programName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "pid \(pid)" }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }

    private static func device(named name: String) -> CMIOObjectID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return nil }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == 0 else { return nil }
        var nameAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        return ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size)
            .first { string($0, &nameAddress) == name }
    }

    /// A CFString property, which is how CoreMediaIO hands over an extension's string.
    private static func string(_ object: CMIOObjectID, _ address: inout CMIOObjectPropertyAddress) -> String? {
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(object, &address, 0, nil,
                                      UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, $0)
        }
        guard status == 0, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
