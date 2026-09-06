import AppKit

/// Farb-, Radius- und Abstandswerte des "Liquid Glass"-Erscheinungsbilds
/// (Claude-Design-Mockup „Assemblage UI", nur der Modus „Liquid Glass" —
/// „Calm" wurde nicht übernommen, da kein Umschalter dafür beauftragt war).
///
/// Alle Zahlenwerte sind 1:1 aus dem Mockup übernommen (siehe
/// `/tmp/template_raw.html`, Zeilen 20-269, zum Zeitpunkt der Umsetzung).
/// Eine einzige Quelle dieser Werte verhindert, dass Werkzeugleiste,
/// Ebenen- und Eigenschaften-Panel beim Nachjustieren auseinanderlaufen.
enum AssemblageTheme {

    // MARK: - Farben

    /// Primäre Textfarbe auf hellem Glas-Untergrund.
    static let textPrimary = NSColor(srgbHex: "#1c1d1f")
    static let textSecondary = NSColor(srgbHex: "#1c1d1f", alpha: 0.6)
    static let textTertiary = NSColor(srgbHex: "#1c1d1f", alpha: 0.4)

    /// Systemblau, wie es auch die aktive Werkzeug-Markierung im Mockup nutzt.
    static let accent = NSColor(srgbHex: "#0a84ff")
    static let accentDark = NSColor(srgbHex: "#0761c9")
    static let accentSoft = NSColor(srgbHex: "#0a84ff", alpha: 0.14)

    static let divider = NSColor(srgbHex: "#000000", alpha: 0.08)

    /// Halbtransparenter Glas-Hintergrund der schwebenden Panels — liegt auf
    /// einem `NSVisualEffectView` (siehe `GlassPanel`), das den eigentlichen
    /// Weichzeichner-Effekt liefert; diese Farbe stellt nur den im Mockup
    /// vorgegebenen Farbton darüber sicher, da Systemmaterialien ihn nicht
    /// exakt treffen.
    static let glassBackground = NSColor(srgbHex: "#ffffff", alpha: 0.55)
    static let glassBorder = NSColor(srgbHex: "#ffffff", alpha: 0.7)
    static let glassShadowColor = NSColor(srgbHex: "#0f172a", alpha: 0.16)

    static let canvasFrameBackground = NSColor(srgbHex: "#ffffff", alpha: 0.92)
    static let inputBackground = NSColor(srgbHex: "#000000", alpha: 0.045)
    static let handleBackground = NSColor.white

    /// Fensterhintergrund hinter dem Canvas-Rahmen (radialer Verlauf im
    /// Mockup; hier als mittlerer Farbwert genähert, da ein exakter radialer
    /// Verlauf für eine reine Arbeitsfläche keinen sichtbaren Zusatznutzen
    /// hätte).
    static let stageBackground = NSColor(srgbHex: "#dde2e8")

    // MARK: - Radien

    static let windowCornerRadius: CGFloat = 20
    static let panelCornerRadius: CGFloat = 22
    static let toolClusterCornerRadius: CGFloat = 18
    static let toolButtonCornerRadius: CGFloat = 12
    static let pillCornerRadius: CGFloat = 999
    static let canvasFrameCornerRadius: CGFloat = 18
    static let canvasCornerRadius: CGFloat = 12
    static let chipCornerRadius: CGFloat = 9
    static let thumbnailCornerRadius: CGFloat = 9

    // MARK: - Abstände

    /// Aussenabstand aller schwebenden Panels zum Fensterrand.
    static let margin: CGFloat = 24
    static let layersPanelWidth: CGFloat = 248
    static let inspectorPanelWidth: CGFloat = 248
    /// Abstand der Werkzeugleiste (und damit von Ebenen-/Eigenschaften-Panel)
    /// von der Fensteroberkante — Platz für die schwebende Werkzeugleiste.
    static let topContentInset: CGFloat = 96

    // MARK: - Schatten

    static let glassShadowRadius: CGFloat = 30
    static let glassShadowOffset = CGSize(width: 0, height: -10)
}

private extension NSColor {
    /// Kurzform für `#RRGGBB`-Literale wie sie das Mockup verwendet.
    convenience init(srgbHex hex: String, alpha: CGFloat = 1) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        let r = CGFloat((value & 0xFF0000) >> 16) / 255
        let g = CGFloat((value & 0x00FF00) >> 8) / 255
        let b = CGFloat(value & 0x0000FF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}
