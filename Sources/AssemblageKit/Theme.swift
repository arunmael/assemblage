import AppKit

/// Die beiden Erscheinungsbilder der App. `AssemblageTheme` (siehe dort)
/// bleibt die einzige Anlaufstelle für Farben/Radien/Schatten — dieses Enum
/// entscheidet nur, welcher `ThemeTokens`-Satz gerade aktiv ist.
///
/// „Soulless" ist das bisherige, einzige Erscheinungsbild der App (bis eben
/// selbst nur „AssemblageTheme" genannt, siehe Git-Historie) — der Name kommt
/// von aussen (Nutzer-Auftrag) und ist bewusst eine Spitze gegen das kühle,
/// makellose „Liquid Glass"-Aussehen. „Beautifull" ist das neue, zweite
/// Erscheinungsbild: die Y2K-/Frutiger-Aero-/Mac-OS-X-Aqua-Optik aus
/// `UI/second-theme/secind-theme.md` (Schreibweise „Beautifull" — mit
/// doppeltem L — ist Absicht des Auftrags, kein Tippfehler dieser Datei).
enum AppTheme: String, CaseIterable, Identifiable {
    case soulless
    case beautifull

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .soulless: "Soulless"
        case .beautifull: "Beautifull"
        }
    }

    var tokens: ThemeTokens {
        switch self {
        case .soulless: SoullessTokens()
        case .beautifull: BeautifullTokens()
        }
    }
}

/// Alle optischen Stellschrauben, die sich zwischen den Erscheinungsbildern
/// unterscheiden. Bewusst getrennt von den Layout-Massen (Abstände,
/// Panelbreiten, Fensterinsets) in `AssemblageTheme` — die bleiben
/// themenunabhängig fix, weil sich an Funktion/Anordnung nichts ändern soll,
/// nur am Aussehen.
protocol ThemeTokens {

    // MARK: Farben

    var textPrimary: NSColor { get }
    var textSecondary: NSColor { get }
    var textTertiary: NSColor { get }

    var accent: NSColor { get }
    var accentDark: NSColor { get }
    var accentSoft: NSColor { get }

    var divider: NSColor { get }

    var glassBackground: NSColor { get }
    var glassBorder: NSColor { get }
    var glassShadowColor: NSColor { get }

    var canvasFrameBackground: NSColor { get }
    var inputBackground: NSColor { get }
    var handleBackground: NSColor { get }
    var stageBackground: NSColor { get }

    // MARK: Radien

    var windowCornerRadius: CGFloat { get }
    var panelCornerRadius: CGFloat { get }
    var toolClusterCornerRadius: CGFloat { get }
    var toolButtonCornerRadius: CGFloat { get }
    var pillCornerRadius: CGFloat { get }
    var canvasFrameCornerRadius: CGFloat { get }
    var canvasCornerRadius: CGFloat { get }
    var chipCornerRadius: CGFloat { get }
    var thumbnailCornerRadius: CGFloat { get }

    /// „Squircle"-Regel aus der Theme-Vorgabe: Aqua/Y2K nutzt durchgehend
    /// stetige Eckenkurven statt Kreisbögen. `CALayer.cornerCurve` ist der
    /// AppKit-Weg dahin (SwiftUI-Pendant: `RoundedRectangle(style: .continuous)`).
    var cornerCurve: CALayerCornerCurve { get }

    // MARK: Schatten

    var glassShadowRadius: CGFloat { get }
    var glassShadowOffset: CGSize { get }

    // MARK: Panel-Material

    /// Das `NSVisualEffectView`-Material hinter den schwebenden Glas-Panels.
    var panelMaterial: NSVisualEffectView.Material { get }

    /// `nil` = heutiges Aussehen (weicher Blur + Farbschicht, „Soulless").
    /// Gesetzt = Y2K-Aqua-Aussehen inklusive glänzender Knöpfe, LED-Glow,
    /// gebürstetem Metall und LCD-Anzeigen (siehe `AquaStyle`).
    var aqua: AquaStyle? { get }
}

/// Zusätzliche Werte, die es nur im Y2K-/Aqua-Erscheinungsbild gibt. Ein
/// einzelnes optionales Feld auf `ThemeTokens` (`aqua`) statt verstreuter
/// `if theme == .beautifull`-Abfragen in den Zeichen-Routinen: Die Routinen
/// fragen nur „gibt es einen `AquaStyle`?" und lesen alle Zahlen/Farben aus
/// diesem einen Wert.
struct AquaStyle {
    /// Glas-Glanz-Knopf (Regel A/B aus der Vorgabe): Verlaufsfarben von oben
    /// nach unten für den Normalzustand.
    let buttonBackgroundGradient: [NSColor]
    /// Der schmale, hellere „Glanzstreifen" nahe der Knopf-Oberkante
    /// (Lickable-Button-Muster: eine zweite, kleinere Form über der
    /// eigentlichen Kapsel).
    let buttonShineGradient: [NSColor]
    /// Verlauf beim Klick — dunkler/gesättigter, der Knopf „sinkt" (Regel A).
    let buttonPressedGradient: [NSColor]
    let buttonOutline: NSColor
    let buttonPressedOutline: NSColor

    /// „Blue LED"-Effekt (Regel C): weisser Kern, umgeben von kräftigem
    /// Leuchten in der Akzentfarbe.
    let ledCoreColor: NSColor
    let ledGlowColor: NSColor

    /// Getönt gebürstetes Metall für die grossen Panel-Flächen — liegt nur
    /// noch als sehr feines Korn *unter* `panelGradient`, siehe dort.
    let brushedMetalTint: NSColor

    /// Deckender Verlauf für Werkzeugleiste/Ebenen-/Eigenschaften-Panel &
    /// Co. — an die Palettenfenster von Pro-Apps aus der Mac-OS-X-Aqua-Ära
    /// angelehnt (z. B. Photoshop 7/CS): ein glattes, helles Blaugrau oben
    /// nach dunklerem Blaugrau unten, undurchsichtig statt durchscheinend.
    /// Ersetzt den ursprünglichen „Liquid Glass"-Weichzeichner-Ansatz für
    /// dieses Erscheinungsbild komplett (Nutzer-Rückmeldung: eher wie ein
    /// echtes Aqua-Werkzeugfenster als wie durchscheinendes Milchglas).
    let panelGradient: [NSColor]
    /// Dünner, matter Rand statt der hellen Glaskante — Pro-App-Paletten
    /// haben eine sichtbare, aber unauffällige dunkle Kontur.
    let panelBorder: NSColor
    /// Schmaler heller Streifen exakt an der Oberkante, wie die Glanzkante
    /// einer Aqua-Titelleiste — bewusst schmal statt eines grossen
    /// Diagonal-Streifens über die halbe Fläche.
    let panelHighlight: NSColor
    /// Ganz leichter heller Schleier über der sonst komplett durchsichtigen
    /// Fläche rund um Leinwand/Widgets (`CanvasViewController.
    /// applyStageBackground`) — macht die Fensterkante als solche erkennbar,
    /// ohne die Durchsicht auf Schreibtisch/andere Programme zu verlieren.
    let stageMilkTint: NSColor

    /// LCD-Anzeige (Regel D): dunkler, versenkter Bildschirm mit heller
    /// Schrift in einer Mono-/Pixel-Schriftart.
    let lcdBackground: NSColor
    let lcdForeground: NSColor
    let lcdFont: NSFont
}

/// Das heutige, einzige Erscheinungsbild — 1:1 die bisherigen Werte aus
/// `AssemblageTheme`, nur umgezogen. Keine Zahl hier wurde verändert.
struct SoullessTokens: ThemeTokens {
    let textPrimary = NSColor(srgbHex: "#1c1d1f")
    let textSecondary = NSColor(srgbHex: "#1c1d1f", alpha: 0.6)
    let textTertiary = NSColor(srgbHex: "#1c1d1f", alpha: 0.4)

    let accent = NSColor(srgbHex: "#0a84ff")
    let accentDark = NSColor(srgbHex: "#0761c9")
    let accentSoft = NSColor(srgbHex: "#0a84ff", alpha: 0.14)

    let divider = NSColor(srgbHex: "#000000", alpha: 0.08)

    let glassBackground = NSColor(srgbHex: "#ffffff", alpha: 0.55)
    let glassBorder = NSColor(srgbHex: "#ffffff", alpha: 0.7)
    let glassShadowColor = NSColor(srgbHex: "#0f172a", alpha: 0.16)

    let canvasFrameBackground = NSColor(srgbHex: "#ffffff", alpha: 0.92)
    let inputBackground = NSColor(srgbHex: "#000000", alpha: 0.045)
    let handleBackground = NSColor.white
    let stageBackground = NSColor(srgbHex: "#dde2e8")

    // Nutzer-Rückmeldung: alle Widget-Ecken (Werkzeugauswahl, Suche,
    // Ebenen-Panel, Werkzeug-Optionen usw.) sollen etwas runder wirken —
    // moderat angehoben gegenüber den bisherigen Werten, kein neuer Look.
    let windowCornerRadius: CGFloat = 24
    let panelCornerRadius: CGFloat = 26
    let toolClusterCornerRadius: CGFloat = 22
    let toolButtonCornerRadius: CGFloat = 15
    let pillCornerRadius: CGFloat = 999
    let canvasFrameCornerRadius: CGFloat = 21
    let canvasCornerRadius: CGFloat = 15
    let chipCornerRadius: CGFloat = 11
    let thumbnailCornerRadius: CGFloat = 11
    let cornerCurve: CALayerCornerCurve = .circular

    let glassShadowRadius: CGFloat = 30
    let glassShadowOffset = CGSize(width: 0, height: -10)

    let panelMaterial: NSVisualEffectView.Material = .hudWindow
    let aqua: AquaStyle? = nil
}

/// Das neue zweite Erscheinungsbild „Beautifull": Y2K-/Frutiger-Aero-/Mac-OS-
/// X-Aqua-Optik nach `UI/second-theme/secind-theme.md`. Farbwerte orientieren
/// sich an den recherchierten Referenzen (siehe „Regeln" unten): der
/// Systemblau-Verlauf des CSS-Beispiels aus der Vorgabe, `AquaColorMixer`
/// (jonsterling/AquaUI) für Ampel-/Glas-Farben und `Lickable-Button`
/// (thompsonate) für den Glanzstreifen-Aufbau.
struct BeautifullTokens: ThemeTokens {
    // Aqua-Pinstripe-Grundton: helles, kühles Blaugrau statt reinem Weiss —
    // die Vorgabe nennt ausdrücklich „translucent, candy-colored plastics"
    // und Pinstripe-Hintergründe.
    let textPrimary = NSColor(srgbHex: "#0b1f33")
    let textSecondary = NSColor(srgbHex: "#0b1f33", alpha: 0.62)
    let textTertiary = NSColor(srgbHex: "#0b1f33", alpha: 0.4)

    // Systemblau-Verlauf-Mittelton aus dem CSS-Beispiel der Vorgabe
    // (`#60c5ff` → `#007aff` → `#0056b3`).
    let accent = NSColor(srgbHex: "#007aff")
    let accentDark = NSColor(srgbHex: "#0056b3")
    let accentSoft = NSColor(srgbHex: "#60c5ff", alpha: 0.22)

    let divider = NSColor(srgbHex: "#003d7a", alpha: 0.18)

    // Nur noch für `GlassPanel`s eigene Fallback-Pfade relevant (z. B.
    // Inhalts-Container) — die sichtbare Panelfläche selbst kommt jetzt aus
    // `aqua.panelGradient`, nicht mehr aus einer durchscheinenden Farbe.
    let glassBackground = NSColor(srgbHex: "#eaf4ff", alpha: 0.32)
    let glassBorder = NSColor(srgbHex: "#7c8ba0", alpha: 0.9)
    let glassShadowColor = NSColor(srgbHex: "#00264d", alpha: 0.28)

    let canvasFrameBackground = NSColor(srgbHex: "#f2f8ff", alpha: 0.95)
    let inputBackground = NSColor(srgbHex: "#003d7a", alpha: 0.06)
    let handleBackground = NSColor.white
    // Blasses Aqua-Pinstripe-Blaugrau statt des neutralen Soulless-Grautons.
    let stageBackground = NSColor(srgbHex: "#cfe3f5")

    // Echte Aqua-Palettenfenster (Photoshop 7/CS & Co.) rundeten ursprünglich
    // nur dezent. Nutzer-Rückmeldung danach: etwas runder, näher am
    // durchgängigen Radius heutiger Apple-Apps (Widgets/Popover/Paneele) —
    // weiterhin spürbar kompakter als „Soulless", aber nicht mehr so knapp.
    let windowCornerRadius: CGFloat = 14
    let panelCornerRadius: CGFloat = 14
    let toolClusterCornerRadius: CGFloat = 13
    let toolButtonCornerRadius: CGFloat = 12
    let pillCornerRadius: CGFloat = 999
    let canvasFrameCornerRadius: CGFloat = 13
    let canvasCornerRadius: CGFloat = 10
    let chipCornerRadius: CGFloat = 9
    let thumbnailCornerRadius: CGFloat = 9
    let cornerCurve: CALayerCornerCurve = .continuous

    let glassShadowRadius: CGFloat = 22
    let glassShadowOffset = CGSize(width: 0, height: -6)

    // Ungenutzt in diesem Erscheinungsbild: `GlassPanel` blendet den
    // Weichzeichner für „Beautifull" komplett aus (siehe `aqua.panelGradient`)
    // — der Wert bleibt nur, weil ihn `ThemeTokens` verlangt.
    let panelMaterial: NSVisualEffectView.Material = .popover

    let aqua: AquaStyle? = AquaStyle(
        buttonBackgroundGradient: [
            NSColor(srgbHex: "#ffffff"),
            NSColor(srgbHex: "#dfefff"),
            NSColor(srgbHex: "#9cd0ff")
        ],
        buttonShineGradient: [
            NSColor(srgbHex: "#ffffff", alpha: 0.95),
            NSColor(srgbHex: "#ffffff", alpha: 0.15)
        ],
        buttonPressedGradient: [
            NSColor(srgbHex: "#0056b3"),
            NSColor(srgbHex: "#007aff"),
            NSColor(srgbHex: "#60c5ff")
        ],
        buttonOutline: NSColor(srgbHex: "#003d7a", alpha: 0.55),
        buttonPressedOutline: NSColor(srgbHex: "#003d7a", alpha: 0.75),
        // „Blue LED"-Regel: weisser Kern, kräftiges Cyan-Leuchten drumherum.
        ledCoreColor: NSColor(srgbHex: "#ffffff"),
        ledGlowColor: NSColor(srgbHex: "#39c7ff"),
        brushedMetalTint: NSColor(srgbHex: "#8fa3b8"),
        // Helles Blaugrau oben, dunkleres unten — der Photoshop-7/CS-
        // Paletten-Look aus dem Referenzfoto, nicht mehr ein durchsichtiger
        // Farbton über System-Weichzeichner.
        panelGradient: [
            NSColor(srgbHex: "#eef2f7"),
            NSColor(srgbHex: "#ccd6e2"),
            NSColor(srgbHex: "#aab8c9"),
            NSColor(srgbHex: "#8fa0b3")
        ],
        panelBorder: NSColor(srgbHex: "#5c6b7f", alpha: 0.8),
        panelHighlight: NSColor(srgbHex: "#ffffff", alpha: 0.9),
        stageMilkTint: NSColor(srgbHex: "#f4f8fd", alpha: 0.5),
        // Gar keine eigene Fläche mehr hinter der Prozentanzeige (Nutzer-
        // Rückmeldung: „Container ganz weg"): Von der ursprünglichen
        // LCD-Idee (Regel D der Theme-Vorgabe) bleiben nur schwarze Schrift
        // in der Mono-Schriftart auf dem Pillen-Verlauf.
        lcdBackground: NSColor.clear,
        lcdForeground: NSColor.black,
        lcdFont: NSFont(name: "Menlo-Bold", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .bold)
    )
}

/// Hält das aktive Erscheinungsbild, persistiert die Wahl und benachrichtigt
/// Beobachter (`$current`, Combine — passend zum bestehenden Stil in
/// `ToolbarController`/`DocumentStageViewController`, die Zustand ebenfalls
/// über `@Published`/Combine statt `NotificationCenter` verteilen).
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    private static let defaultsKey = "AssemblageActiveTheme"

    @Published private(set) var current: AppTheme

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        current = stored.flatMap(AppTheme.init(rawValue:)) ?? .soulless
    }

    var tokens: ThemeTokens { current.tokens }

    func setTheme(_ theme: AppTheme) {
        guard theme != current else { return }
        current = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.defaultsKey)
    }
}

/// Wie deckend der milchige Schleier über der Fensterfläche im
/// Erscheinungsbild „Beautifull" ist (Nutzer-Auftrag: einstellbare
/// Hintergrund-Durchsicht statt des bisher fest verdrahteten Werts in
/// `AquaStyle.stageMilkTint`). 1.0 = „gar nicht durchsichtig" (voll
/// deckend), kleinere Werte lassen mehr vom Schreibtisch/anderen Programmen
/// durchscheinen — dieselbe Alpha-Skala, die `stageMilkTint` schon immer
/// hatte, hier nur nutzerseitig verstellbar statt fix bei 0.5.
///
/// Eigene Klasse statt eines weiteren Felds auf `ThemeManager`: Die Wahl des
/// Erscheinungsbilds und die Durchsicht sind unabhängige Einstellungen, die
/// unabhängig beobachtet werden — `DocumentStageViewController` abonniert
/// ohnehin schon `ThemeManager.$current` separat und braucht hier dieselbe
/// Struktur noch einmal, nicht eine Erweiterung jenes Typs.
@MainActor
final class BackgroundOpacityManager: ObservableObject {
    static let shared = BackgroundOpacityManager()

    private static let defaultsKey = "AssemblageBackgroundOpacity"

    /// Die in der Vorgabe genannten Raststufen — auch als Auswahl im
    /// Menü (`AppDelegate.backgroundOpacityMenuItem`).
    nonisolated static let presets: [CGFloat] = [0.3, 0.5, 0.7, 0.9, 1.0]

    @Published private(set) var opacity: CGFloat

    private init() {
        let stored = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Double
        // 0.5 als Vorgabe, weil das genau der bisherige feste Wert von
        // `stageMilkTint` war — bestehende Fenster sehen beim Umstieg auf
        // diese Einstellung unverändert aus.
        opacity = CGFloat(stored ?? 0.5)
    }

    func setOpacity(_ value: CGFloat) {
        let geklemmt = value.clamped(to: 0...1)
        guard geklemmt != opacity else { return }
        opacity = geklemmt
        UserDefaults.standard.set(Double(geklemmt), forKey: Self.defaultsKey)
    }
}

extension NSColor {
    /// Kurzform für `#RRGGBB`-Literale, wie sie das Mockup/die Theme-Vorgabe
    /// verwenden. (Umgezogen aus `AssemblageTheme.swift`, dort bisher
    /// `private` — beide Token-Sätze hier brauchen sie.)
    convenience init(srgbHex hex: String, alpha: CGFloat = 1) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        let r = CGFloat((value & 0xFF0000) >> 16) / 255
        let g = CGFloat((value & 0x00FF00) >> 8) / 255
        let b = CGFloat(value & 0x0000FF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}
