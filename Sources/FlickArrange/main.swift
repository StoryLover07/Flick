import AppKit

private func runCommandLineModeIfRequested() {
    let arguments = Set(CommandLine.arguments.dropFirst())
    guard arguments.contains("--preview-once") || arguments.contains("--arrange-once") else {
        return
    }

    let preview = arguments.contains("--preview-once")
    do {
        let result = try WindowArranger().arrangeWindows(verbose: true, preview: preview)
        let action = preview ? "Previewed" : "Arranged"
        let completedCount = preview ? result.targetCount : result.arrangedCount
        print("\(action) \(completedCount)/\(result.targetCount) windows")
        print("Collection: \(result.collectionDurationMilliseconds) ms")
        print("Layout: \(result.layoutDurationMilliseconds) ms")
        print("Bounds: \(result.settingDurationMilliseconds) ms")
        print("Total: \(result.totalDurationMilliseconds) ms")
        exit(0)
    } catch {
        fputs("Flick command failed: \(error)\n", stderr)
        exit(1)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: FlickArrangeController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = FlickArrangeController()
        controller?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}

runCommandLineModeIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
