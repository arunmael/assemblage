import AppKit
import CoreGraphics
import CoreImage
import AssemblageModel

/// Einstellungen des Farbpinsels.
struct PaintBrush: Equatable {
    var diameter: Double   // Punkte
    var hardness: Double   // 0 ganz weich … 1 hart
    var colorHex: String   // z. B. "#FF0000"
    var opacity: Double    // 0…1, Deckkraft des GANZEN Strichs
}

/// Malt farbig in eine RGBA-Bitmap — die eigene Ebene, auf der laut
/// Anpassungen.md gemalt werden soll, nicht die Maske eines Fotos.
final class ColorPainter {
    private let width: Int
    private let height: Int
    private let paintContext: CGContext
    private let strokeContext: CGContext

    private var brush: PaintBrush?
    private var lastPoint: Point?
    private var lastPressure = 0.0

    /// `existing == nil` legt eine leere, vollständig durchsichtige Fläche an.
    init?(imageSize: Size, existing: CGImage?) {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              imageSize.width <= Double(Int32.max), imageSize.height <= Double(Int32.max)
        else { return nil }

        let width = Int(imageSize.width.rounded())
        let height = Int(imageSize.height.rounded())
        guard width > 0, height > 0,
              let paintContext = Self.makePaintContext(width: width, height: height),
              let strokeContext = Self.makeGrayContext(width: width, height: height)
        else { return nil }

        self.width = width
        self.height = height
        self.paintContext = paintContext
        self.strokeContext = strokeContext

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        // Bitmap-Speicher ist nicht als gelöscht vertraglich zugesichert; eine
        // neue Farbebene muss trotzdem deterministisch vollständig leer sein.
        paintContext.clear(rect)
        if let existing {
            // Die Farbebene gehört zur vollen Bildauflösung; ältere Inhalte
            // mit anderen Massen werden deshalb auf genau diese Fläche gelegt.
            paintContext.draw(existing, in: rect)
        }

        strokeContext.setFillColor(gray: 0, alpha: 1)
        strokeContext.fill(rect)
    }

    func beginStroke(at point: Point, pressure: Double, brush: PaintBrush) {
        // Nicht-endliche Ereignisdaten dürfen keinen künstlichen
        // Mindestdurchmesser an einer ansonsten gültigen Position erzeugen.
        guard pressure.isFinite else { return }
        // Ein neuer Beginn schliesst einen allenfalls noch offenen Strich ab,
        // damit keine Bearbeitung unbemerkt verloren geht.
        endStroke()
        clearStrokeContext()
        self.brush = brush
        lastPoint = point
        lastPressure = normalizedPressure(pressure)
        stamp(at: point, pressure: lastPressure, brush: brush)
    }

    func continueStroke(to point: Point, pressure: Double) {
        guard pressure.isFinite, let brush, let lastPoint else { return }
        let pressure = normalizedPressure(pressure)
        interpolate(
            from: lastPoint,
            startPressure: lastPressure,
            to: point,
            endPressure: pressure,
            brush: brush
        )
        self.lastPoint = point
        lastPressure = pressure
    }

    func endStroke() {
        guard let brush else { return }
        combineStroke(brush: brush, into: paintContext)
        self.brush = nil
        lastPoint = nil
        clearStrokeContext()
    }

    /// Der aktuelle Stand als RGBA-Bild, inklusive eines noch offenen Strichs
    /// (Vorschau während des Ziehens).
    func currentImage() -> CGImage? {
        guard let brush else { return paintContext.makeImage() }
        guard let preview = Self.makePaintContext(width: width, height: height),
              let base = paintContext.data,
              let target = preview.data
        else { return nil }

        Self.copyRows(
            from: base, sourceBytesPerRow: paintContext.bytesPerRow,
            to: target, targetBytesPerRow: preview.bytesPerRow,
            width: width * 4, height: height
        )
        combineStroke(brush: brush, into: preview)
        return preview.makeImage()
    }

    /// Als PNG, passend für `DocumentResources.addOriginal(_:fileExtension:)`.
    func pngData() -> Data? {
        guard let image = currentImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // MARK: - Strichaufbau

    private func interpolate(
        from start: Point,
        startPressure: Double,
        to end: Point,
        endPressure: Double,
        brush: PaintBrush
    ) {
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite,
              brush.diameter.isFinite, brush.diameter > 0
        else { return }

        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance.isFinite else { return }
        guard distance > 0 else {
            stamp(at: end, pressure: endPressure, brush: brush)
            return
        }

        // Nur den Teil des Ereignis-Segments ablaufen, dessen Pinselkreis das
        // Bild überhaupt berühren kann. Das hält auch Sprünge aus sehr weit
        // ausserhalb der Bitmap zeitlich begrenzt.
        let margin = brush.diameter / 2 + 1
        guard margin.isFinite else { return }
        guard let interval = clippedInterval(
            from: start,
            to: end,
            bounds: CGRect(
                x: -margin,
                y: -margin,
                width: Double(width) + 2 * margin,
                height: Double(height) + 2 * margin
            )
        ) else { return }

        let minimumDiameter = min(
            effectiveDiameter(brush.diameter, pressure: startPressure),
            effectiveDiameter(brush.diameter, pressure: endPressure)
        )
        // Ein Fünftel des kleinsten Durchmessers lässt benachbarte weiche
        // Stempel deutlich überlappen. Unter einem halben Bildpunkt bringt
        // dichteres Abtasten keine zusätzliche Pixelabdeckung.
        let spacing = max(0.5, minimumDiameter * 0.2)
        let clippedDistance = distance * (interval.upperBound - interval.lowerBound)
        let steps = max(1, Int(ceil(clippedDistance / spacing)))

        for index in 0...steps {
            let fraction = Double(index) / Double(steps)
            let t = interval.lowerBound
                + (interval.upperBound - interval.lowerBound) * fraction
            stamp(
                at: Point(x: start.x + dx * t, y: start.y + dy * t),
                pressure: startPressure + (endPressure - startPressure) * t,
                brush: brush
            )
        }
    }

    private func stamp(at point: Point, pressure: Double, brush: PaintBrush) {
        guard point.x.isFinite, point.y.isFinite,
              brush.diameter.isFinite, brush.diameter > 0
        else { return }

        let radius = effectiveDiameter(brush.diameter, pressure: pressure) / 2
        guard radius.isFinite, radius > 0 else { return }

        let hardness = brush.hardness.isFinite ? min(max(brush.hardness, 0), 1) : 0
        let outerRadius: Double
        let innerRadius: Double
        if hardness == 1 {
            // Eine ein Pixel breite Helligkeitsrampe ergibt auch beim harten
            // Pinsel eine saubere Kantenglättung ohne halbtransparente Farbe.
            outerRadius = radius + 0.5
            innerRadius = max(0, radius - 0.5)
        } else {
            outerRadius = radius
            innerRadius = radius * hardness
        }

        guard outerRadius > 0 else { return }
        let colors = [
            CGColor(gray: 1, alpha: 1),
            CGColor(gray: 1, alpha: 1),
            CGColor(gray: 0, alpha: 1)
        ] as CFArray
        let locations: [CGFloat] = [
            0,
            CGFloat(innerRadius / outerRadius),
            1
        ]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceGray(),
            colors: colors,
            locations: locations
        ) else { return }

        // `point` ist ein Modellpunkt: Ursprung oben links, y wächst nach
        // unten — wie überall im Projekt. Ein `CGContext` ohne eigenen
        // Geometrie-Flip zählt y dagegen von unten. Ohne diese Umrechnung
        // malt ein Strich nahe dem oberen Bildrand nahe dem unteren
        // (aus Anpassungen.md: „alles ist noch spiegelverkehrt") —
        // nachgemessen mit einem gezielten Stempel nahe der Bildkante, nicht
        // nur angenommen.
        let gezeichnetesZentrum = CGPoint(x: point.x, y: Double(height) - point.y)

        // Der Strichkontext beginnt schwarz und sammelt pro Pixel immer nur
        // den stärksten Stempel. Die deckenden Grautöne plus `.lighten`
        // bilden ein Maximum; überlappende Stempel addieren sich daher nicht.
        strokeContext.saveGState()
        strokeContext.setBlendMode(.lighten)
        strokeContext.drawRadialGradient(
            gradient,
            startCenter: gezeichnetesZentrum,
            startRadius: 0,
            endCenter: gezeichnetesZentrum,
            endRadius: outerRadius,
            options: []
        )
        strokeContext.restoreGState()
    }

    /// Druck null behält 15 Prozent des eingestellten Durchmessers. Damit
    /// beginnt ein Pencil-Strich natürlich fein, verschwindet aber weder bei
    /// einem sehr leichten Kontakt noch bei Mausereignissen mit Druck null.
    private func effectiveDiameter(_ diameter: Double, pressure: Double) -> Double {
        diameter * (0.15 + 0.85 * normalizedPressure(pressure))
    }

    private func normalizedPressure(_ pressure: Double) -> Double {
        guard pressure.isFinite else { return 0 }
        return min(max(pressure, 0), 1)
    }

    // MARK: - Bitmap-Verrechnung

    private func combineStroke(brush: PaintBrush, into target: CGContext) {
        guard let strokeImage = strokeContext.makeImage() else { return }
        let color = RGBA(hex: brush.colorHex) ?? .black
        let opacity = brush.opacity.isFinite ? min(max(brush.opacity, 0), 1) : 0
        let colored = CIImage(cgImage: strokeImage).applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                // Die Grauabdeckung liegt in allen Farbkanälen gleich vor;
                // Rot liefert deshalb den Alphakanal des ganzen Strichs.
                "inputAVector": CIVector(x: opacity, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(
                    x: color.red, y: color.green, z: color.blue, w: 0
                )
            ]
        )
        guard let image = RenderContext.shared.createCGImage(colored, from: colored.extent) else {
            return
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        // Kein zusätzlicher Spiegel-Trick nötig: Nachgemessen (siehe
        // ColorPaintingTests) landet das aus Core Image zurückkehrende
        // `CGImage`, direkt in einen frischen, ungeflippten Bitmap-Kontext
        // gezeichnet, bereits an der richtigen Stelle — anders als beim
        // Zeichnen eines Core-Image-Ergebnisses in den bereits gedrehten
        // Export-Kontext (`DocumentExporter`). Ein hier zusätzlich
        // angewandter Spiegel hätte die schon korrekte Ausrichtung wieder
        // umgekehrt.
        target.saveGState()
        target.setBlendMode(.normal)
        target.draw(image, in: rect)
        target.restoreGState()
    }

    private func clearStrokeContext() {
        guard let data = strokeContext.data else { return }
        memset(data, 0, strokeContext.bytesPerRow * height)
    }

    private static func makePaintContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func makeGrayContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
    }

    private static func copyRows(
        from source: UnsafeMutableRawPointer,
        sourceBytesPerRow: Int,
        to target: UnsafeMutableRawPointer,
        targetBytesPerRow: Int,
        width: Int,
        height: Int
    ) {
        for y in 0..<height {
            memcpy(
                target.advanced(by: y * targetBytesPerRow),
                source.advanced(by: y * sourceBytesPerRow),
                width
            )
        }
    }

    /// Liang-Barsky-Beschnitt; das Ergebnis sind Parameter entlang des
    /// ursprünglichen Segments. So bleibt auch die Druckinterpolation korrekt.
    private func clippedInterval(
        from start: Point,
        to end: Point,
        bounds: CGRect
    ) -> ClosedRange<Double>? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        var lower = 0.0
        var upper = 1.0

        let edges = [
            (-dx, start.x - bounds.minX),
            (dx, bounds.maxX - start.x),
            (-dy, start.y - bounds.minY),
            (dy, bounds.maxY - start.y)
        ]
        for (direction, distance) in edges {
            if direction == 0 {
                if distance < 0 { return nil }
                continue
            }
            let t = distance / direction
            if direction < 0 {
                lower = max(lower, t)
            } else {
                upper = min(upper, t)
            }
            if lower > upper { return nil }
        }
        return lower...upper
    }
}
