import AVFoundation
import CoreAudio
import Foundation
import os

// MARK: - Ring buffer

/// Interleaved stereo float ring buffer with absolute frame indexing: one
/// real-time writer (the capture IOProc), any number of readers that each
/// track their own absolute cursor. Readers request frames by absolute
/// position; anything outside the valid window is zero-filled.
final class RingBuffer {
    let channels = 2
    let capacityFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private var lock = os_unfair_lock_s()
    private var _writeIndex: Int64 = 0

    init(capacityFrames: Int) {
        self.capacityFrames = capacityFrames
        storage = .allocate(capacity: capacityFrames * channels)
        storage.initialize(repeating: 0, count: capacityFrames * channels)
    }

    deinit { storage.deallocate() }

    /// Total frames ever written (the head of the stream).
    var writeIndex: Int64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _writeIndex
    }

    func write(interleaved input: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        os_unfair_lock_lock(&lock)
        var remaining = frames
        var src = input
        var position = Int(_writeIndex % Int64(capacityFrames))
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - position)
            memcpy(storage + position * channels, src, chunk * channels * MemoryLayout<Float>.size)
            src += chunk * channels
            position = (position + chunk) % capacityFrames
            remaining -= chunk
        }
        _writeIndex += Int64(frames)
        os_unfair_lock_unlock(&lock)
    }

    /// Copies `frames` interleaved frames starting at absolute `position`.
    /// Regions older than the ring window or newer than the head come back
    /// as silence.
    func read(into output: UnsafeMutablePointer<Float>, frames: Int, at position: Int64) {
        memset(output, 0, frames * channels * MemoryLayout<Float>.size)
        os_unfair_lock_lock(&lock)
        let head = _writeIndex
        let tail = max(0, head - Int64(capacityFrames))
        let start = max(position, tail)
        let end = min(position + Int64(frames), head)
        if start < end {
            var absolute = start
            var destination = output + Int(start - position) * channels
            var remaining = Int(end - start)
            while remaining > 0 {
                let ringPosition = Int(absolute % Int64(capacityFrames))
                let chunk = min(remaining, capacityFrames - ringPosition)
                memcpy(destination, storage + ringPosition * channels, chunk * channels * MemoryLayout<Float>.size)
                destination += chunk * channels
                absolute += Int64(chunk)
                remaining -= chunk
            }
        }
        os_unfair_lock_unlock(&lock)
    }

    /// RMS of the most recent `frames`, for the UI level meter.
    func recentRMS(frames: Int) -> Float {
        let count = min(frames, 4096)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count * channels)
        defer { buffer.deallocate() }
        read(into: buffer, frames: count, at: writeIndex - Int64(count))
        var sum: Float = 0
        for i in 0..<(count * channels) { sum += buffer[i] * buffer[i] }
        return sqrt(sum / Float(count * channels))
    }
}

// MARK: - System audio capture (Core Audio process tap)

enum CaptureError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateFailed(OSStatus)
    case ioProcFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            return "System audio capture was refused (OSStatus \(status)). Grant access under System Settings → Privacy & Security → Screen & System Audio Recording."
        case .aggregateFailed(let status):
            return "Could not create the capture device (OSStatus \(status))."
        case .ioProcFailed(let status):
            return "Could not start the capture stream (OSStatus \(status))."
        }
    }
}

/// Captures the whole system output with a global Core Audio process tap
/// (macOS 14.4+). The tap uses `muteBehavior = .muted`, which silences the
/// tapped audio at the physical output device — the app's own legs become the
/// only audible path, so there is no double-playback by construction.
/// The tap is wrapped in a private aggregate device whose IOProc feeds the
/// shared ring buffer.
final class SystemAudioCapture {
    let ring = RingBuffer(capacityFrames: 48000 * 30)
    private(set) var sampleRate: Double = 44100
    private(set) var isRunning = false

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2)

    private static let aggregateUID = "com.umamy.AudioRouterPro.capture"

    deinit {
        stop()
        scratch.deallocate()
    }

    /// Creating the tap triggers the system-audio-recording TCC prompt on
    /// first use; a denial surfaces as `tapCreationFailed`.
    func start() throws {
        guard !isRunning else { return }

        // Exclude our own process from the global tap. The tap mutes every
        // process it captures, and the local playback leg lives in this
        // process — a tap without the exclusion mutes the app's own output
        // (silent speakers) and feeds it back into the capture.
        // The exclude-variant stays dynamic: processes launched later are
        // captured automatically.
        var excluded: [AudioObjectID] = []
        if ProcessInfo.processInfo.environment["AUDIOROUTER_NO_EXCLUDE"] == nil,
           let selfObject = Self.processObject(forPID: getpid()) {
            excluded = [selfObject]
        }
        AudioDebug.log("tap exclusion list: \(excluded) (pid \(getpid()))")

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "AudioRouter Pro System Tap"
        description.isPrivate = true
        description.muteBehavior = .muted

        var tap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != 0 else {
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        tapID = tap

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioRouter Pro Capture",
            kAudioAggregateDeviceUIDKey: Self.aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: 1,
                ],
            ],
        ]
        var aggregate: AudioDeviceID = 0
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard aggregateStatus == noErr, aggregate != 0 else {
            AudioHardwareDestroyProcessTap(tap)
            tapID = 0
            throw CaptureError.aggregateFailed(aggregateStatus)
        }
        aggregateID = aggregate

        // Prefer 44.1 kHz so the RAOP leg needs no resampling; fall back to
        // whatever the tap/aggregate reports.
        let rateAddress = CoreAudioHAL.address(kAudioDevicePropertyNominalSampleRate)
        _ = CoreAudioHAL.setFloat64(aggregate, rateAddress, 44100)
        if let rate = CoreAudioHAL.getFloat64(aggregate, rateAddress), rate > 0 {
            sampleRate = rate
        } else if let format = tapFormat(), format.mSampleRate > 0 {
            sampleRate = format.mSampleRate
        }

        var procID: AudioDeviceIOProcID?
        let ring = self.ring
        let scratch = self.scratch
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, inputData, _, _, _ in
            Self.writeInput(inputData, to: ring, scratch: scratch)
        }
        guard ioStatus == noErr, let procID else {
            teardownDevices()
            throw CaptureError.ioProcFailed(ioStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregate, procID)
            ioProcID = nil
            teardownDevices()
            throw CaptureError.ioProcFailed(startStatus)
        }
        isRunning = true
    }

    /// Destroying the tap also un-mutes normal system playback.
    func stop() {
        guard isRunning || tapID != 0 || aggregateID != 0 else { return }
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        teardownDevices()
        isRunning = false
    }

    private func teardownDevices() {
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    /// Translates a Unix PID into the HAL's process object ID (the currency
    /// CATapDescription's include/exclude lists use).
    private static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = CoreAudioHAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifierPtr in
            AudioObjectGetPropertyData(CoreAudioHAL.systemObject, &address,
                                       UInt32(MemoryLayout<pid_t>.size), qualifierPtr,
                                       &size, &object)
        }
        guard status == noErr, object != 0 else { return nil }
        return object
    }

    private func tapFormat() -> AudioStreamBasicDescription? {
        var address = CoreAudioHAL.address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }

    /// Normalizes whatever buffer layout the HAL delivers (interleaved stereo
    /// or split mono buffers) into the interleaved ring.
    private static func writeInput(_ inputData: UnsafePointer<AudioBufferList>,
                                   to ring: RingBuffer, scratch: UnsafeMutablePointer<Float>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard list.count > 0 else { return }

        if list.count == 1, list[0].mNumberChannels >= 2, let data = list[0].mData {
            let frames = Int(list[0].mDataByteSize) / (Int(list[0].mNumberChannels) * MemoryLayout<Float>.size)
            let samples = data.assumingMemoryBound(to: Float.self)
            if list[0].mNumberChannels == 2 {
                ring.write(interleaved: samples, frames: frames)
            } else {
                let channels = Int(list[0].mNumberChannels)
                let clamped = min(frames, 16384)
                for frame in 0..<clamped {
                    scratch[frame * 2] = samples[frame * channels]
                    scratch[frame * 2 + 1] = samples[frame * channels + 1]
                }
                ring.write(interleaved: scratch, frames: clamped)
            }
        } else if let left = list[0].mData {
            // De-interleaved: buffer 0 = left, buffer 1 = right (or mono).
            let frames = min(Int(list[0].mDataByteSize) / MemoryLayout<Float>.size, 16384)
            let leftSamples = left.assumingMemoryBound(to: Float.self)
            let rightSamples = (list.count > 1 ? list[1].mData : nil)?.assumingMemoryBound(to: Float.self) ?? leftSamples
            for frame in 0..<frames {
                scratch[frame * 2] = leftSamples[frame]
                scratch[frame * 2 + 1] = rightSamples[frame]
            }
            ring.write(interleaved: scratch, frames: frames)
        }
    }
}

// MARK: - Local playback leg

/// Renders the ring buffer to a user-selected output device through
/// AVAudioEngine, `delaySeconds` behind the capture head. The delay is the
/// sync mechanism: it is set to the AirPlay leg's negotiated latency so both
/// outputs play together (Airfoil's model — delay everyone to the slowest).
///
/// Delay changes are handled without replaying audio: when the delay grows,
/// the render callback holds its cursor and plays silence until the target
/// catches up; when it shrinks by more than a jump threshold, the cursor
/// skips forward.
final class LocalPlayer {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ring: RingBuffer
    private let sampleRate: Double
    private(set) var isRunning = false

    private var lock = os_unfair_lock_s()
    private var delayFrames: Int64
    private var cursor: Int64 = -1
    private var scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2)

    // Debug instrumentation (stage 2/3 of the pipeline self-test).
    private var framesServed: Int64 = 0
    private var holdCallbacks: Int64 = 0
    private var renderCallbacks: Int64 = 0
    private var engineOutputRMS: Float = 0

    struct Diagnostics {
        var delaySeconds: Double
        var cursorLagFrames: Int64   // ring head - cursor (should ≈ delay)
        var framesServed: Int64
        var holdCallbacks: Int64
        var renderCallbacks: Int64
        var engineRunning: Bool
        var outputDeviceID: AudioDeviceID
        var outputSampleRate: Double
        var mixerVolume: Float
        var engineOutputRMS: Float
    }

    func diagnostics() -> Diagnostics {
        os_unfair_lock_lock(&lock)
        let delay = Double(delayFrames) / sampleRate
        let lag = ring.writeIndex - cursor
        let served = framesServed
        let holds = holdCallbacks
        let renders = renderCallbacks
        let rms = engineOutputRMS
        os_unfair_lock_unlock(&lock)

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if let audioUnit = engine.outputNode.audioUnit {
            AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &deviceID, &size)
        }
        return Diagnostics(
            delaySeconds: delay,
            cursorLagFrames: lag,
            framesServed: served,
            holdCallbacks: holds,
            renderCallbacks: renders,
            engineRunning: engine.isRunning,
            outputDeviceID: deviceID,
            outputSampleRate: engine.outputNode.outputFormat(forBus: 0).sampleRate,
            mixerVolume: engine.mainMixerNode.outputVolume,
            engineOutputRMS: rms)
    }

    init(ring: RingBuffer, sampleRate: Double, initialDelaySeconds: Double) {
        self.ring = ring
        self.sampleRate = sampleRate
        delayFrames = Int64(initialDelaySeconds * sampleRate)
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    func setDelay(seconds: Double) {
        os_unfair_lock_lock(&lock)
        delayFrames = Int64(max(0.02, seconds) * sampleRate)
        os_unfair_lock_unlock(&lock)
    }

    func start(deviceID: AudioDeviceID?, volume: Float) throws {
        stop()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw CaptureError.ioProcFailed(-1)
        }

        let ring = self.ring
        let scratch = self.scratch
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            os_unfair_lock_lock(&self.lock)
            let target = ring.writeIndex - self.delayFrames
            if self.cursor < 0 { self.cursor = target }
            // Delay grew: hold position, render silence until real time catches up.
            let holding = self.cursor > target
            // Fell behind (delay shrank or long stall): jump forward.
            if !holding, target - self.cursor > Int64(self.sampleRate / 2) {
                self.cursor = target
            }
            let position = self.cursor
            if !holding { self.cursor += Int64(frames) }
            self.renderCallbacks += 1
            if holding { self.holdCallbacks += 1 } else { self.framesServed += Int64(frames) }
            os_unfair_lock_unlock(&self.lock)

            if holding {
                for buffer in buffers where buffer.mData != nil {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return noErr
            }

            ring.read(into: scratch, frames: frames, at: position)
            if buffers.count >= 2,
               let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
               let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<frames {
                    left[frame] = scratch[frame * 2]
                    right[frame] = scratch[frame * 2 + 1]
                }
            } else if let mono = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<frames {
                    mono[frame] = (scratch[frame * 2] + scratch[frame * 2 + 1]) * 0.5
                }
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node

        // Stage-3 probe: RMS of what actually leaves the engine's mixer.
        if AudioDebug.enabled {
            engine.mainMixerNode.removeTap(onBus: 0)
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
                guard let self, let data = buffer.floatChannelData else { return }
                var sum: Float = 0
                let count = Int(buffer.frameLength)
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<count { sum += data[channel][frame] * data[channel][frame] }
                }
                let rms = count > 0 ? sqrt(sum / Float(count * Int(buffer.format.channelCount))) : 0
                os_unfair_lock_lock(&self.lock)
                self.engineOutputRMS = rms
                os_unfair_lock_unlock(&self.lock)
            }
        }

        if let deviceID, let audioUnit = engine.outputNode.audioUnit {
            var device = deviceID
            AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &device,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        engine.mainMixerNode.outputVolume = volume
        os_unfair_lock_lock(&lock)
        cursor = -1
        os_unfair_lock_unlock(&lock)
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning || sourceNode != nil else { return }
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
        }
        sourceNode = nil
        isRunning = false
    }
}
