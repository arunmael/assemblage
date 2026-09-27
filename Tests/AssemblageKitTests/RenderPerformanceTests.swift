import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Unveränderte Render-Ergebnisse bleiben erhalten; Bilder laden ohne blockierenden Aufbau.
@MainActor
final class RenderPerformanceTests: XCTestCase {
    private func bildDaten(width: Int = 80, height: Int = 40, weiss: CGFloat = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: weiss, green: weiss, blue: weiss, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            .representation(using: .png, properties: [:]))
    }

    private func ansicht(_ document: AssemblageModel.Document, images: ImageStore) -> CanvasView {
        let view = CanvasView(document: document, images: images)
        view.layer?.layoutIfNeeded()
        return view
    }

    private func schichten(_ view: CanvasView) throws -> [CALayer] {
        try XCTUnwrap(view.layer?.sublayers?.first?.sublayers)
    }

    private func bildEbene(_ referenz: String) -> Layer {
        Layer(name: "Foto", content: .image(ImageLayerContent(originalFileReference: referenz)))
    }

    private func formEbene(_ name: String) -> Layer {
        Layer(name: name, content: .shape(ShapeLayerContent(
            kind: .rectangle, size: Size(width: 80, height: 40)
        )))
    }

    func testVerschiebenBehaeltBeideMaskenUndIhreInhalte() throws {
        let resources = DocumentResources()
        let referenz = resources.addOriginal(try bildDaten(), fileExtension: "png")
        let maskenReferenz = resources.addMask(try bildDaten())
        var ebene = bildEbene(referenz)
        ebene.mask = LayerMask(maskImageReference: maskenReferenz, source: .manualBrush)
        var andere = bildEbene(referenz)
        andere.mask = ebene.mask
        var document = AssemblageModel.Document(canvas: CanvasSize(width: 400, height: 400), layers: [ebene, andere])
        let view = ansicht(document, images: ImageStore(resources: resources))
        let vorher = try schichten(view)
        let masken = try vorher.map { try XCTUnwrap(($0 as? ImageContentLayer)?.bitmap.mask) }
        let inhalte = try masken.map { try XCTUnwrap($0.contents) as AnyObject }

        document.layers[0].transform.x += 30
        view.update(to: document)

        let nachher = try schichten(view)
        XCTAssertEqual(nachher.count, 2)
        for (index, schicht) in nachher.enumerated() {
            let maske = try XCTUnwrap((schicht as? ImageContentLayer)?.bitmap.mask)
            XCTAssertTrue(maske === masken[index], "Verschieben darf keine Maske neu erzeugen")
            XCTAssertTrue(try XCTUnwrap(maske.contents) as AnyObject === inhalte[index])
        }
        XCTAssertEqual(nachher.first?.position.x, CGFloat(document.layers[0].transform.x))
    }

    func testNeueMaskenReferenzErsetztDenMaskenInhalt() throws {
        let resources = DocumentResources()
        let referenz = resources.addOriginal(try bildDaten(), fileExtension: "png")
        var ebene = bildEbene(referenz)
        ebene.mask = LayerMask(maskImageReference: resources.addMask(try bildDaten()), source: .manualBrush)
        var document = AssemblageModel.Document(canvas: CanvasSize(width: 400, height: 400), layers: [ebene])
        let view = ansicht(document, images: ImageStore(resources: resources))
        let schicht = try XCTUnwrap(try schichten(view).first as? ImageContentLayer)
        let vorher = try XCTUnwrap(schicht.bitmap.mask?.contents) as AnyObject

        document.layers[0].mask = LayerMask(
            maskImageReference: resources.addMask(try bildDaten(weiss: 0)), source: .manualBrush
        )
        view.update(to: document)

        let aktualisiert = try XCTUnwrap(try schichten(view).first as? ImageContentLayer)
        let nachher = try XCTUnwrap(aktualisiert.bitmap.mask?.contents) as AnyObject
        XCTAssertFalse(vorher === nachher, "Eine neue Maske muss neu gerendert werden")
    }

    func testHinzufuegenLoeschenUndUmsortierenVerwendetSchichtenWeiter() throws {
        var document = AssemblageModel.Document(canvas: CanvasSize(width: 400, height: 400), layers: [formEbene("A"), formEbene("B")])
        let view = ansicht(document, images: ImageStore(resources: DocumentResources()))
        let vorher = try schichten(view)
        XCTAssertEqual(vorher.count, 2)
        let a = try XCTUnwrap(vorher.first)
        let b = try XCTUnwrap(vorher.last)

        document.layers.insert(formEbene("C"), at: 1)
        view.update(to: document)
        let hinzugefuegt = try schichten(view)
        XCTAssertEqual(hinzugefuegt.count, 3)
        XCTAssertTrue(hinzugefuegt.first === a)
        XCTAssertTrue(hinzugefuegt.last === b)
        let c = try XCTUnwrap(hinzugefuegt.dropFirst().first)
        XCTAssertFalse(c === a)
        XCTAssertFalse(c === b)

        document.layers.remove(at: 0)
        view.update(to: document)
        let geloescht = try schichten(view)
        XCTAssertEqual(geloescht.count, 2)
        XCTAssertTrue(geloescht.first === c)
        XCTAssertTrue(geloescht.last === b)
        XCTAssertNil(a.superlayer, "Nur die gelöschte Ebene verliert ihre Schicht")

        document.layers.swapAt(0, 1)
        view.update(to: document)
        let umsortiert = try schichten(view)
        XCTAssertEqual(umsortiert.count, 2)
        XCTAssertTrue(umsortiert.first === b)
        XCTAssertTrue(umsortiert.last === c)
    }

    func testSichtbarkeitWirdInBeideRichtungenAktualisiert() throws {
        var document = AssemblageModel.Document(canvas: CanvasSize(width: 400, height: 400), layers: [formEbene("Form")])
        let view = ansicht(document, images: ImageStore(resources: DocumentResources()))
        XCTAssertFalse(try XCTUnwrap(schichten(view).first).isHidden)

        document.layers[0].isVisible = false
        view.update(to: document)
        XCTAssertTrue(try XCTUnwrap(schichten(view).first).isHidden)

        document.layers[0].isVisible = true
        view.update(to: document)
        XCTAssertFalse(try XCTUnwrap(schichten(view).first).isHidden)
    }

    func testHintergrundladenBedientBeideAnfragenMitDemselbenBild() throws {
        let resources = DocumentResources()
        let referenz = resources.addOriginal(try bildDaten(), fileExtension: "png")
        let speicher = ImageStore(resources: resources, loadsInBackground: true)
        let ersterRueckruf = expectation(description: "Erste Anfrage geladen")
        let zweiterRueckruf = expectation(description: "Zweite Anfrage geladen")

        // Ohne Runloop dazwischen bleiben beide Anfragen im selben Ladevorgang.
        for rueckruf in [ersterRueckruf, zweiterRueckruf] {
            let status = speicher.availability(of: referenz) { name in
                XCTAssertEqual(name, referenz)
                rueckruf.fulfill()
            }
            guard case .loading = status else { return XCTFail("Zunächst muss das Bild laden") }
        }
        wait(for: [ersterRueckruf, zweiterRueckruf], timeout: 5)

        guard case .ready(let erstes) = speicher.availability(of: referenz, whenLoaded: { _ in
            XCTFail("Ein fertiges Bild braucht keinen Rückruf")
        }), case .ready(let zweites) = speicher.availability(of: referenz, whenLoaded: { _ in
            XCTFail("Ein fertiges Bild braucht keinen Rückruf")
        }) else { return XCTFail("Nach den Rückrufen muss das Bild bereit sein") }
        XCTAssertTrue(erstes === zweites, "Beide Anfragen verwenden dasselbe dekodierte Bild")
    }

    func testKaputteUndFehlendeOriginaleSindNichtDarstellbar() {
        let resources = DocumentResources()
        let referenz = resources.addOriginal(Data([0, 1]), fileExtension: "png")
        let speicher = ImageStore(resources: resources, loadsInBackground: true)
        let geladen = expectation(description: "Dekodierversuch abgeschlossen")
        let status = speicher.availability(of: referenz) { name in
            XCTAssertEqual(name, referenz)
            geladen.fulfill()
        }
        guard case .loading = status else { return XCTFail("Der Dekodierversuch startet im Hintergrund") }
        wait(for: [geladen], timeout: 5)

        guard case .unavailable = speicher.availability(of: referenz, whenLoaded: { _ in
            XCTFail("Kaputte Daten dürfen nicht erneut geladen werden")
        }) else { return XCTFail("Kaputte Daten müssen als nicht verfügbar gelten") }
        XCTAssertFalse(speicher.canDisplay(named: referenz))
        XCTAssertFalse(speicher.canDisplay(named: "originals/fehlt.png"))
    }

    func testCanvasKenntDieOriginalgroesseSchonWaehrendDesLadens() throws {
        let resources = DocumentResources()
        let referenz = resources.addOriginal(try bildDaten(width: 400, height: 200), fileExtension: "png")
        let speicher = ImageStore(resources: resources, loadsInBackground: true)
        let view = ansicht(AssemblageModel.Document(canvas: CanvasSize(width: 400, height: 400), layers: [bildEbene(referenz)]), images: speicher)
        let schicht = try XCTUnwrap(try schichten(view).first as? ImageContentLayer)
        XCTAssertNil(schicht.displayedReference)
        XCTAssertNil(schicht.bitmap.contents)
        XCTAssertEqual(schicht.bounds.size, CGSize(width: 400, height: 200))

        let frist = Date().addingTimeInterval(5)
        while (schicht.bitmap.contents == nil || schicht.displayedReference == nil), Date() < frist {
            RunLoop.main.run(until: min(frist, Date().addingTimeInterval(0.01)))
        }

        XCTAssertNotNil(schicht.bitmap.contents, "Das Bild muss innerhalb von fünf Sekunden erscheinen")
        XCTAssertEqual(schicht.displayedReference, referenz)
        XCTAssertEqual(schicht.bounds.size, CGSize(width: 400, height: 200))
        XCTAssertTrue(try schichten(view).first === schicht)
    }

    func testVorschaubildHatHoechstens96PixelKantenlaenge() async throws {
        let resources = DocumentResources()
        let referenz = resources.addOriginal(try bildDaten(width: 400, height: 200), fileExtension: "png")
        let speicher = ImageStore(resources: resources, loadsInBackground: true)
        let ergebnis = await speicher.thumbnail(named: referenz)
        let bild = try XCTUnwrap(ergebnis)

        XCTAssertGreaterThan(bild.width, 0)
        XCTAssertGreaterThan(bild.height, 0)
        XCTAssertLessThanOrEqual(max(bild.width, bild.height), 96)
        XCTAssertEqual(bild.width, bild.height * 2, "Das Seitenverhältnis bleibt erhalten")
    }
}
