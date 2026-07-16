import AppKit
import ApplicationServices
import Foundation

struct WorkspaceActionResult {
    let action: FlickAction
    let affectedApplicationCount: Int
    let affectedWindowCount: Int

    var summary: String {
        switch action {
        case .focus:
            return "Flick Focus kept the active window visible and hid \(affectedApplicationCount) apps."
        case .hide:
            return "Flick Hide hid \(affectedApplicationCount) apps to reveal the Desktop."
        case .arrange:
            return ""
        }
    }
}

enum WorkspaceActionError: Error, CustomStringConvertible {
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
        var minimizedWindowCount = 0

        for application in controllableApplications() where application.processIdentifier != activeProcessID {
            if hide(application) {
                hiddenApplicationCount += 1
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
            affectedWindowCount: minimizedWindowCount
        )
    }

    func hideAllApps() throws -> WorkspaceActionResult {
        try requireAccessibilityPermission()
        var hiddenApplicationCount = 0

        for application in controllableApplications() {
            if hide(application) {
                hiddenApplicationCount += 1
            }
        }

        return WorkspaceActionResult(
            action: .hide,
            affectedApplicationCount: hiddenApplicationCount,
            affectedWindowCount: 0
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
