import AppKit
import CoreGraphics
import AssemblageModel

/// Einstellungen des Pinsels (Plan 5.4: „weiche Kante, Grösse und Härte
/// einstellbar").
struct MaskBrush: Equatable {
    /// Durchmesser in Bildpunkten.
    var diameter: Double
    /// 0 = ganz weiche Kante, 1 = harte Kante.
    var hardness: Double
    var mode: Mode

    enum Mode: Equatable {
        /// Deckt Bildteile ab (malt Schwarz).
        case hide
        /// Holt abgedeckte Teile zurück (malt Weiss).
        case reveal
    }
}

/// Malt in eine Maskenbitmap.
final class MaskPainter {
    private let width: Int
    private let height: Int
    private let maskContext: CGContext
    private let strokeContext: CGContext

    private var brush: MaskBrush?
    private var lastPoint: Point?
    private var lastPressure = 0.0

    /// `existing == nil` legt eine neue, vollständig sichtbare Maske an.
    init?(imageSize: Size, existing: CGImage?) {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              imageSize.width <= Double(Int32.max), imageSize.height <= Double(Int32.max)
        else { return nil }

        let width = Int(imageSize.width.rounded())
        let height = Int(imageSize.height.rounded())
        guard width > 0, height > 0,
              let maskContext = Self.makeGrayContext(width: width, height: height),
              let strokeContext = Self.makeGrayContext(width: width, height: height)
        else { return nil }

        self.width = width
        self.height = height
        self.maskContext = maskContext
        self.strokeContext = strokeContext

        maskContext.setFillColor(gray: 1, alpha: 1)
        maskContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let existing {
            // Die Zielgrösse ist immer die volle Bildauflösung. Eine ältere
            // Maske mit abweichenden Massen wird deshalb beim Einlesen auf
            // genau diese Fläche abgebildet statt den Vertrag zu brechen.
            maskContext.draw(existing, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        strokeContext.setFillColor(gray: 0, alpha: 1)
        strokeContext.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Der Kontext selbst trägt keine Ansichts- oder Leinwandtransformation
        // — das erzeugte `CGImage` entspricht deshalb direkt den im Projekt
        // verwendeten Bildkoordinaten. Sein y zählt aber, wie jeder
        // ungeflippte Quartz-Kontext, von unten; `stamp(at:pressure:brush:)`
        // rechnet Modellpunkte deshalb ausdrücklich um, statt sich auf eine
        // (falsche) Übereinstimmung zu verlassen.
    }

    func beginStroke(at point: Point, pressure: Double, brush: MaskBrush) {
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
        guard let brush, let lastPoint else { return }
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
        combineStroke(mode: brush.mode, into: maskContext)
        self.brush = nil
        lastPoint = nil
        clearStrokeContext()
    }

    /// Der aktuelle Stand als Bitmap, passend zum Maskenvertrag.
    func currentMask() -> CGImage? {
        guard let brush else { return maskContext.makeImage() }
        guard let preview = Self.makeGrayContext(width: width, height: height),
              let base = maskContext.data,
              let target = preview.data
        else { return nil }

        Self.copyRows(
            from: base, sourceBytesPerRow: maskContext.bytesPerRow,
            to: target, targetBytesPerRow: preview.bytesPerRow,
            width: width, height: height
        )
        combineStroke(mode: brush.mode, into: preview)
        return preview.makeImage()
    }

    /// Der aktuelle Stand als PNG, passend für `DocumentResources.addMask(_:)`.
    func pngData() -> Data? {
        guard let image = currentMask() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // MARK: - Strichaufbau

    private func interpolate(
        from start: Point,
        startPressure: Double,
        to end: Point,
        endPressure: Double,
        brush: MaskBrush
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

    private func stamp(at point: Point, pressure: Double, brush: MaskBrush) {
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

    private func combineStroke(mode: MaskBrush.Mode, into target: CGContext) {
        guard let strokeData = strokeContext.data, let targetData = target.data else { return }
        let stroke = strokeData.assumingMemoryBound(to: UInt8.self)
        let result = targetData.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            let strokeRow = y * strokeContext.bytesPerRow
            let targetRow = y * target.bytesPerRow
            for x in 0..<width {
                let coverage = Int(stroke[strokeRow + x])
                let base = Int(result[targetRow + x])
                switch mode {
                case .hide:
                    result[targetRow + x] = UInt8((base * (255 - coverage) + 127) / 255)
                case .reveal:
                    result[targetRow + x] = UInt8(base + ((255 - base) * coverage + 127) / 255)
                }
            }
        }
    }

    private func clearStrokeContext() {
        guard let data = strokeContext.data else { return }
        memset(data, 0, strokeContext.bytesPerRow * height)
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
    private func clippedInterval(from start: Point, to end: Point, bounds: CGRect) -> ClosedRange<Double>? {
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
