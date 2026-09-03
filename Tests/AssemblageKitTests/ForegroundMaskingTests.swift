import XCTest
import AppKit
@testable import AssemblageKit

/// Automatisches Freistellen (Plan 5.4, 7.3) über
/// `VNGenerateForegroundInstanceMaskRequest`.
///
/// Vision ist ein Modell, kein deterministischer Algorithmus — ob es auf
/// einem bestimmten Testbild "genau ein Objekt" findet, kann sich zwischen
/// macOS-Versionen ändern. Deshalb prüfen diese Tests vor allem, was
/// **unabhängig vom Modell** gelten muss: Maskenmasse, die Unterscheidung
/// zwischen "kein Motiv gefunden" (kein Fehler) und einem echten Fehler
/// (kaputte Daten), dass das Ergebnis als PNG lesbar ist, und dass der Aufruf
/// den Hauptthread nicht blockiert. Nur ein Test verlässt sich auf eine
/// tatsächliche Erkennung; er ist als solcher gekennzeichnet und weicht bei
/// Nichterkennung auf `XCTSkip` statt auf `XCTFail` aus (siehe dort).
@MainActor
final class ForegroundMaskingTests: XCTestCase {

    // MARK: - Testbilder

    /// Einfarbiges Testbild ohne jede Struktur — Vision hat hier nichts, was
    /// sich von einem "Hintergrund" unterscheiden liesse. Modellunabhängig
    /// robust: Eine Fläche ganz ohne Kontrast oder Kanten enthält per
    /// Definition kein von einem Hintergrund abgrenzbares Objekt, das ist
    /// keine Eigenschaft eines bestimmten Vision-Modells, sondern der
    /// Bildinhalt selbst.
    private func flatColorImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.6, green: 0.6, blue: 0.62, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// Ein Testbild mit einem klaren, kontrastreichen Objekt vor einheitlichem
    /// Grund — der Fall, in dem ein Mensch von "einem Motiv" sprechen würde.
    /// Ob Vision auf einer *gemalten* Form (statt einem echten Foto) tatsächlich
    /// eine Instanz erkennt, ist nicht garantiert — deshalb wird dieses Bild
    /// nur im als solchen gekennzeichneten Modell-Test verwendet, dort mit
    /// `XCTSkip` statt `XCTFail` bei Nichterkennung.
    private func imageWithSalientShape(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.85, green: 0.85, blue: 0.88, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        let inset = min(width, height) / 4
        context.fillEllipse(in: CGRect(x: inset, y: inset, width: width - inset * 2, height: height - inset * 2))
        return try XCTUnwrap(context.makeImage())
    }

    private func pngData(_ image: CGImage) throws -> Data {
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    // MARK: - Modellunabhängige Fälle

    /// Kein erkennbares Motiv ist kein Fehler, sondern ein normales Ergebnis
    /// (Plan 2.1) — muss vom echten Fehlerfall unterscheidbar bleiben.
    func testFlatImageWithoutSubjectReturnsNoSubjectFoundInsteadOfThrowing() async throws {
        let image = try flatColorImage(width: 300, height: 200)

        let result = try await ForegroundMasking.generateMask(from: image)

        guard case .noSubjectFound = result else {
            XCTFail("eine reine Farbfläche darf kein Motiv liefern")
            return
        }
    }

    /// Datenmüll darf nicht abstürzen, sondern muss einen Fehler werfen —
    /// unterscheidbar vom Kein-Motiv-Fall aus dem Test oben.
    func testMalformedDataThrowsInvalidImageInsteadOfCrashing() async throws {
        do {
            _ = try await ForegroundMasking.generateMask(from: Data("kein Bild".utf8))
            XCTFail("Datenmüll darf nicht als Bild durchgehen")
        } catch ForegroundMasking.MaskingError.invalidImage {
            // erwartet
        }
    }

    /// Abgeschnittene, aber PNG-artige Daten dürfen ebenfalls nicht
    /// abstürzen.
    func testTruncatedPNGDataThrowsInvalidImageInsteadOfCrashing() async throws {
        do {
            _ = try await ForegroundMasking.generateMask(from: Data([0x89, 0x50, 0x4E, 0x47]))
            XCTFail("abgeschnittene Datei darf nicht abstürzen")
        } catch ForegroundMasking.MaskingError.invalidImage {
            // erwartet
        }
    }

    /// Der Aufruf darf den Hauptthread nicht blockieren (Plan 2.1). Nachweis:
    /// Während `generateMask` läuft, macht eine parallele Arbeit auf dem
    /// `MainActor` nachweislich Fortschritt — bliebe der Hauptthread blockiert,
    /// käme dieser Zähler nie über 0 hinaus, bevor die Maskierung fertig ist.
    @MainActor
    private final class Fertigmeldung {
        var istFertig = false
    }

    func testGenerateMaskDoesNotBlockTheMainThread() async throws {
        let image = try flatColorImage(width: 400, height: 400)
        let fertig = Fertigmeldung()

        let zaehlerAufgabe = Task { @MainActor () -> Int in
            var n = 0
            while !fertig.istFertig {
                n += 1
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return n
        }

        _ = try await ForegroundMasking.generateMask(from: image)
        fertig.istFertig = true

        let n = await zaehlerAufgabe.value
        XCTAssertGreaterThan(n, 0, "der Hauptthread muss während der Maskierung weiterlaufen können")
    }

    /// Kaputte, aber aus Bytes bestehende Bilddaten (statt eines validen PNGs)
    /// laufen über den `Data`-Einstieg der API und müssen denselben Fehler
    /// werfen wie oben.
    func testGenerateMaskFromDataDelegatesDecodingErrors() async throws {
        do {
            _ = try await ForegroundMasking.generateMask(from: Data(repeating: 0xFF, count: 16))
            XCTFail("Datenmüll darf nicht als Bild durchgehen")
        } catch ForegroundMasking.MaskingError.invalidImage {
            // erwartet
        }
    }

    // MARK: - Modellabhängiger Fall (bewusst mit XCTSkip statt XCTFail)

    /// Prüft die tatsächliche Erkennung — und damit auch, dass eine gefundene
    /// Maske dieselben Pixelmasse wie das Quellbild hat und sich als PNG
    /// schreiben und wieder lesen lässt. Findet Vision auf diesem gemalten
    /// Testbild (kein echtes Foto) nichts, ist das kein Bug in dieser Datei,
    /// sondern eine Modellentscheidung, die sich zwischen macOS-Versionen
    /// ändern darf — deshalb hier `XCTSkip` statt `XCTFail`, wie es die
    /// bestehende Konvention in `PipelineIntegrationTests` für noch nicht
    /// zusicherbare Fälle vorsieht.
    func testSalientShapeProducesMaskMatchingImageDimensions() async throws {
        let width = 600, height = 400
        let image = try imageWithSalientShape(width: width, height: height)

        let result = try await ForegroundMasking.generateMask(from: image)

        guard case .mask(let data) = result else {
            throw XCTSkip("Vision hat auf diesem gemalten Testbild kein Motiv erkannt — modellabhängig, kein Fehler dieser Implementierung.")
        }

        XCTAssertFalse(data.isEmpty, "eine gefundene Maske darf keine leeren PNG-Daten liefern")

        // PNG lässt sich schreiben und wieder lesen (Rundreise).
        let decoded = try XCTUnwrap(ImageDecoding.decode(data), "die Maske muss sich als PNG wieder einlesen lassen")
        XCTAssertEqual(decoded.width, width, "die Maske muss dieselbe Breite wie das Quellbild haben")
        XCTAssertEqual(decoded.height, height, "die Maske muss dieselbe Höhe wie das Quellbild haben")
    }

    /// Derselbe Massstab-Test wie oben, aber über den `Data`-Einstieg und mit
    /// einem Bild, das grösser ist als das interne Analyse-Limit — prüft
    /// damit auch, dass das Hoch-/Herunterskalieren die Endmasse nicht
    /// verändert.
    func testLargeImageMaskStillMatchesOriginalDimensionsAfterDownscaling() async throws {
        let width = 3000, height = 2000
        let image = try imageWithSalientShape(width: width, height: height)
        let data = try pngData(image)

        let result = try await ForegroundMasking.generateMask(from: data)

        guard case .mask(let maskData) = result else {
            throw XCTSkip("Vision hat auf diesem gemalten Testbild kein Motiv erkannt — modellabhängig, kein Fehler dieser Implementierung.")
        }

        let decoded = try XCTUnwrap(ImageDecoding.decode(maskData))
        XCTAssertEqual(decoded.width, width, "nach dem Hochskalieren muss die Maske wieder die Originalbreite haben")
        XCTAssertEqual(decoded.height, height, "nach dem Hochskalieren muss die Maske wieder die Originalhöhe haben")
    }
}
