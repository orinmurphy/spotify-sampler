import AudioToolbox
import CoreAudio
import Darwin
import Foundation

enum TapError: LocalizedError {
    case osStatus(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case let .osStatus(what, status): return "\(what) failed (OSStatus \(status))"
        }
    }
}

@inline(__always)
func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    if status != noErr { throw TapError.osStatus(what(), status) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func read<T>(_ selector: AudioObjectPropertySelector, default value: T) throws -> T {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &result), "Read property \(selector)")
        return result
    }

    func readArray(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size), "Read size \(selector)")
        var array = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if array.isEmpty { return [] }
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &array), "Read array \(selector)")
        return array
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try withUnsafeMutablePointer(to: &value) { ptr in
            try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, ptr), "Read string \(selector)")
        }
        return (value?.takeRetainedValue() as String?) ?? ""
    }
}

enum CoreAudioUtils {
    /// All Core Audio process objects that belong to Spotify (main app + Chromium audio helper).
    static func spotifyProcessObjects() -> [AudioObjectID] {
        guard let all = try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList) else { return [] }
        return all.filter { obj in
            if let bundleID = try? obj.readString(kAudioProcessPropertyBundleID),
               bundleID.lowercased().hasPrefix("com.spotify.client") {
                return true
            }
            if let pid = try? obj.read(kAudioProcessPropertyPID, default: pid_t(0)), pid > 0 {
                return executablePath(of: pid).contains("/Spotify.app/")
            }
            return false
        }.sorted()
    }

    static func defaultOutputDeviceUID() throws -> String {
        let device = try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultSystemOutputDevice, default: AudioObjectID.unknown
        )
        return try device.readString(kAudioDevicePropertyDeviceUID)
    }

    static func executablePath(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }
}
