import AppKit

/// Farb-, Radius- und Abstandswerte des aktiven Erscheinungsbilds.
///
/// Ursprünglich der einzige Wertesatz der App (das „Liquid Glass"-Mockup,
/// siehe Git-Historie). Seit dem zweiten Erscheinungsbild „Beautifull"
/// delegieren die Farb-/Radius-/Schatten-Werte an `ThemeManager.shared` (die
/// beiden Wertesätze stehen in `Theme.swift`) — jede bestehende Aufrufstelle
/// (`AssemblageTheme.textPrimary`, `AssemblageTheme.margin`, …) funktioniert
/// dadurch unverändert weiter, liefert aber je nach Nutzerwahl im
/// „Darstellung"-Menü unterschiedliche Werte.
///
/// Reine Layout-Masse (Abstände, feste Panelbreiten, Fenster-Insets) bleiben
/// bewusst *nicht* Teil von `ThemeTokens`: An Anordnung/Funktion soll sich
/// zwischen den Erscheinungsbildern nichts ändern, nur am Aussehen.
@MainActor
enum AssemblageTheme {

    private static var tokens: ThemeTokens { ThemeManager.shared.tokens }

    // MARK: - Farben

    static var textPrimary: NSColor { tokens.textPrimary }
    static var textSecondary: NSColor { tokens.textSecondary }
    static var textTertiary: NSColor { tokens.textTertiary }

    static var accent: NSColor { tokens.accent }
    static var accentDark: NSColor { tokens.accentDark }
    static var accentSoft: NSColor { tokens.accentSoft }

    static var divider: NSColor { tokens.divider }

    static var glassBackground: NSColor { tokens.glassBackground }
    static var glassBorder: NSColor { tokens.glassBorder }
    static var glassShadowColor: NSColor { tokens.glassShadowColor }

    static var canvasFrameBackground: NSColor { tokens.canvasFrameBackground }
    static var inputBackground: NSColor { tokens.inputBackground }
    static var handleBackground: NSColor { tokens.handleBackground }
    static var stageBackground: NSColor { tokens.stageBackground }

    // MARK: - Radien

    static var windowCornerRadius: CGFloat { tokens.windowCornerRadius }
    static var panelCornerRadius: CGFloat { tokens.panelCornerRadius }
    static var toolClusterCornerRadius: CGFloat { tokens.toolClusterCornerRadius }
    static var toolButtonCornerRadius: CGFloat { tokens.toolButtonCornerRadius }
    static var pillCornerRadius: CGFloat { tokens.pillCornerRadius }
    static var canvasFrameCornerRadius: CGFloat { tokens.canvasFrameCornerRadius }
    static var canvasCornerRadius: CGFloat { tokens.canvasCornerRadius }
    static var chipCornerRadius: CGFloat { tokens.chipCornerRadius }
    static var thumbnailCornerRadius: CGFloat { tokens.thumbnailCornerRadius }
    static var cornerCurve: CALayerCornerCurve { tokens.cornerCurve }

    // MARK: - Abstände (themenunabhängig, siehe Kommentar oben)

    /// Aussenabstand aller schwebenden Panels zum Fensterrand.
    static let margin: CGFloat = 24
    static let layersPanelWidth: CGFloat = 248
    static let inspectorPanelWidth: CGFloat = 248
    /// Abstand der Werkzeugleiste (und damit von Ebenen-/Eigenschaften-Panel)
    /// von der Fensteroberkante — Platz für die schwebende Werkzeugleiste.
    static let topContentInset: CGFloat = 96

    /// Dicke der beiden Lineal-Widgets (siehe `CanvasRulerView`).
    static let rulerThickness: CGFloat = 24

    // MARK: - Schatten

    static var glassShadowRadius: CGFloat { tokens.glassShadowRadius }
    static var glassShadowOffset: CGSize { tokens.glassShadowOffset }

    // MARK: - Panel-Material / Y2K-Aqua-Zusatzwerte

    static var panelMaterial: NSVisualEffectView.Material { tokens.panelMaterial }
    /// `nil` im Erscheinungsbild „Soulless"; gesetzt in „Beautifull" (siehe
    /// `AquaStyle` in `Theme.swift`).
    static var aqua: AquaStyle? { tokens.aqua }
}
