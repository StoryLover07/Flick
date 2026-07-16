import Foundation

enum CloseGestureParameters {
    static let sampleInterval = 0.05
    static let bufferWindow = 1.2
    static let minDropDegrees = 20.0
    static let minEarlyRecoverDegrees = 6.0
    static let minDropSpeedDegPerSec = 60.0
    static let minRecoverSpeedDegPerSec = 40.0
    static let maxEarlyTriggerDuration = 0.8
    static let cooldownSeconds = 1.5
}

struct LidSample {
    let timestamp: TimeInterval
    let angle: Double
}

final class CloseGestureDetector {
    private var samples: [LidSample] = []
    private var lastDetectionTime: TimeInterval = 0

    func addSample(timestamp: TimeInterval, angle: Double) -> Bool {
        samples.append(LidSample(timestamp: timestamp, angle: angle))
        trimOldSamples(now: timestamp)

        if timestamp - lastDetectionTime < CloseGestureParameters.cooldownSeconds {
            return false
        }

        if matchesCloseGesture() {
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
        let cutoff = now - CloseGestureParameters.bufferWindow
        samples.removeAll { $0.timestamp < cutoff }
    }

    // Early trigger: detect the reversal as soon as reopening is clear.
    // The lid never needs to return to its original open angle.
    private func matchesCloseGesture() -> Bool {
        guard samples.count >= 3 else { return false }

        for minIndex in 1..<(samples.count - 1) {
            let minimum = samples[minIndex]
            let before = samples[..<minIndex]
            let after = samples[(minIndex + 1)...]

            guard let start = before.max(by: { $0.angle < $1.angle }),
                  let recovery = after.max(by: { $0.angle < $1.angle }) else {
                continue
            }

            guard start.timestamp < minimum.timestamp,
                  recovery.timestamp > minimum.timestamp else {
                continue
            }

            let duration = recovery.timestamp - start.timestamp
            guard duration > 0,
                  duration <= CloseGestureParameters.maxEarlyTriggerDuration else {
                continue
            }

            let drop = start.angle - minimum.angle
            let recoveryGain = recovery.angle - minimum.angle
            guard drop >= CloseGestureParameters.minDropDegrees,
                  recoveryGain >= CloseGestureParameters.minEarlyRecoverDegrees else {
                continue
            }

            let dropDuration = minimum.timestamp - start.timestamp
            let recoveryDuration = recovery.timestamp - minimum.timestamp
            guard dropDuration > 0, recoveryDuration > 0 else {
                continue
            }

            let dropSpeed = drop / dropDuration
            let recoverySpeed = recoveryGain / recoveryDuration
            guard dropSpeed >= CloseGestureParameters.minDropSpeedDegPerSec,
                  recoverySpeed >= CloseGestureParameters.minRecoverSpeedDegPerSec else {
                continue
            }

            guard isLocalMinimum(index: minIndex) else {
                continue
            }

            return true
        }

        return false
    }

    private func isLocalMinimum(index: Int) -> Bool {
        let minimum = samples[index]
        let leftStart = max(0, index - 2)
        let rightEnd = min(samples.count - 1, index + 2)
        let left = samples[leftStart..<index]
        let right = samples[(index + 1)...rightEnd]
        guard !left.isEmpty, !right.isEmpty else { return false }

        return (left + right).allSatisfy { minimum.angle <= $0.angle }
    }
}
