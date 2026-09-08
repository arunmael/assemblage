import AppKit
import Combine

/// Die Masseinheiten des Lineals — Auswahl und Reihenfolge wie im Vorbild aus
/// dem Nutzer-Auftrag (das Kontextmenü am Lineal einer Bildbearbeitung).
enum RulerUnit: String, CaseIterable {
    case pixel, zoll, zentimeter, millimeter, punkt, pica, prozent

    var displayName: String {
        switch self {
        case .pixel: "Pixel"
        case .zoll: "Zoll"
        case .zentimeter: "Zentimeter"
        case .millimeter: "Millimeter"
        case .punkt: "Punkt"
        case .pica: "Pica"
        case .prozent: "Prozent"
        }
    }

    /// Physische Einheiten hängen an der echten Bildschirmgrösse, nicht am
    /// Dokument: Ein Zentimeter ist ein Zentimeter, den man mit einem Lineal
    /// am Bildschirm nachmessen kann (ausdrücklicher Nutzer-Auftrag). Weil ein
    /// solcher Zentimeter physisch feststeht, ändert sich beim Zoomen, *wie
    /// viel Dokument* darin Platz hat — genau deshalb muss das Lineal bei
    /// jeder Zoomänderung neu rechnen.
    ///
    /// Pixel und Prozent hängen umgekehrt am Dokument: Dort steht die
    /// Dokumentstrecke fest und der Abstand auf dem Schirm wächst mit dem Zoom.
    var isPhysical: Bool {
        switch self {
        case .pixel, .prozent: false
        default: true
        }
    }

    /// Länge einer Einheit in echten Zentimetern (nur für physische Einheiten).
    var centimeters: CGFloat {
        switch self {
        case .zentimeter: 1
        case .millimeter: 0.1
        case .zoll: 2.54
        case .punkt: 2.54 / 72      // 1 Punkt = 1/72 Zoll
        case .pica: 2.54 / 6        // 1 Pica = 12 Punkt
        case .pixel, .prozent: 0
        }
    }

    /// In wie viele Teilstriche eine beschriftete Marke zerfällt. Zoll wird
    /// halbiert (…/8, /4, /2), alles andere dezimal geteilt.
    var subdivisions: Int { self == .zoll ? 8 : 10 }

    /// Mögliche Schrittweiten zwischen zwei beschrifteten Marken, aufsteigend.
    /// Das Lineal nimmt daraus die kleinste, bei der die Zahlen noch nicht
    /// aneinanderstossen.
    var stepLadder: [CGFloat] {
        if self == .zoll {
            return [0.125, 0.25, 0.5, 1, 2, 4, 8, 16, 32, 64]
        }
        return (-2...6).flatMap { exponent -> [CGFloat] in
            let faktor = pow(10, CGFloat(exponent))
            return [1 * faktor, 2 * faktor, 5 * faktor]
        }
    }
}

/// Hält die gewählte Linealeinheit, sichert sie und benachrichtigt die beiden
/// Lineale. Gleiche Bauart wie `ThemeManager`/`BackgroundOpacityManager`.
@MainActor
final class RulerSettings: ObservableObject {
    static let shared = RulerSettings()

    private static let defaultsKey = "AssemblageRulerUnit"

    @Published private(set) var unit: RulerUnit

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        unit = stored.flatMap(RulerUnit.init(rawValue:)) ?? .pixel
    }

    func setUnit(_ unit: RulerUnit) {
        guard unit != self.unit else { return }
        self.unit = unit
        UserDefaults.standard.set(unit.rawValue, forKey: Self.defaultsKey)
    }
}

/// Wo die Leinwand gerade liegt — alles, was ein Lineal zum Zeichnen braucht.
struct RulerGeometry {
    /// Lage des Nullpunkts in Linealkoordinaten. Das ist die *Mitte* der
    /// Leinwand (Nutzer-Auftrag), nicht ihre obere linke Ecke.
    let zero: CGFloat
    /// Bildschirmpunkte je Dokumentpixel, also der Zoomfaktor.
    let scale: CGFloat
    /// Länge der Leinwand in Dokumentpixeln — die Bezugsgrösse für „Prozent".
    let documentLength: CGFloat
}

/// Ein Lineal am oberen oder linken Rand der Arbeitsfläche.
///
/// Es misst *live*: Beim Zoomen und Verschieben liefert
/// `geometryProvider` die neue Lage der Leinwand, das Lineal rechnet Marken
/// und Beschriftung daraufhin komplett neu. Bei den physischen Einheiten
/// (cm, mm, Zoll, Punkt, Pica) sitzen die Marken dabei in echtem Abstand auf
/// dem Bildschirm — ein Zentimeter auf dem Lineal ist ein Zentimeter auf dem
/// Glas, nachmessbar mit einem richtigen Lineal (Nutzer-Auftrag). Was sich
/// beim Zoomen ändert, ist folglich die Dokumentstrecke pro Zentimeter.
///
/// Zeichnet nur Striche und Zahlen, keinen Hintergrund: Das Lineal steckt in
/// einem `GlassPanel` und ist damit ein schwebendes Widget wie Werkzeugleiste
/// oder Ebenenliste (Nutzer-Auftrag), statt als nackte Leiste am Fensterrand
/// zu kleben.
@MainActor
final class CanvasRulerView: NSView {

    enum Orientation { case horizontal, vertical }

    let orientation: Orientation

    /// Liefert die aktuelle Lage der Leinwand. `nil`, solange es keine gibt.
    var geometryProvider: (() -> RulerGeometry?)?

    /// Geflippt, damit „oben" auch bei senkrechter Ausrichtung der kleinere
    /// Wert ist — das entspricht der Dokument-Zählrichtung (y wächst nach
    /// unten) und erspart jede Umrechnerei beim Zeichnen.
    override var isFlipped: Bool { true }

    /// Das Fenster ist `isMovableByWindowBackground`; ohne diesen Widerspruch
    /// verschöbe ein Klick aufs Lineal das ganze Fenster, statt das
    /// Kontextmenü zu öffnen (siehe `CanvasBoardView`).
    override var mouseDownCanMoveWindow: Bool { false }

    private var themeSubscription: AnyCancellable?
    private var unitSubscription: AnyCancellable?

    /// Kleinster Abstand zweier beschrifteter Marken. Grosszügig genug, dass
    /// sich vierstellige Zahlen nicht berühren, klein genug, dass ein echter
    /// Zentimeter (auf üblichen Bildschirmen gut 50 Punkte) noch als eigene
    /// Marke durchgeht statt auf 2 cm zu springen.
    private static let minimumLabelSpacing: CGFloat = 44
    /// Unterhalb dieses Abstands werden Teilstriche weggelassen.
    private static let minimumTickSpacing: CGFloat = 4

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
        unitSubscription = RulerSettings.shared.$unit
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.needsDisplay = true }
            }
        themeSubscription = ThemeManager.shared.$current
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.needsDisplay = true }
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    /// Nach jeder Zoom-/Bildlaufänderung aufzurufen.
    func refresh() { needsDisplay = true }

    // MARK: - Einheitenwahl (das Kontextmenü aus dem Vorbild)

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for unit in RulerUnit.allCases {
            let item = NSMenuItem(
                title: unit.displayName, action: #selector(selectUnit(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = unit
            item.state = unit == RulerSettings.shared.unit ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectUnit(_ sender: NSMenuItem) {
        guard let unit = sender.representedObject as? RulerUnit else { return }
        RulerSettings.shared.setUnit(unit)
    }

    // MARK: - Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        guard let geometry = geometryProvider?(), geometry.scale > 0 else { return }
        let unit = RulerSettings.shared.unit
        let einheitInPunkten = screenPoints(perUnit: unit, geometry: geometry)
        guard einheitInPunkten > 0, einheitInPunkten.isFinite else { return }

        let schritt = labelStep(unit: unit, unitLength: einheitInPunkten)
        let teilung = schritt / CGFloat(unit.subdivisions)
        let zeigeTeilstriche = teilung * einheitInPunkten >= Self.minimumTickSpacing

        let laenge = orientation == .horizontal ? bounds.width : bounds.height
        // Von der ersten sichtbaren Marke bis zur letzten. Beide Enden können
        // negativ sein: Der Nullpunkt liegt in der Leinwandmitte, und das
        // senkrechte Lineal zählt zusätzlich andersherum (siehe
        // `achsenrichtung`), weshalb hier nicht einfach von klein nach gross
        // gerechnet werden darf.
        let feinschritt = zeigeTeilstriche ? teilung : schritt
        let wertAmAnfang = value(atPosition: 0, geometry: geometry, unitLength: einheitInPunkten)
        let wertAmEnde = value(atPosition: laenge, geometry: geometry, unitLength: einheitInPunkten)
        let ersterIndex = Int(floor(min(wertAmAnfang, wertAmEnde) / feinschritt))
        let letzterIndex = Int(ceil(max(wertAmAnfang, wertAmEnde) / feinschritt))
        guard letzterIndex >= ersterIndex, letzterIndex - ersterIndex < 20_000 else { return }

        let strichfarbe = AssemblageTheme.aqua == nil
            ? AssemblageTheme.textTertiary
            : AssemblageTheme.textSecondary
        strichfarbe.setStroke()

        let striche = NSBezierPath()
        striche.lineWidth = 1

        for index in ersterIndex...letzterIndex {
            let wert = CGFloat(index) * feinschritt
            let position = self.position(
                forValue: wert, geometry: geometry, unitLength: einheitInPunkten
            ).rounded() + 0.5
            guard position >= -1, position <= laenge + 1 else { continue }

            // Ob eine Marke beschriftet wird, hängt daran, ob sie auf dem
            // groben Raster liegt — deshalb der Rest gegen `schritt` statt
            // einer eigenen zweiten Schleife.
            let vielfaches = wert / schritt
            let istBeschriftet = abs(vielfaches - vielfaches.rounded()) < 0.001
            let istHalb = !istBeschriftet && abs(abs(vielfaches - vielfaches.rounded(.down)) - 0.5) < 0.001

            let strichlaenge: CGFloat = istBeschriftet ? 9 : (istHalb ? 6 : 3.5)
            appendTick(to: striche, at: position, length: strichlaenge)

            if istBeschriftet {
                drawLabel(value: wert, step: schritt, unit: unit, at: position)
            }
        }
        striche.stroke()
    }

    private func appendTick(to path: NSBezierPath, at position: CGFloat, length: CGFloat) {
        switch orientation {
        case .horizontal:
            // Die Striche hängen an der Innenkante, also unten an der Leinwand.
            path.move(to: NSPoint(x: position, y: bounds.maxY))
            path.line(to: NSPoint(x: position, y: bounds.maxY - length))
        case .vertical:
            path.move(to: NSPoint(x: bounds.maxX, y: position))
            path.line(to: NSPoint(x: bounds.maxX - length, y: position))
        }
    }

    private func drawLabel(value: CGFloat, step: CGFloat, unit: RulerUnit, at position: CGFloat) {
        let text = Self.formatter.string(value: value, step: step)
        let attribute: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: AssemblageTheme.textSecondary
        ]
        let groesse = (text as NSString).size(withAttributes: attribute)

        switch orientation {
        case .horizontal:
            (text as NSString).draw(
                at: NSPoint(x: position + 2.5, y: bounds.minY + 1), withAttributes: attribute
            )
        case .vertical:
            // Gedreht, weil quer nur 18 Punkte Platz sind — wie im Vorbild
            // liest sich die Zahl von unten nach oben.
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.translateBy(x: bounds.minX + 1, y: position + 2.5 + groesse.width)
            context.rotate(by: -.pi / 2)
            (text as NSString).draw(at: .zero, withAttributes: attribute)
            context.restoreGState()
        }
    }

    // MARK: - Umrechnung

    /// In welche Richtung die Werte wachsen. Waagerecht nach rechts, senkrecht
    /// nach **oben** — über der Leinwandmitte ist positiv, darunter negativ
    /// (Nutzer-Auftrag). Die Ansicht selbst ist geflippt, ihre Koordinaten
    /// wachsen also nach unten; deshalb dreht das senkrechte Lineal hier das
    /// Vorzeichen um.
    private var achsenrichtung: CGFloat { orientation == .vertical ? -1 : 1 }

    /// Wo auf dem Lineal ein Wert liegt.
    private func position(
        forValue wert: CGFloat, geometry: RulerGeometry, unitLength: CGFloat
    ) -> CGFloat {
        geometry.zero + achsenrichtung * wert * unitLength
    }

    /// Welcher Wert an einer Stelle des Lineals steht — die Umkehrung von
    /// `position(forValue:…)`.
    private func value(
        atPosition position: CGFloat, geometry: RulerGeometry, unitLength: CGFloat
    ) -> CGFloat {
        (position - geometry.zero) * achsenrichtung / unitLength
    }

    /// Wie viele Bildschirmpunkte eine Einheit misst.
    ///
    /// Der ganze Unterschied zwischen „echten" und Dokumenteinheiten steckt in
    /// dieser einen Funktion: Physische Einheiten kommen aus der tatsächlichen
    /// Bildschirmgrösse und stehen damit unabhängig vom Zoom fest; Pixel und
    /// Prozent kommen aus dem Dokument und wachsen deshalb mit dem Zoom.
    private func screenPoints(perUnit unit: RulerUnit, geometry: RulerGeometry) -> CGFloat {
        switch unit {
        case .pixel:
            return geometry.scale
        case .prozent:
            return geometry.documentLength * geometry.scale / 100
        default:
            return unit.centimeters * pointsPerCentimeter
        }
    }

    /// Bildschirmpunkte je echtem Zentimeter auf *diesem* Bildschirm.
    ///
    /// `CGDisplayScreenSize` liefert die physische Grösse aus den Daten, die
    /// der Bildschirm selbst meldet; zusammen mit seiner Punktgrösse ergibt
    /// das den Massstab. Ohne diesen Schritt wären „Zentimeter" nur eine
    /// Rechengrösse aus 72 dpi und stimmten mit einem angelegten Lineal nicht
    /// überein. Meldet ein Bildschirm keine Grösse (kommt bei manchen externen
    /// Geräten vor), bleibt genau dieser 72-dpi-Notnagel.
    private var pointsPerCentimeter: CGFloat {
        guard let screen = window?.screen,
              let nummer = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return 72 / 2.54 }

        let millimeter = CGDisplayScreenSize(CGDirectDisplayID(nummer.uint32Value))
        guard millimeter.width > 0 else { return 72 / 2.54 }
        return screen.frame.width / (millimeter.width / 10)
    }

    /// Die kleinste Schrittweite, bei der die Beschriftungen einander noch
    /// nicht berühren.
    private func labelStep(unit: RulerUnit, unitLength: CGFloat) -> CGFloat {
        for schritt in unit.stepLadder where schritt * unitLength >= Self.minimumLabelSpacing {
            return schritt
        }
        return unit.stepLadder.last ?? 1
    }

    /// Zahlen im Landesformat (Komma statt Punkt) und nur mit so vielen
    /// Nachkommastellen, wie die Schrittweite überhaupt hergibt.
    private struct LabelFormatter {
        private let formatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            return formatter
        }()

        func string(value: CGFloat, step: CGFloat) -> String {
            let stellen = step >= 1 ? 0 : min(3, Int(ceil(-log10(Double(step)))))
            formatter.minimumFractionDigits = stellen
            formatter.maximumFractionDigits = stellen
            return formatter.string(from: NSNumber(value: Double(value))) ?? "\(Int(value))"
        }
    }
    private static let formatter = LabelFormatter()
}
