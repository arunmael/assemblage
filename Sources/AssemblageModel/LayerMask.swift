/// Herkunft einer Ebenenmaske (Plan 5.4).
public enum MaskSource: String, Codable, Sendable {
    /// Von Hand mit dem Pinsel gemalt.
    case manualBrush
    /// Erstvorschlag durch `VNGenerateForegroundInstanceMaskRequest` (7.3),
    /// danach ggf. von Hand nachgebessert — das Ergebnis der Automatik ist
    /// laut Plan immer nur der Startpunkt, nie das Endergebnis.
    case automaticForegroundInstance
}

/// Maske einer Ebene. Die eigentlichen Maskenpixel liegen als separate
/// Bitmap-Datei im Dokumentpaket (7.4); hier wird nur referenziert.
public struct LayerMask: Codable, Equatable, Sendable {
    /// Relativer Pfad der Masken-Bitmap innerhalb des Dokumentpakets,
    /// z. B. "masks/<layer-id>.png". `nil` = noch keine Maskenpixel vorhanden
    /// (z. B. direkt nach dem Umschalten auf "automatisch freistellen", bevor
    /// die Vision-Anfrage zurückkommt).
    public var maskImageReference: String?
    public var source: MaskSource
    public var isInverted: Bool
    public var isEnabled: Bool

    public init(
        maskImageReference: String? = nil,
        source: MaskSource,
        isInverted: Bool = false,
        isEnabled: Bool = true
    ) {
        self.maskImageReference = maskImageReference
        self.source = source
        self.isInverted = isInverted
        self.isEnabled = isEnabled
    }
}
