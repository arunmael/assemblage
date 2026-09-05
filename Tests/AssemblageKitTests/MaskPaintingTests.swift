import XCTest
import AppKit
import CoreGraphics
@testable import AssemblageKit
@testable import AssemblageModel

/// Die Pinselmaske arbeitet in Bildkoordinaten und speichert die Deckung als
/// Helligkeit: Weiss ist sichtbar, Schwarz ist ausgeblendet.
final class MaskPaintingTests: XCTestCase {

    private func painter(width: Int = 64, height: Int = 64, existing: CGImage? = nil) throws -> MaskPainter {
        try XCTUnwrap(MaskPainter(
            imageSize: Size(width: Double(width), height: Double(height)),
            existing: existing
        ))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> Int {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // Pufferzeile 0 ist die oberste Bildzeile — `CGContext.draw` kippt ein
        // `CGImage` in einem eigenständigen, ungeflippten Bitmap-Kontext
        // NICHT (siehe `TextureRenderingTests.testTextureIsNotFlippedVertically`
        // für die nachgemessene Herleitung). `y` ist hier schon ein
        // Modellpunkt (Ursprung oben links) und braucht daher keine eigene
        // Umrechnung mehr.
        return Int(data[y * context.bytesPerRow + x])
    }

    private func solidImage(width: Int, height: Int, gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private let hardHide = MaskBrush(diameter: 10, hardness: 1, mode: .hide)

    func testNewMaskIsEntirelyWhite() throws {
        let image = try XCTUnwrap(try painter().currentMask())

        XCTAssertGreaterThan(try pixel(image, x: 0, y: 0), 250)
        XCTAssertGreaterThan(try pixel(image, x: 32, y: 32), 250)
        XCTAssertGreaterThan(try pixel(image, x: 63, y: 63), 250)
    }

    func testHideStrokeDarkensHitPointAndLeavesOtherPixelsWhite() throws {
        let painter = try painter()
        painter.beginStroke(at: Point(x: 20, y: 20), pressure: 1, brush: hardHide)
        painter.endStroke()
        let image = try XCTUnwrap(painter.currentMask())

        XCTAssertLessThan(try pixel(image, x: 20, y: 20), 5)
        XCTAssertGreaterThan(try pixel(image, x: 50, y: 50), 250)
    }

    func testRevealStrokeRestoresHiddenPoint() throws {
        let painter = try painter()
        painter.beginStroke(at: Point(x: 20, y: 20), pressure: 1, brush: hardHide)
        painter.endStroke()
        painter.beginStroke(
            at: Point(x: 20, y: 20),
            pressure: 1,
            brush: MaskBrush(diameter: 10, hardness: 1, mode: .reveal)
        )
        painter.endStroke()

        XCTAssertGreaterThan(try pixel(try XCTUnwrap(painter.currentMask()), x: 20, y: 20), 250)
    }

    func testSingleLargeContinueJumpPaintsTheMiddle() throws {
        let painter = try painter()
        painter.beginStroke(at: Point(x: 4, y: 4), pressure: 1, brush: hardHide)
        painter.continueStroke(to: Point(x: 60, y: 60), pressure: 1)
        painter.endStroke()
        let image = try XCTUnwrap(painter.currentMask())

        XCTAssertLessThan(
            try pixel(image, x: 32, y: 32),
            30,
            "Zwischen weit auseinanderliegenden Ereignissen darf keine Lücke bleiben"
        )
    }

    func testSoftEdgeContainsIntermediateBrightness() throws {
        let painter = try painter()
        let brush = MaskBrush(diameter: 24, hardness: 0.1, mode: .hide)
        painter.beginStroke(at: Point(x: 32, y: 32), pressure: 1, brush: brush)
        painter.endStroke()
        let image = try XCTUnwrap(painter.currentMask())

        XCTAssertLessThan(try pixel(image, x: 32, y: 32), 5)
        let edgePixel = try pixel(image, x: 40, y: 32)
        XCTAssertGreaterThan(edgePixel, 10)
        XCTAssertLessThan(edgePixel, 245)
    }

    func testOverlappingStampsWithinOneStrokeDoNotAccumulate() throws {
        let singleStamp = try painter()
        let repeatedStamp = try painter()
        let brush = MaskBrush(diameter: 24, hardness: 0, mode: .hide)

        singleStamp.beginStroke(at: Point(x: 32, y: 32), pressure: 1, brush: brush)
        singleStamp.endStroke()
        repeatedStamp.beginStroke(at: Point(x: 32, y: 32), pressure: 1, brush: brush)
        for _ in 0..<20 {
            repeatedStamp.continueStroke(to: Point(x: 32, y: 32), pressure: 1)
        }
        repeatedStamp.endStroke()

        let once = try pixel(try XCTUnwrap(singleStamp.currentMask()), x: 40, y: 32)
        let repeated = try pixel(try XCTUnwrap(repeatedStamp.currentMask()), x: 40, y: 32)
        XCTAssertEqual(repeated, once, accuracy: 1)
    }

    func testLowPressurePaintsNarrowerThanFullPressure() throws {
        let lowPressure = try painter()
        let fullPressure = try painter()
        let brush = MaskBrush(diameter: 20, hardness: 1, mode: .hide)

        lowPressure.beginStroke(at: Point(x: 32, y: 32), pressure: 0, brush: brush)
        lowPressure.endStroke()
        fullPressure.beginStroke(at: Point(x: 32, y: 32), pressure: 1, brush: brush)
        fullPressure.endStroke()

        let lowImage = try XCTUnwrap(lowPressure.currentMask())
        let fullImage = try XCTUnwrap(fullPressure.currentMask())
        XCTAssertGreaterThan(try pixel(lowImage, x: 37, y: 32), 245)
        XCTAssertLessThan(try pixel(fullImage, x: 37, y: 32), 10)
    }

    func testMaskKeepsImageDimensions() throws {
        let image = try XCTUnwrap(try painter(width: 37, height: 23).currentMask())

        XCTAssertEqual(image.width, 37)
        XCTAssertEqual(image.height, 23)
    }

    func testExistingMaskIsContinuedInsteadOfReplaced() throws {
        let existing = try solidImage(width: 64, height: 64, gray: 0)
        let painter = try painter(existing: existing)
        painter.beginStroke(
            at: Point(x: 48, y: 48),
            pressure: 1,
            brush: MaskBrush(diameter: 10, hardness: 1, mode: .reveal)
        )
        painter.endStroke()
        let image = try XCTUnwrap(painter.currentMask())

        XCTAssertLessThan(try pixel(image, x: 5, y: 5), 5, "bestehende schwarze Pixel bleiben erhalten")
        XCTAssertGreaterThan(try pixel(image, x: 48, y: 48), 250)
    }

    func testPNGDataCanBeDecodedAtTheSameSize() throws {
        let painter = try painter(width: 37, height: 23)
        let data = try XCTUnwrap(painter.pngData())
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage)

        XCTAssertEqual(decoded.width, 37)
        XCTAssertEqual(decoded.height, 23)
    }

    func testInitRejectsZeroSize() {
        XCTAssertNil(MaskPainter(imageSize: .zero, existing: nil))
        XCTAssertNil(MaskPainter(imageSize: Size(width: 20, height: 0), existing: nil))
        XCTAssertNil(MaskPainter(imageSize: Size(width: .infinity, height: 20), existing: nil))
    }

    func testEntirelyOutOfBoundsStrokeDoesNotDamageMask() throws {
        let painter = try painter()
        painter.beginStroke(at: Point(x: -1_000_000, y: -1_000_000), pressure: 1, brush: hardHide)
        painter.continueStroke(to: Point(x: -900_000, y: -900_000), pressure: 1)
        painter.endStroke()
        let image = try XCTUnwrap(painter.currentMask())

        XCTAssertGreaterThan(try pixel(image, x: 0, y: 0), 250)
        XCTAssertGreaterThan(try pixel(image, x: 32, y: 32), 250)
        XCTAssertGreaterThan(try pixel(image, x: 63, y: 63), 250)
    }

    // MARK: - Lasso (Anpassungen 2: „Bild ausschneiden")

    /// Ein Lasso nahe dem oberen Bildrand muss auch oben ausblenden — nicht,
    /// wie bei der ursprünglichen Pinsel-Spiegelung, unten (siehe
    /// `Anpassungen.md`: „alles ist noch spiegelverkehrt"). Direkt
    /// nachgemessen statt angenommen, aus demselben Grund wie bei den
    /// bestehenden Pinseltests hier.
    func testLassoNearTheTopHidesNearTheTopNotTheBottom() throws {
        let painter = try painter(width: 64, height: 64)
        // Ein kleines Quadrat, dessen Mittelpunkt bei (32, 8) liegt — deutlich
        // näher am oberen als am unteren Rand.
        painter.fillLasso([
            Point(x: 24, y: 0),
            Point(x: 40, y: 0),
            Point(x: 40, y: 16),
            Point(x: 24, y: 16)
        ], mode: .hide)
        let image = try XCTUnwrap(painter.currentMask())

        XCTAssertLessThan(try pixel(image, x: 32, y: 8), 5, "oben soll ausgeblendet sein")
        XCTAssertGreaterThan(try pixel(image, x: 32, y: 56), 250, "unten bleibt unangetastet")
    }

    func testLassoHideOnlyAffectsTheEnclosedArea() throws {
        let painter = try painter(width: 64, height: 64)
        painter.fillLasso([
            Point(x: 10, y: 10),
            Point(x: 50, y: 10),
            Point(x: 50, y: 50),
            Point(x: 10, y: 50)
        ], mode: .hide)
        let image = try XCTUnwrap(painter.currentMask())

        XCTAssertLessThan(try pixel(image, x: 30, y: 30), 5, "innerhalb des Lassos ausgeblendet")
        XCTAssertGreaterThan(try pixel(image, x: 2, y: 2), 250, "ausserhalb unverändert sichtbar")
        XCTAssertGreaterThan(try pixel(image, x: 61, y: 61), 250, "ausserhalb unverändert sichtbar")
    }

    /// `.reveal` muss dieselbe Fläche zurückholen können, die zuvor per
    /// `.hide`-Lasso ausgeblendet wurde — die Verrechnung teilt sich mit dem
    /// Pinsel dieselbe `combineStroke`-Logik.
    func testLassoRevealRestoresPreviouslyHiddenArea() throws {
        let painter = try painter(width: 64, height: 64)
        let quadrat = [
            Point(x: 10, y: 10),
            Point(x: 50, y: 10),
            Point(x: 50, y: 50),
            Point(x: 10, y: 50)
        ]
        painter.fillLasso(quadrat, mode: .hide)
        XCTAssertLessThan(try pixel(try XCTUnwrap(painter.currentMask()), x: 30, y: 30), 5)

        painter.fillLasso(quadrat, mode: .reveal)
        XCTAssertGreaterThan(try pixel(try XCTUnwrap(painter.currentMask()), x: 30, y: 30), 250)
    }

    func testLassoWithFewerThanThreePointsDoesNothing() throws {
        let painter = try painter(width: 64, height: 64)
        painter.fillLasso([Point(x: 10, y: 10), Point(x: 20, y: 20)], mode: .hide)
        let image = try XCTUnwrap(painter.currentMask())

        XCTAssertGreaterThan(try pixel(image, x: 15, y: 15), 250, "zu wenige Punkte: keine Änderung")
    }

    /// Ein bereits vorhandener Zustand (z. B. eine ältere, automatische
    /// Maske) muss erhalten bleiben ausserhalb des Lassos — dieselbe Regel
    /// wie beim Pinsel (`testExistingMaskIsContinuedInsteadOfReplaced`).
    func testLassoPreservesExistingMaskOutsideTheEnclosedArea() throws {
        let existing = try solidImage(width: 64, height: 64, gray: 0)
        let painter = try painter(width: 64, height: 64, existing: existing)

        painter.fillLasso([
            Point(x: 10, y: 10),
            Point(x: 50, y: 10),
            Point(x: 50, y: 50),
            Point(x: 10, y: 50)
        ], mode: .reveal)
        let image = try XCTUnwrap(painter.currentMask())

        XCTAssertGreaterThan(try pixel(image, x: 30, y: 30), 250, "innerhalb freigestellt")
        XCTAssertLessThan(try pixel(image, x: 2, y: 2), 5, "ausserhalb bleibt die alte, verdeckte Maske")
    }
}
