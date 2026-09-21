import SwiftUI

@main
struct AudioRouterProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = StreamEngine.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(engine)
        } label: {
            Image(systemName: engine.menuBarSymbolName)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    /// TEARDOWN guarantee: SIGTERM/SIGINT (pkill, logout, Ctrl-C in dev)
    /// must tear the AirPlay sessions and tap down like a normal quit, so no
    /// half-dead RAOP session is ever left shadowing the receiver.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                StreamEngine.shared.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        // Self-test exits the process when done, so it must never trigger on
        // the user-facing install — only dev builds outside /Applications
        // honor the env var (a stale launchctl setenv once made a fresh
        // launch run the test and quit, looking like a crash).
        // Self-tests exit the process when done. On the user-facing install
        // they additionally require a marker file, so a stale launchctl env
        // alone can never make a clicked launch quit itself (which once
        // looked like a crash). Dev builds only need the env var.
        let testsAllowed = !Bundle.main.bundlePath.hasPrefix("/Applications")
            || FileManager.default.fileExists(atPath: "/tmp/audiorouter-test-enable")
        if testsAllowed {
            if AudioDebug.selfTest {
                SelfTest.run(engine: StreamEngine.shared)
            } else if let receiver = AudioDebug.raopTestReceiver {
                SelfTest.runRAOP(engine: StreamEngine.shared, receiverName: receiver)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tears down AirPlay legs and destroys the tap, which un-mutes
        // normal system playback.
        StreamEngine.shared.shutdown()
    }
}
