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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrange: return "Flick Arrange"
        case .focus: return "Flick Focus"
        case .hide: return "Flick Hide"
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
        }
    }

    var symbol: String {
        switch self {
        case .arrange: return "rectangle.3.group"
        case .focus: return "viewfinder"
        case .hide: return "desktopcomputer"
        }
    }
}
