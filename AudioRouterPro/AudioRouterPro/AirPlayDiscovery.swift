import Darwin
import Foundation

/// An AirPlay receiver discovered and resolved via Bonjour `_raop._tcp`.
struct DiscoveredReceiver: Identifiable, Equatable {
    let name: String        // display name ("One", "Office+", …)
    let host: String        // resolved IPv4
    let port: UInt16        // RTSP port from the SRV record
    /// True when the receiver does not accept unencrypted classic RAOP
    /// (TXT `et` list without "0") — HomePod/Apple TV class devices needing
    /// AirPlay 2 HAP auth, or RSA-only legacy receivers. Badged unsupported.
    let requiresAuth: Bool
    /// MAC prefix of the RAOP instance name ("<MAC>@<name>") — used to derive
    /// the Sonos RINCON id for the transport kick.
    let macHint: String?

    var id: String { name }
}

/// Modern Sonos firmware answers classic RAOP completely (RTSP 200s, timing
/// polls, volume) but never attaches the session to the zone's playback
/// pipeline — the transport stays STOPPED and the unit is silent. AirPlay 2
/// senders trigger that attach inside their protocol; we reproduce it out of
/// band via UPnP: point the transport at the AirPlay virtual line-in and
/// press Play. Verified live against a Sonos One (fw 95.1).
/// Non-Sonos receivers simply refuse the HTTP connection — harmless.
enum SonosTransportKick {
    static func kick(host: String, mac: String) {
        let uri = "x-sonos-vli:RINCON_\(mac)01400:2,airplay"
        AudioDebug.log("sonos-kick: attaching transport \(uri) on \(host)")
        soap(host: host, action: "SetAVTransportURI",
             body: "<CurrentURI>\(uri)</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>") { ok in
            guard ok else {
                AudioDebug.log("sonos-kick: SetAVTransportURI refused by \(host)")
                return
            }
            soap(host: host, action: "Play", body: "<Speed>1</Speed>") { ok in
                AudioDebug.log("sonos-kick: Play → \(ok ? "accepted" : "refused") on \(host)")
            }
        }
    }

    private static func soap(host: String, action: String, body: String,
                             completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/AVTransport/Control") else {
            return completion(false)
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        let envelope = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
        <u:\(action) xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\
        <InstanceID>0</InstanceID>\(body)</u:\(action)></s:Body></s:Envelope>
        """
        request.httpBody = Data(envelope.utf8)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }
}

/// Browses and resolves `_raop._tcp` so every receiver is directly reachable
/// by the app's own RAOP sender — no CoreAudio/Control Center involvement.
/// RAOP instance names are "<MAC>@<display name>"; the TXT record's `et` key
/// lists supported encryption types (0 = none, what our sender speaks).
final class AirPlayDiscovery: NSObject {
    private var browser: NetServiceBrowser?
    private var pendingServices: [NetService] = []
    private var resolved: [String: DiscoveredReceiver] = [:]
    private let onUpdate: ([DiscoveredReceiver]) -> Void
    private let localHostName = Host.current().localizedName

    init(onUpdate: @escaping ([DiscoveredReceiver]) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        stop()
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: "_raop._tcp.", inDomain: "local.")
        self.browser = browser
    }

    func stop() {
        browser?.stop()
        browser = nil
        pendingServices.removeAll()
    }

    static func displayName(fromServiceName name: String) -> String {
        if let at = name.firstIndex(of: "@") {
            return String(name[name.index(after: at)...])
        }
        return name
    }

    private func publish() {
        let receivers = resolved.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onUpdate(Array(receivers))
    }
}

extension AirPlayDiscovery: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let name = Self.displayName(fromServiceName: service.name)
        guard name != localHostName else { return } // this Mac advertises too
        service.delegate = self
        pendingServices.append(service) // keep a strong ref while resolving
        service.resolve(withTimeout: 10)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let name = Self.displayName(fromServiceName: service.name)
        resolved.removeValue(forKey: name)
        pendingServices.removeAll { $0 == service }
        publish()
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        defer { pendingServices.removeAll { $0 == service } }
        let name = Self.displayName(fromServiceName: service.name)
        guard let host = Self.ipv4Address(of: service) else { return }
        let macHint: String? = {
            guard let at = service.name.firstIndex(of: "@") else { return nil }
            let prefix = String(service.name[..<at])
            return prefix.count == 12 && prefix.allSatisfy(\.isHexDigit) ? prefix : nil
        }()

        var requiresAuth = true
        if let txtData = service.txtRecordData() {
            let txt = NetService.dictionary(fromTXTRecord: txtData)
            if let etData = txt["et"], let et = String(data: etData, encoding: .utf8) {
                requiresAuth = !et.split(separator: ",").contains("0")
            }
        }

        resolved[name] = DiscoveredReceiver(name: name, host: host,
                                            port: UInt16(service.port),
                                            requiresAuth: requiresAuth,
                                            macHint: macHint)
        publish()
    }

    func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pendingServices.removeAll { $0 == service }
    }

    private static func ipv4Address(of service: NetService) -> String? {
        for addressData in service.addresses ?? [] {
            let ip: String? = addressData.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress,
                      raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
                guard family == sa_family_t(AF_INET) else { return nil }
                var sin = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sin.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
                return String(cString: text)
            }
            if let ip { return ip }
        }
        return nil
    }
}
