import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import Foundation
import AssemblageModel

/// Rendert die komplette Ebenenkette eines Dokuments für den Export (Plan
/// 5.8: PNG mit Transparenz, JPEG und PDF). Bitmap- und PDF-Ausgabe verwenden
/// dieselbe `CGContext`-Zeichenlogik, damit sie nicht auseinanderlaufen.
///
/// Warum das nicht einfach `CanvasView`/`LayerRenderer` wiederverwendet:
/// Der Bildschirm-Canvas komponiert über einen `CALayer`-Baum, dessen
/// `render(in:)` **`compositingFilter` ignoriert** — ein Export über diesen
/// Weg würde also jeden Blend-Modus verlieren. Der Export zeichnet deshalb
/// jede Ebene direkt und einzeln mit `CGContext`, wobei `setBlendMode`/
/// `setAlpha` unmittelbar auf den Zeichenaufruf wirken (Pfad, Bild oder
/// Text) — anders als bei einer vorgelagerten `CALayer`-Komposition ist das
/// hier korrekt, weil kein Core-Animation-Compositor mehr dazwischenliegt.
///
/// Bewusst **kein** `@MainActor`: Das eigentliche Rendern (Bilddekodierung,
/// Pixel-Kompositing) ist rechenintensiv und darf laut Plan 2.1 die
/// Oberfläche nicht blockieren. Die öffentlichen Methoden sind `async` und
/// verlagern die Arbeit explizit auf einen Hintergrund-Task.
enum DocumentExporter {

    /// Nur als Ausweichweg, falls der systemweite GPU-Kontext die projektive
    /// Abbildung nicht bereitstellen kann (etwa ohne WindowServer).
    private static let softwareRenderContext = CIContext(options: [.useSoftwareRenderer: true])

    // MARK: - Fehler

    /// Eigener Fehlertyp statt `try!`/erzwungenem Auspacken (Plan 2.1).
    enum ExportError: Error, LocalizedError, Equatable {
        case invalidTargetSize
        case renderingFailed
        case encodingFailed
        case pdfCreationFailed

        var errorDescription: String? {
            switch self {
            case .invalidTargetSize:
                return "Die Export-Grösse muss breiter und höher als null sein."
            case .renderingFailed:
                return "Die Ebenen liessen sich nicht zu einem Bild zusammensetzen."
            case .encodingFailed:
                return "Das gerenderte Bild liess sich nicht in das Zielformat kodieren."
            case .pdfCreationFailed:
                return "Das PDF-Dokument liess sich nicht erstellen."
            }
        }
    }

    // MARK: - Zielgrösse

    /// Zielgrösse aus einem Skalierungsfaktor relativ zur Leinwand — z. B.
    /// Faktor 2 für einen @2x-Export der aktuellen Canvas-Vorlage (Plan 5.8
    /// „Export-Grössen-Presets passend zu den Canvas-Vorlagen").
    static func targetSize(forCanvas canvas: CanvasSize, scale: Double) -> CGSize {
        CGSize(width: canvas.width * scale, height: canvas.height * scale)
    }

    // MARK: - Öffentliche, asynchrone Schnittstelle

    /// Rendert die Ebenenkette in ein `CGImage` mit Transparenz (Grundlage
    /// für PNG). Frei wählbare Zielgrösse — die Leinwandgrösse ist nur die
    /// Vorgabe, nicht das Limit.
    static func image(
        of document: AssemblageModel.Document,
        resources: DocumentResources,
        targetSize: CGSize
    ) async throws -> CGImage {
        try await runOffMainActor {
            try renderedImage(of: document, resources: resources, targetSize: targetSize)
        }
    }

    /// PNG-Daten mit Transparenz — unbemalte Flächen sind durchsichtig,
    /// anders als der weisse Leinwandgrund auf dem Bildschirm-Canvas.
    static func pngData(
        of document: AssemblageModel.Document,
        resources: DocumentResources,
        targetSize: CGSize
    ) async throws -> Data {
        try await runOffMainActor {
            try encodedPNGData(of: document, resources: resources, targetSize: targetSize)
        }
    }

    /// JPEG-Daten. JPEG kennt keine Transparenz, deshalb bekommt die
    /// exportierte Fläche hier einen weissen Grund (anders als bei PNG).
    static func jpegData(
        of document: AssemblageModel.Document,
        resources: DocumentResources,
        targetSize: CGSize,
        quality: Double = 0.9
    ) async throws -> Data {
        try await runOffMainActor {
            try encodedJPEGData(of: document, resources: resources, targetSize: targetSize, quality: quality)
        }
    }

    /// PDF-Daten mit genau einer transparenten Seite. Die Seitengrösse wird
    /// in Punkten angegeben. Direktes Zeichnen in den PDF-Kontext erhält
    /// Text und Formen als Vektoren; nur Bildebenen und Masken bleiben ihrer
    /// Natur entsprechend Rasterdaten.
    static func pdfData(
        of document: AssemblageModel.Document,
        resources: DocumentResources,
        pageSize: CGSize
    ) async throws -> Data {
        try await runOffMainActor {
            try encodedPDFData(of: document, resources: resources, pageSize: pageSize)
        }
    }

    /// Verlagert eine wirft-fähige, nicht-Sendable-freie Berechnung auf einen
    /// Hintergrund-Task. `@unchecked Sendable`-Fracht ist hier vertretbar wie
    /// beim `ParsedContents`-Muster in `AssemblageDocument.swift`: das
    /// Ergebnis wird genau einmal erzeugt und über die Task-Grenze gereicht,
    /// nie gleichzeitig von zwei Seiten angefasst.
    private static func runOffMainActor<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try body()
        }.value
    }

    // MARK: - Synchroner Kern

    /// Der eigentliche Renderer — bewusst frei von `@MainActor` und ohne
    /// jede Abhängigkeit von `CanvasView`/`LayerRenderer`, damit er auf
    /// einem Hintergrund-Task laufen kann.
    static func renderedImage(
        of document: AssemblageModel.Document,
        resources: DocumentResources,
        targetSize: CGSize
    ) throws -> CGImage {
        guard targetSize.width > 0, targetSize.height > 0 else {
            throw ExportError.invalidTargetSize
        }
        guard let context = makeTransparentContext(size: targetSize) else {
            throw ExportError.renderingFailed
        }

        drawDocument(document, resources: resources, targetSize: targetSize, into: context)

        guard let image = context.makeImage() else { throw ExportError.renderingFailed }
        return image
    }

    /// Gemeinsamer Zeichenpfad für Bitmap und PDF. Der Zielkontext bestimmt,
    /// ob Pfade und Text als Pixel oder als Vektoren ausgegeben werden.
    private static func drawDocument(
        _ document: AssemblageModel.Document,
        resources: DocumentResources,
        targetSize: CGSize,
        into context: CGContext
    ) {
        // Eine Leinwand mit Grösse null hat kein sinnvolles Koordinatensystem.
        // In diesem Fall bleibt das Ziel leer, statt den Export wegen
        // fehlender Inhalte scheitern zu lassen (Plan 2.1).
        if document.canvas.width > 0, document.canvas.height > 0 {
            let exportScale = CGSize(
                width: targetSize.width / CGFloat(document.canvas.width),
                height: targetSize.height / CGFloat(document.canvas.height)
            )
            // Reihenfolge im Modell = Kompositing-Reihenfolge, Index 0
            // zuunterst — dieselbe Regel wie bei `CanvasView.rebuild()`.
            for layer in document.layers where layer.isVisible {
                context.saveGState()
                context.setAlpha(CGFloat(layer.opacity.clamped(to: 0...1)))
                context.setBlendMode(layer.blendMode.cgBlendMode)

                if let effekte = layer.effects, effekte.isActive {
                    drawWithEffects(
                        layer,
                        effects: effekte,
                        canvasHeight: document.canvas.height,
                        targetSize: targetSize,
                        exportScale: exportScale,
                        resources: resources,
                        into: context
                    )
                } else {
                    draw(
                        layer,
                        canvasHeight: document.canvas.height,
                        targetSize: targetSize,
                        exportScale: exportScale,
                        resources: resources,
                        into: context
                    )
                }
                context.restoreGState()
            }
        }
    }

    private static func encodedPNGData(
        of document: AssemblageModel.Document,
        resources: DocumentResources,
        targetSize: CGSize
    ) throws -> Data {
        let image = try renderedImage(of: document, resources: resources, targetSize: targetSize)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ExportError.encodingFailed
        }
        return data
    }

    private static func encodedJPEGData(
        of document: AssemblageModel.Document,
        resources: DocumentResources,
        targetSize: CGSize,
        quality: Double
    ) throws -> Data {
        let composited = try renderedImage(of: document, resources: resources, targetSize: targetSize)

        // JPEG kennt keine Transparenz: erst auf weissem Grund flach drücken,
        // sonst würde jeder Betrachter die fehlenden Pixel schwarz zeigen.
        guard let flattened = makeTransparentContext(size: targetSize) else {
            throw ExportError.renderingFailed
        }
        flattened.setFillColor(CGColor(gray: 1, alpha: 1))
        flattened.fill(CGRect(origin: .zero, size: targetSize))
        flattened.draw(composited, in: CGRect(origin: .zero, size: targetSize))

        guard let flattenedImage = flattened.makeImage() else { throw ExportError.renderingFailed }
        guard let data = NSBitmapImageRep(cgImage: flattenedImage)
            .representation(using: .jpeg, properties: [.compressionFactor: quality])
        else {
            throw ExportError.encodingFailed
        }
        return data
    }

    private static func encodedPDFData(
        of document: AssemblageModel.Document,
        resources: DocumentResources,
        pageSize: CGSize
    ) throws -> Data {
        guard pageSize.width > 0, pageSize.height > 0 else {
            throw ExportError.invalidTargetSize
        }

        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else {
            throw ExportError.pdfCreationFailed
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.pdfCreationFailed
        }

        context.beginPDFPage(nil)
        drawDocument(document, resources: resources, targetSize: pageSize, into: context)
        context.endPDFPage()
        context.closePDF()

        guard mutableData.length > 0 else { throw ExportError.pdfCreationFailed }
        return mutableData as Data
    }

    // MARK: - Eine Ebene zeichnen

    /// Platziert eine Ebene im Zielkontext.
    ///
    /// Bewusst **kein** globaler Geometrie-Flip des Kontexts (anders als
    /// `canvasLayer.isGeometryFlipped` bei `CanvasView`): Position und
    /// Drehung lassen sich auch so korrekt nachbilden, indem nur die
    /// *Position* vom Modell (Ursprung oben links, y nach unten) in
    /// Core-Graphics-Koordinaten (Ursprung unten links, y nach oben)
    /// umgerechnet wird — Rotation braucht dabei kein umgekehrtes Vorzeichen,
    /// weil beide Koordinatensysteme rechtshändig bleiben. Ergebnis wie auf
    /// dem Bildschirm: ein positiver Winkel dreht im Uhrzeigersinn.
    ///
    /// Einzig Bildinhalte brauchen eine Korrektur: `CGContext.draw(_:in:)`
    /// zeichnet ein `CGImage` empirisch verkehrt herum, wenn der Kontext
    /// (wie hier) keinen eigenen Geometrie-Flip trägt — das gleicht
    /// `drawImage(_:in:resources:context:)` lokal wieder aus, statt es hier
    /// pauschal für alle Inhaltstypen zu tun (Formen und Text bräuchten den
    /// Ausgleich nicht und würden durch ihn verkehrt herum landen).
    /// Zeichnet eine Ebene samt Leuchten und Schlagschatten.
    ///
    /// Beide brauchen die **Silhouette** der fertigen Ebene, nicht ihren
    /// rechteckigen Rahmen — sonst bekäme ein freigestelltes Foto einen
    /// rechteckigen Schatten. Deshalb wird die Ebene erst allein in eine
    /// durchsichtige Fläche gezeichnet, daraus der Effekt gebildet und das
    /// Ganze anschliessend eingesetzt.
    ///
    /// Das kostet eine Zwischenfläche in Zielgrösse. Vertretbar, weil es nur
    /// Ebenen mit tatsächlich wirksamen Effekten trifft — `isActive` filtert
    /// vorher.
    private static func drawWithEffects(
        _ layer: Layer,
        effects: LayerEffects,
        canvasHeight: Double,
        targetSize: CGSize,
        exportScale: CGSize,
        resources: DocumentResources,
        into context: CGContext
    ) {
        guard let zwischen = makeTransparentContext(size: targetSize) else {
            // Reicht der Speicher nicht, lieber die Ebene ohne Effekt zeigen
            // als den ganzen Export scheitern zu lassen (Plan 2.1).
            draw(layer, canvasHeight: canvasHeight, targetSize: targetSize,
                 exportScale: exportScale, resources: resources, into: context)
            return
        }

        draw(layer, canvasHeight: canvasHeight, targetSize: targetSize,
             exportScale: exportScale, resources: resources, into: zwischen)

        guard let roh = zwischen.makeImage() else { return }
        let mitEffekt = EffectsRendering.apply(effects, to: CIImage(cgImage: roh))

        guard let fertig = RenderContext.shared.createCGImage(
            mitEffekt,
            from: CGRect(origin: .zero, size: targetSize)
        ) else { return }

        // Wie bei den anderen Core-Image-Ergebnissen: Das Zeichnen in einen
        // ungeflippten Quartz-Kontext kippt das Bild, deshalb lokal
        // gegenspiegeln. (Dieselbe Falle wie bei Bildern, Text und Verziehen.)
        let ziel = CGRect(origin: .zero, size: targetSize)
        context.saveGState()
        context.translateBy(x: 0, y: targetSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(fertig, in: ziel)
        context.restoreGState()
    }

    private static func draw(
        _ layer: Layer,
        canvasHeight: Double,
        targetSize: CGSize,
        exportScale: CGSize,
        resources: DocumentResources,
        into context: CGContext
    ) {
        let contentSize = self.contentSize(of: layer.content, resources: resources)
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        // Projektives Zeichnen arbeitet auf einem Bild. Das Zwischenbild ist
        // absichtlich nur für echte Verzerrungen nötig; der häufige Normalfall
        // bleibt auf dem bisherigen direkten Vektor-/Bildpfad.
        if let distortion = layer.distortion, !distortion.isIdentity {
            drawDistorted(
               layer,
               distortion: distortion,
               contentSize: contentSize,
               canvasHeight: canvasHeight,
               targetSize: targetSize,
               exportScale: exportScale,
               resources: resources,
               into: context
            )
            return
        }

        let centreX = CGFloat(layer.transform.x) * exportScale.width
        let centreY = CGFloat(canvasHeight - layer.transform.y) * exportScale.height
        let radians = CGFloat(layer.transform.rotationDegrees * .pi / 180)

        // Skalierung 0 machte auch beim Bildschirm-Canvas die Matrix
        // unumkehrbar (siehe `Transform2D.renderTransform`) — hier dieselbe
        // Ausweichlösung, damit die Ebene auffindbar bleibt statt zu
        // verschwinden.
        let scaleX = layer.transform.scaleX == 0 ? CGFloat.leastNormalMagnitude : CGFloat(layer.transform.scaleX)
        let scaleY = layer.transform.scaleY == 0 ? CGFloat.leastNormalMagnitude : CGFloat(layer.transform.scaleY)

        context.saveGState()
        context.translateBy(x: centreX, y: centreY)
        context.rotate(by: radians)
        context.scaleBy(x: scaleX * exportScale.width, y: scaleY * exportScale.height)

        let rect = CGRect(
            x: -contentSize.width / 2,
            y: -contentSize.height / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        drawContent(layer.content, texture: layer.texture, in: rect, resources: resources,
                    context: context, mask: maskImage(for: layer, resources: resources))

        context.restoreGState()
    }

    /// Rendert jeden Inhaltstyp zuerst in eine transparente Bitmap und legt
    /// diese danach mit Core Images projektiver Abbildung auf die vier
    /// Modellecken. Damit folgen Bild, Text und Form exakt derselben Geometrie.
    private static func drawDistorted(
        _ layer: Layer,
        distortion: QuadDistortion,
        contentSize: CGSize,
        canvasHeight: Double,
        targetSize: CGSize,
        exportScale: CGSize,
        resources: DocumentResources,
        into context: CGContext
    ) {
        let rasterScale = max(
            abs(layer.transform.scaleX) * exportScale.width,
            abs(layer.transform.scaleY) * exportScale.height,
            1
        )
        let contentWidth = contentSize.width * rasterScale
        let contentHeight = contentSize.height * rasterScale
        let width = Int(contentWidth.rounded(.up))
        let height = Int(contentHeight.rounded(.up))
        guard width > 0, height > 0,
              let sourceContext = makeTransparentContext(size: CGSize(width: width, height: height))
        else { return }

        sourceContext.scaleBy(x: rasterScale, y: rasterScale)
        let sourceRect = CGRect(origin: .zero, size: contentSize)
        drawContent(
            layer.content,
            texture: layer.texture,
            in: sourceRect,
            resources: resources,
            context: sourceContext,
            mask: maskImage(for: layer, resources: resources)
        )
        guard let sourceImage = sourceContext.makeImage() else { return }

        let modelCorners = layer.transform.corners(
            contentSize: Size(contentSize),
            distortion: distortion
        )
        guard modelCorners.count == 4 else { return }
        let corners = modelCorners.map {
            CGPoint(
                x: $0.x * exportScale.width,
                y: (canvasHeight - $0.y) * exportScale.height
            )
        }
        let destinationIndices: [Int]
        switch (layer.transform.scaleX < 0, layer.transform.scaleY < 0) {
        case (false, false): destinationIndices = [0, 1, 2, 3]
        case (true, false): destinationIndices = [1, 0, 3, 2]
        case (false, true): destinationIndices = [3, 2, 1, 0]
        case (true, true): destinationIndices = [2, 3, 0, 1]
        }

        drawPerspectiveImage(
            sourceImage,
            corners: destinationIndices.map { corners[$0] },
            targetSize: targetSize,
            into: context
        )
    }

    /// Zeichnet ein Bild über genau denselben projektiven Pfad, den der
    /// Export für verzogene Ebenen verwendet. Die interne Sichtbarkeit hält
    /// den Identitätstest unabhängig von einer Modellverzerrung: Im normalen
    /// Export wird dieser teurere Pfad weiterhin nur bei echter Verzerrung
    /// aufgerufen.
    static func drawPerspectiveImage(
        _ sourceImage: CGImage,
        corners: [CGPoint],
        targetSize: CGSize,
        into context: CGContext
    ) {
        guard corners.count == 4 else { return }
        let warped = CIImage(cgImage: sourceImage).applyingFilter(
            "CIPerspectiveTransform",
            parameters: [
                "inputTopLeft": CIVector(cgPoint: corners[0]),
                "inputTopRight": CIVector(cgPoint: corners[1]),
                "inputBottomRight": CIVector(cgPoint: corners[2]),
                "inputBottomLeft": CIVector(cgPoint: corners[3])
            ]
        )
        // Ein PDF-Kontext meldet für `width`/`height` null; die vom Aufrufer
        // bekannte Zielgrösse funktioniert für Bitmap und PDF gleichermassen.
        let targetBounds = CGRect(origin: .zero, size: targetSize)
        let extent = warped.extent.intersection(targetBounds).integral
        guard !extent.isNull, !extent.isEmpty,
              let output = RenderContext.shared.createCGImage(warped, from: extent)
                ?? softwareRenderContext.createCGImage(warped, from: extent)
        else { return }

        context.interpolationQuality = .high
        // `CIContext.createCGImage` liefert wie ein dekodiertes `CGImage`
        // Zeilen in Bildkoordinaten. Direkt in den ungeflippten Quartz-
        // Kontext gezeichnet würde das verzogene Viereck innerhalb seiner
        // Umschliessenden vertikal gespiegelt. Zusätzlich liegt `extent` in
        // Core-Image-Koordinaten: Seine untere y-Kante muss deshalb aus der
        // oberen Kante in Quartz-Koordinaten berechnet werden. Bei einem
        // asymmetrischen Viereck sind `extent.minY` und diese Zielposition
        // verschieden; dieselbe Zahl für beide verschob den Export sichtbar.
        let drawingRect = CGRect(
            x: extent.minX,
            y: targetSize.height - extent.maxY,
            width: extent.width,
            height: extent.height
        )
        context.saveGState()
        context.translateBy(x: drawingRect.midX, y: drawingRect.midY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -drawingRect.midX, y: -drawingRect.midY)
        context.draw(output, in: drawingRect)
        context.restoreGState()
    }

    // MARK: - Inhaltsgrösse

    /// Entspricht `LayerRenderer.contentSize(of:)`, hier unabhängig
    /// nachgebildet, damit der Export ohne den `@MainActor`-gebundenen
    /// Bildschirm-Renderer auskommt. Bildebenen liefern hier bewusst ihre
    /// volle Auflösung, nicht die Bildschirmauflösung — genau das ist der
    /// Sinn eines hochauflösenden Exports.
    private static func contentSize(of content: LayerContent, resources: DocumentResources) -> CGSize {
        switch content {
        case .image(let image):
            if let crop = image.cropRect {
                return CGSize(width: crop.width, height: crop.height)
            }
            guard let loaded = loadImage(named: image.originalFileReference, resources: resources) else {
                // Derselbe Platzhalter-Massstab wie `LayerRenderer`, damit
                // eine fehlende Originaldatei nicht unauffindbar wird.
                return CGSize(width: 320, height: 320)
            }
            return CGSize(width: loaded.width, height: loaded.height)

        case .text(let text):
            return TextLayout.naturalSize(of: text)

        case .shape(let shape):
            return shape.size.cgSize
        }
    }

    // MARK: - Inhaltstypen zeichnen

    /// Die wirksame Maske einer Ebene (Plan 5.4), bereits auf den Zuschnitt
    /// beschnitten und bei Bedarf umgekehrt. `nil` heisst „keine Maske" und
    /// nicht „alles ausblenden".
    private static func maskImage(for layer: Layer, resources: DocumentResources) -> CGImage? {
        let ausschnitt: Rect?
        if case .image(let inhalt) = layer.content {
            ausschnitt = inhalt.cropRect
        } else {
            ausschnitt = nil
        }
        return MaskRendering.grayMaskImage(for: layer, cropRect: ausschnitt, resources: resources)
    }

    private static func drawContent(
        _ content: LayerContent,
        texture: LayerTexture? = nil,
        in rect: CGRect,
        resources: DocumentResources,
        context: CGContext,
        mask: CGImage?
    ) {
        // Maske als Beschnitt des Zeichenbereichs: `CGContext.clip(to:mask:)`
        // nimmt die Graustufen der Maske als Deckung — genau die Wirkung, die
        // Plan 7.3 mit CIBlendWithMask beschreibt, nur ohne für jede Ebene ein
        // Zwischenbild anlegen zu müssen.
        if let mask {
            context.saveGState()
            context.clip(to: rect, mask: mask)
        }
        defer { if mask != nil { context.restoreGState() } }

        switch content {
        case .image(let image):
            drawImage(image, in: rect, resources: resources, context: context)
        case .text(let text):
            drawText(text, in: rect, context: context)
        case .shape(let shape):
            drawShape(shape, in: rect, context: context)
        }

        if let texture {
            drawTexture(texture, over: content, in: rect, resources: resources, context: context)
        }
    }

    /// Legt die Textur über den bereits gezeichneten Inhalt.
    ///
    /// Hier und nicht weiter aussen, aus drei Gründen: Die Textur landet damit
    /// innerhalb des Maskenbeschnitts, eine maskierte Ebene bekommt also auch
    /// eine maskierte Textur; eine verzogene Ebene rastert über denselben Weg,
    /// die Textur verzieht sich also mit; und es braucht keine Zwischenfläche
    /// in Leinwandgrösse.
    private static func drawTexture(
        _ texture: LayerTexture,
        over content: LayerContent,
        in rect: CGRect,
        resources: DocumentResources,
        context: CGContext
    ) {
        let werte = texture.clamped()
        guard werte.opacity > 0,
              let gekachelt = TextureRendering.tiledImage(
                  for: werte, size: rect.size, resources: resources)
        else { return }

        context.saveGState()
        defer { context.restoreGState() }

        // Auf die Silhouette des Inhalts beschneiden: Bei einem freigestellten
        // Motiv darf die Textur nicht über dessen Rand hinaus in den leeren
        // Rahmen laufen. Auf dem Bildschirm leistet dasselbe die Maske der
        // Texturschicht in `LayerRenderer.applyTexture`.
        if let silhouette = silhouetteMask(of: content, size: rect.size, resources: resources) {
            context.clip(to: rect, mask: silhouette)
        }

        context.setBlendMode(werte.blendMode.cgBlendMode)
        context.setAlpha(CGFloat(werte.opacity))
        context.interpolationQuality = .high

        // Dieselbe lokale Spiegelung wie bei Bildinhalten — aus demselben
        // Grund, siehe `drawImage(_:in:resources:context:)`.
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -rect.midX, y: -rect.midY)
        context.draw(gekachelt, in: rect)
    }

    /// Der Inhalt allein, als Graustufenbild seiner Deckung — die Form, auf die
    /// die Textur beschnitten wird.
    private static func silhouetteMask(
        of content: LayerContent,
        size: CGSize,
        resources: DocumentResources
    ) -> CGImage? {
        guard let zwischen = makeTransparentContext(size: size) else { return nil }
        // Ohne Textur und ohne Maske: Gefragt ist nur die Form des Inhalts.
        drawContent(content, in: CGRect(origin: .zero, size: size),
                    resources: resources, context: zwischen, mask: nil)
        guard let gezeichnet = zwischen.makeImage() else { return nil }
        return TextureRendering.grayMask(fromAlphaOf: gezeichnet)
    }

    private static func drawImage(_ content: ImageLayerContent, in rect: CGRect, resources: DocumentResources, context: CGContext) {
        guard let image = loadImage(named: content.originalFileReference, resources: resources) else {
            drawMissingImagePlaceholder(in: rect, context: context)
            return
        }

        var drawnImage = image
        if let crop = content.cropRect {
            // `CGImage.cropping(to:)` erwartet den Ursprung oben links —
            // dieselbe Konvention, die das Modell überall verwendet.
            guard let cropped = image.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)) else {
                drawMissingImagePlaceholder(in: rect, context: context)
                return
            }
            drawnImage = cropped
        }

        // Anpassungen aus Plan 5.5 anwenden. Dieselbe Kette wie auf dem
        // Bildschirm (`AdjustmentPipeline`), damit der Export nicht anders
        // aussieht als das, was man eingestellt hat — nur läuft sie hier über
        // den CIContext statt über CALayer.filters.
        //
        // Nach dem Zuschneiden, nicht davor: Ein Weichzeichnen soll die
        // sichtbare Kante weichzeichnen und nicht Bildteile hereinholen, die
        // weggeschnitten wurden.
        if content.adjustments != .neutral,
           let angepasst = AdjustmentPipeline.apply(content.adjustments, to: CIImage(cgImage: drawnImage)),
           let gerendert = RenderContext.shared.createCGImage(angepasst, from: angepasst.extent) {
            drawnImage = gerendert
        }

        context.interpolationQuality = .high

        // `CGContext.draw(_:in:)` zeichnet ein `CGImage` verkehrt herum,
        // wenn der Kontext (wie hier) keinen eigenen Geometrie-Flip trägt —
        // ein gut bekannter Core-Graphics-Stolperstein, empirisch bestätigt:
        // die obere Bildhälfte landet sonst unten. Lokal um die Rechteckmitte
        // gespiegelt gleicht das wieder aus, ohne Rotation/Skalierung der
        // Ebene (die schon in der CTM stecken) zu beeinflussen.
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -rect.midX, y: -rect.midY)
        context.draw(drawnImage, in: rect)
        context.restoreGState()
    }

    private static func drawText(_ content: TextLayerContent, in rect: CGRect, context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // `flipped: true`, weil der Kontext für die Leinwandkoordinaten
        // (Ursprung oben links) bereits gespiegelt ist. Meldet man hier
        // `false`, zeichnet AppKit den Text seitenverkehrt — mit `L` sofort
        // sichtbar, mit einer Formebene dagegen unsichtbar, weil Rechteck und
        // Ellipse senkrecht symmetrisch sind.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        TextLayout.attributedString(for: content).draw(in: rect)
    }

    private static func drawShape(_ content: ShapeLayerContent, in rect: CGRect, context: CGContext) {
        guard let path = ShapePath.cgPath(for: content, in: rect) else { return }

        // Dieselbe lokale Spiegelung wie bei Bildinhalten und aus demselben
        // Grund: `ShapePath` beschreibt die Form im Koordinatensystem des
        // Modells (Ursprung oben links), der Export-Kontext zählt y aber nach
        // oben.
        //
        // Bis zu den Formvorlagen fehlte das hier, ohne aufzufallen: Rechteck,
        // abgerundetes Rechteck und Ellipse sind senkrecht symmetrisch, eine
        // Spiegelung ist an ihnen nicht zu sehen. Ein Dreieck stand dagegen
        // sofort auf dem Kopf.
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -rect.midX, y: -rect.midY)
        context.addPath(path)
        context.setFillColor((RGBA(hex: content.fillColorHex) ?? .white).cgColor)
        context.fillPath()
        context.restoreGState()
    }

    /// Sichtbarer Platzhalter für eine Ebene, deren Originaldatei fehlt —
    /// dieselbe Idee wie `LayerRenderer.makePlaceholderLayer()`: besser
    /// auffindbar als eine leere Fläche, und der Export darf deswegen nicht
    /// scheitern (Plan 2.1).
    private static func drawMissingImagePlaceholder(in rect: CGRect, context: CGContext) {
        context.setFillColor(NSColor.systemGray.withAlphaComponent(0.25).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(2)
        context.stroke(rect.insetBy(dx: 1, dy: 1))
    }

    // MARK: - Bilddekodierung

    /// Der Export dekodiert jedes Original neu, statt den Zwischenspeicher
    /// von `ImageStore` zu nutzen: Der ist an den Hauptakteur gebunden, und
    /// der Export läuft bewusst daneben.
    private static func loadImage(named name: String, resources: DocumentResources) -> CGImage? {
        guard let data = resources.data(for: name) else { return nil }
        return ImageDecoding.decode(data)
    }

    // MARK: - Hilfskontext

    private static func makeTransparentContext(size: CGSize) -> CGContext? {
        CGContext(
            data: nil,
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}

// MARK: - Blend-Modus-Zuordnung

extension AssemblageModel.BlendMode {
    /// Core-Graphics-Entsprechung zu `compositingFilterName` aus
    /// `BlendMode+CoreAnimation.swift` — dieselben sechs Modi, hier für den
    /// direkten `CGContext`-Weg des Exports statt für Core Animation.
    var cgBlendMode: CGBlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .lighten: return .lighten
        case .darken: return .darken
        }
    }
}

// MARK: - Sendable-Übergabe an den Hintergrund-Task

/// Der Export liest die Originale von einem Hintergrund-Task aus, während der
/// Hauptthread weiterläuft. `DocumentResources` sichert seinen Zustand dafür
/// mit einer Sperre ab — `@unchecked` bezieht sich also nur darauf, dass der
/// Übersetzer diese Sperre nicht selbst nachprüfen kann, nicht auf eine
/// Annahme über das Verhalten der Nutzer.
///
/// Diese Zusicherung stand hier zunächst mit der Begründung, es werde während
/// eines Exports schon niemand importieren. Das trifft nicht zu — der Export
/// läuft ja gerade deshalb im Hintergrund, damit man weiterarbeiten kann — und
/// führte reproduzierbar zum Absturz.
extension DocumentResources: @unchecked Sendable {}
