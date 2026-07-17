import AppKit
import CoreGraphics
import Darwin
import Foundation

enum FlickPrivacyStep: String {
    case snapshot
    case brightness
    case volume
    case privacyApps
    case workMode
    case media
    case focus
}

struct FlickPrivacyStepResult {
    let step: FlickPrivacyStep
    let succeeded: Bool
    let detail: String
}

struct FlickPrivacySnapshotCapture {
    let snapshot: FlickPrivacySnapshot
    let warnings: [FlickPrivacyStepResult]
}

struct FlickPrivacyResult {
    let steps: [FlickPrivacyStepResult]
    let summaryItems: [String]
    let needsAccessibilityPermission: Bool
    let snapshot: FlickPrivacySnapshot

    var failures: [FlickPrivacyStepResult] {
        steps.filter { !$0.succeeded }
    }

    var summary: String {
        let applied = summaryItems.isEmpty ? "no enabled steps completed" : summaryItems.joined(separator: ", ")
        let warning = failures.isEmpty ? "" : " \(failures.count) step(s) need attention."
        return "Flick Privacy applied: \(applied).\(warning)"
    }
}

enum FlickPrivacyCancelStep: String {
    case brightness
    case volume
    case hiddenApps
    case workMode
    case activeWindow

    var title: String {
        switch self {
        case .brightness: return "brightness"
        case .volume: return "volume"
        case .hiddenApps: return "hidden apps"
        case .workMode: return "Focus mode"
        case .activeWindow: return "active window"
        }
    }
}

struct FlickPrivacyCancelStepResult {
    let step: FlickPrivacyCancelStep
    let succeeded: Bool
    let detail: String
}

struct FlickPrivacyCancelResult {
    let steps: [FlickPrivacyCancelStepResult]
    let summaryItems: [String]
    let needsAccessibilityPermission: Bool

    var failures: [FlickPrivacyCancelStepResult] {
        steps.filter { !$0.succeeded }
    }

    var fullyRestored: Bool { failures.isEmpty }

    var summary: String {
        let restored = summaryItems.isEmpty ? "no changed state needed restoration" : summaryItems.joined(separator: ", ")
        guard !failures.isEmpty else {
            return "Flick Privacy Cancel restored \(restored)."
        }
        let unavailable = failures.map(\.step.title).joined(separator: ", ")
        return "Flick Privacy Cancel partially restored: \(restored); \(unavailable) unavailable."
    }
}

private enum FlickPrivacyExecutionError: LocalizedError {
    case builtInDisplayUnavailable
    case privateFrameworkUnavailable(String)
    case operationRejected(String)
    case shortcutNotConfigured(String)
    case snapshotValueUnavailable(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .builtInDisplayUnavailable:
            return "No controllable built-in display is currently available."
        case let .privateFrameworkUnavailable(feature):
            return "\(feature) is unavailable on this macOS version."
        case let .operationRejected(feature):
            return "macOS rejected the \(feature) request."
        case let .shortcutNotConfigured(purpose):
            return "Choose a macOS Shortcut for \(purpose)."
        case let .snapshotValueUnavailable(value):
            return "The previous \(value) was not available in the Privacy snapshot."
        case let .commandFailed(message):
            return message
        }
    }
}

struct FlickPrivacyExecutor {
    private let workspaceActions = WorkspaceActionExecutor()

    func captureSnapshot(
        settings: FlickPrivacySettings,
        preferredActiveProcessID: pid_t?
    ) -> FlickPrivacySnapshotCapture {
        var snapshot = FlickPrivacySnapshot(
            focusStateBefore: settings.workModeEnabled ? .unavailable : .notCaptured,
            workModeRestoreShortcutName: settings.workModeCancelShortcutName
        )
        var warnings: [FlickPrivacyStepResult] = []

        if settings.dimDisplayEnabled {
            do {
                snapshot.brightnessBefore = try builtInDisplayBrightness()
            } catch {
                warnings.append(FlickPrivacyStepResult(
                    step: .snapshot,
                    succeeded: false,
                    detail: "Could not save the previous brightness: \(error.localizedDescription)"
                ))
            }
        }

        if settings.muteVolumeEnabled {
            do {
                snapshot.outputVolumeBefore = try systemOutputVolume()
            } catch {
                warnings.append(FlickPrivacyStepResult(
                    step: .snapshot,
                    succeeded: false,
                    detail: "Could not save the previous volume: \(error.localizedDescription)"
                ))
            }
        }

        if settings.hidePrivacyAppsEnabled || settings.focusActiveWindowEnabled {
            snapshot.activeContext = workspaceActions.captureActiveContext(
                preferredProcessID: preferredActiveProcessID
            )
            if snapshot.activeContext == nil {
                warnings.append(FlickPrivacyStepResult(
                    step: .snapshot,
                    succeeded: false,
                    detail: "Could not save the previously active app and window."
                ))
            }
        }

        if settings.workModeEnabled {
            warnings.append(FlickPrivacyStepResult(
                step: .snapshot,
                succeeded: false,
                detail: "macOS does not expose the current Focus state. Cancel will use the configured restore Shortcut."
            ))
        }

        return FlickPrivacySnapshotCapture(snapshot: snapshot, warnings: warnings)
    }

    func apply(
        settings: FlickPrivacySettings,
        preferredActiveProcessID: pid_t?,
        capture: FlickPrivacySnapshotCapture
    ) -> FlickPrivacyResult {
        var snapshot = capture.snapshot
        var steps = capture.warnings
        var summaryItems: [String] = []
        var needsAccessibilityPermission = false
        var newlyHiddenBundleIdentifiers = Set<String>()

        if settings.dimDisplayEnabled {
            let percent = Int((settings.targetBrightness * 100).rounded())
            if record(step: .brightness, into: &steps, operation: {
                try setBuiltInDisplayBrightness(settings.targetBrightness)
                return "Set built-in display brightness to \(percent)%."
            }) {
                snapshot.changedBrightness = true
                summaryItems.append("brightness \(percent)%")
            }
        }

        if settings.muteVolumeEnabled {
            if record(step: .volume, into: &steps, operation: {
                try setSystemOutputVolume(0)
                return "Set system output volume to 0%."
            }) {
                snapshot.changedVolume = true
                summaryItems.append("muted volume")
            }
        }

        if settings.hidePrivacyAppsEnabled {
            let result = workspaceActions.hideApplications(
                bundleIdentifiers: Set(settings.hiddenAppBundleIdentifiers)
            )
            newlyHiddenBundleIdentifiers.formUnion(result.hiddenBundleIdentifiers)
            let failedCount = result.failedBundleIdentifiers.count
            let detail = "Hid \(result.hiddenCount) privacy apps; \(result.alreadyHiddenCount) were already hidden."
            summaryItems.append("hid \(result.hiddenCount) privacy apps")
            steps.append(FlickPrivacyStepResult(
                step: .privacyApps,
                succeeded: failedCount == 0,
                detail: failedCount == 0 ? detail : "\(detail) Could not hide \(failedCount) app(s)."
            ))
            if result.hiddenCount > 0 {
                snapshot.changedActiveContext = true
            }
        }

        if settings.workModeEnabled {
            if record(step: .workMode, into: &steps, operation: {
                let shortcutName = settings.workModeShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !shortcutName.isEmpty else {
                    throw FlickPrivacyExecutionError.shortcutNotConfigured("enabling work mode")
                }
                _ = try runCommand("/usr/bin/shortcuts", arguments: ["run", shortcutName])
                return "Ran the \(shortcutName) Shortcut."
            }) {
                snapshot.changedWorkMode = true
                summaryItems.append("enabled work mode")
            }
        }

        if settings.pauseMediaEnabled {
            if record(step: .media, into: &steps, operation: {
                try pauseSystemMedia()
                return "Sent the system media pause command."
            }) {
                summaryItems.append("paused media")
            }
        }

        if settings.focusActiveWindowEnabled {
            do {
                let result = try workspaceActions.focus(preferredActiveProcessID: preferredActiveProcessID)
                newlyHiddenBundleIdentifiers.formUnion(result.affectedApplicationBundleIdentifiers)
                snapshot.changedActiveContext = true
                summaryItems.append("focused active window")
                steps.append(FlickPrivacyStepResult(
                    step: .focus,
                    succeeded: true,
                    detail: "Focused the active window and hid \(result.affectedApplicationCount) other apps."
                ))
            } catch {
                if case WorkspaceActionError.accessibilityPermissionDenied = error {
                    needsAccessibilityPermission = true
                }
                steps.append(FlickPrivacyStepResult(
                    step: .focus,
                    succeeded: false,
                    detail: error.localizedDescription
                ))
            }
        }

        snapshot.hiddenApplicationBundleIdentifiers = workspaceActions.currentlyHiddenBundleIdentifiers(
            from: newlyHiddenBundleIdentifiers
        )
        return FlickPrivacyResult(
            steps: steps,
            summaryItems: summaryItems,
            needsAccessibilityPermission: needsAccessibilityPermission,
            snapshot: snapshot
        )
    }

    func cancel(snapshot: FlickPrivacySnapshot) -> FlickPrivacyCancelResult {
        var steps: [FlickPrivacyCancelStepResult] = []
        var summaryItems: [String] = []
        var needsAccessibilityPermission = false

        if snapshot.changedBrightness {
            if let brightness = snapshot.brightnessBefore {
                if recordCancel(step: .brightness, into: &steps, operation: {
                    try setBuiltInDisplayBrightness(brightness)
                    return "Restored brightness to \(Int((brightness * 100).rounded()))%."
                }) {
                    summaryItems.append("brightness")
                }
            } else {
                appendMissingSnapshotValue("brightness", step: .brightness, to: &steps)
            }
        }

        if snapshot.changedVolume {
            if let volume = snapshot.outputVolumeBefore {
                if recordCancel(step: .volume, into: &steps, operation: {
                    try setSystemOutputVolume(volume)
                    return "Restored output volume to \(volume)%."
                }) {
                    summaryItems.append("volume")
                }
            } else {
                appendMissingSnapshotValue("volume", step: .volume, to: &steps)
            }
        }

        if !snapshot.hiddenApplicationBundleIdentifiers.isEmpty {
            let result = workspaceActions.restoreApplications(
                bundleIdentifiers: Set(snapshot.hiddenApplicationBundleIdentifiers)
            )
            let restoredCount = result.restoredBundleIdentifiers.count
            let unavailableCount = result.unavailableBundleIdentifiers.count
            let failedCount = result.failedBundleIdentifiers.count
            if restoredCount > 0 {
                summaryItems.append("\(restoredCount) hidden apps")
            }
            steps.append(FlickPrivacyCancelStepResult(
                step: .hiddenApps,
                succeeded: unavailableCount == 0 && failedCount == 0,
                detail: "Restored \(restoredCount) app(s); \(unavailableCount) no longer running; \(failedCount) failed."
            ))
        }

        if snapshot.changedWorkMode {
            if recordCancel(step: .workMode, into: &steps, operation: {
                let shortcutName = snapshot.workModeRestoreShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !shortcutName.isEmpty else {
                    throw FlickPrivacyExecutionError.shortcutNotConfigured("restoring the previous Focus mode")
                }
                _ = try runCommand("/usr/bin/shortcuts", arguments: ["run", shortcutName])
                return "Ran the \(shortcutName) restore Shortcut."
            }) {
                summaryItems.append("work mode")
            }
        }

        if snapshot.changedActiveContext {
            if let activeContext = snapshot.activeContext {
                let result = workspaceActions.restoreActiveContext(activeContext)
                needsAccessibilityPermission = result.needsAccessibilityPermission
                if result.restoredWindow {
                    summaryItems.append("active window")
                } else if result.restoredApplication {
                    summaryItems.append("active app")
                }
                steps.append(FlickPrivacyCancelStepResult(
                    step: .activeWindow,
                    succeeded: result.restoredApplication && result.restoredWindow,
                    detail: result.detail
                ))
            } else {
                appendMissingSnapshotValue("active window", step: .activeWindow, to: &steps)
            }
        }

        return FlickPrivacyCancelResult(
            steps: steps,
            summaryItems: summaryItems,
            needsAccessibilityPermission: needsAccessibilityPermission
        )
    }

    @discardableResult
    private func record(
        step: FlickPrivacyStep,
        into results: inout [FlickPrivacyStepResult],
        operation: () throws -> String
    ) -> Bool {
        do {
            results.append(FlickPrivacyStepResult(step: step, succeeded: true, detail: try operation()))
            return true
        } catch {
            results.append(FlickPrivacyStepResult(
                step: step,
                succeeded: false,
                detail: error.localizedDescription
            ))
            return false
        }
    }

    @discardableResult
    private func recordCancel(
        step: FlickPrivacyCancelStep,
        into results: inout [FlickPrivacyCancelStepResult],
        operation: () throws -> String
    ) -> Bool {
        do {
            results.append(FlickPrivacyCancelStepResult(step: step, succeeded: true, detail: try operation()))
            return true
        } catch {
            results.append(FlickPrivacyCancelStepResult(
                step: step,
                succeeded: false,
                detail: error.localizedDescription
            ))
            return false
        }
    }

    private func appendMissingSnapshotValue(
        _ value: String,
        step: FlickPrivacyCancelStep,
        to results: inout [FlickPrivacyCancelStepResult]
    ) {
        results.append(FlickPrivacyCancelStepResult(
            step: step,
            succeeded: false,
            detail: FlickPrivacyExecutionError.snapshotValueUnavailable(value).localizedDescription
        ))
    }

    private func builtInDisplayBrightness() throws -> Double {
        let displayID = try requireBuiltInDisplayID()
        let handle = try displayServicesHandle()
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "DisplayServicesGetBrightness") else {
            throw FlickPrivacyExecutionError.privateFrameworkUnavailable("display brightness reading")
        }
        typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let getBrightness = unsafeBitCast(symbol, to: GetBrightness.self)
        var brightness: Float = 0
        guard getBrightness(displayID, &brightness) == 0 else {
            throw FlickPrivacyExecutionError.operationRejected("display brightness reading")
        }
        return Double(brightness)
    }

    private func setBuiltInDisplayBrightness(_ target: Double) throws {
        let displayID = try requireBuiltInDisplayID()
        let handle = try displayServicesHandle()
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "DisplayServicesSetBrightness") else {
            throw FlickPrivacyExecutionError.privateFrameworkUnavailable("display brightness control")
        }
        typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let setBrightness = unsafeBitCast(symbol, to: SetBrightness.self)
        let status = setBrightness(displayID, Float(min(max(target, 0), 1)))
        guard status == 0 else {
            throw FlickPrivacyExecutionError.operationRejected("display brightness")
        }
    }

    private func requireBuiltInDisplayID() throws -> CGDirectDisplayID {
        guard let displayID = builtInDisplayID() else {
            throw FlickPrivacyExecutionError.builtInDisplayUnavailable
        }
        return displayID
    }

    private func displayServicesHandle() throws -> UnsafeMutableRawPointer {
        let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            throw FlickPrivacyExecutionError.privateFrameworkUnavailable("display brightness control")
        }
        return handle
    }

    private func builtInDisplayID() -> CGDirectDisplayID? {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return nil
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
            return nil
        }
        return displays.prefix(Int(displayCount)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private func systemOutputVolume() throws -> Int {
        let output = try runCommand(
            "/usr/bin/osascript",
            arguments: ["-e", "output volume of (get volume settings)"]
        )
        guard let volume = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FlickPrivacyExecutionError.commandFailed("Could not read the current output volume.")
        }
        return min(max(volume, 0), 100)
    }

    private func setSystemOutputVolume(_ volume: Int) throws {
        let clampedVolume = min(max(volume, 0), 100)
        _ = try runCommand(
            "/usr/bin/osascript",
            arguments: ["-e", "set volume output volume \(clampedVolume)"]
        )
    }

    private func pauseSystemMedia() throws {
        // macOS has no public API for controlling another app's Now Playing
        // session. Run the optional private call out of process so a framework
        // or ABI change can fail this step without crashing Flick itself.
        let script = """
        ObjC.import('Foundation');

        function run() {
            const framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
            if (!framework || !framework.load) {
                throw new Error('MediaRemote framework is unavailable.');
            }

            const Controller = $.NSClassFromString('MRNowPlayingController');
            if (!Controller) {
                throw new Error('System media controller is unavailable.');
            }

            const controller = Controller.localRouteController;
            const options = $.NSDictionary.alloc.init;
            controller.sendCommandOptionsCompletion(1, options, null);
            return 'pause sent';
        }
        """
        _ = try runCommand("/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e", script])
    }

    @discardableResult
    private func runCommand(_ executablePath: String, arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw FlickPrivacyExecutionError.commandFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw FlickPrivacyExecutionError.commandFailed(
                output.isEmpty ? "Command exited with status \(process.terminationStatus)." : output
            )
        }
        return output
    }
}
