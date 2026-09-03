import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import Foundation
import AssemblageModel

/// Rendert die komplette Ebenenkette eines Dokuments in eine Bitmap zum
/// Exportieren (Plan 5.8: PNG mit Transparenz, JPEG). PDF ist ausdrücklich
/// nicht Teil dieser Datei (Phase 3).
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

    // MARK: - Fehler

    /// Eigener Fehlertyp statt `try!`/erzwungenem Auspacken (Plan 2.1).
    enum ExportError: Error, LocalizedError, Equatable {
        case invalidTargetSize
        case renderingFailed
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidTargetSize:
                return "Die Export-Grösse muss breiter und höher als null sein."
            case .renderingFailed:
                return "Die Ebenen liessen sich nicht zu einem Bild zusammensetzen."
            case .encodingFailed:
                return "Das gerenderte Bild liess sich nicht in das Zielformat kodieren."
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

        // Eine Leinwand mit Grösse null hat kein sinnvolles Koordinaten-
        // system — ein leeres (durchsichtiges) Bild ist dann die richtige
        // Antwort, kein Fehler (Plan 2.1: fehlende Inhalte dürfen den Export
        // nicht scheitern lassen).
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
                draw(layer, canvasHeight: document.canvas.height, exportScale: exportScale, resources: resources, into: context)
                context.restoreGState()
            }
        }

        guard let image = context.makeImage() else { throw ExportError.renderingFailed }
        return image
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
    private static func draw(
        _ layer: Layer,
        canvasHeight: Double,
        exportScale: CGSize,
        resources: DocumentResources,
        into context: CGContext
    ) {
        let contentSize = self.contentSize(of: layer.content, resources: resources)
        guard contentSize.width > 0, contentSize.height > 0 else { return }

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
        drawContent(layer.content, in: rect, resources: resources, context: context)

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

    private static func drawContent(_ content: LayerContent, in rect: CGRect, resources: DocumentResources, context: CGContext) {
        switch content {
        case .image(let image):
            drawImage(image, in: rect, resources: resources, context: context)
        case .text(let text):
            drawText(text, in: rect, context: context)
        case .shape(let shape):
            drawShape(shape, in: rect, context: context)
        }
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
        let path: CGPath
        switch content.kind {
        case .rectangle:
            path = CGPath(rect: rect, transform: nil)
        case .roundedRectangle:
            path = CGPath(
                roundedRect: rect,
                cornerWidth: min(content.cornerRadius, rect.width / 2),
                cornerHeight: min(content.cornerRadius, rect.height / 2),
                transform: nil
            )
        case .ellipse:
            path = CGPath(ellipseIn: rect, transform: nil)
        }

        context.addPath(path)
        context.setFillColor((RGBA(hex: content.fillColorHex) ?? .white).cgColor)
        context.fillPath()
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
