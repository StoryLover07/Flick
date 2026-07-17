import SwiftUI

struct FlickDashboardView: View {
    @ObservedObject var state: FlickAppState
    let toggleMonitoring: () -> Void
    let setCloseGestureEnabled: (Bool) -> Void
    let setOpenGestureEnabled: (Bool) -> Void
    let setAction: (FlickGesture, FlickAction) -> Void
    let runAction: (FlickGesture) -> Void
    let previewLayout: () -> Void
    let openAccessibilitySettings: () -> Void
    @State private var selectedGesture: FlickGesture? = .close

    var body: some View {
        NavigationStack {
            Group {
                switch selectedGesture {
                case .close:
                    CloseGestureDetailView(
                        state: state,
                        toggleMonitoring: toggleMonitoring,
                        setCloseGestureEnabled: setCloseGestureEnabled,
                        setAction: { setAction(.close, $0) },
                        runAction: { runAction(.close) },
                        previewLayout: previewLayout,
                        openAccessibilitySettings: openAccessibilitySettings
                    )
                case .open:
                    OpenGestureDetailView(
                        state: state,
                        toggleMonitoring: toggleMonitoring,
                        setOpenGestureEnabled: setOpenGestureEnabled,
                        setAction: { setAction(.open, $0) },
                        runAction: { runAction(.open) },
                        previewLayout: previewLayout,
                        openAccessibilitySettings: openAccessibilitySettings
                    )
                case .none:
                    VStack(spacing: 10) {
                        Image(systemName: "hand.draw")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Choose a Gesture")
                            .font(.title3.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Lid gesture", selection: $selectedGesture) {
                        ForEach(FlickGesture.allCases) { gesture in
                            Label {
                                Text(gesture.title)
                            } icon: {
                                Image(systemName: gesture.symbol)
                            }
                            .tag(Optional(gesture))
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }

                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 10) {
                        GestureStatus(label: "Close", isEnabled: state.isCloseGestureEnabled)
                        GestureStatus(label: "Open", isEnabled: state.isOpenGestureEnabled)
                    }
                }
            }
        }
        .navigationTitle("Flick")
        .frame(minWidth: 760, minHeight: 560)
    }
}

private struct GestureStatus: View {
    let label: String
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isEnabled ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) gesture \(isEnabled ? "enabled" : "disabled")")
    }
}

private struct CloseGestureDetailView: View {
    @ObservedObject var state: FlickAppState
    let toggleMonitoring: () -> Void
    let setCloseGestureEnabled: (Bool) -> Void
    let setAction: (FlickAction) -> Void
    let runAction: () -> Void
    let previewLayout: () -> Void
    let openAccessibilitySettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                gestureHeader
                detectionCard
                actionCard
                if state.closeAction == .privacy {
                    FlickPrivacySettingsCard(state: state)
                }
                LiveSensorCard(state: state, toggleMonitoring: toggleMonitoring)
                RecentActivityCard(state: state, openAccessibilitySettings: openAccessibilitySettings)
            }
            .padding(28)
        }
        .navigationTitle("Close")
    }

    private var gestureHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            GestureIcon(symbol: "arrow.down")
            VStack(alignment: .leading, spacing: 5) {
                Text("Close")
                    .font(.largeTitle.weight(.bold))
                Text("A fast partial lid close followed by an early reopen.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("This gesture is evaluated from motion direction, speed, and timing. It does not use a fixed lid-angle trigger.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("Enabled", isOn: Binding(
                get: { state.isCloseGestureEnabled },
                set: setCloseGestureEnabled
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Enable Close gesture")
        }
    }

    private var detectionCard: some View {
        DashboardCard(title: "Gesture Motion", systemImage: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 0) {
                    MotionStep(title: "Open", detail: "Ready", symbol: "arrow.up")
                    MotionConnector(label: "Fast close")
                    MotionStep(title: "Close", detail: "Local low point", symbol: "arrow.down")
                    MotionConnector(label: "Early reopen")
                    MotionStep(title: "Recover", detail: "Trigger", symbol: "bolt.fill", isAccent: true)
                }
                Text("Close triggers as soon as a quick drop, local minimum, and early recovery are clear. It does not wait for the lid to return fully open.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionCard: some View {
        ActionAssignmentCard(
            state: state,
            gesture: .close,
            action: state.closeAction,
            setAction: setAction,
            runAction: runAction,
            previewLayout: previewLayout
        )
    }
}

private struct OpenGestureDetailView: View {
    @ObservedObject var state: FlickAppState
    let toggleMonitoring: () -> Void
    let setOpenGestureEnabled: (Bool) -> Void
    let setAction: (FlickAction) -> Void
    let runAction: () -> Void
    let previewLayout: () -> Void
    let openAccessibilitySettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                gestureHeader
                detectionCard
                actionCard
                if state.openAction == .privacy {
                    FlickPrivacySettingsCard(state: state)
                }
                LiveSensorCard(state: state, toggleMonitoring: toggleMonitoring)
                RecentActivityCard(state: state, openAccessibilitySettings: openAccessibilitySettings)
            }
            .padding(28)
        }
        .navigationTitle("Open")
    }

    private var gestureHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            GestureIcon(symbol: "arrow.up")
            VStack(alignment: .leading, spacing: 5) {
                Text("Open")
                    .font(.largeTitle.weight(.bold))
                Text("A fast partial lid open followed by an early close.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("This gesture is evaluated from motion direction, speed, and timing. It does not use a fixed lid-angle trigger.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("Enabled", isOn: Binding(
                get: { state.isOpenGestureEnabled },
                set: setOpenGestureEnabled
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Enable Open gesture")
        }
    }

    private var detectionCard: some View {
        DashboardCard(title: "Gesture Motion", systemImage: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 0) {
                    MotionStep(title: "Closed", detail: "Ready", symbol: "arrow.down")
                    MotionConnector(label: "Fast open")
                    MotionStep(title: "Open", detail: "Local high point", symbol: "arrow.up")
                    MotionConnector(label: "Early close")
                    MotionStep(title: "Recover", detail: "Trigger", symbol: "bolt.fill", isAccent: true)
                }
                Text("Open triggers as soon as a quick rise, local maximum, and early recovery are clear. It does not wait for the lid to return fully closed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionCard: some View {
        ActionAssignmentCard(
            state: state,
            gesture: .open,
            action: state.openAction,
            setAction: setAction,
            runAction: runAction,
            previewLayout: previewLayout
        )
    }
}

private struct ActionAssignmentCard: View {
    @ObservedObject var state: FlickAppState
    let gesture: FlickGesture
    let action: FlickAction
    let setAction: (FlickAction) -> Void
    let runAction: () -> Void
    let previewLayout: () -> Void

    private var pairedGesture: FlickGesture {
        gesture == .close ? .open : .close
    }

    var body: some View {
        DashboardCard(title: "Assigned Action", systemImage: "bolt.circle") {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: action.symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(action.title)
                        .font(.headline)
                    Text(action.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("Action", selection: Binding(
                    get: { action },
                    set: setAction
                )) {
                    ForEach(FlickAction.allCases) { candidate in
                        Label(candidate.title, systemImage: candidate.symbol)
                            .tag(candidate)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Assigned Flick action")
            }

            if action == .privacyCancel,
               state.assignmentOrigin(for: gesture) == .automatic {
                Label(
                    "Automatically paired with Flick Privacy on \(pairedGesture.title). You can choose another action at any time.",
                    systemImage: "link"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 10) {
                Button("Run \(action.title)", action: runAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isArranging)
                if action == .arrange {
                    Button("Preview Layout", action: previewLayout)
                        .disabled(state.isArranging)
                }
                if state.isArranging {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 4)
                }
            }
            Text(state.lastActionStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FlickPrivacySettingsCard: View {
    @ObservedObject var state: FlickAppState
    @State private var appPicker: PrivacyAppPickerPresentation?

    var body: some View {
        DashboardCard(title: "Flick Privacy Settings", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: 16) {
                brightnessSection
                Divider()
                simpleToggle(
                    title: "Mute volume",
                    detail: "Set the system output volume to 0%.",
                    symbol: "speaker.slash",
                    keyPath: \.muteVolumeEnabled
                )
                Divider()
                privacyApplicationsSection
                Divider()
                workModeSection
                Divider()
                simpleToggle(
                    title: "Pause media",
                    detail: "Send a pause command to the current system media session. Some apps may ignore it.",
                    symbol: "pause.circle",
                    keyPath: \.pauseMediaEnabled
                )
                Divider()
                simpleToggle(
                    title: "Focus active window",
                    detail: "Reuse Flick Focus to keep the active window and hide other general app windows.",
                    symbol: "viewfinder",
                    keyPath: \.focusActiveWindowEnabled
                )
            }
        }
        .sheet(item: $appPicker) { presentation in
            PrivacyApplicationPicker(
                applications: presentation.applications,
                addApplication: addPrivacyApplication
            )
        }
    }

    private var brightnessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrivacySettingHeader(
                title: "Dim built-in display",
                detail: "Use an absolute brightness level on the full 0-100% scale.",
                symbol: "sun.min",
                isOn: boolBinding(\.dimDisplayEnabled)
            )
            if state.privacySettings.dimDisplayEnabled {
                HStack(spacing: 12) {
                    Slider(value: brightnessBinding, in: 0...1, step: 0.05)
                    Text("\(Int((state.privacySettings.targetBrightness * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                Text("Built-in MacBook display first. External displays and unsupported macOS versions may reject this step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var privacyApplicationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrivacySettingHeader(
                title: "Hide messenger and mail apps",
                detail: "Hide selected apps by bundle identifier. No semantic app classification is used.",
                symbol: "eye.slash",
                isOn: boolBinding(\.hidePrivacyAppsEnabled)
            )
            if state.privacySettings.hidePrivacyAppsEnabled {
                VStack(spacing: 0) {
                    ForEach(state.privacySettings.hiddenAppBundleIdentifiers, id: \.self) { bundleIdentifier in
                        HStack(spacing: 10) {
                            Image(systemName: "app")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(FlickPrivacyApplicationCatalog.displayName(for: bundleIdentifier))
                                    .font(.subheadline.weight(.medium))
                                Text(bundleIdentifier)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if FlickPrivacyApplicationCatalog.defaultBundleIdentifiers.contains(bundleIdentifier) {
                                Text("Default")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                removePrivacyApplication(bundleIdentifier)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove from Flick Privacy")
                        }
                        .padding(.vertical, 7)
                        if bundleIdentifier != state.privacySettings.hiddenAppBundleIdentifiers.last {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                HStack {
                    Button {
                        let selected = Set(state.privacySettings.hiddenAppBundleIdentifiers)
                        let applications = FlickPrivacyApplicationCatalog.runningApplications().filter {
                            !selected.contains($0.bundleIdentifier)
                        }
                        appPicker = PrivacyAppPickerPresentation(applications: applications)
                    } label: {
                        Label("Add Running App...", systemImage: "plus")
                    }
                    Button("Restore Default List") {
                        state.updatePrivacySettings {
                            $0.hiddenAppBundleIdentifiers = FlickPrivacyApplicationCatalog.defaultBundleIdentifiers
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var workModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrivacySettingHeader(
                title: "Enable work mode",
                detail: "Run a macOS Shortcut that enables the Focus mode you choose.",
                symbol: "briefcase",
                isOn: boolBinding(\.workModeEnabled)
            )
            if state.privacySettings.workModeEnabled {
                LabeledContent("Enable Shortcut") {
                    TextField("Shortcut name", text: workModeShortcutBinding)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Restore Shortcut") {
                    TextField("Optional cancel Shortcut", text: workModeCancelShortcutBinding)
                        .textFieldStyle(.roundedBorder)
                }
                Text("The restore Shortcut should return Focus to the state you want after Flick Privacy Cancel. Leave it blank to skip this restore step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Work mode depends on a Shortcut you create in the Shortcuts app. Focus control has no stable public macOS API, so this step may require system approval or may not run on every setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func simpleToggle(
        title: String,
        detail: String,
        symbol: String,
        keyPath: WritableKeyPath<FlickPrivacySettings, Bool>
    ) -> some View {
        PrivacySettingHeader(
            title: title,
            detail: detail,
            symbol: symbol,
            isOn: boolBinding(keyPath)
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<FlickPrivacySettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { state.privacySettings[keyPath: keyPath] },
            set: { newValue in
                state.updatePrivacySettings { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { state.privacySettings.targetBrightness },
            set: { newValue in
                state.updatePrivacySettings { $0.targetBrightness = newValue }
            }
        )
    }

    private var workModeShortcutBinding: Binding<String> {
        Binding(
            get: { state.privacySettings.workModeShortcutName },
            set: { newValue in
                state.updatePrivacySettings { $0.workModeShortcutName = newValue }
            }
        )
    }

    private var workModeCancelShortcutBinding: Binding<String> {
        Binding(
            get: { state.privacySettings.workModeCancelShortcutName },
            set: { newValue in
                state.updatePrivacySettings { $0.workModeCancelShortcutName = newValue }
            }
        )
    }

    private func addPrivacyApplication(_ application: PrivacyApplicationOption) {
        state.updatePrivacySettings { settings in
            settings.hiddenAppBundleIdentifiers.append(application.bundleIdentifier)
        }
    }

    private func removePrivacyApplication(_ bundleIdentifier: String) {
        state.updatePrivacySettings { settings in
            settings.hiddenAppBundleIdentifiers.removeAll { $0 == bundleIdentifier }
        }
    }
}

private struct PrivacySettingHeader: View {
    let title: String
    let detail: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

private struct PrivacyAppPickerPresentation: Identifiable {
    let id = UUID()
    let applications: [PrivacyApplicationOption]
}

private struct PrivacyApplicationPicker: View {
    @Environment(\.dismiss) private var dismiss
    let applications: [PrivacyApplicationOption]
    let addApplication: (PrivacyApplicationOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Running App")
                .font(.title2.weight(.semibold))
            Text("Choose a currently running general app to hide when Flick Privacy runs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if applications.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "app.dashed")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Apps Available")
                        .font(.headline)
                    Text("All running general apps are already in the Privacy list.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(applications) { application in
                    Button {
                        addApplication(application)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "app")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(application.displayName)
                                Text(application.bundleIdentifier)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.tint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 420)
    }
}

private struct GestureIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: 54, height: 54)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct LiveSensorCard: View {
    @ObservedObject var state: FlickAppState
    let toggleMonitoring: () -> Void

    var body: some View {
        DashboardCard(title: "Live Sensor", systemImage: "sensor") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.isMonitoring ? "Monitoring is active" : state.sensorStatus)
                        .font(.headline)
                    Text(state.lastDetection)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let angle = state.latestAngle {
                    Text(String(format: "%.0f deg", angle))
                        .font(.system(.title, design: .rounded).weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Current lid angle \(Int(angle)) degrees")
                }
                Button(state.isMonitoring ? "Stop" : "Start", action: toggleMonitoring)
                    .controlSize(.small)
            }
        }
    }
}

private struct RecentActivityCard: View {
    @ObservedObject var state: FlickAppState
    let openAccessibilitySettings: () -> Void

    var body: some View {
        DashboardCard(title: "Recent Activity", systemImage: "clock") {
            VStack(alignment: .leading, spacing: 10) {
                if state.activity.isEmpty {
                    Text("Activity will appear here while Flick is running.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.activity) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: icon(for: entry.kind))
                                .foregroundStyle(color(for: entry.kind))
                                .frame(width: 14)
                                .accessibilityHidden(true)
                            Text(entry.message)
                                .font(.subheadline)
                            Spacer(minLength: 8)
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Divider()

                HStack {
                    if state.isAccessibilityTrusted {
                        Label("Accessibility permission is ready.", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text("Window control needs Accessibility permission.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !state.isAccessibilityTrusted {
                        Button("Open Settings", action: openAccessibilitySettings)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func icon(for kind: ActivityLogEntry.Kind) -> String {
        switch kind {
        case .info: return "info.circle"
        case .gesture: return "bolt.fill"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for kind: ActivityLogEntry.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .gesture: return .orange
        case .success: return .green
        case .failure: return .red
        }
    }
}

private struct MotionStep: View {
    let title: String
    let detail: String
    let symbol: String
    var isAccent = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(isAccent ? Color.white : Color.accentColor)
                .frame(width: 38, height: 38)
                .background(isAccent ? Color.accentColor : Color.accentColor.opacity(0.13), in: Circle())
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 82)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MotionConnector: View {
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 110)
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
