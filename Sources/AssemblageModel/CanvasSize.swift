/// Grösse der Arbeitsfläche eines Dokuments, in Punkten.
///
/// Plan-Referenz: 5.1 „Import & Canvas" — freie Leinwandgrösse + Vorlagen-Presets.
public struct CanvasSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Vordefinierte Canvas-Vorlagen aus Plan-Abschnitt 5.1.
/// `.custom` deckt frei gewählte Grössen ab.
public enum CanvasPreset: Equatable, Sendable {
    case instagramPost
    case instagramStory
    case a4Poster
    case custom(CanvasSize)

    /// Auflösung in Punkten (bei 72 dpi als Basis; Export rechnet bei Bedarf hoch).
    public var size: CanvasSize {
        switch self {
        case .instagramPost:
            return CanvasSize(width: 1080, height: 1080)
        case .instagramStory:
            return CanvasSize(width: 1080, height: 1920)
        case .a4Poster:
            // A4 bei 300 dpi: 210mm x 297mm
            return CanvasSize(width: 2480, height: 3508)
        case .custom(let size):
            return size
        }
    }
}
