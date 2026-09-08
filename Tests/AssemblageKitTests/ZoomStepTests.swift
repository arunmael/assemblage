import XCTest
@testable import AssemblageKit

/// Zoomen in festen 20-Prozent-Schritten (Nutzer-Auftrag).
final class ZoomStepTests: XCTestCase {

    private func hinein(_ von: CGFloat) -> CGFloat {
        CanvasViewController.steppedMagnification(from: von, up: true)
    }

    private func hinaus(_ von: CGFloat) -> CGFloat {
        CanvasViewController.steppedMagnification(from: von, up: false)
    }

    func testRundeStufenGehenUmGenauZwanzigProzentWeiter() {
        XCTAssertEqual(hinein(1.0), 1.2, accuracy: 0.0001)
        XCTAssertEqual(hinaus(1.0), 0.8, accuracy: 0.0001)
        XCTAssertEqual(hinein(0.2), 0.4, accuracy: 0.0001)
    }

    /// Ein per Pinch erreichter krummer Wert soll auf der nächsten runden
    /// Stufe landen, nicht krumm bleiben.
    func testKrummeWerteRastenAufDieNaechsteStufeEin() {
        XCTAssertEqual(hinein(0.82), 1.0, accuracy: 0.0001)
        XCTAssertEqual(hinaus(0.82), 0.8, accuracy: 0.0001)
        XCTAssertEqual(hinein(0.05), 0.2, accuracy: 0.0001)
    }

    /// Rundungsreste dürfen keinen Leerschritt erzeugen: Bei „fast genau 100 %"
    /// muss der nächste Druck nach 120 % führen, nicht wieder nach 100 %.
    func testFastGenaueStufeSpringtTrotzdemWeiter() {
        XCTAssertEqual(hinein(0.9999997), 1.2, accuracy: 0.0001)
        XCTAssertEqual(hinaus(1.0000003), 0.8, accuracy: 0.0001)
    }

    func testDieKleinsteStufeIstEineVolleStufe() {
        XCTAssertEqual(hinaus(0.2), 0.2, accuracy: 0.0001)
        XCTAssertEqual(hinaus(0.21), 0.2, accuracy: 0.0001)
    }

    func testDasMaximumWirdNichtUeberschritten() {
        XCTAssertEqual(CanvasViewController.steppedMagnification(from: 16, up: true, maximum: 16), 16)
    }
}
