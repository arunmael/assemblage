import XCTest
import AppKit
import ImageIO
@testable import AssemblageKit

/// Der Bild-Zwischenspeicher darf nicht unbegrenzt wachsen.
///
/// Anlass: Dreissig Fotos zu 8000 × 8000 Pixeln belegen dekodiert rund
/// 7,6 GB. Bis hierher wurden sie gehalten, bis das Dokument geschlossen
/// wurde — auf einem Mac mit 16 GB heisst das Auslagern oder Absturz.
///
/// Was hier NICHT geprüft wird: wann genau `NSCache` etwas verwirft. Das
/// entscheidet das System nach Speicherdruck, und ein Test darauf wäre
/// launisch. Geprüft wird, dass es eine Obergrenze gibt und dass ein
/// verworfenes Bild folgenlos neu entsteht.
@MainActor
final class ImageStoreCacheTests: XCTestCase {

    private func bildDaten(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bild = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(NSBitmapImageRep(cgImage: bild).representation(using: .png, properties: [:]))
    }

    private func speicherMitBild() throws -> (ImageStore, String) {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let bild = try XCTUnwrap(context.makeImage())
        let daten = try XCTUnwrap(NSBitmapImageRep(cgImage: bild).representation(using: .png, properties: [:]))

        let ressourcen = DocumentResources()
        let referenz = ressourcen.addOriginal(daten, fileExtension: "png")
        return (ImageStore(resources: ressourcen), referenz)
    }

    func testCacheHasAnUpperBound() throws {
        let (speicher, _) = try speicherMitBild()
        let grenze = speicher.cacheCostLimitForTesting

        XCTAssertGreaterThan(grenze, 0, "ohne Obergrenze wächst der Speicher unbegrenzt")
        XCTAssertGreaterThanOrEqual(grenze, 256 * 1024 * 1024,
                                    "unter 256 MB würde ständig neu dekodiert")
        XCTAssertLessThanOrEqual(grenze, 2 * 1024 * 1024 * 1024,
                                 "über 2 GB bringt nichts, es ist nur ein Dokument sichtbar")
    }

    func testImageIsCachedBetweenRequests() throws {
        let (speicher, referenz) = try speicherMitBild()

        let erstes = try XCTUnwrap(speicher.image(named: referenz))
        let zweites = try XCTUnwrap(speicher.image(named: referenz))
        XCTAssertTrue(erstes === zweites, "der zweite Aufruf müsste aus dem Zwischenspeicher kommen")
        XCTAssertEqual(erstes.width, 8, "kleine Bilder dürfen nicht verkleinert werden")
        XCTAssertEqual(erstes.height, 8, "kleine Bilder dürfen nicht verkleinert werden")
    }

    func testLargeImageIsDownsampledButReportsOriginalPixelSize() throws {
        let ressourcen = DocumentResources()
        let referenz = ressourcen.addOriginal(
            try bildDaten(width: 8_192, height: 16),
            fileExtension: "png"
        )
        let speicher = ImageStore(resources: ressourcen)

        let bild = try XCTUnwrap(speicher.image(named: referenz))
        XCTAssertEqual(bild.width, 4_096)
        XCTAssertEqual(bild.height, 8)
        XCTAssertEqual(speicher.pixelSize(named: referenz), CGSize(width: 8_192, height: 16))
    }

    func testPixelSizeAccountsForExifOrientation() throws {
        let sourceData = try bildDaten(width: 30, height: 20)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(sourceData as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let orientedData = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            orientedData, "public.jpeg" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let ressourcen = DocumentResources()
        let referenz = ressourcen.addOriginal(orientedData as Data, fileExtension: "jpg")
        let speicher = ImageStore(resources: ressourcen)

        XCTAssertEqual(speicher.pixelSize(named: referenz), CGSize(width: 20, height: 30))
        let bild = try XCTUnwrap(speicher.image(named: referenz))
        XCTAssertEqual(CGSize(width: bild.width, height: bild.height), CGSize(width: 20, height: 30))
    }

    /// Der entscheidende Punkt: Gibt der Zwischenspeicher ein Bild frei, darf
    /// der Aufrufer nichts davon merken.
    func testEvictedImageIsSilentlyDecodedAgain() throws {
        let (speicher, referenz) = try speicherMitBild()
        let vorher = try XCTUnwrap(speicher.image(named: referenz))

        speicher.evictAllForTesting()

        let nachher = try XCTUnwrap(speicher.image(named: referenz),
                                    "nach dem Verwerfen müsste neu dekodiert werden")
        XCTAssertFalse(vorher === nachher, "es müsste tatsächlich ein neues Bild sein")
        XCTAssertEqual(nachher.width, vorher.width)
        XCTAssertEqual(nachher.height, vorher.height)
    }

    /// Eine kaputte Datei darf nicht bei jedem Bild erneut erfolglos
    /// dekodiert werden — und dieses Wissen überlebt ein Verwerfen.
    func testKnowledgeAboutBrokenFilesSurvivesEviction() {
        let ressourcen = DocumentResources()
        let referenz = ressourcen.addOriginal(Data([0x00, 0x01, 0x02]), fileExtension: "png")
        let speicher = ImageStore(resources: ressourcen)

        XCTAssertNil(speicher.image(named: referenz))
        speicher.evictAllForTesting()
        XCTAssertNil(speicher.image(named: referenz))
    }

    /// `forget` muss auch das Wissen über eine kaputte Datei löschen — sonst
    /// bliebe eine ersetzte Datei für immer als unlesbar vermerkt.
    func testForgetClearsTheFailureToo() throws {
        let ressourcen = DocumentResources()
        let referenz = ressourcen.addOriginal(Data([0x00, 0x01]), fileExtension: "png")
        let speicher = ImageStore(resources: ressourcen)
        XCTAssertNil(speicher.image(named: referenz))

        // Datei reparieren, wie es beim erneuten Einsetzen eines Bildes geschieht.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bild = try XCTUnwrap(context.makeImage())
        let daten = try XCTUnwrap(NSBitmapImageRep(cgImage: bild).representation(using: .png, properties: [:]))
        ressourcen.replace(referenz, with: daten)

        XCTAssertNil(speicher.image(named: referenz), "ohne forget bleibt der Vermerk")
        speicher.forget(referenz)
        XCTAssertNotNil(speicher.image(named: referenz))
    }

    func testForgetClearsRememberedPixelSize() throws {
        let ressourcen = DocumentResources()
        let referenz = ressourcen.addOriginal(
            try bildDaten(width: 12, height: 8),
            fileExtension: "png"
        )
        let speicher = ImageStore(resources: ressourcen)
        XCTAssertEqual(speicher.pixelSize(named: referenz), CGSize(width: 12, height: 8))

        ressourcen.replace(referenz, with: try bildDaten(width: 7, height: 5))
        XCTAssertEqual(speicher.pixelSize(named: referenz), CGSize(width: 12, height: 8))

        speicher.forget(referenz)
        XCTAssertEqual(speicher.pixelSize(named: referenz), CGSize(width: 7, height: 5))
    }
}
