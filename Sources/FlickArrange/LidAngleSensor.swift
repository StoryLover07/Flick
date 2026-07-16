import Foundation
import IOKit.hid

enum LidAngleSensorError: Error, CustomStringConvertible {
    case sensorNotFound
    case openFailed(IOReturn)
    case readFailed(IOReturn)

    var description: String {
        switch self {
        case .sensorNotFound:
            return "MacBook lid angle sensor was not found."
        case .openFailed(let code):
            return "Could not open lid angle sensor. IOReturn=\(code)"
        case .readFailed(let code):
            return "Could not read lid angle feature report. IOReturn=\(code)"
        }
    }
}

final class LidAngleSensor {
    private let manager: IOHIDManager
    private var device: IOHIDDevice?

    private let vendorID = 0x05AC
    private let productID = 0x8104
    private let usagePage = 0x0020
    private let usage = 0x008A
    private let featureReportID: CFIndex = 1

    init() throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching: [String: Any] = [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID,
            kIOHIDPrimaryUsagePageKey: usagePage,
            kIOHIDPrimaryUsageKey: usage
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw LidAngleSensorError.openFailed(openResult)
        }

        guard
            let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
            let firstDevice = devices.first
        else {
            throw LidAngleSensorError.sensorNotFound
        }

        device = firstDevice
        _ = try readAngleOrThrow()
    }

    func disconnect() {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        device = nil
    }

    func readAngle() -> Double? {
        try? readAngleOrThrow()
    }

    private func readAngleOrThrow() throws -> Double {
        guard let device else {
            throw LidAngleSensorError.sensorNotFound
        }

        var report = [UInt8](repeating: 0, count: 8)
        var reportLength = report.count
        let result = report.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                featureReportID,
                buffer.baseAddress!,
                &reportLength
            )
        }

        guard result == kIOReturnSuccess else {
            throw LidAngleSensorError.readFailed(result)
        }
        guard reportLength >= 3 else {
            throw LidAngleSensorError.readFailed(kIOReturnUnderrun)
        }

        let rawAngle = UInt16(report[1]) | (UInt16(report[2]) << 8)
        return Double(rawAngle)
    }
}
