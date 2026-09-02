import XCTest
@testable import AssemblageModel

// Diese Tests decken die eigentliche Rendering-/Freistell-Pipeline ab
// (Plan 2.1: "Automatisierte Tests für die Kernpipeline (Kompositing,
// Maskierung, Export) sowie gezielte Stresstests mit sehr grossen Leinwänden
// und vielen Ebenen"). Sie brauchen Core Image / Core Animation / Vision und
// können deshalb nicht auf Windows kompiliert werden — der Block ist absichtlich
// hinter `#if os(macOS)` versteckt, damit `swift test` hier grün bleibt.
//
// TODO (am Mac weiterführen): Diese Platzhalter mit echten Core-Image-/
// Vision-Aufrufen füllen, sobald das AppKit-Rendering-Ziel existiert.
#if os(macOS)
final class PipelineIntegrationTests: XCTestCase {
    func testCompositingManyLayersDoesNotExceedTimeBudget() throws {
        XCTFail("TODO: Stresstest mit vielen Ebenen auf grosser Leinwand — Core Animation Kompositing")
    }

    func testAutomaticForegroundMaskProducesNonEmptyMask() throws {
        XCTFail("TODO: VNGenerateForegroundInstanceMaskRequest auf Testbild anwenden und Maske prüfen")
    }

    func testExportRendersAllVisibleLayersAtRequestedSize() throws {
        XCTFail("TODO: CIContext-Export prüfen (Grösse, Ebenenreihenfolge, Blend-Modi)")
    }

    func testExportSkipsHiddenLayers() throws {
        XCTFail("TODO: isVisible == false darf im Export nicht erscheinen")
    }

    func testMalformedImageImportFailsGracefullyInsteadOfCrashing() throws {
        XCTFail("TODO: korrupte/unsupported Bilddatei -> Fehler, kein try!/Absturz (2.1)")
    }
}
#endif
