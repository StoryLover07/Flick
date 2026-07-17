import ApplicationServices
import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class FlickArrangeAppState: ObservableObject {
    private var actionAssignments: FlickActionAssignments
    @Published private(set) var sensorStatus = "Starting sensor..."
    @Published private(set) var isMonitoring = false
    @Published private(set) var isArranging = false
    @Published private(set) var isCloseGestureEnabled = true
    @Published private(set) var isOpenGestureEnabled = true
    @Published private(set) var isAccessibilityTrusted = false
    @Published private(set) var latestAngle: Double?
    @Published private(set) var lastDetection = "Waiting for a Close or Open gesture"
    @Published private(set) var lastActionStatus = "No action run yet"
    @Published private(set) var closeAction: FlickAction
    @Published private(set) var openAction: FlickAction
    @Published private(set) var privacySettings: FlickPrivacySettings
    @Published private(set) var privacySnapshot: FlickPrivacySnapshot?
    @Published private(set) var activity: [ActivityLogEntry] = []

    init() {
        let assignments = FlickActionAssignmentStore.load()
        actionAssignments = assignments
        closeAction = assignments.closeAction
        openAction = assignments.openAction
        privacySettings = FlickPrivacySettingsStore.load()
        privacySnapshot = FlickPrivacySnapshotStore.load()
    }

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

    func action(for gesture: FlickGesture) -> FlickAction {
        actionAssignments.action(for: gesture)
    }

    func assignmentOrigin(for gesture: FlickGesture) -> FlickActionAssignmentOrigin {
        actionAssignments.origin(for: gesture)
    }

    func setAction(_ action: FlickAction, for gesture: FlickGesture) {
        let pairedGesture: FlickGesture = gesture == .close ? .open : .close
        let previousPairedAction = actionAssignments.action(for: pairedGesture)
        actionAssignments.assignManually(action, to: gesture)
        closeAction = actionAssignments.closeAction
        openAction = actionAssignments.openAction
        FlickActionAssignmentStore.save(actionAssignments)
        addActivity("\(gesture.title) assigned to \(action.title)")

        let pairedAction = actionAssignments.action(for: pairedGesture)
        if pairedAction != previousPairedAction {
            let origin = actionAssignments.origin(for: pairedGesture)
            let note = origin == .automatic ? "automatically paired" : "restored to default"
            addActivity("\(pairedGesture.title) \(note): \(pairedAction.title)")
        }
    }

    func updatePrivacySettings(_ update: (inout FlickPrivacySettings) -> Void) {
        var settings = privacySettings
        update(&settings)
        settings.normalize()
        privacySettings = settings
        FlickPrivacySettingsStore.save(settings)
    }

    func recordDetection(_ gesture: String, note: String? = nil) {
        let time = Self.timeFormatter.string(from: Date())
        lastDetection = "\(gesture) detected at \(time)" + (note.map { " - \($0)" } ?? "")
        addActivity(note.map { "\(gesture) detected: \($0)" } ?? "\(gesture) detected", kind: .gesture)
    }

    func recordArrangement(_ result: ArrangeResult, preview: Bool) {
        let action = preview ? "Layout preview" : "Arrangement"
        let completedCount = preview ? result.targetCount : result.arrangedCount
        lastActionStatus = "\(action): \(completedCount)/\(result.targetCount) windows, \(result.totalDurationMilliseconds) ms"
        addActivity(lastActionStatus, kind: .success)
    }

    func recordWorkspaceAction(_ result: WorkspaceActionResult) {
        lastActionStatus = result.summary
        addActivity(result.summary, kind: .success)
    }

    func recordPrivacyAction(_ result: FlickPrivacyResult) {
        for failure in result.failures {
            addActivity("Privacy \(failure.step.rawValue): \(failure.detail)", kind: .failure)
        }
        lastActionStatus = result.summary
        let summaryKind: ActivityLogEntry.Kind = result.summaryItems.isEmpty ? .failure : .success
        addActivity(result.summary, kind: summaryKind)
    }

    func recordPrivacyCancel(_ result: FlickPrivacyCancelResult) {
        for failure in result.failures {
            addActivity("Privacy Cancel \(failure.step.rawValue): \(failure.detail)", kind: .failure)
        }
        lastActionStatus = result.summary
        let summaryKind: ActivityLogEntry.Kind = result.fullyRestored ? .success : .failure
        addActivity(result.summary, kind: summaryKind)
    }

    func setPrivacySnapshot(_ snapshot: FlickPrivacySnapshot) {
        privacySnapshot = snapshot
        FlickPrivacySnapshotStore.save(snapshot)
    }

    func clearPrivacySnapshot() {
        privacySnapshot = nil
        FlickPrivacySnapshotStore.clear()
    }

    func recordFailure(_ message: String) {
        lastActionStatus = message
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
    private let workspaceActions = WorkspaceActionExecutor()
    private let privacyExecutor = FlickPrivacyExecutor()
    private let state = FlickArrangeAppState()
    private var sensor: LidAngleSensor?
    private var timer: Timer?
    private var lastLoggedAngle: Double?
    private var lastExternalApplicationPID: pid_t?
    private var dashboardWindow: NSWindow?

    func start() {
        state.refreshAccessibilityStatus()
        captureActiveExternalApplication()
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
        menu.addItem(menuItem("Run Close Action (\(state.closeAction.title))", action: #selector(runCloseAction)))
        menu.addItem(menuItem("Run Open Action (\(state.openAction.title))", action: #selector(runOpenAction)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Arrange Now", action: #selector(arrangeNow), key: "a"))
        menu.addItem(menuItem("Focus Active Window", action: #selector(focusNow)))
        menu.addItem(menuItem("Hide Apps for Desktop", action: #selector(hideNow)))
        menu.addItem(menuItem("Apply Flick Privacy", action: #selector(privacyNow)))
        menu.addItem(menuItem("Cancel Flick Privacy", action: #selector(privacyCancelNow)))
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

        captureActiveExternalApplication()
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
            handleGesture(.close)
            return
        }

        if state.isOpenGestureEnabled,
           openDetector.addSample(timestamp: timestamp, angle: angle) {
            print("FlickArrange: Open detected")
            statusItem.button?.title = "Flick!"
            handleGesture(.open)
        }
    }

    private func handleGesture(_ gesture: FlickGesture) {
        let action = state.action(for: gesture)
        state.recordDetection(gesture.title, note: action.title)
        runAction(action, reason: gesture.title)
    }

    private func runAction(_ action: FlickAction, reason: String) {
        switch action {
        case .arrange:
            arrangeWindows(reason: reason, preview: false)
        case .focus, .hide:
            runWorkspaceAction(action, reason: reason)
        case .privacy:
            runPrivacyAction(reason: reason)
        case .privacyCancel:
            runPrivacyCancelAction(reason: reason)
        }
    }

    private func arrangeWindows(reason: String, preview: Bool) {
        guard !state.isArranging else {
            state.addActivity("Another Flick action is already in progress")
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
                    self?.finishActionFailure(error)
                }
            }
        }
    }

    private func runWorkspaceAction(_ action: FlickAction, reason: String) {
        guard !state.isArranging else {
            state.addActivity("Another Flick action is already in progress")
            return
        }

        state.refreshAccessibilityStatus()
        state.setArranging(true)
        state.addActivity("Running \(action.title)...")
        rebuildMenu()

        let workspaceActions = workspaceActions
        let preferredActiveProcessID = lastExternalApplicationPID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result: WorkspaceActionResult
                switch action {
                case .focus:
                    result = try workspaceActions.focus(preferredActiveProcessID: preferredActiveProcessID)
                case .hide:
                    result = try workspaceActions.hideAllApps()
                case .arrange, .privacy, .privacyCancel:
                    return
                }
                DispatchQueue.main.async {
                    self?.finishWorkspaceAction(result, reason: reason)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.finishActionFailure(error)
                }
            }
        }
    }

    private func runPrivacyAction(reason: String) {
        guard !state.isArranging else {
            state.addActivity("Another Flick action is already in progress")
            return
        }

        state.refreshAccessibilityStatus()
        state.setArranging(true)
        state.addActivity("Running Flick Privacy...")
        rebuildMenu()

        let privacyExecutor = privacyExecutor
        let settings = state.privacySettings
        let preferredActiveProcessID = lastExternalApplicationPID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let capture = privacyExecutor.captureSnapshot(
                settings: settings,
                preferredActiveProcessID: preferredActiveProcessID
            )
            // Persist before applying any changes so Cancel remains available
            // even if a later Privacy step or the app process exits unexpectedly.
            FlickPrivacySnapshotStore.save(capture.snapshot)
            let result = privacyExecutor.apply(
                settings: settings,
                preferredActiveProcessID: preferredActiveProcessID,
                capture: capture
            )
            FlickPrivacySnapshotStore.save(result.snapshot)
            DispatchQueue.main.async {
                self?.finishPrivacyAction(result, reason: reason)
            }
        }
    }

    private func runPrivacyCancelAction(reason: String) {
        guard !state.isArranging else {
            state.addActivity("Another Flick action is already in progress")
            return
        }
        guard let snapshot = state.privacySnapshot else {
            state.recordFailure("No Flick Privacy state to restore.")
            rebuildMenu()
            return
        }

        state.refreshAccessibilityStatus()
        state.setArranging(true)
        state.addActivity("Running Flick Privacy Cancel...")
        rebuildMenu()

        let privacyExecutor = privacyExecutor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = privacyExecutor.cancel(snapshot: snapshot)
            DispatchQueue.main.async {
                self?.finishPrivacyCancelAction(result, reason: reason)
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

    private func finishWorkspaceAction(_ result: WorkspaceActionResult, reason: String) {
        state.setArranging(false)
        state.refreshAccessibilityStatus()
        state.recordWorkspaceAction(result)
        print("FlickArrange: \(reason) ran \(result.action.title)")
        if result.action == .hide {
            dashboardWindow?.orderOut(nil)
        }
        statusItem.button?.title = "Flick"
        rebuildMenu()
    }

    private func finishPrivacyAction(_ result: FlickPrivacyResult, reason: String) {
        state.setArranging(false)
        state.refreshAccessibilityStatus()
        state.setPrivacySnapshot(result.snapshot)
        state.recordPrivacyAction(result)
        print("FlickArrange: \(reason) ran Flick Privacy with \(result.failures.count) warning(s)")
        statusItem.button?.title = "Flick"
        rebuildMenu()

        if result.needsAccessibilityPermission {
            showAlert(
                title: "Flick Privacy needs Accessibility",
                message: "The other enabled Privacy steps completed, but focusing the active window needs permission.\n\nAllow Flick in System Settings > Privacy & Security > Accessibility, then quit and reopen the app."
            )
        }
    }

    private func finishPrivacyCancelAction(_ result: FlickPrivacyCancelResult, reason: String) {
        state.setArranging(false)
        state.refreshAccessibilityStatus()
        state.recordPrivacyCancel(result)
        if result.fullyRestored {
            state.clearPrivacySnapshot()
        }
        print("FlickArrange: \(reason) ran Flick Privacy Cancel with \(result.failures.count) warning(s)")
        statusItem.button?.title = "Flick"
        rebuildMenu()

        if result.needsAccessibilityPermission {
            showAlert(
                title: "Flick Privacy Cancel needs Accessibility",
                message: "The available Privacy state was restored, but restoring the previous active window needs permission.\n\nAllow Flick in System Settings > Privacy & Security > Accessibility, then quit and reopen the app."
            )
        }
    }

    private func finishActionFailure(_ error: Error) {
        state.setArranging(false)
        state.refreshAccessibilityStatus()
        let message = "Could not run Flick action: \(error)"
        state.recordFailure(message)
        print("FlickArrange: action failed: \(error)")
        rebuildMenu()
        showAlert(
            title: "Could not run Flick action",
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
        captureActiveExternalApplication()
        if let dashboardWindow {
            dashboardWindow.makeKeyAndOrderFront(nil)
        } else {
            let dashboard = FlickArrangeDashboardView(
                state: state,
                toggleMonitoring: { [weak self] in self?.toggleMonitoring() },
                setCloseGestureEnabled: { [weak self] enabled in self?.setCloseGestureEnabled(enabled) },
                setOpenGestureEnabled: { [weak self] enabled in self?.setOpenGestureEnabled(enabled) },
                setAction: { [weak self] gesture, action in self?.setAction(action, for: gesture) },
                runAction: { [weak self] gesture in self?.runAssignedAction(gesture) },
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

    private func setAction(_ action: FlickAction, for gesture: FlickGesture) {
        state.setAction(action, for: gesture)
        rebuildMenu()
    }

    private func runAssignedAction(_ gesture: FlickGesture) {
        runAction(state.action(for: gesture), reason: "Manual \(gesture.title)")
    }

    @objc private func arrangeNow() {
        arrangeWindows(reason: "Manual arrange", preview: false)
    }

    @objc private func runCloseAction() {
        runAssignedAction(.close)
    }

    @objc private func runOpenAction() {
        runAssignedAction(.open)
    }

    @objc private func focusNow() {
        runAction(.focus, reason: "Manual focus")
    }

    @objc private func hideNow() {
        runAction(.hide, reason: "Manual hide")
    }

    @objc private func privacyNow() {
        runAction(.privacy, reason: "Manual privacy")
    }

    @objc private func privacyCancelNow() {
        runAction(.privacyCancel, reason: "Manual privacy cancel")
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

    private func captureActiveExternalApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != getpid(),
              application.activationPolicy == .regular,
              !application.isTerminated else {
            return
        }
        lastExternalApplicationPID = application.processIdentifier
    }
}
