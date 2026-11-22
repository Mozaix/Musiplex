import CoreAudio
import Foundation
import Observation

/// The Mac's sound outputs: built-in speakers, AirPods and other Bluetooth
/// headphones or speakers, AirPlay, HDMI, USB. Picking one makes it the Mac's
/// output, and Musiplex (which follows the Mac's output) plays there.
@MainActor @Observable
final class AudioOutputs {
    struct Output: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
        let transport: UInt32

        var isBluetooth: Bool {
            transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }

        var symbol: String {
            let n = name.lowercased()
            if n.contains("airpods max") { return "airpodsmax" }
            if n.contains("airpods pro") { return "airpodspro" }
            if n.contains("airpods") { return "airpods" }
            if n.contains("beats") { return "beats.headphones" }
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
            case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                return n.contains("head") || n.contains("bud") || n.contains("ear") ? "headphones" : "hifispeaker.fill"
            default: return "speaker.wave.2.fill"
            }
        }
    }

    private(set) var outputs: [Output] = []
    private(set) var current: AudioDeviceID = 0

    init() {
        refresh()
        // Keep the list fresh as AirPods and speakers connect, and when the output changes elsewhere.
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    var currentOutput: Output? { outputs.first { $0.id == current } }

    func refresh() {
        current = Self.defaultOutput()
        outputs = Self.deviceIDs().compactMap { id in
            guard Self.hasOutput(id) else { return nil }
            let transport = Self.uint32(id, kAudioDevicePropertyTransportType)
            // Aggregate and virtual devices (meeting apps, recorders) aren't speakers.
            // (The one in use is always shown, so the menu can tick it.)
            guard id == current || (transport != kAudioDeviceTransportTypeAggregate && transport != kAudioDeviceTransportTypeVirtual) else { return nil }
            return Output(id: id, name: Self.name(id), transport: transport)
        }
        .sorted { ($0.transport == kAudioDeviceTransportTypeBuiltIn ? 0 : 1, $0.name) < ($1.transport == kAudioDeviceTransportTypeBuiltIn ? 0 : 1, $1.name) }
    }

    /// Makes this the Mac's sound output.
    func select(_ output: Output) {
        var id = output.id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        refresh()
    }

    // MARK: CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultOutput() -> AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func uint32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func name(_ id: AudioDeviceID) -> String {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return "Speaker" }
        return name.takeRetainedValue() as String
    }
}
