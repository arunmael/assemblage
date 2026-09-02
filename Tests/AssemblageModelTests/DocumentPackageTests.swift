import XCTest
@testable import AssemblageModel

/// Tests für das Dokumentpaket-Format (Plan 7.4): JSON-Struktur plus
/// referenzierte Originalbilder/Masken. Bewusst plattformunabhängig — die
/// eigentliche `NSDocument`-/`FileWrapper`-Anbindung am Mac nutzt genau
/// diese Funktionen, damit die fehleranfällige Logik (Formatversion,
/// fehlende Referenzen) hier testbar bleibt.
final class DocumentPackageTests: XCTestCase {

    // MARK: - Hilfsmittel

    private func imageLayer(name: String, file: String, mask: String? = nil) -> Layer {
        Layer(
            name: name,
            mask: mask.map { LayerMask(maskImageReference: $0, source: .manualBrush) },
            content: .image(ImageLayerContent(originalFileReference: file))
        )
    }

    // MARK: - Serialisierung

    func testEncodeDecodeRoundTripPreservesDocument() throws {
        let original = Document(
            preset: .instagramPost,
            layers: [
                imageLayer(name: "Hintergrund", file: "originals/a.heic"),
                Layer(name: "Titel", opacity: 0.5, content: .text(TextLayerContent(string: "Hallo")))
            ]
        )

        let data = try DocumentPackage.encode(original)
        let restored = try DocumentPackage.decode(data)

        XCTAssertEqual(restored, original)
    }

    func testEncodedDataCarriesCurrentFormatVersion() throws {
        let data = try DocumentPackage.encode(Document(preset: .instagramPost))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["formatVersion"] as? Int, DocumentPackage.currentFormatVersion)
    }

    /// Ein Dokument aus einer künftigen App-Version darf nicht halb geöffnet
    /// werden — das würde beim nächsten Speichern Daten zerstören. Plan 2.1
    /// verlangt einen sauberen Fehler statt eines Absturzes.
    func testDecodingNewerFormatVersionThrowsInsteadOfLosingData() throws {
        let future = DocumentPackage.currentFormatVersion + 1
        let data = try XCTUnwrap(
            #"{"formatVersion": \#(future), "document": {"canvas": {"width": 1, "height": 1}, "layers": []}}"#
                .data(using: .utf8)
        )

        XCTAssertThrowsError(try DocumentPackage.decode(data)) { error in
            XCTAssertEqual(error as? DocumentPackageError, .unsupportedFormatVersion(future))
        }
    }

    func testDecodingGarbageThrowsInsteadOfCrashing() {
        let data = Data("kein JSON".utf8)
        XCTAssertThrowsError(try DocumentPackage.decode(data))
    }

    // MARK: - Referenzierte Dateien

    func testReferencedFileNamesCollectsOriginalsAndMasks() {
        let document = Document(
            preset: .instagramPost,
            layers: [
                imageLayer(name: "A", file: "originals/a.heic", mask: "masks/a.png"),
                imageLayer(name: "B", file: "originals/b.png"),
                Layer(name: "Text", content: .text(TextLayerContent(string: "x")))
            ]
        )

        XCTAssertEqual(
            document.referencedFileNames,
            ["originals/a.heic", "masks/a.png", "originals/b.png"]
        )
    }

    /// Eine Maske ohne Bitmap (z. B. während die Vision-Anfrage noch läuft)
    /// darf keine Datei-Referenz erzeugen.
    func testMaskWithoutBitmapIsNotReferenced() {
        let document = Document(
            preset: .instagramPost,
            layers: [
                Layer(
                    name: "A",
                    mask: LayerMask(source: .automaticForegroundInstance),
                    content: .image(ImageLayerContent(originalFileReference: "originals/a.heic"))
                )
            ]
        )

        XCTAssertEqual(document.referencedFileNames, ["originals/a.heic"])
    }

    /// Beim Öffnen eines Pakets, dem eine Bilddatei fehlt (z. B. durch einen
    /// abgebrochenen Kopiervorgang), muss klar benannt werden, was fehlt —
    /// statt später beim Rendern zu scheitern.
    func testValidationReportsMissingReferencedFiles() {
        let document = Document(
            preset: .instagramPost,
            layers: [
                imageLayer(name: "A", file: "originals/a.heic", mask: "masks/a.png"),
                imageLayer(name: "B", file: "originals/b.png")
            ]
        )

        XCTAssertThrowsError(
            try DocumentPackage.validate(document, against: ["originals/a.heic"])
        ) { error in
            XCTAssertEqual(
                error as? DocumentPackageError,
                .missingReferencedFiles(["masks/a.png", "originals/b.png"])
            )
        }
    }

    func testValidationPassesWhenAllFilesPresent() throws {
        let document = Document(
            preset: .instagramPost,
            layers: [imageLayer(name: "A", file: "originals/a.heic")]
        )

        XCTAssertNoThrow(
            try DocumentPackage.validate(
                document,
                against: ["originals/a.heic", "originals/verwaist.png"]
            )
        )
    }

    /// Beim Speichern sollen Originale, die durch Löschen einer Ebene
    /// verwaist sind, nicht ewig mitgeschleppt werden (Plan 2.1: Speicherplatz).
    func testUnreferencedFilesAreReportedForCleanup() {
        let document = Document(
            preset: .instagramPost,
            layers: [imageLayer(name: "A", file: "originals/a.heic")]
        )

        XCTAssertEqual(
            DocumentPackage.unreferencedFileNames(
                in: ["originals/a.heic", "originals/alt.png", "masks/alt.png"],
                for: document
            ),
            ["originals/alt.png", "masks/alt.png"]
        )
    }
}
