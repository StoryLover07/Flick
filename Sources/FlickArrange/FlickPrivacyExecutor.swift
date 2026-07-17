import AppKit
import CoreGraphics
import Darwin
import Foundation

enum FlickPrivacyStep: String {
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

struct FlickPrivacyResult {
    let steps: [FlickPrivacyStepResult]
    let summaryItems: [String]
    let needsAccessibilityPermission: Bool

    var failures: [FlickPrivacyStepResult] {
        steps.filter { !$0.succeeded }
    }

    var summary: String {
        let applied = summaryItems.isEmpty ? "no enabled steps completed" : summaryItems.joined(separator: ", ")
        let warning = failures.isEmpty ? "" : " \(failures.count) step(s) need attention."
        return "Flick Privacy applied: \(applied).\(warning)"
    }
}

private enum FlickPrivacyExecutionError: LocalizedError {
    case builtInDisplayUnavailable
    case privateFrameworkUnavailable(String)
    case operationRejected(String)
    case shortcutNotConfigured
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .builtInDisplayUnavailable:
            return "No controllable built-in display is currently available."
        case let .privateFrameworkUnavailable(feature):
            return "\(feature) is unavailable on this macOS version."
        case let .operationRejected(feature):
            return "macOS rejected the \(feature) request."
        case .shortcutNotConfigured:
            return "Choose a macOS Shortcut that enables your preferred work Focus."
        case let .commandFailed(message):
            return message
        }
    }
}

struct FlickPrivacyExecutor {
    private let workspaceActions = WorkspaceActionExecutor()

    func apply(
        settings: FlickPrivacySettings,
        preferredActiveProcessID: pid_t?
    ) -> FlickPrivacyResult {
        var steps: [FlickPrivacyStepResult] = []
        var summaryItems: [String] = []
        var needsAccessibilityPermission = false

        if settings.dimDisplayEnabled {
            let percent = Int((settings.targetBrightness * 100).rounded())
            record(step: .brightness, into: &steps) {
                try setBuiltInDisplayBrightness(settings.targetBrightness)
                summaryItems.append("brightness \(percent)%")
                return "Set built-in display brightness to \(percent)%."
            }
        }

        if settings.muteVolumeEnabled {
            record(step: .volume, into: &steps) {
                try runCommand("/usr/bin/osascript", arguments: ["-e", "set volume output volume 0"])
                summaryItems.append("muted volume")
                return "Set system output volume to 0%."
            }
        }

        if settings.hidePrivacyAppsEnabled {
            let result = workspaceActions.hideApplications(
                bundleIdentifiers: Set(settings.hiddenAppBundleIdentifiers)
            )
            let failedCount = result.failedBundleIdentifiers.count
            let detail = "Hid \(result.hiddenCount) privacy apps; \(result.alreadyHiddenCount) were already hidden."
            summaryItems.append("hid \(result.hiddenCount) privacy apps")
            steps.append(FlickPrivacyStepResult(
                step: .privacyApps,
                succeeded: failedCount == 0,
                detail: failedCount == 0 ? detail : "\(detail) Could not hide \(failedCount) app(s)."
            ))
        }

        if settings.workModeEnabled {
            record(step: .workMode, into: &steps) {
                let shortcutName = settings.workModeShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !shortcutName.isEmpty else {
                    throw FlickPrivacyExecutionError.shortcutNotConfigured
                }
                try runCommand("/usr/bin/shortcuts", arguments: ["run", shortcutName])
                summaryItems.append("enabled work mode")
                return "Ran the \(shortcutName) Shortcut."
            }
        }

        if settings.pauseMediaEnabled {
            record(step: .media, into: &steps) {
                try pauseSystemMedia()
                summaryItems.append("paused media")
                return "Sent the system media pause command."
            }
        }

        if settings.focusActiveWindowEnabled {
            do {
                let result = try workspaceActions.focus(preferredActiveProcessID: preferredActiveProcessID)
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

        return FlickPrivacyResult(
            steps: steps,
            summaryItems: summaryItems,
            needsAccessibilityPermission: needsAccessibilityPermission
        )
    }

    private func record(
        step: FlickPrivacyStep,
        into results: inout [FlickPrivacyStepResult],
        operation: () throws -> String
    ) {
        do {
            results.append(FlickPrivacyStepResult(step: step, succeeded: true, detail: try operation()))
        } catch {
            results.append(FlickPrivacyStepResult(
                step: step,
                succeeded: false,
                detail: error.localizedDescription
            ))
        }
    }

    private func setBuiltInDisplayBrightness(_ target: Double) throws {
        guard let displayID = builtInDisplayID() else {
            throw FlickPrivacyExecutionError.builtInDisplayUnavailable
        }

        // macOS has no public API for setting display brightness. Resolve the
        // private symbol at runtime so unsupported systems fail this step only.
        let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            throw FlickPrivacyExecutionError.privateFrameworkUnavailable("display brightness control")
        }
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
        try runCommand("/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e", script])
    }

    private func runCommand(_ executablePath: String, arguments: [String]) throws {
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

        guard process.terminationStatus == 0 else {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw FlickPrivacyExecutionError.commandFailed(
                message?.isEmpty == false ? message! : "Command exited with status \(process.terminationStatus)."
            )
        }
    }
}
