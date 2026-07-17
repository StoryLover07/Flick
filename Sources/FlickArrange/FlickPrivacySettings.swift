import AppKit
import Foundation

struct FlickPrivacySettings: Codable, Equatable {
    var dimDisplayEnabled = true
    var targetBrightness = 0.30
    var muteVolumeEnabled = true
    var hidePrivacyAppsEnabled = true
    var hiddenAppBundleIdentifiers = FlickPrivacyApplicationCatalog.defaultBundleIdentifiers
    var workModeEnabled = false
    var workModeShortcutName = ""
    var workModeCancelShortcutName = ""
    var pauseMediaEnabled = true
    var focusActiveWindowEnabled = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dimDisplayEnabled = try container.decodeIfPresent(Bool.self, forKey: .dimDisplayEnabled) ?? true
        targetBrightness = try container.decodeIfPresent(Double.self, forKey: .targetBrightness) ?? 0.30
        muteVolumeEnabled = try container.decodeIfPresent(Bool.self, forKey: .muteVolumeEnabled) ?? true
        hidePrivacyAppsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hidePrivacyAppsEnabled) ?? true
        hiddenAppBundleIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .hiddenAppBundleIdentifiers
        ) ?? FlickPrivacyApplicationCatalog.defaultBundleIdentifiers
        workModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .workModeEnabled) ?? false
        workModeShortcutName = try container.decodeIfPresent(String.self, forKey: .workModeShortcutName) ?? ""
        workModeCancelShortcutName = try container.decodeIfPresent(
            String.self,
            forKey: .workModeCancelShortcutName
        ) ?? ""
        pauseMediaEnabled = try container.decodeIfPresent(Bool.self, forKey: .pauseMediaEnabled) ?? true
        focusActiveWindowEnabled = try container.decodeIfPresent(Bool.self, forKey: .focusActiveWindowEnabled) ?? true
        normalize()
    }

    mutating func normalize() {
        targetBrightness = min(max(targetBrightness, 0), 1)
        hiddenAppBundleIdentifiers = Array(Set(hiddenAppBundleIdentifiers)).sorted()
    }
}

enum FlickPrivacyFocusState: String, Codable {
    case notCaptured
    case unavailable
}

struct FlickPrivacyActiveContext: Codable, Equatable {
    let bundleIdentifier: String
    let processIdentifier: Int32
    let focusedWindowTitle: String?
}

struct FlickPrivacySnapshot: Codable, Equatable {
    let capturedAt: Date
    var brightnessBefore: Double?
    var outputVolumeBefore: Int?
    var focusStateBefore: FlickPrivacyFocusState
    var workModeRestoreShortcutName: String
    var hiddenApplicationBundleIdentifiers: [String]
    var activeContext: FlickPrivacyActiveContext?
    var changedBrightness: Bool
    var changedVolume: Bool
    var changedWorkMode: Bool
    var changedActiveContext: Bool

    init(
        capturedAt: Date = Date(),
        focusStateBefore: FlickPrivacyFocusState = .notCaptured,
        workModeRestoreShortcutName: String = ""
    ) {
        self.capturedAt = capturedAt
        brightnessBefore = nil
        outputVolumeBefore = nil
        self.focusStateBefore = focusStateBefore
        self.workModeRestoreShortcutName = workModeRestoreShortcutName
        hiddenApplicationBundleIdentifiers = []
        activeContext = nil
        changedBrightness = false
        changedVolume = false
        changedWorkMode = false
        changedActiveContext = false
    }
}

struct PrivacyApplicationOption: Identifiable, Hashable {
    let bundleIdentifier: String
    let displayName: String

    var id: String { bundleIdentifier }
}

enum FlickPrivacyApplicationCatalog {
    static let defaultApplications: [PrivacyApplicationOption] = [
        PrivacyApplicationOption(bundleIdentifier: "com.kakao.KakaoTalkMac", displayName: "KakaoTalk"),
        PrivacyApplicationOption(bundleIdentifier: "com.apple.MobileSMS", displayName: "Messages"),
        PrivacyApplicationOption(bundleIdentifier: "com.apple.mail", displayName: "Mail"),
        PrivacyApplicationOption(bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack"),
        PrivacyApplicationOption(bundleIdentifier: "com.hnc.Discord", displayName: "Discord"),
        PrivacyApplicationOption(bundleIdentifier: "ru.keepcoder.Telegram", displayName: "Telegram"),
        PrivacyApplicationOption(bundleIdentifier: "net.whatsapp.WhatsApp", displayName: "WhatsApp"),
        PrivacyApplicationOption(bundleIdentifier: "com.facebook.archon", displayName: "Messenger")
    ]

    static let defaultBundleIdentifiers = defaultApplications.map(\PrivacyApplicationOption.bundleIdentifier)

    static func displayName(for bundleIdentifier: String) -> String {
        if let known = defaultApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return known.displayName
        }
        if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return FileManager.default.displayName(atPath: applicationURL.path)
        }
        return bundleIdentifier
    }

    @MainActor
    static func runningApplications() -> [PrivacyApplicationOption] {
        var applicationsByBundleIdentifier: [String: PrivacyApplicationOption] = [:]

        for application in NSWorkspace.shared.runningApplications {
            guard application.activationPolicy == .regular,
                  application.processIdentifier != getpid(),
                  !application.isTerminated,
                  let bundleIdentifier = application.bundleIdentifier else {
                continue
            }
            let displayName = application.localizedName ?? displayName(for: bundleIdentifier)
            applicationsByBundleIdentifier[bundleIdentifier] = PrivacyApplicationOption(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName
            )
        }

        return applicationsByBundleIdentifier.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

enum FlickPrivacySettingsStore {
    private static let key = "FlickPrivacy.Settings.v1"

    static func load(from defaults: UserDefaults = .standard) -> FlickPrivacySettings {
        guard let data = defaults.data(forKey: key),
              var settings = try? JSONDecoder().decode(FlickPrivacySettings.self, from: data) else {
            return FlickPrivacySettings()
        }
        settings.normalize()
        return settings
    }

    static func save(_ settings: FlickPrivacySettings, to defaults: UserDefaults = .standard) {
        var normalizedSettings = settings
        normalizedSettings.normalize()
        guard let data = try? JSONEncoder().encode(normalizedSettings) else { return }
        defaults.set(data, forKey: key)
    }
}

enum FlickPrivacySnapshotStore {
    private static let key = "FlickPrivacy.RestoreSnapshot.v1"

    static func load(from defaults: UserDefaults = .standard) -> FlickPrivacySnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FlickPrivacySnapshot.self, from: data)
    }

    static func save(_ snapshot: FlickPrivacySnapshot, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
