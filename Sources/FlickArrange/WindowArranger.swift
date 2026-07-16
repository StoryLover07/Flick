import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

struct WindowInfo {
    let processName: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let windowIndex: Int
    let frame: CGRect
    let minimized: Bool
    let isFocused: Bool
    fileprivate let element: AXUIElement
}

struct WindowPlacement {
    let window: WindowInfo
    let frame: CGRect
}

struct ArrangeResult {
    let collectedCount: Int
    let targetCount: Int
    let arrangedCount: Int
    let collectionDurationMilliseconds: Int
    let layoutDurationMilliseconds: Int
    let settingDurationMilliseconds: Int
    let totalDurationMilliseconds: Int
}

enum WindowArrangerError: Error, CustomStringConvertible {
    case accessibilityPermissionDenied
    case accessibilityFailed(String)
    case noScreen

    var description: String {
        switch self {
        case .accessibilityPermissionDenied:
            return "Flick is not allowed to control other apps."
        case .accessibilityFailed(let message):
            return message
        case .noScreen:
            return "Could not read main screen bounds."
        }
    }
}

struct WindowArranger: Sendable {
    private let minScreenIntersectionPixels: CGFloat = 20
    private let minScreenIntersectionRatio: CGFloat = 0.10
    // Windows Snap-style layouts use fixed zones with one consistent gutter.
    private let gap: CGFloat = 8
    private let frameTolerance: CGFloat = 12

    func arrangeWindows(verbose: Bool, preview: Bool) throws -> ArrangeResult {
        let totalStart = CFAbsoluteTimeGetCurrent()
        try requireAccessibilityPermission()
        let screen = try mainScreenBounds()
        let collectionStart = CFAbsoluteTimeGetCurrent()
        let collection = try collectWindows()
        if collection.windows.isEmpty,
           collection.accessibilityFailureCount > 0 {
            let details = collection.errorLines.prefix(8).joined(separator: "\n")
            let suffix = details.isEmpty ? "" : "\n\n\(details)"
            throw WindowArrangerError.accessibilityFailed("Could not collect visible windows.\(suffix)")
        }
        let collectionDuration = milliseconds(since: collectionStart)
        let layoutStart = CFAbsoluteTimeGetCurrent()
        let filtered = collection.windows.filter {
            shouldInclude(window: $0, screen: screen) && $0.processName != ProcessInfo.processInfo.processName
        }
        let ordered = prioritizeActiveWindow(filtered, frontmostProcess: collection.frontmostProcess)
        var placements = calculateLayout(windows: ordered, screen: screen)
        try validateLayout(placements, screen: screen)
        let layoutDuration = milliseconds(since: layoutStart)

        if verbose {
            print("Visible processes: \(collection.visibleProcessCount)")
            for line in collection.skippedLines {
                print("Skipped: \(line)")
            }
            for line in collection.errorLines {
                print("Accessibility: \(line)")
            }
            print("Collected \(collection.windows.count), target \(placements.count)")
            for placement in placements {
                print("\(placement.window.processName) \(placement.window.windowIndex) -> \(placement.frame.integral)")
            }
        }

        if preview {
            return ArrangeResult(
                collectedCount: collection.windows.count,
                targetCount: placements.count,
                arrangedCount: 0,
                collectionDurationMilliseconds: collectionDuration,
                layoutDurationMilliseconds: layoutDuration,
                settingDurationMilliseconds: 0,
                totalDurationMilliseconds: milliseconds(since: totalStart)
            )
        }

        let settingStart = CFAbsoluteTimeGetCurrent()
        var settingResult = try setWindowBoundsBatch(placements, verbose: verbose)

        // Some apps enforce a tall minimum window size. If a regular grid cannot
        // be accepted, give one constrained window a full-height Snap zone and
        // divide the other half evenly between the remaining windows.
        if let fallback = calculateConstraintFallback(
            windows: ordered,
            screen: screen,
            mismatches: settingResult.mismatches
        ) {
            placements = fallback
            try validateLayout(placements, screen: screen)
            if verbose {
                print("Retrying with a tall-window Snap layout")
                for placement in placements {
                    print("Retry: \(placement.window.processName) \(placement.window.windowIndex) -> \(placement.frame.integral)")
                }
            }
            settingResult = try setWindowBoundsBatch(placements, verbose: verbose)
        }
        let settingDuration = milliseconds(since: settingStart)
        return ArrangeResult(
            collectedCount: collection.windows.count,
            targetCount: placements.count,
            arrangedCount: settingResult.successCount,
            collectionDurationMilliseconds: collectionDuration,
            layoutDurationMilliseconds: layoutDuration,
            settingDurationMilliseconds: settingDuration,
            totalDurationMilliseconds: milliseconds(since: totalStart)
        )
    }

    private func milliseconds(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    private func requireAccessibilityPermission() throws {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw WindowArrangerError.accessibilityPermissionDenied
        }
    }

    private func mainScreenBounds() throws -> CGRect {
        let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
        if !mainDisplayBounds.isEmpty {
            return mainScreenVisibleBounds(displayBounds: mainDisplayBounds) ?? mainDisplayBounds
        }
        print("FlickArrange: CGMainDisplayID=\(CGMainDisplayID()) bounds=\(mainDisplayBounds)")

        var displayCount: UInt32 = 0
        if CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 {
            print("FlickArrange: active display count=\(displayCount)")
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
            if CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success {
                print("FlickArrange: active display bounds=\(displays.map(CGDisplayBounds))")
                if let bounds = displays.map(CGDisplayBounds).first(where: { !$0.isEmpty }) {
                    return bounds
                }
            }
        } else {
            print("FlickArrange: active display list unavailable count=\(displayCount)")
        }

        if let bounds = mainScreenBoundsFromWindowServer(), !bounds.isEmpty {
            return bounds
        }

        throw WindowArrangerError.noScreen
    }

    private func mainScreenVisibleBounds(displayBounds: CGRect) -> CGRect? {
        let readVisibleBounds: () -> CGRect? = {
            let displayID = CGMainDisplayID()
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            }) ?? NSScreen.main else {
                return nil
            }

            // AppKit uses a bottom-left origin while Accessibility uses the
            // top-left screen coordinates returned by CoreGraphics.
            let frame = screen.frame
            let visible = screen.visibleFrame
            return CGRect(
                x: displayBounds.minX + visible.minX - frame.minX,
                y: displayBounds.minY + frame.maxY - visible.maxY,
                width: visible.width,
                height: visible.height
            ).integral
        }

        if Thread.isMainThread {
            return readVisibleBounds()
        }
        return DispatchQueue.main.sync(execute: readVisibleBounds)
    }

    private func mainScreenBoundsFromWindowServer() -> CGRect? {
        guard let windowInfo = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let origin = CGPoint.zero
        return windowInfo.compactMap { item -> CGRect? in
            guard let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer < 0,
                  let frame = cgRect(from: item[kCGWindowBounds as String]),
                  frame.width >= 640,
                  frame.height >= 480,
                  frame.contains(origin) else {
                return nil
            }
            return frame
        }.max { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }
    }

    private func shouldInclude(window: WindowInfo, screen: CGRect) -> Bool {
        guard !window.minimized, window.frame.width > 0, window.frame.height > 0 else {
            return false
        }
        let intersection = window.frame.intersection(screen)
        guard intersection.width >= minScreenIntersectionPixels,
              intersection.height >= minScreenIntersectionPixels else {
            return false
        }
        return intersection.width * intersection.height / (window.frame.width * window.frame.height) >= minScreenIntersectionRatio
    }

    private func prioritizeActiveWindow(_ windows: [WindowInfo], frontmostProcess: String?) -> [WindowInfo] {
        guard let frontmostProcess,
              let index = windows.firstIndex(where: {
                  $0.processName == frontmostProcess && $0.isFocused
              }) ?? windows.firstIndex(where: { $0.processName == frontmostProcess }) else {
            return windows
        }
        var reordered = windows
        let active = reordered.remove(at: index)
        reordered.insert(active, at: 0)
        return reordered
    }

    private func calculateLayout(windows: [WindowInfo], screen: CGRect) -> [WindowPlacement] {
        let count = windows.count
        guard count > 0 else { return [] }

        let frames: [CGRect]
        switch count {
        case 1:
            frames = [screen]
        case 2:
            frames = gridFrames(count: count, columns: 2, rows: 1, screen: screen)
        case 3:
            let halves = gridFrames(count: 2, columns: 2, rows: 1, screen: screen)
            let leftStack = gridFrames(count: 2, columns: 1, rows: 2, screen: halves[0])
            frames = [
                halves[1],
                leftStack[0],
                leftStack[1]
            ]
        case 4:
            frames = gridFrames(count: count, columns: 2, rows: 2, screen: screen)
        case 5...6:
            frames = gridFrames(count: count, columns: 3, rows: 2, screen: screen)
        case 7:
            let horizontalRows = gridFrames(count: 2, columns: 1, rows: 2, screen: screen)
            frames = gridFrames(count: 3, columns: 3, rows: 1, screen: horizontalRows[0])
                + gridFrames(count: 4, columns: 4, rows: 1, screen: horizontalRows[1])
        case 8:
            frames = gridFrames(count: count, columns: 4, rows: 2, screen: screen)
        case 9:
            frames = gridFrames(count: count, columns: 3, rows: 3, screen: screen)
        default:
            let columns = Int(ceil(sqrt(Double(count))))
            let rows = Int(ceil(Double(count) / Double(columns)))
            frames = gridFrames(count: count, columns: columns, rows: rows, screen: screen)
        }

        return zip(windows, frames).map { WindowPlacement(window: $0.0, frame: $0.1.integral) }
    }

    private func gridFrames(count: Int, columns: Int, rows: Int, screen: CGRect) -> [CGRect] {
        guard count > 0, columns > 0, rows > 0 else { return [] }
        let usableWidth = screen.width - gap * CGFloat(columns - 1)
        let usableHeight = screen.height - gap * CGFloat(rows - 1)

        return (0..<count).map { index in
            let column = index % columns
            let row = index / columns
            let left = screen.minX + CGFloat(column) * usableWidth / CGFloat(columns) + CGFloat(column) * gap
            let right = screen.minX + CGFloat(column + 1) * usableWidth / CGFloat(columns) + CGFloat(column) * gap
            let top = screen.minY + CGFloat(row) * usableHeight / CGFloat(rows) + CGFloat(row) * gap
            let bottom = screen.minY + CGFloat(row + 1) * usableHeight / CGFloat(rows) + CGFloat(row) * gap
            return CGRect(x: left, y: top, width: right - left, height: bottom - top).integral
        }
    }

    private func calculateConstraintFallback(
        windows: [WindowInfo],
        screen: CGRect,
        mismatches: [WindowMismatch]
    ) -> [WindowPlacement]? {
        if (6...9).contains(windows.count) {
            return calculateTopRowPriorityLayout(
                windows: windows,
                screen: screen,
                mismatches: mismatches
            )
        }

        // Smaller layouts can change row heights after measuring app limits.
        guard (3...5).contains(windows.count) else { return nil }

        // Collision-only entries are victims of a neighboring oversized
        // window. The constrained set contains only windows that rejected
        // their own target frame.
        let constrainedMismatches = mismatches.filter { $0.reason != "final bounds overlap another window" }
        let constrainedWindows = constrainedMismatches.map(\.placement.window)
        guard !constrainedWindows.isEmpty,
              constrainedWindows.count < windows.count else {
            return nil
        }

        let minimumTopHeight = constrainedMismatches.compactMap(\.actualFrame?.height).max() ?? screen.height * 0.58
        let topHeight = min(screen.height - 280, max(screen.height * 0.58, minimumTopHeight))
        let bottomHeight = screen.height - topHeight - gap
        guard bottomHeight >= 260 else { return nil }

        let topRect = CGRect(
            x: screen.minX,
            y: screen.minY,
            width: screen.width,
            height: topHeight
        ).integral
        let bottomRect = CGRect(
            x: screen.minX,
            y: topRect.maxY + gap,
            width: screen.width,
            height: bottomHeight
        ).integral
        let topFrames = gridFrames(
            count: constrainedWindows.count,
            columns: constrainedWindows.count,
            rows: 1,
            screen: topRect
        )

        // Do not retry a fallback that is already narrower than a window's
        // observed minimum width.
        for (window, target) in zip(constrainedWindows, topFrames) {
            guard let mismatch = constrainedMismatches.first(where: {
                sameWindow($0.placement.window, window)
            }),
            let actual = mismatch.actualFrame,
            actual.width <= target.width + frameTolerance else {
                return nil
            }
        }

        let remainingWindows = windows.filter { window in
            !constrainedWindows.contains(where: { sameWindow($0, window) })
        }
        let bottomFrames = gridFrames(
            count: remainingWindows.count,
            columns: remainingWindows.count,
            rows: 1,
            screen: bottomRect
        )
        let ordered = constrainedWindows + remainingWindows
        let fallbackFrames = topFrames + bottomFrames
        return zip(ordered, fallbackFrames).map {
            WindowPlacement(window: $0.0, frame: $0.1.integral)
        }
    }

    private func calculateTopRowPriorityLayout(
        windows: [WindowInfo],
        screen: CGRect,
        mismatches: [WindowMismatch]
    ) -> [WindowPlacement]? {
        let constrained = mismatches
            .filter { $0.reason != "final bounds overlap another window" }
            .sorted { lhs, rhs in
                constraintOverflow(for: lhs) > constraintOverflow(for: rhs)
            }
            .map(\.placement.window)
        guard !constrained.isEmpty else { return nil }

        // Put windows that rejected their target size into the first row.
        // Eight windows use four columns; the other supported layouts use three.
        let topRowCapacity = windows.count == 8 ? 4 : 3
        let promoted = Array(constrained.prefix(topRowCapacity))
        let remaining = windows.filter { window in
            !promoted.contains(where: { sameWindow($0, window) })
        }
        let reordered = promoted + remaining
        guard zip(reordered, windows).contains(where: { !sameWindow($0.0, $0.1) }) else {
            return nil
        }
        return calculateLayout(windows: reordered, screen: screen)
    }

    private func constraintOverflow(for mismatch: WindowMismatch) -> CGFloat {
        guard let actual = mismatch.actualFrame else { return .greatestFiniteMagnitude }
        let target = mismatch.placement.frame
        return max(0, actual.width - target.width) + max(0, actual.height - target.height)
    }

    private func sameWindow(_ lhs: WindowInfo, _ rhs: WindowInfo) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier && lhs.windowIndex == rhs.windowIndex
    }

    private func validateLayout(_ placements: [WindowPlacement], screen: CGRect) throws {
        for placement in placements where !screen.insetBy(dx: -1, dy: -1).contains(placement.frame) {
            throw WindowArrangerError.accessibilityFailed("Calculated a window position outside the usable screen.")
        }
        for firstIndex in placements.indices {
            for secondIndex in placements.indices where secondIndex > firstIndex {
                let overlap = placements[firstIndex].frame.intersection(placements[secondIndex].frame)
                if !overlap.isNull, overlap.width > 1, overlap.height > 1 {
                    throw WindowArrangerError.accessibilityFailed("Calculated overlapping window positions.")
                }
            }
        }
    }
}

private struct WindowMismatch {
    let placement: WindowPlacement
    let actualFrame: CGRect?
    let reason: String
}

private struct WindowSettingResult {
    let successCount: Int
    let mismatches: [WindowMismatch]
}

private struct WindowCollection {
    let windows: [WindowInfo]
    let frontmostProcess: String?
    let visibleProcessCount: Int
    let accessibilityFailureCount: Int
    let errorLines: [String]
    let skippedLines: [String]
}

private struct OnScreenWindow {
    let processIdentifier: pid_t
    let frame: CGRect
    let title: String?
}

private extension WindowArranger {
    func collectWindows() throws -> WindowCollection {
        let onScreenWindows = currentSpaceWindows()
        let windowsByProcess = Dictionary(grouping: onScreenWindows, by: \.processIdentifier)
        var windows: [WindowInfo] = []
        var accessibilityFailureCount = 0
        var errorLines: [String] = []
        var skippedLines: [String] = []

        for processIdentifier in windowsByProcess.keys.sorted() {
            guard processIdentifier != getpid(),
                  let app = NSRunningApplication(processIdentifier: processIdentifier) else {
                continue
            }

            let processName = app.localizedName
                ?? onScreenWindows.first(where: { $0.processIdentifier == processIdentifier })?.title
                ?? "PID \(processIdentifier)"

            guard !app.isHidden else {
                skippedLines.append("\(processName): application is hidden")
                continue
            }
            guard app.activationPolicy == .regular else {
                skippedLines.append("\(processName): background-only application")
                continue
            }

            let applicationElement = AXUIElementCreateApplication(processIdentifier)
            let windowResult = copyAttribute(kAXWindowsAttribute as CFString, from: applicationElement)
            guard windowResult.error == .success,
                  let applicationWindows = windowResult.value as? [AXUIElement] else {
                accessibilityFailureCount += 1
                errorLines.append("\(processName): could not read windows (AX error \(windowResult.error.rawValue))")
                continue
            }

            let focusedResult = copyAttribute(kAXFocusedWindowAttribute as CFString, from: applicationElement)
            let focusedWindow: AXUIElement?
            if focusedResult.error == .success,
               let focusedValue = focusedResult.value,
               CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
                focusedWindow = unsafeBitCast(focusedValue, to: AXUIElement.self)
            } else {
                focusedWindow = nil
            }
            var unmatchedOnScreenWindows = windowsByProcess[processIdentifier] ?? []

            for (offset, element) in applicationWindows.enumerated() {
                let windowIndex = offset + 1
                let role = stringAttribute(kAXRoleAttribute as CFString, from: element)
                guard role == (kAXWindowRole as String) else {
                    skippedLines.append("\(processName) \(windowIndex): non-window accessibility element")
                    continue
                }

                if let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element),
                   subrole != (kAXStandardWindowSubrole as String) {
                    skippedLines.append("\(processName) \(windowIndex): non-standard window (\(subrole))")
                    continue
                }

                let minimized = boolAttribute(kAXMinimizedAttribute as CFString, from: element) ?? false
                guard !minimized else {
                    skippedLines.append("\(processName) \(windowIndex): minimized")
                    continue
                }

                guard let frame = frame(of: element), frame.width > 0, frame.height > 0 else {
                    skippedLines.append("\(processName) \(windowIndex): invalid bounds")
                    continue
                }

                let title = stringAttribute(kAXTitleAttribute as CFString, from: element)
                guard let matchIndex = matchingWindowIndex(
                    frame: frame,
                    title: title,
                    candidates: unmatchedOnScreenWindows
                ) else {
                    skippedLines.append("\(processName) \(windowIndex): not visible on the active Space")
                    continue
                }
                unmatchedOnScreenWindows.remove(at: matchIndex)

                windows.append(
                    WindowInfo(
                        processName: processName,
                        bundleIdentifier: app.bundleIdentifier,
                        processIdentifier: processIdentifier,
                        windowIndex: windowIndex,
                        frame: frame,
                        minimized: false,
                        isFocused: focusedWindow.map { CFEqual($0, element) } ?? false,
                        element: element
                    )
                )
            }
        }

        return WindowCollection(
            windows: windows,
            frontmostProcess: NSWorkspace.shared.frontmostApplication?.localizedName,
            visibleProcessCount: windowsByProcess.count,
            accessibilityFailureCount: accessibilityFailureCount,
            errorLines: errorLines,
            skippedLines: skippedLines
        )
    }

    func setWindowBoundsBatch(_ placements: [WindowPlacement], verbose: Bool) throws -> WindowSettingResult {
        // Resize every window first. Moving a wide window into a narrow zone
        // before resizing makes macOS clamp its position to the old width.
        for placement in placements {
            _ = setSize(placement.frame.size, for: placement.window.element)
        }
        for placement in placements {
            _ = setPosition(placement.frame.origin, for: placement.window.element)
        }

        Thread.sleep(forTimeInterval: 0.04)
        var mismatches = frameMismatches(for: placements)

        // A second size-position pass handles apps that update their minimum
        // size or toolbar state only after the first Accessibility mutation.
        for mismatch in mismatches {
            let placement = mismatch.placement
            let sizeError = setSize(placement.frame.size, for: placement.window.element)
            let positionError = setPosition(placement.frame.origin, for: placement.window.element)
            if verbose, sizeError != .success || positionError != .success {
                print(
                    "Could not move \(placement.window.processName) \(placement.window.windowIndex): "
                    + "size AX \(sizeError.rawValue), position AX \(positionError.rawValue)"
                )
            }
        }

        if !mismatches.isEmpty {
            Thread.sleep(forTimeInterval: 0.04)
            mismatches = frameMismatches(for: placements)
        }
        mismatches = mismatchesIncludingCollisions(placements: placements, frameMismatches: mismatches)

        if verbose {
            for mismatch in mismatches {
                let actual = mismatch.actualFrame.map { NSStringFromRect($0) } ?? "unavailable"
                print(
                    "Unsnapped \(mismatch.placement.window.processName) \(mismatch.placement.window.windowIndex): "
                    + "\(mismatch.reason), target \(mismatch.placement.frame.integral), actual \(actual)"
                )
            }
        }

        guard AXIsProcessTrusted() else {
            throw WindowArrangerError.accessibilityPermissionDenied
        }
        return WindowSettingResult(
            successCount: placements.count - mismatches.count,
            mismatches: mismatches
        )
    }

    func setSize(_ size: CGSize, for element: AXUIElement) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    func setPosition(_ position: CGPoint, for element: AXUIElement) -> AXError {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    func frameMismatches(for placements: [WindowPlacement]) -> [WindowMismatch] {
        placements.compactMap { placement in
            guard let actual = frame(of: placement.window.element) else {
                return WindowMismatch(placement: placement, actualFrame: nil, reason: "could not read final bounds")
            }
            guard frameDistance(actual, placement.frame) <= frameTolerance * 4 else {
                return WindowMismatch(placement: placement, actualFrame: actual, reason: "app did not accept the Snap zone")
            }
            return nil
        }
    }

    func mismatchesIncludingCollisions(
        placements: [WindowPlacement],
        frameMismatches: [WindowMismatch]
    ) -> [WindowMismatch] {
        var mismatches = frameMismatches
        let finalFrames = placements.map { frame(of: $0.window.element) }

        for firstIndex in placements.indices {
            guard let firstFrame = finalFrames[firstIndex] else { continue }
            for secondIndex in placements.indices where secondIndex > firstIndex {
                guard let secondFrame = finalFrames[secondIndex] else { continue }
                let overlap = firstFrame.intersection(secondFrame)
                guard !overlap.isNull, overlap.width > frameTolerance, overlap.height > frameTolerance else {
                    continue
                }
                for index in [firstIndex, secondIndex] {
                    let placement = placements[index]
                    let alreadyRecorded = mismatches.contains {
                        $0.placement.window.processIdentifier == placement.window.processIdentifier
                            && $0.placement.window.windowIndex == placement.window.windowIndex
                    }
                    if !alreadyRecorded {
                        mismatches.append(
                            WindowMismatch(
                                placement: placement,
                                actualFrame: finalFrames[index],
                                reason: "final bounds overlap another window"
                            )
                        )
                    }
                }
            }
        }
        return mismatches
    }

    func currentSpaceWindows() -> [OnScreenWindow] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return windowInfo.compactMap { item in
            guard let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let processIdentifier = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let frame = cgRect(from: item[kCGWindowBounds as String]),
                  frame.width > 0,
                  frame.height > 0 else {
                return nil
            }
            return OnScreenWindow(
                processIdentifier: processIdentifier,
                frame: frame,
                title: item[kCGWindowName as String] as? String
            )
        }
    }

    func matchingWindowIndex(frame: CGRect, title: String?, candidates: [OnScreenWindow]) -> Int? {
        let matches = candidates.enumerated().filter { _, candidate in
            abs(frame.minX - candidate.frame.minX) <= 12
                && abs(frame.minY - candidate.frame.minY) <= 12
                && abs(frame.width - candidate.frame.width) <= 24
                && abs(frame.height - candidate.frame.height) <= 24
        }
        guard !matches.isEmpty else { return nil }

        if let title, !title.isEmpty,
           let titleMatch = matches.first(where: { $0.element.title == title }) {
            return titleMatch.offset
        }
        return matches.min { lhs, rhs in
            frameDistance(frame, lhs.element.frame) < frameDistance(frame, rhs.element.frame)
        }?.offset
    }

    func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    func frame(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute as CFString, from: element),
              let size = sizeAttribute(kAXSizeAttribute as CFString, from: element) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> (error: AXError, value: CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        return (error, value)
    }

    func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        let result = copyAttribute(attribute, from: element)
        guard result.error == .success else { return nil }
        return result.value as? String
    }

    func boolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        let result = copyAttribute(attribute, from: element)
        guard result.error == .success else { return nil }
        return (result.value as? NSNumber)?.boolValue
    }

    func pointAttribute(_ attribute: CFString, from element: AXUIElement) -> CGPoint? {
        let result = copyAttribute(attribute, from: element)
        guard result.error == .success,
              let value = result.value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    func sizeAttribute(_ attribute: CFString, from element: AXUIElement) -> CGSize? {
        let result = copyAttribute(attribute, from: element)
        guard result.error == .success,
              let value = result.value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    func cgRect(from value: Any?) -> CGRect? {
        guard let dictionary = value as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
}
