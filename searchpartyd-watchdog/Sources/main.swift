import AppKit
import ServiceManagement

// MARK: - Preferences

enum Pref {
    static let autoKill  = "autoKillEnabled"
    static let cpuLimit  = "cpuThresholdPercent"
    static let memLimit  = "memThresholdMB"
    static let sustain   = "sustainSeconds"
}

let prefs = UserDefaults.standard

// MARK: - Shell helper

@discardableResult
func run(_ path: String, _ args: [String], captureStderr: Bool = false) -> (status: Int32, output: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = captureStderr ? pipe : FileHandle.nullDevice
    proc.standardInput = FileHandle.nullDevice
    do { try proc.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// Parses the `ps` TIME column: "12.34", "917:56.72", "1:02:03.45", "2-01:02:03".
func parseCPUTime(_ raw: String) -> Double? {
    var str = raw
    var days = 0.0
    if let dash = str.firstIndex(of: "-") {
        days = Double(str[str.startIndex..<dash]) ?? 0
        str = String(str[str.index(after: dash)...])
    }
    let parts = str.split(separator: ":")
    guard !parts.isEmpty else { return nil }
    var total = 0.0
    for part in parts {
        guard let value = Double(part) else { return nil }
        total = total * 60 + value
    }
    return total + days * 86400
}

// MARK: - Monitor

/// Samples searchpartyd via `ps`. libproc (proc_pid_rusage / proc_pidinfo) returns
/// EPERM for root-owned processes when we run unprivileged, so `ps` is the only
/// route to these numbers without elevating the whole app.
final class Monitor {
    static let defaultPath = "/usr/libexec/searchpartyd"

    let processPath: String

    struct Stats {
        let pid: pid_t
        let cpuPercent: Double?   // % of one core, as Activity Monitor reports it; nil on first sample
        let rssBytes: UInt64
    }

    init(processPath: String = Monitor.defaultPath) {
        self.processPath = processPath
    }

    private var trackedPID: pid_t = -1
    private var lastCPUSeconds: Double = 0
    private var lastSampledAt: Date = .distantPast

    /// Blocking — call off the main thread.
    func poll() -> Stats? {
        var found: (pid: pid_t, rssKB: UInt64, cpuSeconds: Double)?

        // Fast path: the PID we already know about.
        if trackedPID > 0 {
            let result = run("/bin/ps", ["-o", "rss=,time=", "-p", String(trackedPID)])
            if let line = result.output.split(separator: "\n").first {
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if fields.count >= 2,
                   let rss = UInt64(fields[0]),
                   let cpu = parseCPUTime(String(fields[1])) {
                    found = (trackedPID, rss, cpu)
                }
            }
        }

        // Slow path: scan for the process (first run, or it restarted with a new PID).
        if found == nil {
            let result = run("/bin/ps", ["-axo", "pid=,rss=,time=,comm="])
            for line in result.output.split(separator: "\n") {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 4,
                      fields[3...].joined(separator: " ") == processPath,
                      let pid = pid_t(fields[0]),
                      let rss = UInt64(fields[1]),
                      let cpu = parseCPUTime(String(fields[2])) else { continue }
                // If several ever match, watch the hungriest one.
                if found == nil || rss > found!.rssKB { found = (pid, rss, cpu) }
            }
        }

        guard let sample = found else {
            trackedPID = -1
            lastSampledAt = .distantPast
            return nil
        }

        let now = Date()
        var cpuPercent: Double?
        if sample.pid == trackedPID, lastSampledAt > .distantPast {
            let elapsed = now.timeIntervalSince(lastSampledAt)
            if elapsed > 0.05 {
                cpuPercent = max(0, (sample.cpuSeconds - lastCPUSeconds) / elapsed * 100)
            }
        }

        trackedPID = sample.pid
        lastCPUSeconds = sample.cpuSeconds
        lastSampledAt = now
        return Stats(pid: sample.pid, cpuPercent: cpuPercent, rssBytes: sample.rssKB * 1024)
    }

    func forgetHistory() {
        lastSampledAt = .distantPast
    }
}

// MARK: - Killing

enum Killer {
    static let sudoersFile = "/etc/sudoers.d/searchpartyd-watchdog"

    /// One fixed command, no arguments derived from runtime state. That is what
    /// lets the sudoers rule below be an exact match with no wildcard in it:
    /// it authorises this invocation and nothing else. `-xf` means the whole
    /// command line must equal the daemon's path, so no other process can match.
    static let tool = "/usr/bin/pkill"
    static let args = ["-9", "-xf", Monitor.defaultPath]

    enum Outcome {
        case killed
        case cancelled
        case failed(String)
    }

    /// True once the user has added the sudoers rule. `sudo -l` only *checks* the
    /// rule — it never runs the command.
    static var isPasswordless: Bool {
        run("/usr/bin/sudo", ["-n", "-l", tool] + args).status == 0
    }

    static func kill() -> Outcome {
        let silent = run("/usr/bin/sudo", ["-n", tool] + args, captureStderr: true)
        // sudo reports its own refusals on stderr prefixed "sudo:". Without that
        // marker, pkill itself ran: exit 0 signalled it, exit 1 means it was
        // already gone. Either way there is no searchpartyd left.
        if !silent.output.contains("sudo:") { return .killed }

        let script = "do shell script \"\(tool) \(args.joined(separator: " "))\" with administrator privileges"
        let elevated = run("/usr/bin/osascript", ["-e", script], captureStderr: true)
        if elevated.status == 0 { return .killed }

        // osascript exits 1 for every script error, so read the message to tell a
        // dismissed auth dialog (-128) apart from a genuine failure.
        let message = elevated.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") {
            return .cancelled
        }
        if run("/usr/bin/pgrep", ["-xf", Monitor.defaultPath]).status != 0 { return .killed }

        let short = message.split(separator: "\n").last.map(String.init) ?? "unknown error"
        return .failed(String(short.prefix(60)))
    }

    static var sudoersRule: String? {
        let user = NSUserName()
        // Refuse to build a rule from a name that could alter the file's meaning.
        guard !user.isEmpty,
              user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        return "\(user) ALL=(root) NOPASSWD: \(tool) \(args.joined(separator: " "))"
    }

    /// Installs the rule with one admin prompt. Validates before and after, and
    /// rolls back rather than leaving a sudoers file that could break `sudo`.
    /// Exposed so `--print-rule` can show exactly what will run as root.
    static func installScript(destination: String = sudoersFile) -> String? {
        guard let rule = sudoersRule else { return nil }
        return """
        set -e
        umask 077
        tmp=$(mktemp /tmp/spwd.XXXXXXXX)
        trap 'rm -f "$tmp"' EXIT
        printf '%s\\n' \(shellQuoted(rule)) > "$tmp"
        /usr/sbin/visudo -cf "$tmp"
        /usr/bin/install -o root -g wheel -m 440 "$tmp" \(shellQuoted(destination))
        /usr/sbin/visudo -c || { rm -f \(shellQuoted(destination)); exit 1; }
        """
    }

    static func enablePasswordless() -> String? {
        guard let script = installScript() else { return "Unexpected user name." }
        return runElevated(script)
    }

    static func disablePasswordless() -> String? {
        runElevated("rm -f \(shellQuoted(sudoersFile))")
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a script as root. The script is base64'd so nothing in it has to be
    /// escaped for AppleScript's string literal syntax.
    private static func runElevated(_ script: String) -> String? {
        let encoded = Data(script.utf8).base64EncodedString()
        let command = "/bin/echo \(encoded) | /usr/bin/base64 -D | /bin/sh"
        let applescript = "do shell script \"\(command)\" with administrator privileges"
        let result = run("/usr/bin/osascript", ["-e", applescript], captureStderr: true)
        if result.status == 0 { return nil }
        let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") {
            return "cancelled"
        }
        return message.split(separator: "\n").last.map(String.init) ?? "unknown error"
    }
}

// MARK: - Views

final class BarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var color: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        Palette.track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return }
        let width = max(bounds.height, bounds.width * clamped)
        let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                                xRadius: radius, yRadius: radius)
        // Deeper at the root, full colour at the tip — reads as a level rather than a block.
        let base = color.usingColorSpace(.sRGB) ?? color
        let root = base.blended(withFraction: 0.22, of: .black) ?? base
        if let gradient = NSGradient(starting: root, ending: base) {
            gradient.draw(in: path, angle: 0)
        } else {
            base.setFill()
            path.fill()
        }
    }
}

/// The one and only readout: CPU on the left, memory on the right.
final class StatsView: NSView {
    private let cpuValue = StatsView.valueLabel()
    private let memValue = StatsView.valueLabel()
    private let cpuBar = BarView()
    private let memBar = BarView()

    private static func valueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "—")
        label.font = .monospacedDigitSystemFont(ofSize: 21, weight: .medium)
        label.alignment = .center
        return label
    }

    private static func captionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        return label
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 84))
        let columnWidth = (bounds.width - 32) / 2

        for (index, pair) in [(cpuValue, cpuBar), (memValue, memBar)].enumerated() {
            let x = 16 + CGFloat(index) * columnWidth
            pair.0.frame = NSRect(x: x, y: 42, width: columnWidth, height: 26)
            let caption = StatsView.captionLabel(index == 0 ? "CPU" : "MEMORY")
            caption.frame = NSRect(x: x, y: 28, width: columnWidth, height: 12)
            pair.1.frame = NSRect(x: x + 14, y: 16, width: columnWidth - 28, height: 5)
            addSubview(pair.0)
            addSubview(caption)
            addSubview(pair.1)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(cpu: Double?, memBytes: UInt64?, cpuLimit: Double, memLimitMB: Double) {
        if let cpu {
            cpuValue.stringValue = String(format: cpu >= 100 ? "%.0f%%" : "%.1f%%", cpu)
            cpuValue.textColor = Palette.color(for: cpu / cpuLimit)
            cpuBar.fraction = cpu / cpuLimit
            cpuBar.color = Palette.color(for: cpu / cpuLimit)
        } else {
            cpuValue.stringValue = "—"
            cpuValue.textColor = .tertiaryLabelColor
            cpuBar.fraction = 0
        }

        if let memBytes {
            let mb = Double(memBytes) / 1_048_576
            memValue.stringValue = mb >= 1024 ? String(format: "%.2f GB", mb / 1024)
                                              : String(format: "%.0f MB", mb)
            memValue.textColor = Palette.color(for: mb / memLimitMB)
            memBar.fraction = mb / memLimitMB
            memBar.color = Palette.color(for: mb / memLimitMB)
        } else {
            memValue.stringValue = "—"
            memValue.textColor = .tertiaryLabelColor
            memBar.fraction = 0
        }
    }
}

/// Perceptual colour mixing. Interpolating two vivid colours channel-by-channel in
/// sRGB dips through grey — green to amber comes out olive halfway. Oklab is a
/// perceptually uniform space where the straight line between them stays vivid.
private struct Oklab {
    var L: Double, a: Double, b: Double

    init(srgb c: (r: Double, g: Double, b: Double)) {
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = linear(c.r), g = linear(c.g), bl = linear(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    private init(L: Double, a: Double, b: Double) { self.L = L; self.a = a; self.b = b }

    static func mix(_ x: Oklab, _ y: Oklab, _ t: Double) -> Oklab {
        Oklab(L: x.L + (y.L - x.L) * t, a: x.a + (y.a - x.a) * t, b: x.b + (y.b - x.b) * t)
    }

    var nsColor: NSColor {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        func srgb(_ v: Double) -> CGFloat {
            let c = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(max(v, 0), 1 / 2.4) - 0.055
            return CGFloat(min(max(c, 0), 1))
        }
        return NSColor(srgbRed: srgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                       green: srgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                       blue: srgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
                       alpha: 1)
    }
}

enum Palette {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// Ramp stops as (fraction of the limit, light-mode colour, dark-mode colour).
    /// Green at idle, warming through amber and orange to red at the limit. Yellow is
    /// skipped on purpose — it is the one hue that cannot be both vivid and readable
    /// on a light menu. Each appearance gets its own stops so both stay legible.
    private static let stops: [(ratio: Double, light: RGB, dark: RGB)] = [
        (0.00, (0.16, 0.63, 0.38), (0.29, 0.83, 0.51)),
        (0.50, (0.20, 0.64, 0.32), (0.36, 0.84, 0.45)),
        (0.78, (0.87, 0.62, 0.05), (0.99, 0.80, 0.32)),
        (0.92, (0.87, 0.40, 0.06), (0.99, 0.59, 0.30)),
        (1.00, (0.83, 0.19, 0.16), (1.00, 0.44, 0.40)),
    ]

    /// Stops for the menu bar glyph. It holds the menu bar's own colour — white on a
    /// dark menu bar, black on a light one — through the safe zone, then warms to red.
    /// Starting from the plain colour rather than green is what keeps the item looking
    /// like every other icon up there until there is something to say.
    private static let menuStops: [(ratio: Double, light: RGB, dark: RGB)] = [
        (0.00, (0.00, 0.00, 0.00), (1.00, 1.00, 1.00)),
        (0.45, (0.00, 0.00, 0.00), (1.00, 1.00, 1.00)),
        (0.78, (0.87, 0.62, 0.05), (0.99, 0.80, 0.32)),
        (1.00, (0.83, 0.19, 0.16), (1.00, 0.44, 0.40)),
    ]

    /// The colour for a value sitting at `ratio` of its limit.
    static func color(for ratio: Double) -> NSColor { ramp(stops, ratio) }

    /// The menu bar glyph's tint, or nil to leave it on the system's own rendering.
    /// Below the hold point the ramp is flat white anyway, and nil gets that colour
    /// properly — vibrant, matching the neighbouring items — rather than approximated.
    ///
    /// This one resolves the appearance itself instead of handing back a dynamic
    /// colour. A status bar button does not report the menu bar's appearance: in Dark
    /// Mode it still resolves as `.aqua`, so a dynamic colour picks the light-mode end
    /// of the ramp and paints a black glyph onto the dark menu bar. `NSApp` knows.
    static func menuBarTint(for ratio: Double) -> NSColor? {
        let r = min(max(ratio.isFinite ? ratio : 0, 0), 1)
        guard r > menuStops[1].ratio else { return nil }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return resolvedColor(ramp(menuStops, r), dark: dark)
    }

    /// Flattens a dynamic ramp colour to the one appearance we mean.
    private static func resolvedColor(_ color: NSColor, dark: Bool) -> NSColor {
        var result = color
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    private static func ramp(_ stops: [(ratio: Double, light: RGB, dark: RGB)],
                             _ ratio: Double) -> NSColor {
        let r = min(max(ratio.isFinite ? ratio : 0, 0), 1)
        let last = stops[stops.count - 1]
        var light = Oklab(srgb: last.light)
        var dark = Oklab(srgb: last.dark)
        for (lower, upper) in zip(stops, stops.dropFirst()) where r <= upper.ratio {
            let span = upper.ratio - lower.ratio
            let t = span > 0 ? (r - lower.ratio) / span : 0
            light = .mix(Oklab(srgb: lower.light), Oklab(srgb: upper.light), t)
            dark = .mix(Oklab(srgb: lower.dark), Oklab(srgb: upper.dark), t)
            break
        }
        let lightColor = light.nsColor, darkColor = dark.nsColor
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
    }

    /// The unfilled part of a bar. The system's tertiary label all but vanishes
    /// against the dark menu background, so the track is spelled out here.
    static let track = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.17)
            : NSColor(white: 0.0, alpha: 0.11)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = Monitor()
    private let statsView = StatsView()
    private let queue = DispatchQueue(label: "watchdog.sampler", qos: .utility)

    private var timer: Timer?
    private var latest: Monitor.Stats?
    private var overLimitSince: Date?
    private var suppressAutoKillUntil: Date = .distantPast
    private var lastKillNote: String?

    private var killItem: NSMenuItem!
    private var autoKillItem: NSMenuItem!
    private var passwordlessItem: NSMenuItem!
    private var passwordlessCache = false
    private var loginItem: NSMenuItem!
    private var noteItem: NSMenuItem!

    /// The CPU limits the Limits menu offers, and the only values `cpuLimit` returns.
    ///
    /// The number these are compared against is CPU-seconds burned per wall second,
    /// times 100 — the same scale Activity Monitor uses, where 100% is one core fully
    /// occupied and a threaded process can reach 100% × the core count. One pinned core
    /// is where searchpartyd's misbehaviour starts, not where it ends, so the steps are
    /// whole cores rather than fractions of one.
    static let cpuChoices: [Double] = {
        let cores = Double(ProcessInfo.processInfo.processorCount)
        return [1.0, 2.0, 4.0, 6.0, 8.0].filter { $0 <= cores }.map { $0 * 100 }
    }()

    /// Snapped to the nearest offered value. Earlier builds wrote limits that are no
    /// longer on the menu (it used to run 50% to 200%), and an unlisted limit is one
    /// you cannot see or change back from — no item would carry the checkmark.
    private var cpuLimit: Double {
        let stored = prefs.double(forKey: Pref.cpuLimit)
        return AppDelegate.cpuChoices.min { abs($0 - stored) < abs($1 - stored) } ?? 200
    }
    /// The memory limits the Limits menu offers, in MB. Sized for a machine with
    /// 16 GB of RAM: searchpartyd sits in the hundreds of MB, so the useful range is
    /// well under a gigabyte and the old 2 GB and 3 GB steps never meant anything.
    static let memChoices: [Double] = [250, 500, 750, 1000, 1500]

    /// Snapped to the nearest offered value, for the same reason as `cpuLimit`.
    private var memLimit: Double {
        let stored = prefs.double(forKey: Pref.memLimit)
        return AppDelegate.memChoices.min { abs($0 - stored) < abs($1 - stored) } ?? 750
    }
    private var sustain: Double { prefs.double(forKey: Pref.sustain) }
    private var autoKillOn: Bool { prefs.bool(forKey: Pref.autoKill) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        prefs.register(defaults: [
            Pref.autoKill: false,
            Pref.cpuLimit: 200.0,
            Pref.memLimit: 1000.0,
            Pref.sustain: 30.0,
        ])

        if let button = statusItem.button {
            button.image = AppDelegate.glyph(tint: nil)
            button.imagePosition = .imageOnly
            button.title = ""
        }

        buildMenu()
        refreshPasswordlessState()
        tick()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.5
        // .common, not .default: otherwise sampling stops while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        menu.addItem(titleHeader())

        let header = NSMenuItem()
        header.view = statsView
        menu.addItem(header)
        menu.addItem(.separator())

        killItem = NSMenuItem(title: "Force Kill searchpartyd",
                              action: #selector(killNow), keyEquivalent: "k")
        killItem.target = self
        menu.addItem(killItem)

        autoKillItem = NSMenuItem(title: "Auto-Kill When Over Limit",
                                  action: #selector(toggleAutoKill), keyEquivalent: "")
        autoKillItem.target = self
        menu.addItem(autoKillItem)

        passwordlessItem = NSMenuItem(title: "Kill Without Password",
                                      action: #selector(togglePasswordless), keyEquivalent: "")
        passwordlessItem.target = self
        menu.addItem(passwordlessItem)

        let limits = NSMenuItem(title: "Limits", action: nil, keyEquivalent: "")
        limits.submenu = buildLimitsMenu()
        menu.addItem(limits)

        noteItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        noteItem.isEnabled = false
        noteItem.isHidden = true
        menu.addItem(noteItem)

        menu.addItem(.separator())

        let activity = NSMenuItem(title: "Open Activity Monitor",
                                  action: #selector(openActivityMonitor), keyEquivalent: "")
        activity.target = self
        menu.addItem(activity)

        let copyStats = NSMenuItem(title: "Copy Stats", action: #selector(copyStats),
                                   keyEquivalent: "c")
        copyStats.target = self
        menu.addItem(copyStats)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About \(AppDelegate.appName)",
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let readMe = NSMenuItem(title: "Read Me", action: #selector(showReadMe),
                                keyEquivalent: "?")
        readMe.target = self
        menu.addItem(readMe)

        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let quit = NSMenuItem(title: "Quit \(AppDelegate.appName)",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func buildLimitsMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(sectionHeader("CPU  (100% = 1 core)"))
        for value in AppDelegate.cpuChoices {
            let item = NSMenuItem(title: String(format: "%.0f%%", value),
                                  action: #selector(setCPULimit(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader("Memory"))
        for value in AppDelegate.memChoices {
            let item = NSMenuItem(title: value >= 1000 ? String(format: "%.1f GB", value / 1000)
                                                       : String(format: "%.0f MB", value),
                                  action: #selector(setMemLimit(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader("Sustained For"))
        for value in [10.0, 30.0, 60.0, 120.0] {
            let item = NSMenuItem(title: value >= 60 ? String(format: "%.0f min", value / 60)
                                                     : String(format: "%.0f sec", value),
                                  action: #selector(setSustain(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            menu.addItem(item)
        }
        return menu
    }

    /// The app's own name and version, so the menu identifies itself the way a
    /// regular app's menu bar does.
    private func titleHeader() -> NSMenuItem {
        let item = NSMenuItem(title: AppDelegate.appName, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let title = NSMutableAttributedString(
            string: AppDelegate.appName,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: NSColor.labelColor])
        title.append(NSAttributedString(
            string: "   \(AppDelegate.appVersion)",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                         .foregroundColor: NSColor.tertiaryLabelColor]))
        item.attributedTitle = title
        return item
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        killItem.isEnabled = latest != nil
        killItem.title = latest.map { "Force Kill searchpartyd (\($0.pid))" } ?? "searchpartyd Not Running"
        autoKillItem.state = autoKillOn ? .on : .off
        passwordlessItem.state = passwordlessCache ? .on : .off
        refreshPasswordlessState()
        // Auto-kill that has to ask for a password isn't really automatic.
        autoKillItem.attributedTitle = (autoKillOn && !passwordlessCache)
            ? NSAttributedString(string: "Auto-Kill When Over Limit  (will ask)")
            : nil

        if let limits = menu.item(withTitle: "Limits")?.submenu {
            for item in limits.items {
                guard let value = item.representedObject as? Double else { continue }
                switch item.action {
                case #selector(setCPULimit(_:)): item.state = value == cpuLimit ? .on : .off
                case #selector(setMemLimit(_:)): item.state = value == memLimit ? .on : .off
                case #selector(setSustain(_:)):  item.state = value == sustain ? .on : .off
                default: break
                }
            }
        }

        if let note = lastKillNote {
            noteItem.isHidden = false
            noteItem.attributedTitle = NSAttributedString(string: note, attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        } else {
            noteItem.isHidden = true
        }

        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: Sampling loop

    private func tick() {
        queue.async { [weak self] in
            guard let self else { return }
            let stats = self.monitor.poll()
            DispatchQueue.main.async { self.apply(stats) }
        }
    }

    private func apply(_ stats: Monitor.Stats?) {
        latest = stats
        let cpu = stats?.cpuPercent
        let mem = stats.map { Double($0.rssBytes) / 1_048_576 }

        statsView.update(cpu: cpu, memBytes: stats?.rssBytes,
                         cpuLimit: cpuLimit, memLimitMB: memLimit)

        // Menu bar: the glyph alone, no number. It holds the menu bar's own white
        // through the safe zone and warms to red as either limit is approached, so the
        // item says how bad things are without adding a figure to read. Memory drives
        // it as much as CPU, so a memory runaway colours it on its own.
        if let button = statusItem.button {
            if stats != nil {
                let pressure = max((cpu ?? 0) / cpuLimit, (mem ?? 0) / memLimit)
                button.image = AppDelegate.glyph(tint: Palette.menuBarTint(for: pressure))
                button.alphaValue = 1
            } else {
                // Dimmed rather than tinted: searchpartyd is not running to report on.
                button.image = AppDelegate.glyph(tint: nil)
                button.alphaValue = 0.4
            }
        }

        evaluateAutoKill(cpu: cpu, memMB: mem, pid: stats?.pid)
    }

    private func isOverLimit(cpu: Double?, memMB: Double?) -> Bool {
        (cpu ?? 0) >= cpuLimit || (memMB ?? 0) >= memLimit
    }

    private func evaluateAutoKill(cpu: Double?, memMB: Double?, pid: pid_t?) {
        guard autoKillOn, let pid, isOverLimit(cpu: cpu, memMB: memMB) else {
            overLimitSince = nil
            return
        }
        let since = overLimitSince ?? Date()
        overLimitSince = since
        guard Date().timeIntervalSince(since) >= sustain,
              Date() > suppressAutoKillUntil else { return }

        overLimitSince = nil
        suppressAutoKillUntil = Date().addingTimeInterval(120)
        performKill(pid: pid, automatic: true)
    }

    // MARK: Actions

    @objc private func killNow() {
        performKill(pid: latest?.pid, automatic: false)
    }

    private func performKill(pid: pid_t?, automatic: Bool) {
        queue.async { [weak self] in
            let result = Killer.kill()
            DispatchQueue.main.async {
                guard let self else { return }
                let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                switch result {
                case .killed:
                    let which = pid.map { "\($0)" } ?? "searchpartyd"
                    self.lastKillNote = "Killed \(which) at \(stamp)\(automatic ? " (auto)" : "")"
                    self.monitor.forgetHistory()
                case .cancelled:
                    self.lastKillNote = "Kill cancelled at \(stamp)"
                    // Don't nag: if an automatic kill is dismissed, back off for a while.
                    if automatic { self.suppressAutoKillUntil = Date().addingTimeInterval(900) }
                case .failed(let reason):
                    self.lastKillNote = "\(reason) at \(stamp)"
                }
                self.tick()
            }
        }
    }

    @objc private func togglePasswordless() {
        if passwordlessCache {
            if let error = Killer.disablePasswordless(), error != "cancelled" {
                report("Couldn't remove the rule", error)
            }
            refreshPasswordlessState()
            return
        }

        guard let rule = Killer.sudoersRule else { return }
        let alert = NSAlert()
        alert.messageText = "Kill searchpartyd without a password?"
        alert.informativeText = """
        This adds one line to \(Killer.sudoersFile):

        \(rule)

        It permits that exact command and nothing else — no wildcards. The effect         is that anything running as you can restart the Find My daemon without a         password. No other command gains privileges.

        macOS will ask for your admin password once, to add the rule.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add Rule")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let error = Killer.enablePasswordless() {
            if error != "cancelled" { report("Couldn't add the rule", error) }
            refreshPasswordlessState()
            return
        }
        refreshPasswordlessState()
        // Confirm the rule actually took effect rather than assuming it did.
        if !Killer.isPasswordless {
            report("The rule was added but isn't active",
                   "sudo still won't run the kill command without a password. Check that /etc/sudoers includes /etc/sudoers.d.")
        }
    }

    private func report(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func toggleAutoKill() {
        prefs.set(!autoKillOn, forKey: Pref.autoKill)
        overLimitSince = nil
    }

    // MARK: Menu bar glyph

    private static let baseGlyph: NSImage? = {
        let image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right",
                            accessibilityDescription: "searchpartyd")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        // withSymbolConfiguration does not carry the template flag over, and the glyph
        // has to be a template to be usable as a mask below.
        image?.isTemplate = true
        return image
    }()

    /// The menu bar glyph, with `tint` baked into its pixels.
    ///
    /// The colour cannot go through `contentTintColor`: the menu bar re-maps a tinted
    /// status item against its own appearance, which it reports as light even in Dark
    /// Mode, so a near-white tint came out black on a dark menu bar. Painting the
    /// pixels here and handing over a plain, non-template image leaves nothing to
    /// re-map. A nil tint keeps the template, which is what gets the system's own
    /// menu bar white — the correct colour, vibrancy and all, while there is headroom.
    static func glyph(tint: NSColor?) -> NSImage? {
        guard let base = baseGlyph else { return nil }
        guard let tint else { return base }
        let out = NSImage(size: base.size)
        out.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: base.size))
        tint.set()
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        out.unlockFocus()
        out.isTemplate = false
        return out
    }

    // MARK: About, Read Me and the rest of the furniture

    static let appName = "SearchParty Watchdog"

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let credits = NSAttributedString(
            string: "Watches /usr/libexec/searchpartyd and kills it when it runs away "
                  + "with your CPU or memory.\nlaunchd restarts it within seconds, at a "
                  + "normal size.",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: centred])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppDelegate.appName,
            .applicationVersion: AppDelegate.appVersion,
            .version: AppDelegate.appBuild,
            .credits: credits,
        ])
    }

    @objc private func showReadMe() {
        ReadMeWindow.show()
    }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// One line covering the sample and the limits it is being judged against —
    /// the thing you would want to paste into a bug report.
    @objc private func copyStats() {
        let sample = latest.map {
            String(format: "pid %d · CPU %.1f%% · Memory %.0f MB",
                   $0.pid, $0.cpuPercent ?? 0, Double($0.rssBytes) / 1_048_576)
        } ?? "not running"
        let line = String(format: "searchpartyd: %@ (limits %.0f%% / %.0f MB, sustained %.0fs)",
                          sample, cpuLimit, memLimit, sustain)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    @objc private func setCPULimit(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { prefs.set(value, forKey: Pref.cpuLimit) }
        refreshNow()
    }

    @objc private func setMemLimit(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { prefs.set(value, forKey: Pref.memLimit) }
        refreshNow()
    }

    @objc private func setSustain(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { prefs.set(value, forKey: Pref.sustain) }
        overLimitSince = nil
    }

    private func refreshPasswordlessState() {
        queue.async { [weak self] in
            let enabled = Killer.isPasswordless
            DispatchQueue.main.async {
                guard let self, self.passwordlessCache != enabled else { return }
                self.passwordlessCache = enabled
                self.passwordlessItem.state = enabled ? .on : .off
            }
        }
    }

    private func refreshNow() {
        overLimitSince = nil
        apply(latest)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

if CommandLine.arguments.contains("--print-rule") {
    print("sudoers rule:\n  \(Killer.sudoersRule ?? "<unavailable>")\n")
    print("kill command:\n  \(Killer.tool) \(Killer.args.joined(separator: " "))\n")
    print("passwordless currently: \(Killer.isPasswordless ? "enabled" : "disabled")\n")
    let destination = CommandLine.arguments.firstIndex(of: "--print-rule")
        .flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
        ?? Killer.sudoersFile
    print("script that runs as root:\n\(Killer.installScript(destination: destination) ?? "<unavailable>")")
    exit(0)
}

if CommandLine.arguments.contains("--probe") {
    // `--probe [executable-path]` prints one sample and exits, no GUI.
    var probePath = Monitor.defaultPath
    if let index = CommandLine.arguments.firstIndex(of: "--probe"),
       index + 1 < CommandLine.arguments.count {
        probePath = CommandLine.arguments[index + 1]
    }
    let monitor = Monitor(processPath: probePath)
    _ = monitor.poll()
    Thread.sleep(forTimeInterval: 2.0)
    if let stats = monitor.poll() {
        let cpu = stats.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "n/a"
        let mem = String(format: "%.1f MB", Double(stats.rssBytes) / 1_048_576)
        print("pid \(stats.pid)  cpu \(cpu)  mem \(mem)")
    } else {
        print("searchpartyd is not running")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
