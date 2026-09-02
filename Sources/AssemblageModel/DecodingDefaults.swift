import Foundation

// Tolerante Dekodierung für alle Felder mit neutralem Vorgabewert.
//
// Codable verlangt von sich aus *jeden* Schlüssel, auch wenn die Eigenschaft
// im Initialisierer eine Vorgabe hat. Ohne die Ergänzungen hier würde ein in
// Version 2 hinzugefügtes Feld sämtliche in Version 1 gesicherten Dokumente
// unlesbar machen — obwohl deren Daten vollständig sind. Plan 2.1 verbietet
// genau solchen Datenverlust.
//
// Umgekehrt bleiben Felder ohne sinnvollen Ersatzwert Pflicht: die Ebenen-ID,
// der Dateiname des Originals, die Leinwandgrösse. Fehlt eines davon, ist das
// Dokument wirklich beschädigt und soll einen Fehler geben, statt sich
// stillschweigend „reparieren" zu lassen (siehe DecodingToleranceTests).

extension KeyedDecodingContainer {
    /// Liest einen Wert oder liefert die Vorgabe, wenn der Schlüssel fehlt.
    fileprivate func value<T: Decodable>(_ key: Key, or fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

extension Document {
    // Muss ausgeschrieben werden: Ein eigenes `init(from:)` unterdrückt
    // auch die automatisch erzeugten CodingKeys.
    enum CodingKeys: String, CodingKey {
        case canvas, layers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            canvas: try container.decode(CanvasSize.self, forKey: .canvas),
            layers: try container.value(.layers, or: [])
        )
    }
}

extension Layer {
    // Muss ausgeschrieben werden: Ein eigenes `init(from:)` unterdrückt
    // auch die automatisch erzeugten CodingKeys.
    enum CodingKeys: String, CodingKey {
        case id, name, isVisible, opacity, blendMode, transform, mask, content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            isVisible: try container.value(.isVisible, or: true),
            opacity: try container.value(.opacity, or: 1),
            blendMode: try container.value(.blendMode, or: .normal),
            transform: try container.value(.transform, or: .identity),
            mask: try container.decodeIfPresent(LayerMask.self, forKey: .mask),
            content: try container.decode(LayerContent.self, forKey: .content)
        )
    }
}

extension Transform2D {
    // Muss ausgeschrieben werden: Ein eigenes `init(from:)` unterdrückt
    // auch die automatisch erzeugten CodingKeys.
    enum CodingKeys: String, CodingKey {
        case x, y, scaleX, scaleY, rotationDegrees
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.value(.x, or: 0),
            y: try container.value(.y, or: 0),
            scaleX: try container.value(.scaleX, or: 1),
            scaleY: try container.value(.scaleY, or: 1),
            rotationDegrees: try container.value(.rotationDegrees, or: 0)
        )
    }
}

extension LayerMask {
    // Muss ausgeschrieben werden: Ein eigenes `init(from:)` unterdrückt
    // auch die automatisch erzeugten CodingKeys.
    enum CodingKeys: String, CodingKey {
        case maskImageReference, source, isInverted, isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maskImageReference: try container.decodeIfPresent(String.self, forKey: .maskImageReference),
            source: try container.decode(MaskSource.self, forKey: .source),
            isInverted: try container.value(.isInverted, or: false),
            isEnabled: try container.value(.isEnabled, or: true)
        )
    }
}

extension ImageLayerContent {
    // Muss ausgeschrieben werden: Ein eigenes `init(from:)` unterdrückt
    // auch die automatisch erzeugten CodingKeys.
    enum CodingKeys: String, CodingKey {
        case originalFileReference, cropRect, adjustments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            originalFileReference: try container.decode(String.self, forKey: .originalFileReference),
            cropRect: try container.decodeIfPresent(Rect.self, forKey: .cropRect),
            adjustments: try container.value(.adjustments, or: .neutral)
        )
    }
}

extension ImageAdjustments {
    // Muss ausgeschrieben werden: Ein eigenes `init(from:)` unterdrückt
    // auch die automatisch erzeugten CodingKeys.
    enum CodingKeys: String, CodingKey {
        case brightness, contrast, saturation, warmth, blurRadius, sharpenAmount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            brightness: try container.value(.brightness, or: 0),
            contrast: try container.value(.contrast, or: 0),
            saturation: try container.value(.saturation, or: 0),
            warmth: try container.value(.warmth, or: 0),
            blurRadius: try container.value(.blurRadius, or: 0),
            sharpenAmount: try container.value(.sharpenAmount, or: 0)
        )
    }
}

extension TextLayerContent {
    // Muss ausgeschrieben werden: Ein eigenes `init(from:)` unterdrückt
    // auch die automatisch erzeugten CodingKeys.
    enum CodingKeys: String, CodingKey {
        case string, fontName, fontSize, colorHex, alignment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            string: try container.decode(String.self, forKey: .string),
            fontName: try container.value(.fontName, or: "Helvetica"),
            fontSize: try container.value(.fontSize, or: 48),
            colorHex: try container.value(.colorHex, or: "#000000"),
            alignment: try container.value(.alignment, or: .left)
        )
    }
}

extension ShapeLayerContent {
    // Muss ausgeschrieben werden: Ein eigenes `init(from:)` unterdrückt
    // auch die automatisch erzeugten CodingKeys.
    enum CodingKeys: String, CodingKey {
        case kind, size, cornerRadius, fillColorHex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(ShapeKind.self, forKey: .kind),
            size: try container.decode(Size.self, forKey: .size),
            cornerRadius: try container.value(.cornerRadius, or: 0),
            fillColorHex: try container.value(.fillColorHex, or: "#FFFFFF")
        )
    }
}
