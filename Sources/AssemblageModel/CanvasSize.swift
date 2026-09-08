/// Breite × Höhe in Punkten — für die Arbeitsfläche ebenso wie für die
/// Grösse einer Formebene.
///
/// Bewusst eigene Struktur statt `CGSize`: das Modell bleibt so
/// plattformunabhängig (siehe Package.swift).
public struct Size: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = Size(width: 0, height: 0)
}

/// Grösse der Arbeitsfläche eines Dokuments.
///
/// Plan-Referenz: 5.1 „Import & Canvas" — freie Leinwandgrösse + Vorlagen-Presets.
public typealias CanvasSize = Size

/// Vordefinierte Canvas-Vorlagen aus Plan-Abschnitt 5.1.
/// `.custom` deckt frei gewählte Grössen ab.
///
/// Die Papierformate rechnen mit 300 dpi — der übliche Druckwert. Bei 72 dpi
/// wäre ein A4-Blatt nur 595 × 842 Punkte gross und beim Drucken sichtbar
/// grob.
public enum CanvasPreset: Equatable, Sendable {
    case instagramPost
    case instagramPortrait
    case instagramStory
    case fullHD
    case a4Portrait
    case a4Landscape
    case a5Portrait
    case a5Landscape
    case a3Portrait
    case custom(CanvasSize)

    /// Auflösung in Punkten (bei 72 dpi als Basis; Export rechnet bei Bedarf hoch).
    public var size: CanvasSize {
        switch self {
        case .instagramPost:
            return CanvasSize(width: 1080, height: 1080)
        case .instagramPortrait:
            return CanvasSize(width: 1080, height: 1350)
        case .instagramStory:
            return CanvasSize(width: 1080, height: 1920)
        case .fullHD:
            return CanvasSize(width: 1920, height: 1080)
        case .a4Portrait:
            // A4 bei 300 dpi: 210mm × 297mm
            return CanvasSize(width: 2480, height: 3508)
        case .a4Landscape:
            return CanvasSize(width: 3508, height: 2480)
        case .a5Portrait:
            // A5 bei 300 dpi: 148mm × 210mm
            return CanvasSize(width: 1748, height: 2480)
        case .a5Landscape:
            return CanvasSize(width: 2480, height: 1748)
        case .a3Portrait:
            // A3 bei 300 dpi: 297mm × 420mm
            return CanvasSize(width: 3508, height: 4961)
        case .custom(let size):
            return size
        }
    }

    /// Name ohne Masse — die hängt die Oberfläche selbst an, damit hier keine
    /// Formatierung liegt.
    public var displayName: String {
        switch self {
        case .instagramPost: return "Quadrat"
        case .instagramPortrait: return "Beitrag hoch"
        case .instagramStory: return "Story"
        case .fullHD: return "Full HD"
        case .a4Portrait: return "A4 hoch"
        case .a4Landscape: return "A4 quer"
        case .a5Portrait: return "A5 hoch"
        case .a5Landscape: return "A5 quer"
        case .a3Portrait: return "A3 hoch"
        case .custom: return "Eigene Grösse"
        }
    }

    /// Papierformate stehen im Menü als eigene Gruppe unter den Bildschirm-
    /// formaten.
    public var isPaperFormat: Bool {
        switch self {
        case .a4Portrait, .a4Landscape, .a5Portrait, .a5Landscape, .a3Portrait: return true
        case .instagramPost, .instagramPortrait, .instagramStory, .fullHD, .custom: return false
        }
    }

    /// Alle auswählbaren Vorlagen in Menü-Reihenfolge (ohne `.custom`, das
    /// keine feste Grösse hat).
    public static let selectable: [CanvasPreset] = [
        .instagramPost, .instagramPortrait, .instagramStory, .fullHD,
        .a4Portrait, .a4Landscape, .a5Portrait, .a5Landscape, .a3Portrait
    ]

    /// Zu welcher Vorlage eine Grösse gehört — `nil`, wenn sie frei gewählt
    /// ist. Damit zeigt ein Vorlagenmenü beim Öffnen den passenden Eintrag an,
    /// statt immer beim ersten zu stehen.
    public static func matching(_ size: CanvasSize) -> CanvasPreset? {
        selectable.first { $0.size == size }
    }
}
