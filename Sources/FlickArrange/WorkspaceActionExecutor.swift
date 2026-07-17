import AppKit
import ApplicationServices
import Foundation

struct WorkspaceActionResult {
    let action: FlickAction
    let affectedApplicationCount: Int
    let affectedWindowCount: Int
    let affectedApplicationBundleIdentifiers: [String]

    init(
        action: FlickAction,
        affectedApplicationCount: Int,
        affectedWindowCount: Int,
        affectedApplicationBundleIdentifiers: [String] = []
    ) {
        self.action = action
        self.affectedApplicationCount = affectedApplicationCount
        self.affectedWindowCount = affectedWindowCount
        self.affectedApplicationBundleIdentifiers = affectedApplicationBundleIdentifiers
    }

    var summary: String {
        switch action {
        case .focus:
            return "Flick Focus kept the active window visible and hid \(affectedApplicationCount) apps."
        case .hide:
            return "Flick Hide hid \(affectedApplicationCount) apps to reveal the Desktop."
        case .arrange, .privacy, .privacyCancel:
            return ""
        }
    }
}

struct WorkspaceApplicationHideResult {
    let hiddenCount: Int
    let alreadyHiddenCount: Int
    let hiddenBundleIdentifiers: [String]
    let failedBundleIdentifiers: [String]
}

struct WorkspaceApplicationRestoreResult {
    let restoredBundleIdentifiers: [String]
    let unavailableBundleIdentifiers: [String]
    let failedBundleIdentifiers: [String]
}

struct WorkspaceActiveRestoreResult {
    let restoredApplication: Bool
    let restoredWindow: Bool
    let needsAccessibilityPermission: Bool
    let detail: String
}

enum WorkspaceActionError: Error, CustomStringConvertible, LocalizedError {
    case accessibilityPermissionDenied
    case noActiveApplication

    var description: String {
        switch self {
        case .accessibilityPermissionDenied:
            return "Flick is not allowed to control other apps. Allow Flick in System Settings > Privacy & Security > Accessibility."
        case .noActiveApplication:
            return "Could not find an active application to focus."
        }
    }

    var errorDescription: String? { description }
}

struct WorkspaceActionExecutor: Sendable {
    func focus(preferredActiveProcessID: pid_t?) throws -> WorkspaceActionResult {
        try requireAccessibilityPermission()
        guard let activeApplication = activeApplication(preferredProcessID: preferredActiveProcessID) else {
            throw WorkspaceActionError.noActiveApplication
        }

        let activeProcessID = activeApplication.processIdentifier
        let activeElement = AXUIElementCreateApplication(activeProcessID)
        let focusedWindow = focusedWindow(of: activeElement)
        var hiddenApplicationCount = 0
        var hiddenBundleIdentifiers: [String] = []
        var minimizedWindowCount = 0

        for application in controllableApplications() where application.processIdentifier != activeProcessID {
            if hide(application) {
                hiddenApplicationCount += 1
                if let bundleIdentifier = application.bundleIdentifier {
                    hiddenBundleIdentifiers.append(bundleIdentifier)
                }
            }
        }

        if let focusedWindow {
            for window in windows(of: activeElement) where !CFEqual(window, focusedWindow) {
                guard isStandardWindow(window), !isMinimized(window) else { continue }
                if AXUIElementSetAttributeValue(
                    window,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanTrue
                ) == .success {
                    minimizedWindowCount += 1
                }
            }
            _ = AXUIElementPerformAction(focusedWindow, kAXRaiseAction as CFString)
        }

        _ = activeApplication.activate(options: [.activateIgnoringOtherApps])
        return WorkspaceActionResult(
            action: .focus,
            affectedApplicationCount: hiddenApplicationCount,
            affectedWindowCount: minimizedWindowCount,
            affectedApplicationBundleIdentifiers: hiddenBundleIdentifiers
        )
    }

    func hideAllApps() throws -> WorkspaceActionResult {
        try requireAccessibilityPermission()
        var hiddenApplicationCount = 0
        var hiddenBundleIdentifiers: [String] = []

        for application in controllableApplications() {
            if hide(application) {
                hiddenApplicationCount += 1
                if let bundleIdentifier = application.bundleIdentifier {
                    hiddenBundleIdentifiers.append(bundleIdentifier)
                }
            }
        }

        return WorkspaceActionResult(
            action: .hide,
            affectedApplicationCount: hiddenApplicationCount,
            affectedWindowCount: 0,
            affectedApplicationBundleIdentifiers: hiddenBundleIdentifiers
        )
    }

    func hideApplications(bundleIdentifiers: Set<String>) -> WorkspaceApplicationHideResult {
        var hiddenCount = 0
        var alreadyHiddenCount = 0
        var hiddenBundleIdentifiers: [String] = []
        var failedBundleIdentifiers: [String] = []

        let applications = controllableApplications().filter { application in
            guard let bundleIdentifier = application.bundleIdentifier else { return false }
            return bundleIdentifiers.contains(bundleIdentifier)
        }

        for application in applications {
            if application.isHidden {
                alreadyHiddenCount += 1
            } else if hide(application) {
                hiddenCount += 1
                if let bundleIdentifier = application.bundleIdentifier {
                    hiddenBundleIdentifiers.append(bundleIdentifier)
                }
            } else if let bundleIdentifier = application.bundleIdentifier {
                failedBundleIdentifiers.append(bundleIdentifier)
            }
        }

        return WorkspaceApplicationHideResult(
            hiddenCount: hiddenCount,
            alreadyHiddenCount: alreadyHiddenCount,
            hiddenBundleIdentifiers: hiddenBundleIdentifiers,
            failedBundleIdentifiers: failedBundleIdentifiers
        )
    }

    func captureActiveContext(preferredProcessID: pid_t?) -> FlickPrivacyActiveContext? {
        guard let application = activeApplication(preferredProcessID: preferredProcessID),
              let bundleIdentifier = application.bundleIdentifier else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let windowTitle = focusedWindow(of: applicationElement).flatMap {
            stringAttribute(kAXTitleAttribute as CFString, from: $0)
        }
        return FlickPrivacyActiveContext(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: Int32(application.processIdentifier),
            focusedWindowTitle: windowTitle
        )
    }

    func currentlyHiddenBundleIdentifiers(from bundleIdentifiers: Set<String>) -> [String] {
        bundleIdentifiers.filter { bundleIdentifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains {
                !$0.isTerminated && $0.isHidden
            }
        }.sorted()
    }

    func restoreApplications(bundleIdentifiers: Set<String>) -> WorkspaceApplicationRestoreResult {
        var restored: [String] = []
        var unavailable: [String] = []
        var failed: [String] = []

        for bundleIdentifier in bundleIdentifiers.sorted() {
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { !$0.isTerminated }
            guard !applications.isEmpty else {
                unavailable.append(bundleIdentifier)
                continue
            }

            if applications.contains(where: unhide) {
                restored.append(bundleIdentifier)
            } else {
                failed.append(bundleIdentifier)
            }
        }

        return WorkspaceApplicationRestoreResult(
            restoredBundleIdentifiers: restored,
            unavailableBundleIdentifiers: unavailable,
            failedBundleIdentifiers: failed
        )
    }

    func restoreActiveContext(_ context: FlickPrivacyActiveContext) -> WorkspaceActiveRestoreResult {
        let processID = pid_t(context.processIdentifier)
        let processApplication = NSRunningApplication(processIdentifier: processID)
        let application: NSRunningApplication?
        if let processApplication,
           processApplication.bundleIdentifier == context.bundleIdentifier,
           !processApplication.isTerminated {
            application = processApplication
        } else {
            application = NSRunningApplication.runningApplications(withBundleIdentifier: context.bundleIdentifier)
                .first { !$0.isTerminated }
        }

        guard let application else {
            return WorkspaceActiveRestoreResult(
                restoredApplication: false,
                restoredWindow: false,
                needsAccessibilityPermission: false,
                detail: "The previously active app is no longer running."
            )
        }

        _ = unhide(application)
        let activated = application.activate(options: [.activateIgnoringOtherApps])
        guard let windowTitle = context.focusedWindowTitle, !windowTitle.isEmpty else {
            return WorkspaceActiveRestoreResult(
                restoredApplication: activated,
                restoredWindow: activated,
                needsAccessibilityPermission: false,
                detail: activated ? "Restored the previously active app." : "Could not reactivate the previous app."
            )
        }

        guard AXIsProcessTrusted() else {
            return WorkspaceActiveRestoreResult(
                restoredApplication: activated,
                restoredWindow: false,
                needsAccessibilityPermission: true,
                detail: "Restored the app, but Accessibility permission is needed to restore its active window."
            )
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let targetWindow = windows(of: applicationElement).first(where: {
            stringAttribute(kAXTitleAttribute as CFString, from: $0) == windowTitle
        }) else {
            return WorkspaceActiveRestoreResult(
                restoredApplication: activated,
                restoredWindow: false,
                needsAccessibilityPermission: false,
                detail: "Restored the app, but its previous window is no longer available."
            )
        }

        if isMinimized(targetWindow) {
            _ = AXUIElementSetAttributeValue(
                targetWindow,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }
        let raised = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString) == .success
        return WorkspaceActiveRestoreResult(
            restoredApplication: activated,
            restoredWindow: raised,
            needsAccessibilityPermission: false,
            detail: raised ? "Restored the previously active window." : "Could not raise the previous window."
        )
    }

    private func requireAccessibilityPermission() throws {
        guard AXIsProcessTrusted() else {
            throw WorkspaceActionError.accessibilityPermissionDenied
        }
    }

    private func activeApplication(preferredProcessID: pid_t?) -> NSRunningApplication? {
        if let preferredProcessID,
           let application = NSRunningApplication(processIdentifier: preferredProcessID),
           isExternalRegularApplication(application) {
            return application
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           isExternalRegularApplication(frontmost) {
            return frontmost
        }
        return nil
    }

    private func controllableApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter(isExternalRegularApplication)
    }

    private func isExternalRegularApplication(_ application: NSRunningApplication) -> Bool {
        application.processIdentifier != getpid()
            && !application.isTerminated
            && application.activationPolicy == .regular
    }

    private func hide(_ application: NSRunningApplication) -> Bool {
        guard !application.isHidden else { return false }
        if application.hide() {
            return true
        }

        let element = AXUIElementCreateApplication(application.processIdentifier)
        return AXUIElementSetAttributeValue(
            element,
            kAXHiddenAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    private func unhide(_ application: NSRunningApplication) -> Bool {
        guard application.isHidden else { return true }
        if application.unhide() {
            return true
        }

        guard AXIsProcessTrusted() else { return false }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        return AXUIElementSetAttributeValue(
            element,
            kAXHiddenAttribute as CFString,
            kCFBooleanFalse
        ) == .success
    }

    private func focusedWindow(of application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func windows(of application: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return []
        }
        return windows
    }

    private func isStandardWindow(_ window: AXUIElement) -> Bool {
        stringAttribute(kAXRoleAttribute as CFString, from: window) == (kAXWindowRole as String)
            && (stringAttribute(kAXSubroleAttribute as CFString, from: window) == nil
                || stringAttribute(kAXSubroleAttribute as CFString, from: window) == (kAXStandardWindowSubrole as String))
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
              let value else {
            return false
        }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }
        return value as? String
    }
}
