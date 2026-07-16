import AppIntents
import Foundation

@available(macOS 13.0, *)
struct ArrangeWindowsIntent: AppIntent {
    static var title: LocalizedStringResource = "Arrange Windows"
    static var description = IntentDescription("Arrange visible windows using the current Flick layout.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        let result = try WindowArranger().arrangeWindows(verbose: false, preview: false)
        return .result(dialog: "Arranged \(result.arrangedCount) of \(result.targetCount) windows.")
    }
}

@available(macOS 13.0, *)
struct FlickArrangeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ArrangeWindowsIntent(),
            phrases: [
                "Arrange windows with \(.applicationName)",
                "Run window arrangement with \(.applicationName)"
            ],
            shortTitle: "Arrange Windows",
            systemImageName: "rectangle.3.group"
        )
    }
}
