import CryptoKit
import Darwin
import Foundation

/// A minimal AirPlay-audio (RAOP) sender speaking the classic v2 protocol:
/// RTSP session control over TCP, uncompressed L16 audio over RTP/UDP, plus
/// the sync (control) and NTP (timing) side channels. Targets receivers that
/// accept unencrypted classic RAOP (`et=0` in their Bonjour TXT record —
/// Sonos-class AirPlay 2 speakers, AirPort Express, many third parties).
/// HomePod/Apple TV require AirPlay 2 HAP pairing and are NOT supported here.
///
/// Wire behavior was ported from the protocol as implemented by
/// philippe44/libraop and verified packet-for-packet against a Sonos One.
final class RAOPSender {
    enum SenderError: LocalizedError {
        case connectionFailed(String)
        case rtspError(method: String, status: Int)
        case notConnected

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let why): return "Could not reach the receiver: \(why)"
            case .rtspError(let method, let status): return "Receiver refused \(method) (RTSP \(status))"
            case .notConnected: return "Not connected"
            }
        }
    }

    static let sampleRate = 44100
    static let framesPerPacket = 352
    /// Receivers add this on top of their advertised latency (libraop's
    /// RAOP_LATENCY_MIN, empirically required).
    static let latencyMinFrames: UInt32 = 11025

    let host: String
    let port: UInt16

    /// Advertised receiver latency + the fixed minimum: delay the local leg
    /// by this many frames to play in sync. Valid after connect().
    private(set) var totalLatencyFrames: UInt32 = 44100 + RAOPSender.latencyMinFrames

    var log: (String) -> Void = { print("[raop] \($0)") }

    /// Evidence of receiver engagement. A receiver that is actually playing
    /// polls our timing port continuously (~1/s) for the whole session; a
    /// session that handshakes but never queries timing was accepted but is
    /// not being consumed (busy/shadowed receiver, or it gave up).
    struct Stats {
        var timingQueries = 0
        var lastTimingQueryAt: Date?
        var controlPackets = 0
        var resendRequests = 0
        var syncsSent = 0
        var audioPacketsSent = 0
        var lastAudioRMS: Float = 0
        var lastVolumeDB: Float = 0
        /// Failed sendto() calls on the audio socket. Nonzero means packets
        /// never left this machine — e.g. UDP egress denied by the Local
        /// Network privacy layer while TCP still works.
        var audioSendErrors = 0
        var lastSendErrno: Int32 = 0
    }

    private var stats = Stats()
    private let statsLock = NSLock()

    func snapshotStats() -> Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return stats
    }

    /// True while the receiver has queried our timing port in the last 3 s.
    var receiverEngaged: Bool {
        statsLock.lock()
        defer { statsLock.unlock() }
        guard let last = stats.lastTimingQueryAt else { return false }
        return -last.timeIntervalSinceNow < 3
    }

    private func updateStats(_ mutate: (inout Stats) -> Void) {
        statsLock.lock()
        mutate(&stats)
        statsLock.unlock()
    }

    // RTSP
    private var rtspFD: Int32 = -1
    private var cseq = 0
    private var session: String?
    private var localIP = ""
    private var url = ""
    private let clientInstance = String(format: "%08X%08X", UInt32.random(in: .min ... .max), UInt32.random(in: .min ... .max))
    private let dacpID = String(format: "%08X%08X", UInt32.random(in: .min ... .max), UInt32.random(in: .min ... .max))
    private let activeRemote = String(UInt32.random(in: .min ... .max))
    private let rtspLock = NSLock()

    // RTP
    private var audioFD: Int32 = -1
    private var controlFD: Int32 = -1
    private var timingFD: Int32 = -1
    private var peerAudioPort: UInt16 = 0
    private var peerControlPort: UInt16 = 0
    private var peerTimingPort: UInt16 = 0
    private var seqNumber: UInt16 = .random(in: 0...0x7fff)
    private var headTS: UInt64 = 0
    private let ssrc = UInt32.random(in: .min ... .max)
    private var firstPacket = true
    private var running = false
    private let stateLock = NSLock()

    // Retransmit backlog: last N packets, indexed by sequence number.
    private static let backlogSize = 512
    private var backlog: [Data?]

    private var timingThread: Thread?
    private var controlThread: Thread?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        backlog = Array(repeating: nil, count: Self.backlogSize)
    }

    deinit { disconnect() }

    // MARK: - NTP helpers (seconds since 1900 << 32 | fraction)

    static func ntpNow() -> UInt64 {
        var tv = timeval()
        gettimeofday(&tv, nil)
        let seconds = UInt64(tv.tv_sec) + 2_208_988_800 // 1900 → 1970 offset
        let fraction = (UInt64(tv.tv_usec) << 32) / 1_000_000
        return (seconds << 32) | fraction
    }

    static func ntpToTimestamp(_ ntp: UInt64, rate: Int) -> UInt64 {
        (ntp >> 32) * UInt64(rate) + (((ntp & 0xFFFF_FFFF) * UInt64(rate)) >> 32)
    }

    static func timestampToNTP(_ ts: UInt64, rate: Int) -> UInt64 {
        ((ts / UInt64(rate)) << 32) + (((ts % UInt64(rate)) << 32) / UInt64(rate))
    }

    // MARK: - Connection lifecycle

    /// Full RTSP handshake. Blocking; call off the main thread.
    /// `volumeDB` is the RAOP scale: -30 (quiet) … 0 (full), -144 = mute.
    func connect(volumeDB: Float, authSetup: Bool = true) throws {
        try openRTSP()

        // Timing responder must exist before SETUP (some receivers probe it).
        try openUDPSockets()
        running = true
        startTimingThread()

        // MFi/AirPlay2-compat receivers (et includes 4) expect an
        // auth-setup exchange even when streaming unencrypted.
        if authSetup {
            let key = Curve25519.KeyAgreement.PrivateKey()
            var body = Data([0x01])
            body.append(key.publicKey.rawRepresentation)
            _ = try? request(method: "POST", uri: "/auth-setup",
                             contentType: "application/octet-stream", body: body)
        }

        let sid = String(format: "%010u", UInt32.random(in: .min ... .max))
        url = "rtsp://\(localIP)/\(sid)"

        let sdp = """
        v=0\r
        o=iTunes \(sid) 0 IN IP4 \(localIP)\r
        s=iTunes\r
        c=IN IP4 \(host)\r
        t=0 0\r
        m=audio 0 RTP/AVP 96\r
        a=rtpmap:96 L16/\(Self.sampleRate)/2\r

        """
        _ = try request(method: "ANNOUNCE", contentType: "application/sdp",
                        body: Data(sdp.utf8))

        let localControl = try boundPort(of: controlFD)
        let localTiming = try boundPort(of: timingFD)
        let setup = try request(method: "SETUP", headers: [
            "Transport": "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=\(localControl);timing_port=\(localTiming)",
        ])
        session = setup.headers["Session"]?.trimmingCharacters(in: .whitespaces)
        guard let transport = setup.headers["Transport"] else {
            throw SenderError.connectionFailed("SETUP response missing Transport")
        }
        for part in transport.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, let value = UInt16(kv[1]) else { continue }
            switch kv[0] {
            case "server_port": peerAudioPort = value
            case "control_port": peerControlPort = value
            case "timing_port": peerTimingPort = value
            default: break
            }
        }
        guard peerAudioPort != 0 else {
            throw SenderError.connectionFailed("no server_port in SETUP response")
        }

        headTS = Self.ntpToTimestamp(Self.ntpNow(), rate: Self.sampleRate)
        let record = try request(method: "RECORD", headers: [
            "Range": "npt=0-",
            "RTP-Info": "seq=\(seqNumber &+ 1);rtptime=\(UInt32(truncatingIfNeeded: headTS))",
        ])
        if let latency = record.headers["Audio-Latency"].flatMap({ UInt32($0.trimmingCharacters(in: .whitespaces)) }) {
            totalLatencyFrames = max(latency, 44100) + Self.latencyMinFrames
        }
        log("connected; receiver latency \(totalLatencyFrames) frames (\(totalLatencyFrames * 1000 / UInt32(Self.sampleRate)) ms)")

        setVolume(db: volumeDB)
        firstPacket = true
        startControlThread()
    }

    func disconnect() {
        stateLock.lock()
        let wasRunning = running
        running = false
        stateLock.unlock()
        guard wasRunning else { return }

        if session != nil {
            _ = try? request(method: "FLUSH", headers: [
                "RTP-Info": "seq=\(seqNumber &+ 1);rtptime=\(UInt32(truncatingIfNeeded: headTS &+ 1))",
            ])
            _ = try? request(method: "TEARDOWN")
        }
        for fd in [rtspFD, audioFD, controlFD, timingFD] where fd >= 0 { close(fd) }
        rtspFD = -1; audioFD = -1; controlFD = -1; timingFD = -1
        session = nil
    }

    /// RAOP volume scale: -30…0 dB, -144 mutes. Map a 0…1 slider with
    /// `db = -30 + 30 * value` (0 → -144).
    func setVolume(db: Float) {
        updateStats { $0.lastVolumeDB = db }
        AudioDebug.log("raop[\(host)] SET_PARAMETER volume: \(db) dB")
        let body = "volume: \(db)\r\n"
        _ = try? request(method: "SET_PARAMETER", contentType: "text/parameters",
                         body: Data(body.utf8))
    }

    // MARK: - Audio

    /// Sends exactly one RTP packet of `framesPerPacket` interleaved stereo
    /// Int16 host-endian frames. The caller paces delivery at real-time rate
    /// (the capture pipeline does this naturally).
    func send(frames: [Int16]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running, frames.count == Self.framesPerPacket * 2 else { return }

        if firstPacket { sendSync(first: true) }

        seqNumber &+= 1
        var packet = Data(capacity: 12 + frames.count * 2)
        packet.append(0x80)
        packet.append(firstPacket ? 0xE0 : 0x60)
        firstPacket = false
        packet.appendBE(seqNumber)
        packet.appendBE(UInt32(truncatingIfNeeded: headTS))
        packet.appendBE(ssrc)
        for sample in frames {
            packet.appendBE(UInt16(bitPattern: sample))
        }

        backlog[Int(seqNumber) % Self.backlogSize] = packet
        let sent = sendUDP(audioFD, packet, toPort: peerAudioPort)
        if !sent {
            let err = errno
            updateStats { stats in
                stats.audioSendErrors += 1
                stats.lastSendErrno = err
            }
            if AudioDebug.enabled, seqNumber % 125 == 0 {
                AudioDebug.log("raop[\(host)] AUDIO SEND FAILED errno=\(err) (\(String(cString: strerror(err))))")
            }
        }
        headTS &+= UInt64(Self.framesPerPacket)

        updateStats { stats in
            stats.audioPacketsSent += 1
            if stats.audioPacketsSent % 32 == 0 {
                var sum: Float = 0
                for sample in frames {
                    let value = Float(sample) / 32768
                    sum += value * value
                }
                stats.lastAudioRMS = sqrt(sum / Float(frames.count))
            }
        }

        // Timestamp-axis health: RTP timestamps must track wall-clock NTP
        // (that's the contract the sync packets promise). If ts falls behind
        // "now", the receiver treats every packet as late and discards it —
        // an engaged but silent session.
        if AudioDebug.enabled, seqNumber % 125 == 0 {
            let tsNTP = Self.timestampToNTP(headTS, rate: Self.sampleRate)
            let now = Self.ntpNow()
            let driftMS = (Double(Int64(bitPattern: tsNTP &- now)) / 4_294_967_296.0) * 1000
            AudioDebug.log("raop[\(host)] seq=\(seqNumber) ts-vs-now=\(Int(driftMS))ms")
        }
    }

    /// NTP time at which the frame at the head of the stream will be heard.
    var playbackHorizonNTP: UInt64 {
        Self.timestampToNTP(headTS + UInt64(totalLatencyFrames), rate: Self.sampleRate)
    }

    // MARK: - Sync + timing channels

    /// 20-byte sync packet on the control channel: tells the receiver how the
    /// RTP timestamp axis maps onto NTP time. Sent before the first audio
    /// packet (with the extension bit) and roughly every second after.
    private func sendSync(first: Bool) {
        var packet = Data(capacity: 20)
        packet.append(first ? 0x90 : 0x80)
        packet.append(0xD4)
        packet.appendBE(UInt16(7)) // fixed by protocol
        packet.appendBE(UInt32(truncatingIfNeeded: headTS &- UInt64(totalLatencyFrames &- Self.latencyMinFrames)))
        packet.appendBE(Self.timestampToNTP(headTS, rate: Self.sampleRate))
        packet.appendBE(UInt32(truncatingIfNeeded: headTS))
        sendUDP(controlFD, packet, toPort: peerControlPort)
        updateStats { $0.syncsSent += 1 }
        if first {
            AudioDebug.log("raop[\(host)] first sync sent (ts \(headTS))")
        }
    }

    private func startControlThread() {
        let thread = Thread { [weak self] in
            var lastSync = Date.distantPast
            var lastKeepalive = Date()
            while let self, self.isRunning {
                if -lastSync.timeIntervalSinceNow >= 1.0 {
                    self.stateLock.lock()
                    if !self.firstPacket { self.sendSync(first: false) }
                    self.stateLock.unlock()
                    lastSync = Date()
                }
                // AirPlay-2-compat receivers drop idle RTSP connections.
                if -lastKeepalive.timeIntervalSinceNow >= 25 {
                    _ = try? self.request(method: "OPTIONS", uri: "*")
                    lastKeepalive = Date()
                }
                self.handleResendRequests()
            }
        }
        thread.name = "raop-control"
        controlThread = thread
        thread.start()
    }

    /// Control channel receive side: type 0x55 packets ask for lost audio
    /// packets, answered from the backlog wrapped in a retransmit header.
    private func handleResendRequests() {
        var buffer = [UInt8](repeating: 0, count: 32)
        let n = recvWithTimeout(controlFD, &buffer, timeoutMS: 300)
        guard n >= 8 else { return }
        updateStats { $0.controlPackets += 1 }
        guard buffer[1] & 0x7F == 0x55 else { return }
        updateStats { $0.resendRequests += 1 }
        let firstSeq = UInt16(buffer[4]) << 8 | UInt16(buffer[5])
        let count = UInt16(buffer[6]) << 8 | UInt16(buffer[7])
        stateLock.lock()
        defer { stateLock.unlock() }
        for i in 0..<count {
            let seq = firstSeq &+ i
            guard let original = backlog[Int(seq) % Self.backlogSize] else { continue }
            // Verify the backlog slot still holds the wanted sequence number.
            guard original.count > 3,
                  UInt16(original[2]) << 8 | UInt16(original[3]) == seq else { continue }
            var packet = Data(capacity: 4 + original.count)
            packet.append(0x80)
            packet.append(0xD6)
            packet.appendBE(seq)
            packet.append(original)
            sendUDP(controlFD, packet, toPort: peerControlPort)
        }
    }

    /// Timing channel: the receiver sends NTP queries (0x52); we answer
    /// (0x53) with our clock so it can align its DAC with our timestamps.
    /// Replies go to the query's source address: the first query arrives
    /// while SETUP is still in flight (i.e. before we know the receiver's
    /// timing port), and receivers wait for the answer before completing
    /// SETUP.
    private func startTimingThread() {
        let thread = Thread { [weak self] in
            while let self, self.isRunning {
                var buffer = [UInt8](repeating: 0, count: 32)
                var source = sockaddr_in()
                let n = self.recvfromWithTimeout(self.timingFD, &buffer, from: &source, timeoutMS: 500)
                guard n >= 32, buffer[1] & 0x7F == 0x52 else { continue }
                self.updateStats { stats in
                    stats.timingQueries += 1
                    stats.lastTimingQueryAt = Date()
                }
                var reply = Data(capacity: 32)
                reply.append(buffer[0] & 0xEF)
                reply.append(0xD3)
                reply.append(contentsOf: buffer[2..<4])   // echo sequence
                reply.appendBE(UInt32(0))                 // dummy
                reply.append(contentsOf: buffer[24..<32]) // origin = their transmit time
                let now = Self.ntpNow()
                reply.appendBE(now)                       // receive time
                reply.appendBE(now)                       // transmit time
                self.sendUDP(self.timingFD, reply, to: source)
            }
        }
        thread.name = "raop-timing"
        timingThread = thread
        thread.start()
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    // MARK: - RTSP plumbing

    private func openRTSP() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SenderError.connectionFailed("socket() failed") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            close(fd)
            throw SenderError.connectionFailed("bad address \(host)")
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            close(fd)
            throw SenderError.connectionFailed(String(cString: strerror(errno)))
        }
        rtspFD = fd

        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &len)
            }
        }
        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
        localIP = String(cString: ip)
    }

    struct RTSPResponse {
        let status: Int
        let headers: [String: String]
    }

    @discardableResult
    private func request(method: String, uri: String? = nil,
                         headers: [String: String] = [:],
                         contentType: String? = nil, body: Data = Data()) throws -> RTSPResponse {
        rtspLock.lock()
        defer { rtspLock.unlock() }
        guard rtspFD >= 0 else { throw SenderError.notConnected }

        cseq += 1
        var text = "\(method) \(uri ?? url) RTSP/1.0\r\n"
        text += "CSeq: \(cseq)\r\n"
        text += "User-Agent: iTunes/7.6.2 (Windows; N;)\r\n"
        text += "Client-Instance: \(clientInstance)\r\n"
        text += "DACP-ID: \(dacpID)\r\n"
        text += "Active-Remote: \(activeRemote)\r\n"
        if let session { text += "Session: \(session)\r\n" }
        for (key, value) in headers { text += "\(key): \(value)\r\n" }
        if let contentType {
            text += "Content-Type: \(contentType)\r\n"
            text += "Content-Length: \(body.count)\r\n"
        }
        text += "\r\n"

        var out = Data(text.utf8)
        out.append(body)
        let sent = out.withUnsafeBytes { Darwin.send(rtspFD, $0.baseAddress, out.count, 0) }
        guard sent == out.count else { throw SenderError.connectionFailed("RTSP send failed") }

        // Read status line + headers (+ drain any body).
        var raw = Data()
        var headerEnd: Range<Data.Index>?
        var chunk = [UInt8](repeating: 0, count: 2048)
        while headerEnd == nil {
            let n = recv(rtspFD, &chunk, chunk.count, 0)
            guard n > 0 else {
                let detail = n == 0 ? "connection closed by receiver" : String(cString: strerror(errno))
                throw SenderError.connectionFailed("\(method): \(detail)")
            }
            raw.append(contentsOf: chunk[0..<n])
            headerEnd = raw.range(of: Data("\r\n\r\n".utf8))
        }
        let headerText = String(decoding: raw[..<headerEnd!.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "0") ?? 0
        var parsed: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            parsed[String(line[..<colon])] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        if let lengthText = parsed["Content-Length"], let length = Int(lengthText) {
            var bodyGot = raw.count - (headerEnd!.upperBound - raw.startIndex)
            while bodyGot < length {
                let n = recv(rtspFD, &chunk, min(chunk.count, length - bodyGot), 0)
                guard n > 0 else { break }
                bodyGot += n
            }
        }
        log("\(method) → \(status)")
        guard (200..<300).contains(status) else {
            // 453 = receiver busy with another session; 401/403/470 = auth.
            log("\(method) failed; response headers: \(parsed)")
            throw SenderError.rtspError(method: method, status: status)
        }
        return RTSPResponse(status: status, headers: parsed)
    }

    // MARK: - UDP plumbing

    private func openUDPSockets() throws {
        for keyPath in [\RAOPSender.audioFD, \RAOPSender.controlFD, \RAOPSender.timingFD] {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { throw SenderError.connectionFailed("udp socket() failed") }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            // Bind to the interface the RTSP connection uses (libraop does
            // the same) rather than INADDR_ANY, so the RTP flows share the
            // exact network identity of the session.
            if !localIP.isEmpty, inet_pton(AF_INET, localIP, &addr.sin_addr) == 1 {
                // bound to RTSP local address
            } else {
                addr.sin_addr.s_addr = INADDR_ANY
            }
            addr.sin_port = 0
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard rc == 0 else {
                close(fd)
                throw SenderError.connectionFailed("udp bind failed")
            }
            self[keyPath: keyPath] = fd
        }
    }

    private func boundPort(of fd: Int32) throws -> UInt16 {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard rc == 0 else { throw SenderError.connectionFailed("getsockname failed") }
        return UInt16(bigEndian: addr.sin_port)
    }

    @discardableResult
    private func sendUDP(_ fd: Int32, _ data: Data, toPort port: UInt16) -> Bool {
        guard port != 0 else { return false }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        return sendUDP(fd, data, to: addr)
    }

    @discardableResult
    private func sendUDP(_ fd: Int32, _ data: Data, to address: sockaddr_in) -> Bool {
        guard fd >= 0 else { return false }
        var address = address
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, data.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == data.count
    }

    private func recvWithTimeout(_ fd: Int32, _ buffer: inout [UInt8], timeoutMS: Int32) -> Int {
        var source = sockaddr_in()
        return recvfromWithTimeout(fd, &buffer, from: &source, timeoutMS: timeoutMS)
    }

    private func recvfromWithTimeout(_ fd: Int32, _ buffer: inout [UInt8],
                                     from source: inout sockaddr_in, timeoutMS: Int32) -> Int {
        guard fd >= 0 else { return -1 }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, timeoutMS) > 0 else { return -1 }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        return withUnsafeMutablePointer(to: &source) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sourcePtr in
                recvfrom(fd, &buffer, buffer.count, 0, sourcePtr, &len)
            }
        }
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8(value >> 8)); append(UInt8(value & 0xFF))
    }
    mutating func appendBE(_ value: UInt32) {
        appendBE(UInt16(value >> 16)); appendBE(UInt16(value & 0xFFFF))
    }
    mutating func appendBE(_ value: UInt64) {
        appendBE(UInt32(value >> 32)); appendBE(UInt32(value & 0xFFFF_FFFF))
    }
}
