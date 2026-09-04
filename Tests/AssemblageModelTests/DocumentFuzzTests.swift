import XCTest
import Foundation
@testable import AssemblageModel

final class DocumentFuzzTests: XCTestCase {

    // MARK: - Hilfsfunktionen

    private func erstelleGueltigesDokument() -> Document {
        let canvas = CanvasSize(width: 800, height: 600)

        let imageContent = ImageLayerContent(
            originalFileReference: "bild.png",
            cropRect: nil,
            adjustments: .neutral
        )
        let imageLayer = Layer(
            name: "Hintergrundbild",
            content: .image(imageContent)
        )

        let textContent = TextLayerContent(
            string: "Hallo Welt",
            fontName: "Helvetica",
            fontSize: 48,
            colorHex: "#000000",
            alignment: .left
        )
        let textLayer = Layer(
            name: "Titel",
            content: .text(textContent)
        )

        let shapeContent = ShapeLayerContent(
            kind: .star,
            size: Size(width: 100, height: 100),
            cornerRadius: 0,
            fillColorHex: "#FF0000",
            pointCount: 5
        )
        let shapeLayer = Layer(
            name: "Stern",
            content: .shape(shapeContent)
        )

        return Document(canvas: canvas, layers: [imageLayer, textLayer, shapeLayer])
    }

    /// Erlaubt sind Fehler und gültige Dokumente. Verboten ist alles andere —
    /// und „alles andere" heisst hier: das Testprogramm überlebt es nicht.
    private func mussUeberleben(_ daten: Data) {
        _ = try? DocumentPackage.decode(daten)
    }

    // MARK: - Tests

    /// Simuliert eine unvollständige Datei, wie sie bei einer abgebrochenen Sicherung
    /// oder einer unvollständigen Netzwerkübertragung entstehen kann.
    func testTruncatedDataNeverCrashes() throws {
        let doc = erstelleGueltigesDokument()
        let daten = try DocumentPackage.encode(doc)
        
        for prozent in stride(from: 0, through: 90, by: 10) {
            let laenge = (daten.count * prozent) / 100
            let teilDaten = daten.prefix(laenge)
            mussUeberleben(teilDaten)
        }
    }

    /// Simuliert Bit-Flips oder defekte Sektoren auf einem Speichermedium,
    /// bei denen einzelne Bytes im Datenstrom verfälscht wurden.
    func testSingleCorruptedBytesNeverCrash() throws {
        let doc = erstelleGueltigesDokument()
        let daten = try DocumentPackage.encode(doc)
        let anzahlAenderungen = 40
        let schrittweite = max(1, daten.count / anzahlAenderungen)

        // Ein deterministischer Algorithmus wird verwendet, damit Fehlschläge
        // ohne Zufallskomponente jederzeit exakt reproduzierbar sind.
        for i in 0..<anzahlAenderungen {
            let index = i * schrittweite
            if index < daten.count {
                var mutierteDaten = daten
                mutierteDaten[index] = 0xFF
                mussUeberleben(mutierteDaten)
            }
        }
    }

    /// Simuliert manipulierte Dateien oder fehlerhafte Exporte von Drittanbieter-Software,
    /// die extreme, unendliche oder ungültige Zahlenwerte in die Struktur einbringen.
    func testExtremeNumbersNeverCrash() throws {
        let doc = erstelleGueltigesDokument()
        let daten = try DocumentPackage.encode(doc)
        let jsonString = try XCTUnwrap(String(data: daten, encoding: .utf8))

        let extremeWerte = [
            "0", "-1", "1e308", "-1e308", "999999999999999999999",
            "\"NaN\"", "\"Infinity\"", "\"nicht eine Zahl\"", "null"
        ]

        // Wir suchen gezielt nach dem Schlüssel für die Breite, um die Robustheit
        // des Parsers bei der Typkonvertierung von Zahlen zu testen.
        let suchMuster = "\"width\" :"
        guard let range = jsonString.range(of: suchMuster) else {
            XCTFail("Schlüssel 'width' nicht im JSON gefunden")
            return
        }

        let startIndex = range.upperBound
        let restString = jsonString[startIndex...]
        guard let endOfValueIndex = restString.firstIndex(where: { $0 == "," || $0 == "\n" }) else {
            XCTFail("Ende des Wertes für 'width' nicht gefunden")
            return
        }

        let wertRange = startIndex..<endOfValueIndex

        for wert in extremeWerte {
            var modifiziertesJson = jsonString
            modifiziertesJson.replaceSubrange(wertRange, with: " \(wert)")
            
            if let modifizierteDaten = modifiziertesJson.data(using: .utf8) {
                if let decodiert = try? DocumentPackage.decode(modifizierteDaten) {
                    let breite = decodiert.canvas.width
                    if breite.isInfinite || breite.isNaN {
                        XCTFail("Ungültige Breite dekodiert: \(breite)")
                    }
                }
            }
        }
    }

    /// Simuliert unvollständige Datenstrukturen aus älteren Versionen oder fehlerhaften
    /// Datenbank-Dumps, bei denen beliebige Felder fälschlicherweise null sind.
    func testNullEverywhereNeverCrashes() throws {
        let doc = erstelleGueltigesDokument()
        let daten = try DocumentPackage.encode(doc)
        let jsonString = try XCTUnwrap(String(data: daten, encoding: .utf8))

        let zeilen = jsonString.components(separatedBy: .newlines)
        for (index, zeile) in zeilen.enumerated() {
            if zeile.contains(":") {
                // Wir ersetzen den Wert nach dem Doppelpunkt durch null,
                // um die Robustheit gegenüber fehlenden Pflichtfeldern zu prüfen.
                let teile = zeile.components(separatedBy: ":")
                guard teile.count >= 2 else { continue }
                let schluessel = teile[0]
                let hatKomma = zeile.hasSuffix(",")
                let neueZeile = "\(schluessel): null\(hatKomma ? "," : "")"

                var modifizierteZeilen = zeilen
                modifizierteZeilen[index] = neueZeile
                let modifiziertesJson = modifizierteZeilen.joined(separator: "\n")

                if let modifizierteDaten = modifiziertesJson.data(using: .utf8) {
                    mussUeberleben(modifizierteDaten)
                }
            }
        }
    }

    /// Schützt vor Stack-Overflow-Abstürzen durch extrem tief verschachtelte Strukturen,
    /// wie sie bei gezielten Denial-of-Service-Angriffen vorkommen können.
    func testDeeplyNestedJSONNeverCrashes() throws {
        let tiefe = 1000
        let oeffnend = String(repeating: "[", count: tiefe)
        let schliessend = String(repeating: "]", count: tiefe)
        let jsonString = "{\"formatVersion\":1,\"document\":\(oeffnend)1\(schliessend)}"

        let daten = try XCTUnwrap(jsonString.data(using: .utf8))
        mussUeberleben(daten)
    }

    /// Überprüft die Skalierbarkeit und Speicherstabilität bei extrem großen Dokumenten,
    /// die aus automatisierten Massenimporten stammen könnten.
    func testHugeLayerArrayIsHandled() throws {
        let canvas = CanvasSize(width: 100, height: 100)
        // Wir verwenden eine minimale Ebene, um den Speicherbedarf während des
        // Tests gering zu halten und die reine Array-Verarbeitung zu fokussieren.
        let basisEbene = Layer(
            name: "Ebene",
            content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 1, height: 1)))
        )
        let ebenen = Array(repeating: basisEbene, count: 50_000)
        let doc = Document(canvas: canvas, layers: ebenen)

        let daten = try DocumentPackage.encode(doc)
        let decodiert = try DocumentPackage.decode(daten)

        XCTAssertEqual(decodiert.layers.count, 50_000)
    }

    /// Verhindert Pufferüberläufe und übermäßigen Speicherverbrauch bei unerwartet
    /// langen Textfeldern, die durch Fehlbedienung oder Skripte entstehen.
    func testVeryLongStringsAreHandled() throws {
        let langerText = String(repeating: "A", count: 200_000)
        let langerName = String(repeating: "B", count: 100_000)

        let canvas = CanvasSize(width: 800, height: 600)
        let textContent = TextLayerContent(string: langerText)
        let layer = Layer(name: langerName, content: .text(textContent))
        let doc = Document(canvas: canvas, layers: [layer])

        let daten = try DocumentPackage.encode(doc)
        let decodiert = try DocumentPackage.decode(daten)

        XCTAssertEqual(decodiert.layers.first?.name.count, 100_000)
        if case let .text(content) = decodiert.layers.first?.content {
            XCTAssertEqual(content.string.count, 200_000)
        } else {
            XCTFail("Inhaltstyp hat sich verändert")
        }
    }

    /// Schützt vor Directory-Traversal-Angriffen, bei denen manipulierte Pfade
    /// den Zugriff auf sensible Systemdateien außerhalb des Sandboxes erzwingen wollen.
    func testPathTraversalReferencesAreTreatedAsPlainNames() throws {
        let canvas = CanvasSize(width: 800, height: 600)
        let imageContent = ImageLayerContent(originalFileReference: "../../../etc/passwd")
        let layer = Layer(name: "Angriff", content: .image(imageContent))
        let doc = Document(canvas: canvas, layers: [layer])

        let daten = try DocumentPackage.encode(doc)
        let decodiert = try DocumentPackage.decode(daten)

        // Der Pfad muss exakt so erhalten bleiben, da er später nur als Schlüssel
        // in einem isolierten In-Memory-Wörterbuch dient. Ein direkter Zugriff auf
        // das Dateisystem findet über diese Referenz niemals statt.
        XCTAssertEqual(decodiert.referencedFileNames.first, "../../../etc/passwd")
    }

    /// Stellt sicher, dass strukturell leere oder ungültige Datenströme sofort
    /// und sauber abgewiesen werden, statt undefiniertes Verhalten auszulösen.
    func testEmptyAndWhitespaceDataAreRejected() throws {
        let testStrings = [" ", "{}", "[]", "null", "nicht json"]
        var testFaelle = [Data()]

        for string in testStrings {
            let daten = try XCTUnwrap(string.data(using: .utf8))
            testFaelle.append(daten)
        }

        for daten in testFaelle {
            XCTAssertThrowsError(try DocumentPackage.decode(daten))
        }
    }
}
