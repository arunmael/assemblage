/// Bildebene (Plan 5.1, 5.3, 5.5): referenziert das Originalbild im
/// Dokumentpaket (Original bleibt erhalten, 7.4), Zuschnitt und Anpassungen
/// sind nicht-destruktiv separat gespeichert.
public struct ImageLayerContent: Codable, Equatable, Sendable {
    /// Relativer Pfad der Originaldatei innerhalb des Dokumentpakets,
    /// z. B. "originals/<uuid>.heic".
    public var originalFileReference: String
    /// `nil` = kompletter Import ohne Zuschnitt.
    public var cropRect: Rect?
    public var adjustments: ImageAdjustments

    /// Der Umriss, auf den das Bild beschnitten wird — „Bild in eine Form
    /// setzen". `nil` = rechteckig wie bisher.
    ///
    /// Bewusst hier und nicht als zweite Maske neben `Layer.mask`: Eine
    /// gemalte Maske und ein Formzuschnitt sollen sich überlagern können
    /// (erst freistellen, dann in eine Form setzen). Beide laufen deshalb
    /// beim Zeichnen durch dieselbe Stelle zusammen.
    public var clipShape: ShapeKind?

    /// Rahmenstärke in Punkten; 0 = kein Rahmen. Der Rahmen folgt
    /// `clipShape`, sonst dem Bildrechteck.
    public var borderWidth: Double
    public var borderColorHex: String

    public init(
        originalFileReference: String,
        cropRect: Rect? = nil,
        adjustments: ImageAdjustments = .neutral,
        clipShape: ShapeKind? = nil,
        borderWidth: Double = 0,
        borderColorHex: String = "#FFFFFF"
    ) {
        self.originalFileReference = originalFileReference
        self.cropRect = cropRect
        self.adjustments = adjustments
        self.clipShape = clipShape
        self.borderWidth = borderWidth
        self.borderColorHex = borderColorHex
    }
}

public enum TextAlignment: String, Codable, Sendable {
    case left, center, right
}

/// Textebene (Plan 5.6) — bewusst reduziert, kein volles Typografie-Werkzeug.
public struct TextLayerContent: Codable, Equatable, Sendable {
    public var string: String
    public var fontName: String
    public var fontSize: Double
    public var colorHex: String
    public var alignment: TextAlignment

    public init(
        string: String,
        fontName: String = "Helvetica",
        fontSize: Double = 48,
        colorHex: String = "#000000",
        alignment: TextAlignment = .left
    ) {
        self.string = string
        self.fontName = fontName
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.alignment = alignment
    }
}

/// Einfache Formen (Plan 5.7) — reine Nutzflächen für Rahmen/Hintergründe,
/// kein Vektor-Zeichenwerkzeug (das ist Sceau vorbehalten).
public enum ShapeKind: String, Codable, Sendable, CaseIterable {
    case rectangle
    case roundedRectangle
    case ellipse

    // Formvorlagen (aus missing.md). Bewusst als weitere Fälle **hier** und
    // nicht als zweites Feld neben `kind`: Sonst hätte ein Dokument zwei
    // Stellen, die beschreiben, welche Form gemeint ist, und die beiden
    // könnten einander widersprechen. Die Rohwerte entsprechen genau denen
    // von `ShapeTemplate`, das die Umrisse liefert.
    case triangle
    case pentagon
    case hexagon
    case star
    case heart
    case arrow
    case speechBubble

    // Zehn weitere Vorlagen (aus Anpassungen.md: „mindestens 20 Formen").
    case diamond
    case cross
    case octagon
    case rightTriangle
    case parallelogram
    case trapezoid
    case crescent
    case lightningBolt
    case cloud
    case shield
    case pill
    case chevron
    case bookmark
    case burst
    case teardrop
    case heptagon
    case decagon
    case arrowDouble
    case house
    case flag

    /// Ein von Hand gezeichneter Zug. Der Umriss steckt nicht in einer
    /// Vorlage, sondern in `ShapeLayerContent.path` — deshalb hat diese Art
    /// bewusst kein Gegenstück in `ShapeTemplate`.
    case freehand

    /// Die Vorlage hinter dieser Form — `nil` bei den drei Grundformen, die
    /// Core Graphics direkt kennt und die deshalb keinen Streckenzug brauchen,
    /// und bei `.freehand`, das seinen Umriss selbst mitbringt.
    public var template: ShapeTemplate? { ShapeTemplate(rawValue: rawValue) }
}

public struct ShapeLayerContent: Codable, Equatable, Sendable {
    public var kind: ShapeKind
    /// Grösse der Form in Punkten, vor der Skalierung aus `Transform2D`.
    /// Bild- und Textebenen leiten ihre Grösse aus dem Inhalt ab (Pixelmasse
    /// bzw. Textsatz) — eine Form hat keine solche natürliche Grösse und
    /// führt sie deshalb selbst.
    public var size: Size
    /// Nur relevant für `.roundedRectangle`.
    public var cornerRadius: Double
    public var fillColorHex: String
    /// Zacken eines Sterns. Nur für `.star` von Bedeutung; die übrigen
    /// Vorlagen haben eine feste Punktzahl.
    public var pointCount: Int
    /// Farbe des Rands (aus Anpassungen 2: „Rahmen/Rand rund um alle
    /// Formen"). Gilt für jede Vorlage gleichermassen, weil alle über
    /// denselben Pfad gezeichnet werden.
    public var strokeColorHex: String
    /// Breite des Rands in Punkten. `0` heisst: kein Rand — der bisherige,
    /// unveränderte Normalfall.
    public var strokeWidth: Double
    /// Der gezeichnete Umriss. Nur für `.freehand` von Bedeutung; alle
    /// anderen Arten leiten ihren Umriss aus `kind` und `size` ab — genau wie
    /// `cornerRadius` nur das abgerundete Rechteck und `pointCount` nur den
    /// Stern betrifft.
    ///
    /// Die Punkte liegen im eigenen Rechteck der Ebene (Ursprung oben links,
    /// Ausdehnung `size`), nicht in Leinwandkoordinaten: Die Lage führt
    /// `Transform2D`, sonst wäre ein Zug doppelt verschoben.
    public var path: VectorPath?

    /// Ein offener Zug hat kein Innen — er wird nur gestrichen, nicht
    /// gefüllt. Eine Fläche für ihn zu berechnen hiesse, Anfang und Ende
    /// stillschweigend zu verbinden; das Ergebnis sähe wie ein Klecks aus.
    public var isStrokeOnly: Bool {
        guard kind == .freehand, let path else { return false }
        return path.subpaths.contains { !$0.isClosed }
    }

    public init(
        kind: ShapeKind,
        size: Size,
        cornerRadius: Double = 0,
        fillColorHex: String = "#FFFFFF",
        pointCount: Int = 5,
        strokeColorHex: String = "#000000",
        strokeWidth: Double = 0,
        path: VectorPath? = nil
    ) {
        self.kind = kind
        self.size = size
        self.cornerRadius = cornerRadius
        self.fillColorHex = fillColorHex
        self.pointCount = pointCount
        self.strokeColorHex = strokeColorHex
        self.strokeWidth = strokeWidth
        self.path = path
    }
}

/// Der eigentliche Inhalt einer Ebene — genau einer der drei Ebenentypen
/// aus dem MVP-Feature-Set (5.1–5.7). Weitere Fälle (z. B. Gruppen) sind
/// laut Plan für Assemblage v1 nicht vorgesehen.
public enum LayerContent: Codable, Equatable, Sendable {
    case image(ImageLayerContent)
    case text(TextLayerContent)
    case shape(ShapeLayerContent)
}
