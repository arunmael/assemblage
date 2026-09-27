import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Auflösungsstufen sparen Speicher, ohne sichtbare Bilder unnötig zu verkleinern.
@MainActor
final class ResolutionTierTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated {
            MemoryPressure.shared.report(.normal)
        }
        super.tearDown()
    }

    private func bildDaten(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            .representation(using: .png, properties: [:]))
    }

    private func fensterMitBildebenen() throws -> (
        fenster: NSWindow, view: CanvasView, sichtbar: ImageContentLayer, unsichtbar: ImageContentLayer
    ) {
        _ = NSApplication.shared
        MemoryPressure.shared.report(.normal)
        let resources = DocumentResources()
        let referenz = resources.addOriginal(try bildDaten(width: 2000, height: 1000), fileExtension: "png")
        var sichtbar = Layer(name: "Sichtbar", content: .image(ImageLayerContent(originalFileReference: referenz)))
        sichtbar.transform.x = 200
        sichtbar.transform.y = 150
        var unsichtbar = Layer(name: "Ausserhalb", content: .image(ImageLayerContent(originalFileReference: referenz)))
        unsichtbar.transform.x = 3500
        unsichtbar.transform.y = 150
        // init ruft rebuild(), nicht update(to:) auf: lastTouched bleibt leer.
        // Auch keine Auswahl setzen, damit keine 120-Sekunden-Schonfrist beginnt.
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 4000, height: 300), layers: [sichtbar, unsichtbar]
        )
        let view = CanvasView(document: document, images: ImageStore(resources: resources, loadsInBackground: false))
        let fenster = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        fenster.isReleasedWhenClosed = false
        // Auch bei einem fehlgeschlagenen XCTUnwrap das Fenster aufräumen.
        addTeardownBlock { @MainActor in
            fenster.contentView = nil
            fenster.close()
        }
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.documentView = view
        fenster.contentView = scrollView
        fenster.orderFront(nil)
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        view.layer?.layoutIfNeeded()
        XCTAssertTrue(view.window === fenster)
        XCTAssertNil(view.selectedLayerID)
        XCTAssertFalse(view.visibleRect.isEmpty)
        XCTAssertLessThanOrEqual(view.visibleRect.width, 400)
        XCTAssertEqual(view.visibleRect.minX, 0, accuracy: 0.001)
        let schichten = try XCTUnwrap(view.layer?.sublayers?.first?.sublayers)
        XCTAssertEqual(schichten.count, 2)
        return (
            fenster, view,
            try XCTUnwrap(schichten.first as? ImageContentLayer),
            try XCTUnwrap(schichten.last as? ImageContentLayer)
        )
    }

    func testStufenGrenzenUndUnendlichePixelkante() {
        let faelle: [(CGFloat, Int)] = [
            (1, 256), (256, 256), (257, 1024), (3000, 4096), (99999, 4096), (.infinity, 4096)
        ]
        for (kante, stufe) in faelle {
            XCTAssertEqual(ImageStore.tier(forPixelEdge: kante), stufe, "Pixelkante: \(kante)")
        }
    }

    func testEffektiveStufeFasstFassungenAbOriginalgroesseZusammen() throws {
        let resources = DocumentResources()
        let klein = resources.addOriginal(try bildDaten(width: 800, height: 600), fileExtension: "png")
        let gross = resources.addOriginal(try bildDaten(width: 5000, height: 100), fileExtension: "png")
        let images = ImageStore(resources: resources, loadsInBackground: false)
        for stufe in [1024, 2048, 4096] {
            XCTAssertEqual(images.effectiveTier(stufe, for: klein), ImageStore.fullTier)
        }
        XCTAssertEqual(images.effectiveTier(256, for: klein), 256)
        XCTAssertEqual(images.effectiveTier(1024, for: gross), 1024)
    }

    func testSynchronesLadenBegrenztKantenUndVerwendetStufenCache() throws {
        let resources = DocumentResources()
        let referenz = resources.addOriginal(try bildDaten(width: 3000, height: 1500), fileExtension: "png")
        let images = ImageStore(resources: resources, loadsInBackground: false)
        func bild(stufe: Int) throws -> CGImage {
            guard case .ready(let bild) = images.availability(of: referenz, tier: stufe, whenLoaded: { _ in
                XCTFail("Synchrones Laden braucht keinen Rückruf")
            }) else {
                XCTFail("Stufe \(stufe) muss sofort bereit sein")
                throw NSError(domain: "ResolutionTierTests", code: 1)
            }
            return bild
        }
        let klein = try bild(stufe: 1024)
        let gross = try bild(stufe: 4096)
        XCTAssertLessThanOrEqual(max(klein.width, klein.height), 1024)
        XCTAssertEqual(max(gross.width, gross.height), 3000)
        XCTAssertFalse(klein === gross)
        XCTAssertTrue(klein === (try bild(stufe: 1024)))
    }

    func testUnsichtbareUnberuehrteEbeneErhaeltUngefaehreStufe() throws {
        let aufbau = try fensterMitBildebenen()
        aufbau.view.visibleRegionDidChange()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(aufbau.unsichtbar.desiredTier, 256)
        XCTAssertGreaterThan(aufbau.sichtbar.desiredTier, 256)
    }

    func testKritischerSpeicherdruckSenktSofortUndNormalStelltStufeWiederHer() throws {
        let aufbau = try fensterMitBildebenen()
        aufbau.view.visibleRegionDidChange()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let urspruenglich = aufbau.sichtbar.desiredTier
        XCTAssertGreaterThan(urspruenglich, 1024, "Die Absenkung muss tatsächlich eine kleinere Stufe wählen")

        MemoryPressure.shared.report(.critical)
        // Kein Runloop dazwischen: Speicherdruck muss synchron wirken.
        XCTAssertLessThanOrEqual(aufbau.sichtbar.desiredTier, 1024)
        XCTAssertEqual(aufbau.unsichtbar.desiredTier, 256)

        MemoryPressure.shared.report(.normal)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(aufbau.sichtbar.desiredTier, urspruenglich)
    }

    func testAlphamaskeHatAchtBitUndBegrenztePixelkante() throws {
        let resources = DocumentResources()
        let daten = try bildDaten(width: 400, height: 200)
        let referenz = resources.addOriginal(daten, fileExtension: "png")
        var ebene = Layer(name: "Maskiert", content: .image(ImageLayerContent(originalFileReference: referenz)))
        ebene.mask = LayerMask(maskImageReference: resources.addMask(daten), source: .manualBrush)
        let bild = try XCTUnwrap(MaskRendering.alphaMaskImage(
            for: ebene, cropRect: nil, resources: resources, maxPixelEdge: 64
        ))
        XCTAssertEqual(bild.bitsPerPixel, 8)
        XCTAssertLessThanOrEqual(max(bild.width, bild.height), 64)
    }

    func testGekachelteTexturBegrenztPixelkante() throws {
        let resources = DocumentResources()
        let referenz = resources.addOriginal(try bildDaten(width: 16, height: 16), fileExtension: "png")
        let textur = LayerTexture(imageReference: referenz, blendMode: .normal, opacity: 1, scale: 1)
        let bild = try XCTUnwrap(TextureRendering.tiledImage(
            for: textur, size: CGSize(width: 4000, height: 2000), resources: resources, maxPixelEdge: 500
        ))
        XCTAssertLessThanOrEqual(max(bild.width, bild.height), 500)
    }
}
