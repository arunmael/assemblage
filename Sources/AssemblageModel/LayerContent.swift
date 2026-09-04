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

    public init(originalFileReference: String, cropRect: Rect? = nil, adjustments: ImageAdjustments = .neutral) {
        self.originalFileReference = originalFileReference
        self.cropRect = cropRect
        self.adjustments = adjustments
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

    /// Die Vorlage hinter dieser Form — `nil` bei den drei Grundformen, die
    /// Core Graphics direkt kennt und die deshalb keinen Streckenzug brauchen.
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

    public init(
        kind: ShapeKind,
        size: Size,
        cornerRadius: Double = 0,
        fillColorHex: String = "#FFFFFF",
        pointCount: Int = 5
    ) {
        self.kind = kind
        self.size = size
        self.cornerRadius = cornerRadius
        self.fillColorHex = fillColorHex
        self.pointCount = pointCount
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
