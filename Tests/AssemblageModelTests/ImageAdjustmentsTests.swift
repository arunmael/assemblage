import XCTest
@testable import AssemblageModel

/// Deckt die Regler aus 5.5 ab (Helligkeit/Kontrast/Sättigung/Wärme/
/// Weichzeichnen/Schärfen) — insbesondere das Clamping, das verhindert,
/// dass ein schnell gezogener Regler einen ungültigen Wert speichert.
final class ImageAdjustmentsTests: XCTestCase {
    func testNeutralIsAllZero() {
        let neutral = ImageAdjustments.neutral
        XCTAssertEqual(neutral.brightness, 0)
        XCTAssertEqual(neutral.contrast, 0)
        XCTAssertEqual(neutral.saturation, 0)
        XCTAssertEqual(neutral.warmth, 0)
        XCTAssertEqual(neutral.blurRadius, 0)
        XCTAssertEqual(neutral.sharpenAmount, 0)
    }

    func testClampedRestrictsSignedRangesToMinusOneToOne() {
        let extreme = ImageAdjustments(brightness: 5, contrast: -5, saturation: 2, warmth: -2, blurRadius: 0, sharpenAmount: 0)
        let clamped = extreme.clamped()

        XCTAssertEqual(clamped.brightness, 1)
        XCTAssertEqual(clamped.contrast, -1)
        XCTAssertEqual(clamped.saturation, 1)
        XCTAssertEqual(clamped.warmth, -1)
    }

    func testClampedRestrictsUnsignedRangesToZeroToOne() {
        let extreme = ImageAdjustments(blurRadius: 3, sharpenAmount: -3)
        let clamped = extreme.clamped()

        XCTAssertEqual(clamped.blurRadius, 1)
        XCTAssertEqual(clamped.sharpenAmount, 0)
    }

    func testClampedLeavesValidValuesUnchanged() {
        let valid = ImageAdjustments(brightness: 0.3, contrast: -0.2, saturation: 0.1, warmth: -0.4, blurRadius: 0.6, sharpenAmount: 0.8)
        XCTAssertEqual(valid.clamped(), valid)
    }
}
