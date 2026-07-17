import Foundation

enum FlickGesture: String, CaseIterable, Identifiable {
    case close
    case open

    var id: String { rawValue }

    var title: String {
        switch self {
        case .close: return "Close"
        case .open: return "Open"
        }
    }

    var subtitle: String {
        switch self {
        case .close: return "Quick close, then reopen"
        case .open: return "Quick open, then close slightly"
        }
    }

    var symbol: String {
        switch self {
        case .close: return "arrow.down"
        case .open: return "arrow.up"
        }
    }
}

enum FlickAction: String, CaseIterable, Identifiable {
    case arrange
    case focus
    case hide
    case privacy
    case privacyCancel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrange: return "Flick Arrange"
        case .focus: return "Flick Focus"
        case .hide: return "Flick Hide"
        case .privacy: return "Flick Privacy"
        case .privacyCancel: return "Flick Privacy Cancel"
        }
    }

    var subtitle: String {
        switch self {
        case .arrange:
            return "Arrange visible windows on the active screen and Space."
        case .focus:
            return "Keep the active window visible and hide the rest."
        case .hide:
            return "Hide general app windows to reveal the Desktop."
        case .privacy:
            return "Protect privacy by dimming the display, muting audio, hiding sensitive apps, enabling work mode, pausing media, and focusing the active window."
        case .privacyCancel:
            return "Restore the most recent state saved before Flick Privacy ran."
        }
    }

    var symbol: String {
        switch self {
        case .arrange: return "rectangle.3.group"
        case .focus: return "viewfinder"
        case .hide: return "desktopcomputer"
        case .privacy: return "lock.shield"
        case .privacyCancel: return "arrow.uturn.backward.circle"
        }
    }
}

enum FlickActionAssignmentOrigin: String, Codable {
    case defaultValue
    case automatic
    case manual
}

struct FlickActionAssignments: Equatable {
    private(set) var closeAction: FlickAction
    private(set) var openAction: FlickAction
    private(set) var closeOrigin: FlickActionAssignmentOrigin
    private(set) var openOrigin: FlickActionAssignmentOrigin

    init(
        closeAction: FlickAction = .arrange,
        openAction: FlickAction = .focus,
        closeOrigin: FlickActionAssignmentOrigin = .defaultValue,
        openOrigin: FlickActionAssignmentOrigin = .defaultValue
    ) {
        self.closeAction = closeAction
        self.openAction = openAction
        self.closeOrigin = closeOrigin
        self.openOrigin = openOrigin
    }

    func action(for gesture: FlickGesture) -> FlickAction {
        gesture == .close ? closeAction : openAction
    }

    func origin(for gesture: FlickGesture) -> FlickActionAssignmentOrigin {
        gesture == .close ? closeOrigin : openOrigin
    }

    mutating func assignManually(_ action: FlickAction, to gesture: FlickGesture) {
        let previousAction = self.action(for: gesture)
        if previousAction == .privacy, action != .privacy {
            resetAutomaticCancel(for: counterpart(of: gesture))
        }

        set(action, origin: .manual, for: gesture)
        if action == .privacy {
            pairPrivacyCancel(with: gesture)
        }
    }

    mutating func reconcileAutomaticPrivacyCancel() {
        if closeAction == .privacy, openOrigin != .manual {
            set(.privacyCancel, origin: .automatic, for: .open)
        } else if openAction == .privacy, closeOrigin != .manual {
            set(.privacyCancel, origin: .automatic, for: .close)
        }
    }

    private mutating func pairPrivacyCancel(with gesture: FlickGesture) {
        let pairedGesture = counterpart(of: gesture)
        guard origin(for: pairedGesture) != .manual else { return }
        set(.privacyCancel, origin: .automatic, for: pairedGesture)
    }

    private mutating func resetAutomaticCancel(for gesture: FlickGesture) {
        guard origin(for: gesture) == .automatic,
              action(for: gesture) == .privacyCancel else {
            return
        }
        set(defaultAction(for: gesture), origin: .defaultValue, for: gesture)
    }

    private mutating func set(
        _ action: FlickAction,
        origin: FlickActionAssignmentOrigin,
        for gesture: FlickGesture
    ) {
        switch gesture {
        case .close:
            closeAction = action
            closeOrigin = origin
        case .open:
            openAction = action
            openOrigin = origin
        }
    }

    private func counterpart(of gesture: FlickGesture) -> FlickGesture {
        gesture == .close ? .open : .close
    }

    private func defaultAction(for gesture: FlickGesture) -> FlickAction {
        gesture == .close ? .arrange : .focus
    }
}

enum FlickActionAssignmentStore {
    static func load(from defaults: UserDefaults = .standard) -> FlickActionAssignments {
        var assignments = FlickActionAssignments(
            closeAction: savedAction(for: .close, fallback: .arrange, from: defaults),
            openAction: savedAction(for: .open, fallback: .focus, from: defaults),
            closeOrigin: savedOrigin(for: .close, from: defaults),
            openOrigin: savedOrigin(for: .open, from: defaults)
        )
        assignments.reconcileAutomaticPrivacyCancel()
        save(assignments, to: defaults)
        return assignments
    }

    static func save(_ assignments: FlickActionAssignments, to defaults: UserDefaults = .standard) {
        for gesture in FlickGesture.allCases {
            defaults.set(assignments.action(for: gesture).rawValue, forKey: actionKey(for: gesture))
            defaults.set(assignments.origin(for: gesture).rawValue, forKey: originKey(for: gesture))
        }
    }

    private static func savedAction(
        for gesture: FlickGesture,
        fallback: FlickAction,
        from defaults: UserDefaults
    ) -> FlickAction {
        guard let rawValue = defaults.string(forKey: actionKey(for: gesture)),
              let action = FlickAction(rawValue: rawValue) else {
            return fallback
        }
        return action
    }

    private static func savedOrigin(
        for gesture: FlickGesture,
        from defaults: UserDefaults
    ) -> FlickActionAssignmentOrigin {
        if let rawValue = defaults.string(forKey: originKey(for: gesture)),
           let origin = FlickActionAssignmentOrigin(rawValue: rawValue) {
            return origin
        }

        // Existing saved assignments predate origin tracking. Treat them as
        // manual so an upgrade never overwrites a user's previous choice.
        return defaults.object(forKey: actionKey(for: gesture)) == nil ? .defaultValue : .manual
    }

    private static func actionKey(for gesture: FlickGesture) -> String {
        "FlickActionAssignment.\(gesture.rawValue)"
    }

    private static func originKey(for gesture: FlickGesture) -> String {
        "FlickActionAssignment.\(gesture.rawValue).origin"
    }
}
