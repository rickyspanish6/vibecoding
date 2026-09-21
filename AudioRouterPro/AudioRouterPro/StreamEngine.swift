import Combine
import CoreAudio
import Foundation

enum LegState: Equatable {
    case idle
    case connecting
    /// Receiver is actively consuming: timing queries within the last ~3 s.
    case streaming
    /// RTSP session is up but the receiver is not polling our timing port —
    /// it accepted the session without playing it (busy/shadowed receiver).
    case connectedNotConsuming
    /// Receiver demands AirPlay 2 (HAP) authentication we don't implement.
    case authRequired
    case failed(String)
}

/// One AirPlay receiver leg: owns a RAOPSender plus a feeder thread that
/// pulls from the shared ring buffer, resamples to 44.1 kHz Int16, and
/// paces RTP packets by data availability (the capture side produces in
/// real time, so availability *is* the clock).
final class ReceiverLeg {
    let receiver: DiscoveredReceiver
    let sender: RAOPSender

    /// Feeder starts this far behind the capture head; also part of the
    /// local-leg delay so the legs line up.
    static let backlogSeconds = 0.1

    private let ring: RingBuffer
    private let ringRate: Double
    private var thread: Thread?
    private var lock = os_unfair_lock_s()
    private var running = false

    init(receiver: DiscoveredReceiver, ring: RingBuffer, ringRate: Double) {
        self.receiver = receiver
        self.ring = ring
        self.ringRate = ringRate
        sender = RAOPSender(host: receiver.host, port: receiver.port)
    }

    /// Blocking RTSP handshake — call from a background queue.
    func start(volumeDB: Float) throws {
        try sender.connect(volumeDB: volumeDB)
        os_unfair_lock_lock(&lock)
        running = true
        os_unfair_lock_unlock(&lock)

        let thread = Thread { [weak self] in self?.feederLoop() }
        thread.name = "raop-feeder-\(receiver.name)"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        os_unfair_lock_lock(&lock)
        running = false
        os_unfair_lock_unlock(&lock)
        sender.disconnect()
    }

    private var isRunning: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return running
    }

    private func feederLoop() {
        let outFrames = RAOPSender.framesPerPacket
        let ratio = ringRate / Double(RAOPSender.sampleRate)
        let spanFrames = Int(ceil(Double(outFrames) * ratio)) + 2
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: spanFrames * 2)
        defer { scratch.deallocate() }

        // Start slightly behind the head: bounded initial burst, then the
        // real-time producer paces us.
        var cursor = Double(ring.writeIndex) - Self.backlogSeconds * ringRate
        var packet = [Int16](repeating: 0, count: outFrames * 2)

        while isRunning {
            let base = Int64(cursor)
            guard ring.writeIndex >= base + Int64(spanFrames) else {
                Thread.sleep(forTimeInterval: 0.004)
                continue
            }
            ring.read(into: scratch, frames: spanFrames, at: base)
            let offset = cursor - Double(base)
            for i in 0..<outFrames {
                let position = offset + Double(i) * ratio
                let index = Int(position)
                let fraction = Float(position - Double(index))
                for channel in 0..<2 {
                    let a = scratch[index * 2 + channel]
                    let b = scratch[(index + 1) * 2 + channel]
                    let sample = a + (b - a) * fraction
                    packet[i * 2 + channel] = Int16(max(-32768, min(32767, sample * 32767)))
                }
            }
            sender.send(frames: packet)
            cursor += Double(outFrames) * ratio
        }
    }
}

/// Coordinates the Airfoil-style pipeline: system-audio tap → ring buffer →
/// local playback leg + N AirPlay legs. Owns permission state, discovery,
/// device selection, volumes, and sync.
final class StreamEngine: ObservableObject {
    static let shared = StreamEngine()

    // MARK: - Published state

    @Published private(set) var isRouting = false
    /// Set after the tap was refused — the TCC permission is missing.
    @Published private(set) var permissionDenied = false
    @Published private(set) var localDevices: [AudioDevice] = []
    @Published private(set) var receivers: [DiscoveredReceiver] = []
    @Published private(set) var legStates: [String: LegState] = [:]
    @Published private(set) var alertMessage: String?
    /// 0…1 RMS of the captured signal — proof in the UI that samples flow.
    @Published private(set) var captureLevel: Float = 0

    @Published var selectedLocalUID: String? {
        didSet {
            defaults.set(selectedLocalUID, forKey: Keys.localUID)
            if isRouting, oldValue != selectedLocalUID { restartLocalLeg() }
        }
    }

    @Published var masterVolume: Float = 0.75 {
        didSet {
            defaults.set(masterVolume, forKey: Keys.masterVolume)
            applyVolumes()
        }
    }

    /// Manual fine-trim on the automatic sync delay (Airfoil's Sync slider).
    @Published var syncTrimMS: Double = 0 {
        didSet {
            defaults.set(syncTrimMS, forKey: Keys.syncTrim)
            updateLocalDelay()
        }
    }

    // MARK: - Private state

    private enum Keys {
        static let localUID = "localPlaybackUID"
        static let masterVolume = "masterVolume"
        static let syncTrim = "syncTrimMS"
        static let receiverVolumes = "receiverVolumes"
    }

    private let defaults = UserDefaults.standard
    private var capture: SystemAudioCapture?
    private var localPlayer: LocalPlayer?
    private var legs: [String: ReceiverLeg] = [:]
    private var receiverVolumes: [String: Float]
    private var discovery: AirPlayDiscovery?
    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var levelTimer: Timer?
    private var legMonitorTimer: Timer?
    private let workQueue = DispatchQueue(label: "stream-engine", qos: .userInitiated)

    private init() {
        selectedLocalUID = defaults.string(forKey: Keys.localUID)
        if defaults.object(forKey: Keys.masterVolume) != nil {
            masterVolume = defaults.float(forKey: Keys.masterVolume)
        }
        syncTrimMS = defaults.double(forKey: Keys.syncTrim)
        receiverVolumes = (defaults.dictionary(forKey: Keys.receiverVolumes) as? [String: Double])?
            .mapValues { Float($0) } ?? [:]

        refreshLocalDevices()
        installDeviceListListener()
        let discovery = AirPlayDiscovery { [weak self] found in
            self?.receivers = found
        }
        discovery.start()
        self.discovery = discovery
    }

    func shutdown() {
        stopRouting()
        discovery?.stop()
    }

    // Exposed for the debug self-test harness only.
    var debugCapture: SystemAudioCapture? { capture }
    var debugLocalPlayer: LocalPlayer? { localPlayer }
    func debugLeg(_ name: String) -> ReceiverLeg? { legs[name] }

    // MARK: - Derived state

    var selectedLocalDevice: AudioDevice? {
        localDevices.first { $0.uid == selectedLocalUID }
            ?? localDevices.first { $0.transport == .builtIn }
    }

    var statusLine: String {
        guard isRouting else { return "Idle — system audio untouched" }
        var parts = [selectedLocalDevice?.name ?? "Local"]
        parts += legs.keys.sorted().filter { legStates[$0] == .streaming }
        return "Routing to " + parts.joined(separator: " + ")
    }

    var menuBarSymbolName: String {
        if alertMessage != nil || permissionDenied { return "exclamationmark.triangle.fill" }
        return isRouting ? "hifispeaker.2.fill" : "hifispeaker.2"
    }

    func legState(_ name: String) -> LegState { legStates[name] ?? .idle }

    func receiverVolume(_ name: String) -> Float { receiverVolumes[name] ?? 0.75 }

    // MARK: - Routing lifecycle

    /// Starts capture (may trigger the TCC prompt) and the local leg. The
    /// tap mutes normal playback, so from here the app owns the audio path.
    func startRouting() {
        guard !isRouting else { return }
        alertMessage = nil

        let capture = SystemAudioCapture()
        do {
            try capture.start()
        } catch {
            permissionDenied = true
            alertMessage = error.localizedDescription
            return
        }
        permissionDenied = false
        self.capture = capture

        let player = LocalPlayer(ring: capture.ring, sampleRate: capture.sampleRate,
                                 initialDelaySeconds: 0.1)
        do {
            try player.start(deviceID: selectedLocalDevice?.id, volume: masterVolume)
        } catch {
            capture.stop()
            self.capture = nil
            alertMessage = "Local playback failed: \(error.localizedDescription)"
            return
        }
        localPlayer = player
        isRouting = true
        startLevelTimer()
    }

    func stopRouting() {
        for (name, leg) in legs {
            leg.stop()
            legStates[name] = .idle
        }
        legs.removeAll()
        localPlayer?.stop()
        localPlayer = nil
        capture?.stop() // destroys the tap → system playback un-mutes
        capture = nil
        levelTimer?.invalidate()
        levelTimer = nil
        captureLevel = 0
        isRouting = false
    }

    private func restartLocalLeg() {
        guard let capture, let localPlayer else { return }
        do {
            try localPlayer.start(deviceID: selectedLocalDevice?.id, volume: masterVolume)
        } catch {
            alertMessage = "Local playback failed: \(error.localizedDescription)"
            _ = capture // capture keeps running; audio resumes on next device pick
        }
        updateLocalDelay()
    }

    // MARK: - AirPlay legs

    func toggleTransmit(_ receiver: DiscoveredReceiver) {
        if let leg = legs[receiver.name] {
            leg.stop()
            legs.removeValue(forKey: receiver.name)
            legStates[receiver.name] = .idle
            updateLocalDelay()
            return
        }

        guard !receiver.requiresAuth else { return }
        if !isRouting { startRouting() }
        guard isRouting, let capture else { return }

        legStates[receiver.name] = .connecting
        let leg = ReceiverLeg(receiver: receiver, ring: capture.ring, ringRate: capture.sampleRate)
        legs[receiver.name] = leg
        let volumeDB = volumeToDB(effectiveVolume(receiver.name))
        workQueue.async { [weak self] in
            do {
                try leg.start(volumeDB: volumeDB)
                // Sonos: attach the session to the zone's playback pipeline
                // (classic RAOP alone leaves the transport STOPPED).
                if let mac = receiver.macHint {
                    SonosTransportKick.kick(host: receiver.host, mac: mac)
                }
                DispatchQueue.main.async {
                    // Provisional: the monitor flips it to .streaming only
                    // once the receiver demonstrably consumes (timing polls).
                    self?.legStates[receiver.name] = .connectedNotConsuming
                    self?.updateLocalDelay()
                    self?.startLegMonitor()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.legs.removeValue(forKey: receiver.name)
                    self?.legStates[receiver.name] = Self.classify(error)
                    self?.updateLocalDelay()
                }
            }
        }
    }

    /// Maps RTSP failures to user-meaningful states: auth-refusals get the
    /// AirPlay 2 badge instead of a generic "Failed".
    private static func classify(_ error: Error) -> LegState {
        if case RAOPSender.SenderError.rtspError(_, let status) = error {
            switch status {
            case 401, 403, 470: return .authRequired
            case 453: return .failed("Receiver is busy with another AirPlay session")
            default: break
            }
        }
        if case RAOPSender.SenderError.connectionFailed(let why) = error,
           why.contains("No route to host") || why.contains("Host is down") {
            return .failed("Blocked by macOS Local Network permission — toggle AudioRouterPro off and on under System Settings → Privacy & Security → Local Network, then retry.")
        }
        return .failed(error.localizedDescription)
    }

    /// Engagement-based status: "Streaming" only while the receiver has hit
    /// our timing port within the last ~3 s; never optimistic.
    private func startLegMonitor() {
        guard legMonitorTimer == nil else { return }
        legMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.legs.isEmpty {
                self.legMonitorTimer?.invalidate()
                self.legMonitorTimer = nil
                return
            }
            for (name, leg) in self.legs {
                switch self.legStates[name] {
                case .streaming, .connectedNotConsuming:
                    self.legStates[name] = leg.sender.receiverEngaged ? .streaming : .connectedNotConsuming
                default:
                    break
                }
                if AudioDebug.enabled {
                    let s = leg.sender.snapshotStats()
                    AudioDebug.log("leg[\(name)] engaged=\(leg.sender.receiverEngaged) timingQ=\(s.timingQueries) ctrl=\(s.controlPackets) resend=\(s.resendRequests) syncs=\(s.syncsSent) audioPkts=\(s.audioPacketsSent) sendErrs=\(s.audioSendErrors) errno=\(s.lastSendErrno) rms=\(s.lastAudioRMS) vol=\(s.lastVolumeDB)dB")
                }
            }
        }
    }

    func setReceiverVolume(_ name: String, _ value: Float) {
        receiverVolumes[name] = value
        defaults.set(receiverVolumes.mapValues(Double.init), forKey: Keys.receiverVolumes)
        guard let leg = legs[name] else { return }
        let db = volumeToDB(effectiveVolume(name))
        workQueue.async { leg.sender.setVolume(db: db) }
    }

    // MARK: - Sync + volume

    /// Airfoil's sync model: delay the local leg to the slowest AirPlay leg
    /// (negotiated latency + feeder backlog), plus the user's fine trim.
    private func updateLocalDelay() {
        guard let localPlayer else { return }
        let maxLatency = legs.values
            .map { Double($0.sender.totalLatencyFrames) / Double(RAOPSender.sampleRate) }
            .max()
        let delay: Double
        if let maxLatency {
            delay = maxLatency + ReceiverLeg.backlogSeconds + syncTrimMS / 1000
        } else {
            delay = 0.1
        }
        localPlayer.setDelay(seconds: delay)
    }

    private func applyVolumes() {
        localPlayer?.volume = masterVolume
        for (name, leg) in legs {
            let db = volumeToDB(effectiveVolume(name))
            workQueue.async { leg.sender.setVolume(db: db) }
        }
    }

    private func effectiveVolume(_ name: String) -> Float {
        masterVolume * receiverVolume(name)
    }

    /// RAOP volume scale: 0 → mute (-144), otherwise -30…0 dB.
    private func volumeToDB(_ value: Float) -> Float {
        value <= 0.001 ? -144 : -30 + 30 * min(value, 1)
    }

    // MARK: - Local devices

    func refreshLocalDevices() {
        localDevices = CoreAudioHAL.outputDevices().filter {
            $0.transport != .airPlay && $0.transport != .aggregate && $0.transport != .virtual
        }
    }

    private func installDeviceListListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.refreshLocalDevices()
            // Selected output vanished mid-route: fall back to built-in.
            if self.isRouting, self.selectedLocalUID != nil,
               !self.localDevices.contains(where: { $0.uid == self.selectedLocalUID }) {
                self.alertMessage = "Output device disconnected — playing through \(self.selectedLocalDevice?.name ?? "built-in speakers")."
                self.restartLocalLeg()
            }
        }
        devicesListenerBlock = block
        var address = CoreAudioHAL.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(CoreAudioHAL.systemObject, &address, .main, block)
    }

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, let capture = self.capture else { return }
            self.captureLevel = min(1, capture.ring.recentRMS(frames: 2048) * 4)
        }
    }

    func clearAlert() {
        alertMessage = nil
    }
}
