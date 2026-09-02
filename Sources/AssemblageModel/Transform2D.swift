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
