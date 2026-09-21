import AppKit
import CoreAudio
import Foundation

/// Debug switches. `AUDIOROUTER_DEBUG=1` turns on stage logging;
/// `AUDIOROUTER_SELFTEST=1` additionally runs the automated pipeline test on
/// launch and exits with a pass/fail code. Kept in the build for sync tuning.
enum AudioDebug {
    static let selfTest = ProcessInfo.processInfo.environment["AUDIOROUTER_SELFTEST"] == "1"
    /// Name of a receiver to stream to headlessly for ~30 s (integrated-path
    /// RAOP test), e.g. AUDIOROUTER_RAOPTEST=One.
    static let raopTestReceiver = ProcessInfo.processInfo.environment["AUDIOROUTER_RAOPTEST"]
    static let enabled = selfTest || raopTestReceiver != nil
        || ProcessInfo.processInfo.environment["AUDIOROUTER_DEBUG"] != nil

    static func log(_ message: String) {
        guard enabled else { return }
        emit("[audio-debug] \(message)")
    }

    /// Self-test runs launched via LaunchServices have no visible stdout, so
    /// everything is mirrored to a log file.
    static let logPath = "/tmp/audiorouter-selftest.log"

    static func emit(_ line: String) {
        print(line)
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? (line + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }
}

/// Automated end-to-end check of the capture → ring → engine → device chain
/// using `afplay` as a deterministic signal source. Verifies, in order:
///   stage 1 — ring ingest (write head advances, RMS above threshold)
///   stage 2 — ring → source-node handoff (frames served, no permanent hold,
///             delay at its no-AirPlay floor)
///   stage 3 — engine output (mixer-tap RMS, engine running, device matches)
///   stage 4 — device-level activity (kAudioDevicePropertyDeviceIsRunningSomewhere)
/// plus a feedback check (RMS must decay once the source stops) and an
/// unmute check (default output active again after routing stops).
enum SelfTest {
    private static let sound = "/System/Library/Sounds/Submarine.aiff"

    static func run(engine: StreamEngine) {
        Thread.detachNewThread {
            let passed = execute(engine: engine)
            AudioDebug.emit("[selftest] \(passed ? "ALL STAGES PASSED" : "FAILED")")
            DispatchQueue.main.async {
                engine.stopRouting()
                exit(passed ? 0 : 1)
            }
        }
    }

    private static func execute(engine: StreamEngine) -> Bool {
        AudioDebug.emit("[selftest] starting; excluding self: \(ProcessInfo.processInfo.environment["AUDIOROUTER_NO_EXCLUDE"] == nil)")

        DispatchQueue.main.sync { engine.startRouting() }
        guard DispatchQueue.main.sync(execute: { engine.isRouting }) else {
            AudioDebug.emit("[selftest] FAIL: routing did not start (capture permission?)")
            return false
        }
        guard let capture = engine.debugCapture, let player = engine.debugLocalPlayer else {
            AudioDebug.emit("[selftest] FAIL: engine internals unavailable")
            return false
        }
        let expectedDevice = DispatchQueue.main.sync(execute: { engine.selectedLocalDevice })
        AudioDebug.emit("[selftest] ring rate \(capture.sampleRate) Hz; local device \(expectedDevice?.name ?? "?") (id \(expectedDevice?.id ?? 0))")

        // Deterministic source, looped for ~6 s.
        let playerProcess = playSoundRepeatedly(times: 4)
        defer { playerProcess?.terminate() }

        var maxRingRMS: Float = 0
        var maxEngineRMS: Float = 0
        var ringAdvanced = false
        var deviceRan = false
        var servedGrew = false
        var lastServed: Int64 = 0
        var delaySeconds = 0.0
        var diag = player.diagnostics()

        let startHead = capture.ring.writeIndex
        for tick in 0..<16 {
            Thread.sleep(forTimeInterval: 0.4)
            let head = capture.ring.writeIndex
            let ringRMS = capture.ring.recentRMS(frames: 2048)
            diag = player.diagnostics()
            if head > startHead { ringAdvanced = true }
            maxRingRMS = max(maxRingRMS, ringRMS)
            maxEngineRMS = max(maxEngineRMS, diag.engineOutputRMS)
            if diag.framesServed > lastServed { servedGrew = true }
            lastServed = diag.framesServed
            delaySeconds = diag.delaySeconds
            if let device = expectedDevice, deviceIsRunningSomewhere(device.id) { deviceRan = true }
            AudioDebug.emit(String(format: "[selftest] t=%.1fs head=+%d ringRMS=%.4f served=%d holds=%d delay=%.2fs engineRMS=%.4f engineRunning=%@ dev=%d@%.0fHz vol=%.2f",
                         Double(tick + 1) * 0.4, head - startHead, ringRMS,
                         diag.framesServed, diag.holdCallbacks, diag.delaySeconds,
                         diag.engineOutputRMS,
                         diag.engineRunning ? "yes" : "NO",
                         diag.outputDeviceID, diag.outputSampleRate, diag.mixerVolume))
        }

        // Feedback check: source stopped → capture should decay to silence.
        playerProcess?.terminate()
        Thread.sleep(forTimeInterval: 2.5)
        let decayedRMS = capture.ring.recentRMS(frames: 2048)

        let deviceMatches = expectedDevice == nil || diag.outputDeviceID == expectedDevice!.id
        let stage1 = ringAdvanced && maxRingRMS > 0.001
        let stage2 = servedGrew && delaySeconds < 0.2
        let stage3 = maxEngineRMS > 0.001 && diag.engineRunning && deviceMatches && diag.mixerVolume > 0.01
        let stage4 = deviceRan
        let feedback = decayedRMS < max(0.01, maxRingRMS * 0.1)

        AudioDebug.emit("[selftest] stage1 ring ingest:      \(stage1 ? "PASS" : "FAIL") (advanced=\(ringAdvanced) maxRMS=\(maxRingRMS))")
        AudioDebug.emit("[selftest] stage2 source handoff:   \(stage2 ? "PASS" : "FAIL") (served=\(lastServed) delay=\(delaySeconds)s holds=\(diag.holdCallbacks))")
        AudioDebug.emit("[selftest] stage3 engine output:    \(stage3 ? "PASS" : "FAIL") (maxRMS=\(maxEngineRMS) running=\(diag.engineRunning) deviceMatch=\(deviceMatches) vol=\(diag.mixerVolume))")
        AudioDebug.emit("[selftest] stage4 device activity:  \(stage4 ? "PASS" : "FAIL")")
        AudioDebug.emit("[selftest] feedback decay:          \(feedback ? "PASS" : "FAIL") (post-stop RMS=\(decayedRMS))")

        // Unmute check: routing off → default system output works again.
        DispatchQueue.main.sync { engine.stopRouting() }
        Thread.sleep(forTimeInterval: 0.5)
        let unmuteProcess = playSound()
        Thread.sleep(forTimeInterval: 1.0)
        var unmuted = false
        if let defaultDevice = CoreAudioHAL.defaultOutputDeviceID() {
            unmuted = deviceIsRunningSomewhere(defaultDevice)
        }
        unmuteProcess?.waitUntilExit()
        AudioDebug.emit("[selftest] unmute after stop:       \(unmuted ? "PASS" : "FAIL")")

        return stage1 && stage2 && stage3 && stage4 && feedback && unmuted
    }

    /// Integrated-path RAOP test: start routing, transmit to the named
    /// receiver through the real StreamEngine/ReceiverLeg machinery, and
    /// judge by receiver engagement (timing-query liveness).
    static func runRAOP(engine: StreamEngine, receiverName: String) {
        Thread.detachNewThread {
            AudioDebug.emit("[raoptest] integrated test to '\(receiverName)'")
            DispatchQueue.main.sync { engine.startRouting() }
            guard DispatchQueue.main.sync(execute: { engine.isRouting }) else {
                AudioDebug.emit("[raoptest] FAIL: routing did not start")
                exit(2)
            }

            // Wait for Bonjour to resolve the receiver.
            var receiver: DiscoveredReceiver?
            for _ in 0..<20 {
                receiver = DispatchQueue.main.sync {
                    engine.receivers.first { $0.name == receiverName }
                }
                if receiver != nil { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard let receiver else {
                AudioDebug.emit("[raoptest] FAIL: receiver '\(receiverName)' not discovered")
                DispatchQueue.main.sync { engine.stopRouting() }
                exit(2)
            }
            AudioDebug.emit("[raoptest] resolved \(receiver.name) at \(receiver.host):\(receiver.port) requiresAuth=\(receiver.requiresAuth)")

            DispatchQueue.main.sync { engine.toggleTransmit(receiver) }
            let source = playSoundRepeatedly(times: 20)
            defer { source?.terminate() }

            var engagedTicks = 0
            for tick in 0..<30 {
                Thread.sleep(forTimeInterval: 1.0)
                let leg = DispatchQueue.main.sync { engine.debugLeg(receiverName) }
                guard let leg else {
                    let state = DispatchQueue.main.sync { engine.legState(receiverName) }
                    AudioDebug.emit("[raoptest] leg gone at t=\(tick)s state=\(state)")
                    break
                }
                let stats = leg.sender.snapshotStats()
                let engaged = leg.sender.receiverEngaged
                if engaged { engagedTicks += 1 }
                let ringRMS = DispatchQueue.main.sync { engine.debugCapture?.ring.recentRMS(frames: 2048) ?? -1 }
                AudioDebug.emit("[raoptest] t=\(tick)s engaged=\(engaged) timingQ=\(stats.timingQueries) ctrl=\(stats.controlPackets) resend=\(stats.resendRequests) syncs=\(stats.syncsSent) audioPkts=\(stats.audioPacketsSent) sendErrs=\(stats.audioSendErrors) errno=\(stats.lastSendErrno) rms=\(stats.lastAudioRMS) ringRMS=\(ringRMS) vol=\(stats.lastVolumeDB)dB")
            }

            let verdict = engagedTicks >= 10
            AudioDebug.emit("[raoptest] engagedTicks=\(engagedTicks)/30 → \(verdict ? "RECEIVER CONSUMED STREAM" : "RECEIVER NEVER ENGAGED")")
            DispatchQueue.main.sync { engine.stopRouting() }
            exit(verdict ? 0 : 3)
        }
    }

    private static func playSound() -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [sound]
        try? process.run()
        return process
    }

    private static func playSoundRepeatedly(times: Int) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "for i in $(seq \(times)); do /usr/bin/afplay \(sound); done"]
        try? process.run()
        return process
    }

    private static func deviceIsRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        CoreAudioHAL.getUInt32(deviceID, CoreAudioHAL.address(kAudioDevicePropertyDeviceIsRunningSomewhere)) == 1
    }
}
