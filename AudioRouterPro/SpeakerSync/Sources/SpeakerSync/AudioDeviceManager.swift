import CoreAudio
import Foundation

struct AudioDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32

    var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }
    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
    var isAggregate: Bool {
        transportType == kAudioDeviceTransportTypeAggregate
            || transportType == kAudioDeviceTransportTypeAutoAggregate
    }
    var isVirtual: Bool { transportType == kAudioDeviceTransportTypeVirtual }

    var transportLabel: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return "Aggregate"
        default: return "Other"
        }
    }
}

enum CoreAudioHelper {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func getUInt32(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func getString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func getObjectIDs(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}

/// Enumerates HAL output devices and reports hardware topology changes.
final class AudioDeviceManager {
    var onDevicesChanged: (() -> Void)?
    var onDefaultOutputChanged: (() -> Void)?

    private let systemID = AudioObjectID(kAudioObjectSystemObject)
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?

    func startListening() {
        var devicesAddr = CoreAudioHelper.address(kAudioHardwarePropertyDevices)
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDevicesChanged?()
        }
        AudioObjectAddPropertyListenerBlock(systemID, &devicesAddr, DispatchQueue.main, devicesBlock)
        devicesListener = devicesBlock

        var defaultAddr = CoreAudioHelper.address(kAudioHardwarePropertyDefaultOutputDevice)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDefaultOutputChanged?()
        }
        AudioObjectAddPropertyListenerBlock(systemID, &defaultAddr, DispatchQueue.main, defaultBlock)
        defaultOutputListener = defaultBlock
    }

    func stopListening() {
        if let block = devicesListener {
            var addr = CoreAudioHelper.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(systemID, &addr, DispatchQueue.main, block)
            devicesListener = nil
        }
        if let block = defaultOutputListener {
            var addr = CoreAudioHelper.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(systemID, &addr, DispatchQueue.main, block)
            defaultOutputListener = nil
        }
    }

    /// All HAL devices that have at least one output stream, excluding aggregates.
    func outputDevices() -> [AudioDevice] {
        CoreAudioHelper.getObjectIDs(systemID, kAudioHardwarePropertyDevices).compactMap { id in
            guard hasOutputStreams(id),
                  let uid = CoreAudioHelper.getString(id, kAudioDevicePropertyDeviceUID),
                  let name = CoreAudioHelper.getString(id, kAudioDevicePropertyDeviceNameCFString)
            else { return nil }
            let transport = CoreAudioHelper.getUInt32(id, kAudioDevicePropertyTransportType) ?? 0
            let device = AudioDevice(id: id, uid: uid, name: name, transportType: transport)
            guard !device.isAggregate else { return nil }
            return device
        }
    }

    func device(withUID uid: String) -> AudioDevice? {
        outputDevices().first { $0.uid == uid }
    }

    func currentDefaultOutputID() -> AudioObjectID? {
        CoreAudioHelper.getUInt32(systemID, kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        var addr = CoreAudioHelper.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }
}
