/// Position, Skalierung und Rotation einer Ebene auf dem Canvas.
///
/// Bewusst eigene, plattformunabhängige Struktur statt `CGAffineTransform`
/// (das ist Apple-exklusiv) — eine Umrechnung in `CGAffineTransform` kommt
/// später als Extension im macOS-Ziel dazu.
public struct Transform2D: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var scaleX: Double
    public var scaleY: Double
    public var rotationDegrees: Double

    public init(x: Double = 0, y: Double = 0, scaleX: Double = 1, scaleY: Double = 1, rotationDegrees: Double = 0) {
        self.x = x
        self.y = y
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.rotationDegrees = rotationDegrees
    }

    public static let identity = Transform2D()

    // MARK: - Geometrie

    /// Der von der Ebene belegte Rahmen, **ohne** Rotation: Inhaltsgrösse mal
    /// Skalierung, zentriert auf `(x, y)`.
    ///
    /// Der Renderer setzt diesen Rahmen als `bounds`/`position` der `CALayer`
    /// und legt die Rotation separat als Transformationsmatrix an — deshalb
    /// bleibt sie hier bewusst unberücksichtigt.
    public func unrotatedFrame(forContentSize contentSize: Size) -> Rect {
        // Spiegelung (negative Skalierung, Plan 5.5) steckt allein in der
        // Matrix; ein Rahmen mit negativer Breite wäre für den Renderer
        // unbrauchbar.
        let width = contentSize.width * abs(scaleX)
        let height = contentSize.height * abs(scaleY)
        return Rect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    /// Anfangsplatzierung für frisch importierte Inhalte (Plan 5.1): mittig
    /// auf der Leinwand, proportional eingepasst und nie hochskaliert —
    /// Hochskalieren würde ein kleines Foto nur sichtbar unscharf machen.
    public static func fitting(contentSize: Size, into canvas: CanvasSize) -> Transform2D {
        let scale: Double
        if contentSize.width > 0, contentSize.height > 0 {
            // `min(…, 1)` verhindert das Hochskalieren.
            scale = min(canvas.width / contentSize.width, canvas.height / contentSize.height, 1)
        } else {
            // Leerer/kaputter Inhalt: neutral bleiben statt durch null zu
            // teilen und NaN in das Dokument zu schreiben (Plan 2.1).
            scale = 1
        }
        return Transform2D(
            x: canvas.width / 2,
            y: canvas.height / 2,
            scaleX: scale,
            scaleY: scale
        )
    }
}

/// Achsenparalleles Rechteck, z. B. für den Zuschnitt einer Bildebene (5.3).
public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
