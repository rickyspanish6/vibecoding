import AudioToolbox
import CoreAudio
import Foundation

/// Transport categories, used for the UI badge and for auto-picking the
/// aggregate clock master (wired clocks are steadier than network ones).
enum DeviceTransport {
    case builtIn
    case usb
    case thunderbolt
    case pci
    case fireWire
    case hdmi
    case displayPort
    case avb
    case airPlay
    case bluetooth
    case virtual
    case aggregate
    case other

    init(rawTransportType: UInt32) {
        switch rawTransportType {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeFireWire: self = .fireWire
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAVB: self = .avb
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        default: self = .other
        }
    }

    var badgeLabel: String {
        switch self {
        case .builtIn: return "Built-in"
        case .usb: return "USB"
        case .thunderbolt: return "Thunderbolt"
        case .pci: return "PCI"
        case .fireWire: return "FireWire"
        case .hdmi: return "HDMI"
        case .displayPort: return "DisplayPort"
        case .avb: return "AVB"
        case .airPlay: return "AirPlay"
        case .bluetooth: return "Bluetooth"
        case .virtual: return "Virtual"
        case .aggregate: return "Aggregate"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .builtIn: return "laptopcomputer"
        case .usb: return "cable.connector"
        case .thunderbolt, .pci: return "bolt"
        case .fireWire: return "cable.coaxial"
        case .hdmi, .displayPort: return "display"
        case .avb: return "network"
        case .airPlay: return "airplayaudio"
        case .bluetooth: return "dot.radiowaves.right"
        case .virtual: return "waveform"
        case .aggregate: return "square.stack.3d.down.right"
        case .other: return "speaker.wave.2"
        }
    }

    /// Lower rank wins when auto-picking the clock master: prefer wired
    /// transports whose clocks barely drift over network/wireless ones.
    var clockMasterRank: Int {
        switch self {
        case .usb: return 0
        case .builtIn: return 1
        case .thunderbolt: return 2
        case .pci: return 3
        case .fireWire: return 4
        case .hdmi: return 5
        case .displayPort: return 6
        case .avb: return 7
        case .other: return 8
        case .virtual: return 9
        case .aggregate: return 10
        case .bluetooth: return 11
        case .airPlay: return 12
        }
    }

    /// Aggregates and virtual loopback devices are hidden unless the user
    /// enables "Show advanced devices".
    var isAdvanced: Bool { self == .virtual || self == .aggregate }
}

/// A snapshot of a CoreAudio output device at enumeration time.
/// `uid` is the stable identifier persisted across launches; `id` is only
/// valid for the current HAL session.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: DeviceTransport
}

/// Thin wrappers over the CoreAudio HAL property API.
enum CoreAudioHAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func getUInt32(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setUInt32(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: UInt32) -> OSStatus {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(objectID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func setFloat32(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: Float32) -> OSStatus {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(objectID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func getFloat64(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float64? {
        var address = address
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setFloat64(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: Float64) -> OSStatus {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(objectID, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
    }

    static func getString(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
              let cfString = value?.takeRetainedValue() else { return nil }
        return cfString as String
    }

    static func getObjectIDs(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        getObjectIDs(systemObject, address(kAudioHardwarePropertyDevices))
    }

    static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        getString(deviceID, address(kAudioDevicePropertyDeviceUID))
    }

    static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        getString(deviceID, address(kAudioObjectPropertyName))
    }

    static func transportType(_ deviceID: AudioDeviceID) -> UInt32? {
        getUInt32(deviceID, address(kAudioDevicePropertyTransportType))
    }

    static func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let bufferList = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        getUInt32(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice))
    }

    @discardableResult
    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> OSStatus {
        setUInt32(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice), deviceID)
    }

    // MARK: - Data sources
    //
    // On macOS versions where AirPlay is one HAL device whose receivers are
    // selectable data sources, these are how a specific receiver is targeted.

    static func dataSourceIDs(_ deviceID: AudioDeviceID) -> [UInt32] {
        var address = address(kAudioDevicePropertyDataSources, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(deviceID, &address) else { return [] }
        return getObjectIDs(deviceID, address)
    }

    static func dataSourceName(_ deviceID: AudioDeviceID, sourceID: UInt32) -> String? {
        var sourceID = sourceID
        var nameRef: Unmanaged<CFString>?
        var status: OSStatus = noErr
        withUnsafeMutablePointer(to: &sourceID) { sourcePtr in
            withUnsafeMutablePointer(to: &nameRef) { namePtr in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(sourcePtr),
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(namePtr),
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                var address = address(kAudioDevicePropertyDataSourceNameForIDCFString,
                                      scope: kAudioObjectPropertyScopeOutput)
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &translation)
            }
        }
        guard status == noErr, let cfString = nameRef?.takeRetainedValue() else { return nil }
        return cfString as String
    }

    static func currentDataSource(_ deviceID: AudioDeviceID) -> UInt32? {
        getUInt32(deviceID, address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput))
    }

    @discardableResult
    static func setDataSource(_ deviceID: AudioDeviceID, sourceID: UInt32) -> OSStatus {
        setUInt32(deviceID, address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput), sourceID)
    }

    // MARK: - Volume

    private static var virtualMainVolumeAddress: AudioObjectPropertyAddress {
        address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    }

    /// Whether the device exposes any software-settable output volume control
    /// (virtual main volume or channel-1 scalar). AirPlay/HDMI devices often
    /// don't — their volume is fixed or controlled on the receiver.
    static func hasSettableVolume(_ deviceID: AudioDeviceID) -> Bool {
        var settable = DarwinBoolean(false)
        var main = virtualMainVolumeAddress
        if AudioObjectHasProperty(deviceID, &main),
           AudioObjectIsPropertySettable(deviceID, &main, &settable) == noErr,
           settable.boolValue {
            return true
        }
        var channel = address(kAudioDevicePropertyVolumeScalar,
                              scope: kAudioObjectPropertyScopeOutput,
                              element: 1)
        if AudioObjectHasProperty(deviceID, &channel),
           AudioObjectIsPropertySettable(deviceID, &channel, &settable) == noErr,
           settable.boolValue {
            return true
        }
        return false
    }

    /// Tries the virtual main volume first, then per-channel scalars.
    static func setDeviceVolume(_ value: Float, deviceID: AudioDeviceID) {
        var settable = DarwinBoolean(false)
        var main = virtualMainVolumeAddress
        if AudioObjectHasProperty(deviceID, &main),
           AudioObjectIsPropertySettable(deviceID, &main, &settable) == noErr,
           settable.boolValue {
            _ = setFloat32(deviceID, virtualMainVolumeAddress, value)
            return
        }
        for channel in 1...2 {
            let channelAddress = address(kAudioDevicePropertyVolumeScalar,
                                         scope: kAudioObjectPropertyScopeOutput,
                                         element: AudioObjectPropertyElement(channel))
            _ = setFloat32(deviceID, channelAddress, value)
        }
    }

    /// Enumerates every device that has at least one output channel. AirPlay
    /// receivers only show up here after macOS has resolved them via Bonjour
    /// (typically after they have been used once from Control Center), which
    /// is why callers should re-run this on `kAudioHardwarePropertyDevices`
    /// change notifications rather than enumerating once.
    static func outputDevices() -> [AudioDevice] {
        allDeviceIDs().compactMap { deviceID in
            guard outputChannelCount(deviceID) > 0,
                  let uid = deviceUID(deviceID),
                  let name = deviceName(deviceID) else { return nil }
            let transport = transportType(deviceID).map(DeviceTransport.init(rawTransportType:)) ?? .other
            return AudioDevice(id: deviceID, uid: uid, name: name, transport: transport)
        }
    }
}
