import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import AssemblageKit
@testable import AssemblageModel

/// Prüft die Logik aus `ImageImporter` (Plan 5.1) — nicht die
/// Drag-&-Drop-Anbindung, die es bewusst nicht gibt.
@MainActor
final class ImageImporterTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AssemblageImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Testbilder erzeugen

    private struct EncodingFailed: Error {}

    /// Baut echte, gültige Bilddaten in einem beliebigen ImageIO-Format —
    /// so lassen sich alle vier laut Plan 5.1 unterstützten Formate mit
    /// derselben Methode erzeugen (anders als `NSBitmapImageRep`, das kein
    /// HEIC schreiben kann).
    private func imageData(
        width: Int = 8,
        height: Int = 8,
        type: UTType,
        color: CGColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
        exifOrientation: UInt32? = nil
    ) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = try XCTUnwrap(context.makeImage())

        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        )
        var properties: [CFString: Any] = [:]
        if let exifOrientation {
            properties[kCGImagePropertyOrientation] = exifOrientation
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EncodingFailed() }
        return data as Data
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeResources() -> DocumentResources { DocumentResources() }

    // MARK: - Formate

    func testAllFourSupportedFormatsAreImported() throws {
        let files = [
            try write(try imageData(type: .jpeg), named: "foto.jpg"),
            try write(try imageData(type: .png), named: "foto.png"),
            try write(try imageData(type: .heic), named: "foto.heic"),
            try write(try imageData(type: .tiff), named: "foto.tiff"),
        ]

        let result = ImageImporter.import(fileURLs: files, resources: makeResources(), canvas: CanvasSize(width: 1080, height: 1080))

        XCTAssertEqual(result.images.count, 4, "alle vier laut Plan 5.1 unterstützten Formate müssen ankommen")
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testUnsupportedFileIsSkippedWithoutBlockingTheOthers() throws {
        let png = try write(try imageData(type: .png), named: "gut.png")
        let pdf = try write(Data("kein Bild".utf8), named: "unterlagen.pdf")

        let result = ImageImporter.import(fileURLs: [pdf, png], resources: makeResources(), canvas: CanvasSize(width: 500, height: 500))

        XCTAssertEqual(result.images.count, 1)
        XCTAssertTrue(result.failures.isEmpty, "eine nicht unterstützte Datei ist kein Fehler, sie wird einfach übergangen")
    }

    func testCorruptImageFileDoesNotFailTheWholeImport() throws {
        let good = try write(try imageData(type: .png), named: "gut.png")
        // Gültige JPEG-Endung, aber Datenmüll dahinter — genau der Fall einer
        // beschädigten Datei.
        let corrupt = try write(Data([0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x02]), named: "kaputt.jpg")

        let result = ImageImporter.import(fileURLs: [corrupt, good], resources: makeResources(), canvas: CanvasSize(width: 500, height: 500))

        XCTAssertEqual(result.images.count, 1, "das lesbare Bild muss trotzdem ankommen")
        XCTAssertEqual(result.failures.count, 1, "die kaputte Datei wird gemeldet, nicht verschluckt")
        XCTAssertEqual(result.failures.first?.name, "kaputt")
    }

    // MARK: - Ebenenname

    func testLayerNameComesFromFileNameWithoutExtension() throws {
        let file = try write(try imageData(type: .png), named: "Urlaubsfoto.png")

        let result = ImageImporter.import(fileURLs: [file], resources: makeResources(), canvas: CanvasSize(width: 500, height: 500))

        XCTAssertEqual(result.images.first?.layer.name, "Urlaubsfoto")
    }

    func testPasteboardImageWithoutFileGetsAGenericName() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }
        let data = try imageData(type: .png)
        pasteboard.declareTypes([NSPasteboard.PasteboardType(UTType.png.identifier)], owner: nil)
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(UTType.png.identifier))

        let result = ImageImporter.import(from: pasteboard, resources: makeResources(), canvas: CanvasSize(width: 500, height: 500))

        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.images.first?.layer.name, "Importiertes Bild")
    }

    // MARK: - Anfangsplatzierung

    func testSmallImageIsCenteredAndNotUpscaled() throws {
        let file = try write(try imageData(width: 8, height: 8, type: .png), named: "klein.png")

        let result = ImageImporter.import(fileURLs: [file], resources: makeResources(), canvas: CanvasSize(width: 1080, height: 1080))

        let transform = try XCTUnwrap(result.images.first?.layer.transform)
        XCTAssertEqual(transform.x, 540, accuracy: 0.001)
        XCTAssertEqual(transform.y, 540, accuracy: 0.001)
        XCTAssertEqual(transform.scaleX, 1, accuracy: 0.001, "ein 8×8-Bild auf eine 1080er-Leinwand darf nicht hochskaliert werden")
        XCTAssertEqual(transform.scaleY, 1, accuracy: 0.001)
    }

    func testMultipleImagesAreNotStackedExactlyOnTopOfEachOther() throws {
        let files = try (0..<3).map { index in
            try write(try imageData(type: .png), named: "bild\(index).png")
        }

        let result = ImageImporter.import(fileURLs: files, resources: makeResources(), canvas: CanvasSize(width: 1080, height: 1080))

        XCTAssertEqual(result.images.count, 3)
        let positions = Set(result.images.map { "\($0.layer.transform.x),\($0.layer.transform.y)" })
        XCTAssertEqual(positions.count, 3, "gleichzeitig importierte Bilder müssen sichtbar gegeneinander versetzt sein")
    }

    // MARK: - Paket

    func testOriginalEndsUpInThePackageAndDecodesAgain() throws {
        let file = try write(try imageData(type: .png), named: "foto.png")
        let resources = makeResources()

        let result = ImageImporter.import(fileURLs: [file], resources: resources, canvas: CanvasSize(width: 500, height: 500))

        let reference = try XCTUnwrap(result.images.first?.originalFileReference)
        let stored = try XCTUnwrap(resources.data(for: reference), "die Originaldatei muss im Paket liegen")
        XCTAssertNotNil(ImageDecoding.decode(stored), "und sich wieder dekodieren lassen")
    }

    // MARK: - Leere Eingabe

    func testEmptyInputProducesNoLayersAndNoError() {
        let result = ImageImporter.import(fileURLs: [], resources: makeResources(), canvas: CanvasSize(width: 500, height: 500))

        XCTAssertTrue(result.images.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
    }

    // MARK: - EXIF-Drehung

    /// Ein Hochformat-Foto, das (wie eine Handykamera es tut) in
    /// Sensor-Lage quer gespeichert ist und erst über den EXIF-Tag als
    /// Hochformat gilt, darf nicht quer in die Leinwand eingepasst werden.
    func testExifRotatedPhotoIsFittedByItsDisplayedSizeNotSensorSize() throws {
        // Sensor-Lage: 800×400 (quer). Orientierung 6 = 90° im Uhrzeigersinn
        // drehen, um es richtig anzuzeigen → angezeigt 400×800 (hoch).
        let data = try imageData(width: 800, height: 400, type: .jpeg, exifOrientation: 6)
        let file = try write(data, named: "hochkant.jpg")

        // Absichtlich eine schmale, hohe Leinwand: Nur bei korrekter
        // (angezeigter) Grösse 400×800 reicht Massstab 1 — bei der falschen
        // Sensor-Grösse 800×400 müsste stattdessen auf 0.625 herunterskaliert
        // werden, um in die Breite 500 zu passen.
        let result = ImageImporter.import(fileURLs: [file], resources: makeResources(), canvas: CanvasSize(width: 500, height: 1000))

        let transform = try XCTUnwrap(result.images.first?.layer.transform)
        XCTAssertEqual(transform.scaleX, 1, accuracy: 0.001, "die Grösse muss aus der angezeigten (gedrehten) Lage kommen, nicht aus der Sensor-Lage")
    }

    // MARK: - Ermitteln ohne Import

    func testImportableFileURLsFiltersUnsupportedFormats() throws {
        let png = try write(try imageData(type: .png), named: "gut.png")
        let txt = try write(Data("hallo".utf8), named: "notiz.txt")

        let importable = ImageImporter.importableFileURLs(from: [png, txt])

        XCTAssertEqual(importable, [png])
    }
}
