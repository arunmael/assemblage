/// Kuratierte Blend-Modi aus Plan-Abschnitt 5.2 — bewusst nur diese sechs,
/// nicht die 20+ Modi aus Photoshop.
public enum BlendMode: String, Codable, CaseIterable, Sendable {
    case normal
    case multiply
    case screen
    case overlay
    case lighten
    case darken
}
