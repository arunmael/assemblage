import XCTest
import AppKit
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
}
