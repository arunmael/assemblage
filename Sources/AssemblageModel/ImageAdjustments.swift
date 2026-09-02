/// Grundlegende, nicht-destruktive Bildanpassungen (Plan 5.5).
/// Wird später am Mac in eine `CIFilter`-Kette übersetzt (7.2) — hier nur
/// die reinen Parameter, damit sie versioniert/getestet werden können.
public struct ImageAdjustments: Codable, Equatable, Sendable {
    /// -1 (dunkler) ... 0 (unverändert) ... 1 (heller)
    public var brightness: Double
    /// -1 (kontrastärmer) ... 0 (unverändert) ... 1 (kontrastreicher)
    public var contrast: Double
    /// -1 (entsättigt) ... 0 (unverändert) ... 1 (übersättigt)
    public var saturation: Double
    /// -1 (kühler/blau) ... 0 (neutral) ... 1 (wärmer/orange)
    public var warmth: Double
    /// 0 (kein Weichzeichnen) ... 1 (maximal, z. B. für Bokeh-Hintergrund)
    public var blurRadius: Double
    /// 0 (kein Schärfen) ... 1 (maximal)
    public var sharpenAmount: Double

    public init(
        brightness: Double = 0,
        contrast: Double = 0,
        saturation: Double = 0,
        warmth: Double = 0,
        blurRadius: Double = 0,
        sharpenAmount: Double = 0
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.blurRadius = blurRadius
        self.sharpenAmount = sharpenAmount
    }

    /// Unveränderter Ausgangszustand — Basisfall für neu importierte Bilder.
    public static let neutral = ImageAdjustments()

    /// Alle Regler auf den gültigen Wertebereich begrenzt zurückgeben.
    /// Die UI ruft das beim Verschieben eines Reglers auf, damit nie ein
    /// ungültiger Zwischenwert (z. B. durch schnelles Ziehen) gespeichert wird.
    public func clamped() -> ImageAdjustments {
        ImageAdjustments(
            brightness: brightness.clamped(to: -1...1),
            contrast: contrast.clamped(to: -1...1),
            saturation: saturation.clamped(to: -1...1),
            warmth: warmth.clamped(to: -1...1),
            blurRadius: blurRadius.clamped(to: 0...1),
            sharpenAmount: sharpenAmount.clamped(to: 0...1)
        )
    }
}

extension Comparable {
    /// Auf einen gültigen Bereich begrenzen. Wird an vielen Stellen gebraucht,
    /// an denen ein Regler kurzzeitig ausserhalb landen kann.
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
