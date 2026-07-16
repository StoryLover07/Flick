import ApplicationServices
import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class FlickArrangeAppState: ObservableObject {
    @Published private(set) var sensorStatus = "Starting sensor..."
    @Published private(set) var isMonitoring = false
    @Published private(set) var isArranging = false
    @Published private(set) var isCloseGestureEnabled = true
    @Published private(set) var isOpenGestureEnabled = true
    @Published private(set) var isAccessibilityTrusted = false
    @Published private(set) var latestAngle: Double?
    @Published private(set) var lastDetection = "Waiting for a Close or Open gesture"
    @Published private(set) var lastArrangement = "No windows arranged yet"
    @Published private(set) var activity: [ActivityLogEntry] = []

    var monitoringDetail: String {
        if isMonitoring, let latestAngle {
            return String(format: "Lid angle %.0f deg", latestAngle)
        }
        return sensorStatus
    }

    func setSensorStatus(_ status: String, monitoring: Bool) {
        sensorStatus = status
        isMonitoring = monitoring
    }

    func setAngle(_ angle: Double) {
        latestAngle = angle
    }

    func setArranging(_ arranging: Bool) {
        isArranging = arranging
    }

    func refreshAccessibilityStatus() {
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    func setCloseGestureEnabled(_ enabled: Bool) {
        isCloseGestureEnabled = enabled
        addActivity(enabled ? "Close gesture enabled" : "Close gesture disabled")
    }

    func setOpenGestureEnabled(_ enabled: Bool) {
        isOpenGestureEnabled = enabled
        addActivity(enabled ? "Open gesture enabled" : "Open gesture disabled")
    }

    func recordDetection(_ gesture: String, note: String? = nil) {
        let time = Self.timeFormatter.string(from: Date())
        lastDetection = "\(gesture) detected at \(time)" + (note.map { " - \($0)" } ?? "")
        addActivity(note.map { "\(gesture) detected: \($0)" } ?? "\(gesture) detected", kind: .gesture)
    }

    func recordArrangement(_ result: ArrangeResult, preview: Bool) {
        let action = preview ? "Layout preview" : "Arrangement"
        let completedCount = preview ? result.targetCount : result.arrangedCount
        lastArrangement = "\(action): \(completedCount)/\(result.targetCount) windows, \(result.totalDurationMilliseconds) ms"
        addActivity("\(action): \(completedCount)/\(result.targetCount) windows in \(result.totalDurationMilliseconds) ms", kind: .success)
    }

    func recordFailure(_ message: String) {
        lastArrangement = message
        addActivity(message, kind: .failure)
    }

    func addActivity(_ message: String, kind: ActivityLogEntry.Kind = .info) {
        activity.insert(ActivityLogEntry(message: message, kind: kind), at: 0)
        activity = Array(activity.prefix(8))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

struct ActivityLogEntry: Identifiable {
    enum Kind {
        case info
        case gesture
        case success
        case failure
    }

    let id = UUID()
    let date = Date()
    let message: String
    let kind: Kind

    init(message: String, kind: Kind) {
        self.message = message
        self.kind = kind
    }
}

@MainActor
final class FlickArrangeController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let closeDetector = CloseGestureDetector()
    private let openDetector = OpenGestureDetector()
    private let arranger = WindowArranger()
    private let state = FlickArrangeAppState()
    private var sensor: LidAngleSensor?
    private var timer: Timer?
    private var lastLoggedAngle: Double?
    private var dashboardWindow: NSWindow?

    func start() {
        state.refreshAccessibilityStatus()
        configureMenu()
        showDashboard()
        startMonitoring()
    }

    func stop() {
        stopMonitoring()
    }

    private func configureMenu() {
        statusItem.button?.title = "Flick"
        statusItem.button?.toolTip = "Flick"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = state.isMonitoring ? "Monitoring" : state.sensorStatus
        let statusLine = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        if let latestAngle = state.latestAngle {
            let angleLine = NSMenuItem(title: String(format: "Lid angle: %.0f deg", latestAngle), action: nil, keyEquivalent: "")
            angleLine.isEnabled = false
            menu.addItem(angleLine)
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("Open Flick", action: #selector(showDashboard)))
        menu.addItem(menuItem(state.isMonitoring ? "Stop Monitoring" : "Start Monitoring", action: #selector(toggleMonitoring), key: "m"))
        menu.addItem(menuItem("Arrange Now", action: #selector(arrangeNow), key: "a"))
        menu.addItem(menuItem("Preview Current Layout", action: #selector(previewLayout), key: "p"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Open Accessibility Settings", action: #selector(openAccessibilitySettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Flick", action: #selector(quit), key: "q"))

        statusItem.menu = menu
    }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func startMonitoring() {
        guard !state.isMonitoring else { return }
        do {
            sensor = try LidAngleSensor()
            state.setSensorStatus("Monitoring", monitoring: true)
            state.addActivity("Lid sensor monitoring started")
            print("FlickArrange: sensor monitoring started")
            rebuildMenu()
            timer = Timer.scheduledTimer(withTimeInterval: CloseGestureParameters.sampleInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.pollSensor()
                }
            }
        } catch {
            state.setSensorStatus("Sensor unavailable", monitoring: false)
            state.recordFailure("Lid sensor unavailable: \(error)")
            print("FlickArrange: sensor unavailable: \(error)")
            rebuildMenu()
            showAlert(
                title: "Lid sensor unavailable",
                message: "\(error)\n\nThis needs a supported MacBook lid angle sensor."
            )
        }
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        sensor?.disconnect()
        sensor = nil
        state.setSensorStatus("Monitoring paused", monitoring: false)
        state.addActivity("Lid sensor monitoring paused")
        rebuildMenu()
    }

    private func pollSensor() {
        guard let sensor, let angle = sensor.readAngle() else { return }

        state.setAngle(angle)
        statusItem.button?.title = String(format: "Flick %.0f", angle)

        if lastLoggedAngle == nil || abs(angle - (lastLoggedAngle ?? angle)) >= 2 {
            print(String(format: "FlickArrange: lid angle %.0f deg", angle))
            lastLoggedAngle = angle
        }

        let timestamp = Date().timeIntervalSince1970

        if state.isCloseGestureEnabled,
           closeDetector.addSample(timestamp: timestamp, angle: angle) {
            print("FlickArrange: Close detected")
            statusItem.button?.title = "Flick!"
            state.recordDetection("Close")
            arrangeWindows(reason: "Close", preview: false)
            return
        }

        if state.isOpenGestureEnabled,
           openDetector.addSample(timestamp: timestamp, angle: angle) {
            print("FlickArrange: Open detected")
            statusItem.button?.title = "Flick!"
            state.recordDetection("Open", note: "No action assigned yet")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard self?.state.isArranging == false else { return }
                self?.statusItem.button?.title = "Flick"
            }
        }
    }

    private func arrangeWindows(reason: String, preview: Bool) {
        guard !state.isArranging else {
            state.addActivity("An arrangement is already in progress")
            return
        }

        state.refreshAccessibilityStatus()
        state.setArranging(true)
        state.addActivity(preview ? "Calculating layout preview..." : "Arranging visible windows...")
        rebuildMenu()

        let arranger = arranger
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try arranger.arrangeWindows(verbose: true, preview: preview)
                DispatchQueue.main.async {
                    self?.finishArrangement(result, reason: reason, preview: preview)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.finishArrangementFailure(error)
                }
            }
        }
    }

    private func finishArrangement(_ result: ArrangeResult, reason: String, preview: Bool) {
        state.setArranging(false)
        state.refreshAccessibilityStatus()
        state.recordArrangement(result, preview: preview)
        let action = preview ? "previewed" : "arranged"
        print("FlickArrange: \(action) \(result.arrangedCount)/\(result.targetCount) windows in \(result.totalDurationMilliseconds) ms")
        statusItem.button?.title = "Flick"
        rebuildMenu()
    }

    private func finishArrangementFailure(_ error: Error) {
        state.setArranging(false)
        state.refreshAccessibilityStatus()
        let message = "Could not arrange windows: \(error)"
        state.recordFailure(message)
        print("FlickArrange: arrange failed: \(error)")
        rebuildMenu()
        showAlert(
            title: "Could not arrange windows",
                message: "\(error)\n\nAllow Flick in System Settings > Privacy & Security > Accessibility, then quit and reopen the app."
        )
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    @objc private func showDashboard() {
        if let dashboardWindow {
            dashboardWindow.makeKeyAndOrderFront(nil)
        } else {
            let dashboard = FlickArrangeDashboardView(
                state: state,
                toggleMonitoring: { [weak self] in self?.toggleMonitoring() },
                setCloseGestureEnabled: { [weak self] enabled in self?.setCloseGestureEnabled(enabled) },
                setOpenGestureEnabled: { [weak self] enabled in self?.setOpenGestureEnabled(enabled) },
                arrangeNow: { [weak self] in self?.arrangeNow() },
                previewLayout: { [weak self] in self?.previewLayout() },
                openAccessibilitySettings: { [weak self] in self?.openAccessibilitySettings() }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Flick"
            window.contentViewController = NSHostingController(rootView: dashboard)
            window.center()
            window.isReleasedWhenClosed = false
            dashboardWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleMonitoring() {
        if state.isMonitoring {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    private func setCloseGestureEnabled(_ enabled: Bool) {
        closeDetector.reset()
        state.setCloseGestureEnabled(enabled)
        rebuildMenu()
    }

    private func setOpenGestureEnabled(_ enabled: Bool) {
        openDetector.reset()
        state.setOpenGestureEnabled(enabled)
        rebuildMenu()
    }

    @objc private func arrangeNow() {
        arrangeWindows(reason: "Manual arrange", preview: false)
    }

    @objc private func previewLayout() {
        arrangeWindows(reason: "Layout preview", preview: true)
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
