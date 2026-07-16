import SwiftUI

private enum LidGesture: String, CaseIterable, Identifiable {
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

struct FlickArrangeDashboardView: View {
    @ObservedObject var state: FlickArrangeAppState
    let toggleMonitoring: () -> Void
    let setCloseGestureEnabled: (Bool) -> Void
    let setOpenGestureEnabled: (Bool) -> Void
    let arrangeNow: () -> Void
    let previewLayout: () -> Void
    let openAccessibilitySettings: () -> Void
    @State private var selectedGesture: LidGesture? = .close

    var body: some View {
        NavigationStack {
            Group {
                switch selectedGesture {
                case .close:
                    CloseGestureDetailView(
                        state: state,
                        toggleMonitoring: toggleMonitoring,
                        setCloseGestureEnabled: setCloseGestureEnabled,
                        arrangeNow: arrangeNow,
                        previewLayout: previewLayout,
                        openAccessibilitySettings: openAccessibilitySettings
                    )
                case .open:
                    OpenGestureDetailView(
                        state: state,
                        toggleMonitoring: toggleMonitoring,
                        setOpenGestureEnabled: setOpenGestureEnabled,
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
                        ForEach(LidGesture.allCases) { gesture in
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
    @ObservedObject var state: FlickArrangeAppState
    let toggleMonitoring: () -> Void
    let setCloseGestureEnabled: (Bool) -> Void
    let arrangeNow: () -> Void
    let previewLayout: () -> Void
    let openAccessibilitySettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                gestureHeader
                detectionCard
                actionCard
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
        DashboardCard(title: "Assigned Action", systemImage: "bolt.circle") {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "rectangle.3.group")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Flick")
                        .font(.headline)
                    Text("Arrange non-minimized windows visible on the active screen and Space.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 10) {
                Button("Run Action Now", action: arrangeNow)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isArranging)
                Button("Preview Layout", action: previewLayout)
                    .disabled(state.isArranging)
                if state.isArranging {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 4)
                }
            }
            Text(state.lastArrangement)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct OpenGestureDetailView: View {
    @ObservedObject var state: FlickArrangeAppState
    let toggleMonitoring: () -> Void
    let setOpenGestureEnabled: (Bool) -> Void
    let openAccessibilitySettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                gestureHeader
                detectionCard
                actionCard
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
        DashboardCard(title: "Assigned Action", systemImage: "bolt.circle") {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text("No action assigned yet")
                        .font(.headline)
                    Text("Open is ready as an input gesture. Launcher, Recent Apps, and Recall remain outside this MVP for now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
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
    @ObservedObject var state: FlickArrangeAppState
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
    @ObservedObject var state: FlickArrangeAppState
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
