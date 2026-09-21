import CoreAudio
import Foundation

enum MultiOutputError: LocalizedError {
    case noDevices
    case osStatus(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case .noDevices:
            return "No output devices selected."
        case .osStatus(let status, let operation):
            return "\(operation) failed (OSStatus \(status))."
        }
    }
}

/// Owns the lifecycle of the stacked (multi-output) aggregate device:
/// creation, drift compensation, default-output switching, and teardown.
final class MultiOutputController {
    static let aggregateName = "SpeakerSync Multi-Output"
    static let aggregateUIDPrefix = "ca.umamy.speakersync.aggregate."

    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private(set) var activeSubDeviceUIDs: Set<String> = []
    private var previousDefaultUID: String?

    private let deviceManager: AudioDeviceManager
    private let systemID = AudioObjectID(kAudioObjectSystemObject)

    var isActive: Bool { aggregateID != kAudioObjectUnknown }

    init(deviceManager: AudioDeviceManager) {
        self.deviceManager = deviceManager
    }

    /// Creates the aggregate from `devices`, remembers the current default
    /// output, and makes the aggregate the system default.
    func activate(devices: [AudioDevice]) throws {
        guard !devices.isEmpty else { throw MultiOutputError.noDevices }

        if previousDefaultUID == nil,
           let currentID = deviceManager.currentDefaultOutputID(),
           currentID != aggregateID {
            previousDefaultUID = CoreAudioHelper.getString(currentID, kAudioDevicePropertyDeviceUID)
        }

        let newID = try createAggregate(devices: devices)

        let oldID = aggregateID
        aggregateID = newID
        activeSubDeviceUIDs = Set(devices.map(\.uid))

        try setDefaultOutput(newID)
        if oldID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(oldID)
        }
    }

    /// Rebuilds the aggregate with a new device set (e.g. after a Bluetooth
    /// device connects or disconnects) while staying the default output.
    func rebuild(devices: [AudioDevice]) throws {
        guard isActive else { return }
        try activate(devices: devices)
    }

    /// Restores the previous default output and destroys the aggregate.
    func deactivate(restoreDefault: Bool = true) {
        guard isActive else { return }

        if restoreDefault {
            let restoredID = previousDefaultUID.flatMap { deviceManager.device(withUID: $0)?.id }
                ?? deviceManager.outputDevices().first { $0.isBuiltIn }?.id
            if let restoredID {
                try? setDefaultOutput(restoredID)
            }
        }

        AudioHardwareDestroyAggregateDevice(aggregateID)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        activeSubDeviceUIDs = []
        previousDefaultUID = nil
    }

    // MARK: - Aggregate creation

    private func createAggregate(devices: [AudioDevice]) throws -> AudioObjectID {
        let clockMaster = pickClockMaster(devices)

        let subDeviceList: [[String: Any]] = devices.map { device in
            [
                kAudioSubDeviceUIDKey: device.uid,
                // The clock master keeps its native clock; everyone else
                // resamples to follow it.
                kAudioSubDeviceDriftCompensationKey: device.uid == clockMaster.uid ? 0 : 1,
            ]
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.aggregateName,
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceSubDeviceListKey: subDeviceList,
            kAudioAggregateDeviceMainSubDeviceKey: clockMaster.uid,
            // "Stacked" = multi-output: every sub-device gets the same
            // mixed-down signal, matching Audio MIDI Setup's
            // "Create Multi-Output Device". Without it the aggregate
            // concatenates channels across sub-devices instead.
            kAudioAggregateDeviceIsStackedKey: 1,
            kAudioAggregateDeviceIsPrivateKey: 0,
        ]

        var newID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID)
        guard status == noErr, newID != kAudioObjectUnknown else {
            throw MultiOutputError.osStatus(status, "AudioHardwareCreateAggregateDevice")
        }

        enforceDriftCompensation(aggregate: newID, clockMasterUID: clockMaster.uid)
        return newID
    }

    /// Prefer a wired/internal clock source: built-in first, then any
    /// non-Bluetooth device, then whatever is available.
    private func pickClockMaster(_ devices: [AudioDevice]) -> AudioDevice {
        devices.first { $0.isBuiltIn }
            ?? devices.first { !$0.isBluetooth && !$0.isVirtual }
            ?? devices[0]
    }

    /// Some macOS versions ignore the drift key in the composition dict, so
    /// re-apply it. The property lives on the aggregate's owned AudioSubDevice
    /// objects, not on the underlying devices. Best-effort.
    private func enforceDriftCompensation(aggregate: AudioObjectID, clockMasterUID: String) {
        for subID in ownedSubDeviceObjects(of: aggregate) {
            guard let uid = CoreAudioHelper.getString(subID, kAudioDevicePropertyDeviceUID),
                  uid != clockMasterUID else { continue }
            var addr = CoreAudioHelper.address(kAudioSubDevicePropertyDriftCompensation)
            var enabled: UInt32 = 1
            AudioObjectSetPropertyData(subID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &enabled)
        }
    }

    private func ownedSubDeviceObjects(of aggregate: AudioObjectID) -> [AudioObjectID] {
        var addr = CoreAudioHelper.address(kAudioObjectPropertyOwnedObjects)
        var qualifier: AudioClassID = kAudioSubDeviceClassID
        let qualifierSize = UInt32(MemoryLayout<AudioClassID>.size)
        var size: UInt32 = 0
        let sizeStatus = withUnsafePointer(to: &qualifier) { q in
            AudioObjectGetPropertyDataSize(aggregate, &addr, qualifierSize, q, &size)
        }
        guard sizeStatus == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { q in
            AudioObjectGetPropertyData(aggregate, &addr, qualifierSize, q, &size, &ids)
        }
        return status == noErr ? ids : []
    }

    // MARK: - Default output

    private func setDefaultOutput(_ deviceID: AudioObjectID) throws {
        var addr = CoreAudioHelper.address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = deviceID
        let status = AudioObjectSetPropertyData(
            systemID, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value
        )
        guard status == noErr else {
            throw MultiOutputError.osStatus(status, "Set default output device")
        }
    }
}
