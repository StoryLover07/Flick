import Foundation

enum OpenGestureParameters {
    // These mirror Close so both gestures have a similarly intentional feel.
    static let bufferWindow = 1.2
    static let minRiseDegrees = 20.0
    static let minEarlyRecoverDegrees = 6.0
    static let minRiseSpeedDegPerSec = 60.0
    static let minRecoverSpeedDegPerSec = 40.0
    static let maxEarlyTriggerDuration = 0.8
    static let cooldownSeconds = 1.5
}

final class OpenGestureDetector {
    private var samples: [LidSample] = []
    private var lastDetectionTime: TimeInterval = 0

    func addSample(timestamp: TimeInterval, angle: Double) -> Bool {
        samples.append(LidSample(timestamp: timestamp, angle: angle))
        trimOldSamples(now: timestamp)

        if timestamp - lastDetectionTime < OpenGestureParameters.cooldownSeconds {
            return false
        }

        if matchesOpenGesture() {
            lastDetectionTime = timestamp
            return true
        }
        return false
    }

    func reset() {
        samples.removeAll()
        lastDetectionTime = 0
    }

    private func trimOldSamples(now: TimeInterval) {
        let cutoff = now - OpenGestureParameters.bufferWindow
        samples.removeAll { $0.timestamp < cutoff }
    }

    // Early trigger: detect a fast opening motion, its local peak, and the
    // first clear closing movement. No absolute lid angle is used.
    private func matchesOpenGesture() -> Bool {
        guard samples.count >= 3 else { return false }

        for maximumIndex in 1..<(samples.count - 1) {
            let maximum = samples[maximumIndex]
            let before = samples[..<maximumIndex]
            let after = samples[(maximumIndex + 1)...]

            guard let start = before.min(by: { $0.angle < $1.angle }),
                  let recovery = after.min(by: { $0.angle < $1.angle }) else {
                continue
            }

            let duration = recovery.timestamp - start.timestamp
            guard duration > 0,
                  duration <= OpenGestureParameters.maxEarlyTriggerDuration else {
                continue
            }

            let rise = maximum.angle - start.angle
            let recoveryDrop = maximum.angle - recovery.angle
            guard rise >= OpenGestureParameters.minRiseDegrees,
                  recoveryDrop >= OpenGestureParameters.minEarlyRecoverDegrees else {
                continue
            }

            let riseDuration = maximum.timestamp - start.timestamp
            let recoveryDuration = recovery.timestamp - maximum.timestamp
            guard riseDuration > 0, recoveryDuration > 0 else { continue }

            let riseSpeed = rise / riseDuration
            let recoverySpeed = recoveryDrop / recoveryDuration
            guard riseSpeed >= OpenGestureParameters.minRiseSpeedDegPerSec,
                  recoverySpeed >= OpenGestureParameters.minRecoverSpeedDegPerSec else {
                continue
            }

            guard isLocalMaximum(index: maximumIndex) else { continue }
            return true
        }

        return false
    }

    private func isLocalMaximum(index: Int) -> Bool {
        let maximum = samples[index]
        let leftStart = max(0, index - 2)
        let rightEnd = min(samples.count - 1, index + 2)
        let left = samples[leftStart..<index]
        let right = samples[(index + 1)...rightEnd]
        guard !left.isEmpty, !right.isEmpty else { return false }

        return (left + right).allSatisfy { maximum.angle >= $0.angle }
    }
}
