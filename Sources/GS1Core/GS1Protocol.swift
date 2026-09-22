import Foundation

public enum GS1ProtocolError: Error, Equatable, Sendable {
    case invalidBluetoothAddress(String)
}

public struct GS1Reading: Equatable, Sendable, Identifiable {
    public var id: Int { index }

    public let index: Int
    public let temperatureTenths: Int
    public let electricalRaw: Int
    public let glucoseTenths: Int
    public let status: Int
    public let unreceivedCount: Int
    public let addTimeSeconds: Int

    public init(
        index: Int,
        temperatureTenths: Int,
        electricalRaw: Int,
        glucoseTenths: Int,
        status: Int,
        unreceivedCount: Int,
        addTimeSeconds: Int
    ) {
        self.index = index
        self.temperatureTenths = temperatureTenths
        self.electricalRaw = electricalRaw
        self.glucoseTenths = glucoseTenths
        self.status = status
        self.unreceivedCount = unreceivedCount
        self.addTimeSeconds = addTimeSeconds
    }

    public var sensorMmolPerLitre: Double { Double(glucoseTenths) / 10.0 }
    public var temperatureCelsius: Double { Double(temperatureTenths) / 10.0 }
    public var isPlausible: Bool { GS1Protocol.isPlausibleGlucose(sensorMmolPerLitre) }

    public func time(from now: Date) -> Date {
        let secondsFromNow = addTimeSeconds - unreceivedCount * 60
        let claimed = now.addingTimeInterval(TimeInterval(secondsFromNow))
        return min(claimed, now)
    }
}

/// Port of the public legacy SIBIONICS GS1 protocol implementation in Gluco Glance.
/// This represents the legacy/plain-text GS1 conversation, not GS3/newSI.
public enum GS1Protocol {
    public static let frameStartFirst: UInt8 = 0xAA
    public static let frameStartSecond: UInt8 = 0x55
    public static let commandAsk: UInt8 = 0x07
    public static let commandGlucose: UInt8 = 0x09
    public static let recordLength = 14
    public static let firstIndex = 1
    public static let sensorWearHours = 572
    public static let readingsPerPoint = 5
    public static let askZeroPadding = 8

    public static let authRequest: [UInt8] = [0x23, 0xF7, 0x6F, 0xD9, 0xF4]

    public static let roughCalibrationGapMmol = 3.0
    public static let temperatureDriftMmolPerC = 0.27
    public static let neutralTemperatureC = 33.0

    public static func daysLeft(at newestIndex: Int) -> Int {
        let minutesLeft = sensorWearHours * 60 - newestIndex
        guard minutesLeft > 0 else { return 0 }
        let minutesPerDay = 24 * 60
        return (minutesLeft + minutesPerDay - 1) / minutesPerDay
    }

    public static func isPlausibleGlucose(_ mmolPerLitre: Double) -> Bool {
        mmolPerLitre > 1.8 && mmolPerLitre < 30.0
    }

    public static func temperatureDrift(at temperatureCelsius: Double) -> Double {
        temperatureDriftMmolPerC * (temperatureCelsius - neutralTemperatureC)
    }

    public static func temperatureCorrectedMmol(
        rawMmolPerLitre: Double,
        temperatureCelsius: Double
    ) -> Double {
        rawMmolPerLitre - temperatureDrift(at: temperatureCelsius)
    }

    public static func checksum(for bytes: [UInt8], length: Int? = nil) -> UInt8 {
        let count = min(length ?? bytes.count, bytes.count)
        let sum = bytes.prefix(count).reduce(0) { ($0 + Int($1)) & 0xFF }
        return UInt8((256 - sum) & 0xFF)
    }

    public static func isChecksumValid(_ frame: [UInt8]) -> Bool {
        frame.reduce(0) { ($0 + Int($1)) & 0xFF } == 0
    }

    public static func addressBytesReversed(_ address: String) throws -> [UInt8] {
        let parts = address.split(separator: ":")
        guard parts.count == 6 else { throw GS1ProtocolError.invalidBluetoothAddress(address) }

        let bytes = try parts.map { part -> UInt8 in
            guard part.count == 2, let value = UInt8(part, radix: 16) else {
                throw GS1ProtocolError.invalidBluetoothAddress(address)
            }
            return value
        }
        return bytes.reversed()
    }

    /// Legacy GS1: AA 55 07 + little-endian index + reversed six-byte BLE address
    /// + eight zero bytes + additive checksum.
    public static func buildAskFrame(
        fromIndex: Int,
        address: String,
        zeroPadding: Int = askZeroPadding
    ) throws -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 3 + 2 + 6 + zeroPadding + 1)
        frame[0] = frameStartFirst
        frame[1] = frameStartSecond
        frame[2] = commandAsk
        frame[3] = UInt8(fromIndex & 0xFF)
        frame[4] = UInt8((fromIndex >> 8) & 0xFF)

        let reversedAddress = try addressBytesReversed(address)
        for (offset, byte) in reversedAddress.enumerated() {
            frame[5 + offset] = byte
        }
        frame[frame.count - 1] = checksum(for: frame, length: frame.count - 1)
        return frame
    }

    public static func isGlucoseFrame(_ frame: [UInt8]) -> Bool {
        frame.count >= 4 &&
        frame[0] == frameStartFirst &&
        frame[1] == frameStartSecond &&
        frame[2] == commandGlucose
    }

    public static func isAuthRequest(_ frame: [UInt8]) -> Bool {
        frame == authRequest
    }

    public static func parseGlucoseFrame(_ frame: [UInt8]) -> [GS1Reading]? {
        guard isGlucoseFrame(frame) else { return nil }
        let count = Int(frame[3])
        guard frame.count >= 4 + count * recordLength + 1 else { return nil }

        return (0..<count).map { reading(at: 4 + $0 * recordLength, in: frame) }
    }

    public static func takenAtByMinute(
        readings: [GS1Reading],
        now: Date
    ) -> [Int: Date] {
        guard let newest = readings.max(by: { $0.index < $1.index }) else { return [:] }
        let newestTakenAt = newest.time(from: now)

        return Dictionary(uniqueKeysWithValues: readings.map { reading in
            let minutesBehind = newest.index - reading.index
            return (reading.index, newestTakenAt.addingTimeInterval(TimeInterval(-minutesBehind * 60)))
        })
    }

    private static func reading(at offset: Int, in frame: [UInt8]) -> GS1Reading {
        func word(_ position: Int) -> Int {
            let at = offset + position * 2
            return (Int(frame[at]) << 8) | Int(frame[at + 1])
        }

        return GS1Reading(
            index: word(0),
            temperatureTenths: word(1),
            electricalRaw: word(2),
            glucoseTenths: word(3),
            status: word(4),
            unreceivedCount: word(5),
            addTimeSeconds: word(6)
        )
    }
}
