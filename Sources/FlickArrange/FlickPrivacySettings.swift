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
    var pauseMediaEnabled = true
    var focusActiveWindowEnabled = true

    mutating func normalize() {
        targetBrightness = min(max(targetBrightness, 0), 1)
        hiddenAppBundleIdentifiers = Array(Set(hiddenAppBundleIdentifiers)).sorted()
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
