import XCTest
@testable import GS1Core

final class GS1ProtocolTests: XCTestCase {
    func testAskFrameMatchesLegacyLayout() throws {
        let frame = try GS1Protocol.buildAskFrame(
            fromIndex: 1,
            address: "AA:BB:CC:DD:EE:FF"
        )

        XCTAssertEqual(frame, [
            0xAA, 0x55, 0x07, 0x01, 0x00,
            0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xFE
        ])
        XCTAssertTrue(GS1Protocol.isChecksumValid(frame))
    }

    func testParsesOneGlucoseRecordAsBigEndianWords() {
        var frame: [UInt8] = [0xAA, 0x55, 0x09, 0x01]
        // index=258, temp=331 (33.1C), electrical=1000,
        // glucoseTenths=72 (7.2 mmol/L sensor figure), status=0,
        // unreceived=2, addTimeSeconds=30
        frame += [
            0x01, 0x02,
            0x01, 0x4B,
            0x03, 0xE8,
            0x00, 0x48,
            0x00, 0x00,
            0x00, 0x02,
            0x00, 0x1E
        ]
        frame.append(GS1Protocol.checksum(for: frame))

        XCTAssertTrue(GS1Protocol.isChecksumValid(frame))
        let readings = GS1Protocol.parseGlucoseFrame(frame)
        XCTAssertEqual(readings?.count, 1)
        XCTAssertEqual(readings?.first?.index, 258)
        XCTAssertEqual(readings?.first?.temperatureTenths, 331)
        XCTAssertEqual(readings?.first?.electricalRaw, 1000)
        XCTAssertEqual(readings?.first?.glucoseTenths, 72)
        XCTAssertEqual(readings?.first?.sensorMmolPerLitre, 7.2)
    }

    func testTemperatureCorrection() {
        XCTAssertEqual(
            GS1Protocol.temperatureCorrectedMmol(rawMmolPerLitre: 10.0, temperatureCelsius: 35.0),
            9.46,
            accuracy: 0.000_001
        )
    }

    func testInvalidMacIsRejected() {
        XCTAssertThrowsError(
            try GS1Protocol.buildAskFrame(fromIndex: 1, address: "NOT-A-MAC")
        )
    }
}
