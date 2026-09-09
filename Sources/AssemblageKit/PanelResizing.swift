import AppKit
import Combine

/// Die vom Nutzer gezogenen Breiten der beiden seitlichen Panels
/// (Ebenen links, Werkzeug-Spezifikationen rechts).
///
/// Gleiche Bauart wie `ThemeManager`/`WidgetAutoHideSettings`: ein
/// gemeinsamer Stand für alle offenen Fenster, in `UserDefaults` gesichert.
/// Bewusst app- und nicht dokumentweit — die Breite eines Panels ist eine
/// Vorliebe des Nutzers, keine Eigenschaft seiner Collage.
@MainActor
final class PanelWidthSettings: ObservableObject {
    static let shared = PanelWidthSettings()

    /// Schmaler wird unbrauchbar: Die Ebenenzeilen brauchen Vorschaubild,
    /// Name und Sichtbarkeitsschalter nebeneinander.
    static let minimum: CGFloat = 190
    /// Breiter verdeckt zu viel Leinwand; die tatsächliche Obergrenze ist
    /// ohnehin der Platz im Fenster (siehe `DocumentStageViewController`).
    static let maximum: CGFloat = 520

    private static let layersKey = "AssemblageLayersPanelWidth"
    private static let inspectorKey = "AssemblageInspectorPanelWidth"

    @Published private(set) var layersWidth: CGFloat
    @Published private(set) var inspectorWidth: CGFloat

    private init() {
        layersWidth = Self.gelesen(Self.layersKey, standard: AssemblageTheme.layersPanelWidth)
        inspectorWidth = Self.gelesen(Self.inspectorKey, standard: AssemblageTheme.inspectorPanelWidth)
    }

    /// Ein fehlender Eintrag liefert 0 — dann gilt der Vorgabewert, nicht ein
    /// auf das Minimum hochgeklemmtes Nichts.
    private static func gelesen(_ key: String, standard: CGFloat) -> CGFloat {
        let wert = CGFloat(UserDefaults.standard.double(forKey: key))
        guard wert > 0 else { return standard }
        return min(max(wert, minimum), maximum)
    }

    func setLayersWidth(_ breite: CGFloat) {
        let neu = min(max(breite, Self.minimum), Self.maximum)
        guard neu != layersWidth else { return }
        layersWidth = neu
        UserDefaults.standard.set(Double(neu), forKey: Self.layersKey)
    }

    func setInspectorWidth(_ breite: CGFloat) {
        let neu = min(max(breite, Self.minimum), Self.maximum)
        guard neu != inspectorWidth else { return }
        inspectorWidth = neu
        UserDefaults.standard.set(Double(neu), forKey: Self.inspectorKey)
    }

    /// Beide zurück auf die Vorgabe — der Ausweg, wenn man sich verzogen hat
    /// (Doppelklick auf den Griff).
    func resetLayersWidth() { setLayersWidth(AssemblageTheme.layersPanelWidth) }
    func resetInspectorWidth() { setInspectorWidth(AssemblageTheme.inspectorPanelWidth) }
}

/// Der Griff, mit dem sich ein seitliches Panel breiter und schmaler ziehen
/// lässt (Nutzer-Auftrag).
///
/// Liegt **innerhalb** der Panelkante, nicht darauf oder daneben: Sonst zählte
/// der Zeiger beim Ziehen nicht mehr als „über dem Widget", und das
/// automatische Ausblenden zöge einem das Panel unter der Hand weg.
///
/// Sichtbar erst beim Überfahren — im Ruhezustand soll das Panel so
/// aufgeräumt aussehen wie bisher.
@MainActor
final class PanelResizeGripView: NSView {

    /// An welcher Kante des Panels der Griff sitzt. Bestimmt, in welche
    /// Richtung Ziehen das Panel *breiter* macht.
    enum Side {
        /// Panel hängt links, Griff an seiner rechten Kante.
        case trailingEdge
        /// Panel hängt rechts, Griff an seiner linken Kante.
        case leadingEdge
    }

    static let thickness: CGFloat = 11

    private let side: Side
    /// Die aktuelle Breite beim Aufsetzen der Maus — dagegen wird gerechnet,
    /// nicht Schritt für Schritt aufaddiert.
    private var startWidth: CGFloat = 0
    private var startX: CGFloat = 0
    private var isHovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    /// Was der Griff nicht selbst wissen kann — der Besitzer reicht es nach.
    var currentWidth: () -> CGFloat = { 0 }
    var maximumWidth: () -> CGFloat = { PanelWidthSettings.maximum }
    var apply: (CGFloat) -> Void = { _ in }
    var reset: () -> Void = {}

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        toolTip = "Breite ziehen — Doppelklick setzt zurück"
        setAccessibilityLabel("Breite des Panels ändern")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            reset()
            return
        }
        startWidth = currentWidth()
        startX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = event.locationInWindow.x - startX
        // Am rechten Panel macht Ziehen nach links breiter, am linken
        // umgekehrt — der Griff folgt in beiden Fällen dem Zeiger.
        let gewuenscht = side == .trailingEdge ? startWidth + dx : startWidth - dx
        let obergrenze = min(PanelWidthSettings.maximum, maximumWidth())
        apply(min(max(gewuenscht, PanelWidthSettings.minimum), obergrenze))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        let breite: CGFloat = 3
        let hoehe = min(bounds.height * 0.3, 60)
        let strich = NSRect(
            x: (bounds.width - breite) / 2,
            y: (bounds.height - hoehe) / 2,
            width: breite,
            height: hoehe
        )
        AssemblageTheme.textTertiary.setFill()
        NSBezierPath(roundedRect: strich, xRadius: breite / 2, yRadius: breite / 2).fill()
    }
}
