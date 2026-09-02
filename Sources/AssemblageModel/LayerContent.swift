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
public enum ShapeKind: String, Codable, Sendable {
    case rectangle
    case roundedRectangle
    case ellipse
}

public struct ShapeLayerContent: Codable, Equatable, Sendable {
    public var kind: ShapeKind
    /// Nur relevant für `.roundedRectangle`.
    public var cornerRadius: Double
    public var fillColorHex: String

    public init(kind: ShapeKind, cornerRadius: Double = 0, fillColorHex: String = "#FFFFFF") {
        self.kind = kind
        self.cornerRadius = cornerRadius
        self.fillColorHex = fillColorHex
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
