import AppKit
import CoreAudio

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let deviceManager = AudioDeviceManager()
    private lazy var controller = MultiOutputController(deviceManager: deviceManager)

    private var statusItem: NSStatusItem!
    private var combinedEnabled = false

    /// UIDs the user wants in the combined output. Until the user touches
    /// the device list, selection is automatic: built-in output + every
    /// connected Bluetooth output.
    private var selectedUIDs: Set<String> = []
    private var userCustomizedSelection = false

    private var deviceChangeDebounce: DispatchWorkItem?

    private let defaults = UserDefaults.standard
    private static let selectedUIDsKey = "SelectedDeviceUIDs"
    private static let customizedKey = "UserCustomizedSelection"

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        userCustomizedSelection = defaults.bool(forKey: Self.customizedKey)
        if userCustomizedSelection,
           let saved = defaults.stringArray(forKey: Self.selectedUIDsKey) {
            selectedUIDs = Set(saved)
        } else {
            selectedUIDs = autoSelection()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "hifispeaker.2", accessibilityDescription: "SpeakerSync"
        )
        statusItem.menu = NSMenu()

        deviceManager.onDevicesChanged = { [weak self] in self?.handleDevicesChanged() }
        deviceManager.onDefaultOutputChanged = { [weak self] in self?.handleDefaultOutputChanged() }
        deviceManager.startListening()

        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        deviceManager.stopListening()
        controller.deactivate()
    }

    // MARK: - Selection

    private func autoSelection() -> Set<String> {
        let devices = deviceManager.outputDevices()
        var uids = Set(devices.filter { $0.isBuiltIn || $0.isBluetooth }.map(\.uid))
        if uids.isEmpty, let first = devices.first {
            uids.insert(first.uid)
        }
        return uids
    }

    private func selectedDevices() -> [AudioDevice] {
        deviceManager.outputDevices().filter { selectedUIDs.contains($0.uid) }
    }

    private func persistSelection() {
        defaults.set(Array(selectedUIDs), forKey: Self.selectedUIDsKey)
        defaults.set(userCustomizedSelection, forKey: Self.customizedKey)
    }

    // MARK: - Enable / disable

    private func setCombined(enabled: Bool) {
        if enabled {
            let devices = selectedDevices()
            do {
                try controller.activate(devices: devices)
                combinedEnabled = true
            } catch {
                combinedEnabled = false
                presentError(error)
            }
        } else {
            controller.deactivate()
            combinedEnabled = false
        }
        rebuildMenu()
    }

    private func rebuildAggregateIfNeeded() {
        guard combinedEnabled else { return }
        let devices = selectedDevices()
        guard !devices.isEmpty else {
            // Every selected device vanished; fall back to the previous default.
            controller.deactivate()
            combinedEnabled = false
            return
        }
        guard Set(devices.map(\.uid)) != controller.activeSubDeviceUIDs else { return }
        do {
            try controller.rebuild(devices: devices)
        } catch {
            combinedEnabled = false
            controller.deactivate()
            presentError(error)
        }
    }

    // MARK: - Hardware events

    private func handleDevicesChanged() {
        // The HAL fires several notifications per hot-plug; coalesce them.
        deviceChangeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.userCustomizedSelection {
                self.selectedUIDs = self.autoSelection()
            }
            self.rebuildAggregateIfNeeded()
            self.rebuildMenu()
        }
        deviceChangeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func handleDefaultOutputChanged() {
        // If the user picks a different output in System Settings while we
        // are active, treat that as an external disable: tear down the
        // aggregate but leave their choice alone.
        guard combinedEnabled, controller.isActive else { return }
        if deviceManager.currentDefaultOutputID() != controller.aggregateID {
            controller.deactivate(restoreDefault: false)
            combinedEnabled = false
            rebuildMenu()
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let devices = deviceManager.outputDevices()

        let toggle = NSMenuItem(
            title: combinedEnabled ? "Combined Output: On" : "Combined Output: Off",
            action: #selector(toggleCombined), keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = combinedEnabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())

        let header = NSMenuItem(title: "Output Devices", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if devices.isEmpty {
            let empty = NSMenuItem(title: "No output devices found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for device in devices {
            let item = NSMenuItem(
                title: "\(device.name) (\(device.transportLabel))",
                action: #selector(toggleDevice(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.uid
            item.state = selectedUIDs.contains(device.uid) ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }

        if !userCustomizedSelection {
            let auto = NSMenuItem(
                title: "Auto: built-in + Bluetooth", action: nil, keyEquivalent: ""
            )
            auto.isEnabled = false
            auto.indentationLevel = 1
            menu.addItem(auto)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit SpeakerSync", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.button?.image = NSImage(
            systemSymbolName: combinedEnabled ? "hifispeaker.2.fill" : "hifispeaker.2",
            accessibilityDescription: "SpeakerSync"
        )
    }

    // MARK: - Actions

    @objc private func toggleCombined() {
        setCombined(enabled: !combinedEnabled)
    }

    @objc private func toggleDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        userCustomizedSelection = true
        if selectedUIDs.contains(uid) {
            selectedUIDs.remove(uid)
        } else {
            selectedUIDs.insert(uid)
        }
        persistSelection()
        rebuildAggregateIfNeeded()
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "SpeakerSync"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
