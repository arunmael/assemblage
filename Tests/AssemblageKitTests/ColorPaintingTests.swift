import XCTest
import AppKit
import CoreGraphics
@testable import AssemblageKit
@testable import AssemblageModel

/// Die Farbebene arbeitet in Bildkoordinaten und speichert ihre Deckung im
/// Alphakanal einer RGBA-Bitmap.
final class ColorPaintingTests: XCTestCase {

    private struct Pixel {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int
    }

    private func painter(
        width: Int = 64,
        height: Int = 64,
        existing: CGImage? = nil
    ) throws -> ColorPainter {
        try XCTUnwrap(ColorPainter(
            imageSize: Size(width: Double(width), height: Double(height)),
            existing: existing
        ))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> Pixel {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // Pufferzeile 0 ist die oberste Bildzeile — `y` ist bereits ein
        // Modellpunkt und darf hier nicht nochmals umgerechnet werden.
        let offset = y * context.bytesPerRow + x * 4
        return Pixel(
            red: Int(data[offset]),
            green: Int(data[offset + 1]),
            blue: Int(data[offset + 2]),
            alpha: Int(data[offset + 3])
        )
    }

    private func solidImage(
        width: Int,
        height: Int,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat
    ) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(
            red: red, green: green, blue: blue, alpha: alpha
        ))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private let hardRed = PaintBrush(
        diameter: 10,
        hardness: 1,
        colorHex: "#FF0000",
        opacity: 1
    )

    func testNewPaintLayerIsEntirelyTransparent() throws {
        let image = try XCTUnwrap(try painter().currentImage())

        XCTAssertEqual(try pixel(image, x: 0, y: 0).alpha, 0)
        XCTAssertEqual(try pixel(image, x: 32, y: 32).alpha, 0)
        XCTAssertEqual(try pixel(image, x: 63, y: 63).alpha, 0)
    }

    func testHardStampUsesChosenColorAndLeavesDistantPixelTransparent() throws {
        let painter = try painter()
        painter.beginStroke(at: Point(x: 20, y: 20), pressure: 1, brush: hardRed)
        let image = try XCTUnwrap(painter.currentImage())

        let hit = try pixel(image, x: 20, y: 20)
        XCTAssertGreaterThan(hit.red, 245)
        XCTAssertLessThan(hit.green, 10)
        XCTAssertLessThan(hit.blue, 10)
        XCTAssertGreaterThan(hit.alpha, 245)
        XCTAssertEqual(try pixel(image, x: 50, y: 50).alpha, 0)
    }

    /// Ein Strich nahe dem oberen Bildrand darf nicht unten landen (aus
    /// Anpassungen.md: „alles ist noch spiegelverkehrt").
    func testStrokeNearTheTopLandsNearTheTopNotTheBottom() throws {
        let painter = try painter(width: 40, height: 80)
        painter.beginStroke(at: Point(x: 20, y: 8), pressure: 1, brush: hardRed)
        painter.endStroke()
        let image = try XCTUnwrap(painter.currentImage())

        XCTAssertGreaterThan(try pixel(image, x: 20, y: 8).alpha, 245)
        XCTAssertEqual(try pixel(image, x: 20, y: 72).alpha, 0)
    }

    func testStrokeOpacityControlsWholeStrokeAlpha() throws {
        let painter = try painter()
        let brush = PaintBrush(
            diameter: 10,
            hardness: 1,
            colorHex: "#00FF00",
            opacity: 0.5
        )
        painter.beginStroke(at: Point(x: 32, y: 32), pressure: 1, brush: brush)
        painter.endStroke()

        let alpha = Double(try pixel(
            try XCTUnwrap(painter.currentImage()), x: 32, y: 32
        ).alpha) / 255
        XCTAssertEqual(alpha, 0.5, accuracy: 0.15)
    }

    func testOverlappingStampsWithinOneStrokeDoNotAccumulate() throws {
        let singleStamp = try painter()
        let repeatedStamp = try painter()
        let brush = PaintBrush(
            diameter: 24,
            hardness: 0,
            colorHex: "#3366CC",
            opacity: 0.5
        )

        singleStamp.beginStroke(at: Point(x: 32, y: 32), pressure: 1, brush: brush)
        singleStamp.endStroke()
        repeatedStamp.beginStroke(at: Point(x: 32, y: 32), pressure: 1, brush: brush)
        for _ in 0..<20 {
            repeatedStamp.continueStroke(to: Point(x: 32, y: 32), pressure: 1)
        }
        repeatedStamp.endStroke()

        let once = try pixel(try XCTUnwrap(singleStamp.currentImage()), x: 40, y: 32)
        let repeated = try pixel(try XCTUnwrap(repeatedStamp.currentImage()), x: 40, y: 32)
        XCTAssertGreaterThan(once.alpha, 10)
        XCTAssertEqual(repeated.alpha, once.alpha, accuracy: 2)
    }

    func testExistingImageIsContinuedInsteadOfReplaced() throws {
        let existing = try solidImage(
            width: 64, height: 64, red: 0, green: 0, blue: 1, alpha: 1
        )
        let painter = try painter(existing: existing)
        painter.beginStroke(at: Point(x: 48, y: 48), pressure: 1, brush: hardRed)
        painter.endStroke()
        let image = try XCTUnwrap(painter.currentImage())

        let oldPixel = try pixel(image, x: 5, y: 5)
        XCTAssertLessThan(oldPixel.red, 10)
        XCTAssertGreaterThan(oldPixel.blue, 245)
        XCTAssertGreaterThan(oldPixel.alpha, 245)
        let newPixel = try pixel(image, x: 48, y: 48)
        XCTAssertGreaterThan(newPixel.red, 245)
        XCTAssertLessThan(newPixel.blue, 10)
    }

    func testInvalidGeometryAndPressureDrawNothing() throws {
        let painter = try painter()
        let invalidDiameter = PaintBrush(
            diameter: 0,
            hardness: 1,
            colorHex: "#FF0000",
            opacity: 1
        )
        painter.beginStroke(at: Point(x: 20, y: 20), pressure: 1, brush: invalidDiameter)
        painter.endStroke()
        painter.beginStroke(at: Point(x: .nan, y: 20), pressure: 1, brush: hardRed)
        painter.continueStroke(to: Point(x: 20, y: 20), pressure: .nan)
        painter.continueStroke(to: Point(x: 20, y: .infinity), pressure: 1)
        painter.endStroke()
        painter.beginStroke(at: Point(x: 20, y: 20), pressure: .infinity, brush: hardRed)
        painter.endStroke()

        let image = try XCTUnwrap(painter.currentImage())
        XCTAssertEqual(try pixel(image, x: 20, y: 20).alpha, 0)
    }

    func testPNGDataCanBeDecodedAtTheSameSize() throws {
        let painter = try painter(width: 37, height: 23)
        let data = try XCTUnwrap(painter.pngData())
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage)

        XCTAssertEqual(decoded.width, 37)
        XCTAssertEqual(decoded.height, 23)
    }
}
