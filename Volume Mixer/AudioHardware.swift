import CoreAudio
import Foundation

struct MixerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw MixerError("\(operation) failed (\(status)).") }
    }

    static func address(_ key: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: key, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ id: AudioObjectID, _ key: AudioObjectPropertySelector, _ initial: T,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var addr = address(key, scope)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutableBytes(of: &result) { bytes in
            try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bytes.baseAddress!), "Read property \(key)")
        }
        guard size == MemoryLayout<T>.size else { throw MixerError("Incomplete Core Audio property \(key).") }
        return result
    }

    static func string(_ id: AudioObjectID, _ key: AudioObjectPropertySelector) throws -> String {
        let value: Unmanaged<CFString>? = try read(id, key, Optional<Unmanaged<CFString>>.none)
        guard let value else { throw MixerError("Missing Core Audio name or UID.") }
        return value.takeRetainedValue() as String
    }

    static func ids(_ id: AudioObjectID, _ key: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var addr = address(key, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size), "Size property \(key)")
        guard size > 0 else { return [] }
        let width = MemoryLayout<AudioObjectID>.stride
        guard Int(size).isMultiple(of: width) else { throw MixerError("Malformed Core Audio object list.") }
        var items = Array(repeating: AudioObjectID(0), count: Int(size) / width)
        try items.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bytes.baseAddress!), "Read list \(key)")
        }
        return Array(items.prefix(Int(size) / width))
    }
}

struct OutputRoute: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let rate: Double
    let channels: UInt32
    let flags: UInt32

    static func current() throws -> OutputRoute {
        let id = try HAL.read(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
        let streams = try HAL.ids(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard streams.count == 1 else { throw MixerError("Select an output with one mono or stereo stream.") }
        let f = try HAL.read(streams[0], kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
        return try OutputRoute(id: id, uid: HAL.string(id, kAudioDevicePropertyDeviceUID),
                               name: HAL.string(id, kAudioObjectPropertyName), rate: f.mSampleRate,
                               channels: f.mChannelsPerFrame, flags: f.mFormatFlags)
    }
}
