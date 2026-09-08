import AppKit
import Combine

/// Ein schwebendes Panel, wie es für jede aufgesetzte Fläche verwendet wird
/// (Werkzeugleisten-Cluster, Ebenenliste, Eigenschaften-Panel, Zoom- und
/// Verlaufs-Pille).
///
/// Im Erscheinungsbild „Soulless" liefert `NSVisualEffectView` einen
/// Weichzeichner (macOS kann `backdrop-filter: blur() saturate()` nicht 1:1
/// als CSS-Wert annehmen — das System-Material ist die nächstliegende native
/// Entsprechung), eine zusätzliche Farbebene darüber gleicht den im Mockup
/// vorgegebenen Farbton an, den das reine Systemmaterial nicht trifft.
///
/// Im Erscheinungsbild „Beautifull" gibt es dagegen **keinen** Weichzeichner
/// mehr: Nutzer-Rückmeldung mit einem Photoshop-7/CS-Screenshot als Vorbild
/// war ausdrücklich, dass die Paletten wie echte, undurchsichtige Aqua-
/// Werkzeugfenster aussehen sollen statt wie durchscheinendes Milchglas.
/// Der Weichzeichner wird deshalb ausgeblendet und durch einen deckenden
/// Verlauf (`aqua.panelGradient`) ersetzt, mit ganz feinem gebürstetem Metall
/// darunter (niedrige Deckkraft, nur als Korn wahrnehmbar) und einer
/// schmalen hellen Glanzkante an der Oberkante statt eines grossen
/// Diagonal-Streifens.
///
/// Rand, Ecken-Radius und Schatten kommen in beiden Erscheinungsbildern vom
/// Panel selbst, nicht von einer der inneren Ebenen — die maskieren an ihren
/// eigenen Ecken, ein Schatten auf einer maskierten Ebene würde aber
/// mitmaskiert und verschwinden.
///
/// Ein Combine-Abonnement auf `ThemeManager.shared.$current` hält alle
/// Panels beim Umschalten synchron, ohne dass die aufrufende Seite
/// (`ToolbarController`, `DocumentStageViewController`) davon wissen muss.
@MainActor
final class GlassPanel: NSView {

    /// Bei `true` wird der Ecken-Radius bei jedem Layout auf die halbe Höhe
    /// gesetzt (Kapsel-/Pillenform, z. B. Zoom- und Verlaufsleiste) statt
    /// einen festen Radius zu behalten.
    var isPill: Bool {
        didSet { needsLayout = true }
    }

    private var fixedCornerRadius: CGFloat
    private let effectView = NSVisualEffectView()
    private let brushedMetal = BrushedMetalView(tint: .white)
    private let tint = NSView()
    private let gradientLayer = CAGradientLayer()
    private let highlightLayer = CAGradientLayer()
    /// Maskiert wie `effectView`/`tint`, aus demselben Grund: Ohne eigene
    /// Maskierung lief Inhalt, der die verfügbare Höhe sprengt (z. B. ein
    /// zu langer Hinweistext im Eigenschaften-Panel), einfach über die
    /// abgerundete Ecke hinaus auf den nackten Fensterhintergrund weiter,
    /// statt sauber am Panelrand abgeschnitten zu werden.
    private let contentContainer = NSView()

    private var themeSubscription: AnyCancellable?

    /// Die eigentliche Inhaltsansicht des Panels (z. B. ein `NSStackView`
    /// oder eine `NSHostingView`). Füllt den Innenraum vollständig aus.
    var content: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let content else { return }
            content.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
        }
    }

    init(cornerRadius: CGFloat, isPill: Bool = false) {
        self.fixedCornerRadius = cornerRadius
        self.isPill = isPill
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Blendmodus ist themenabhängig (siehe `applyTheme`) — Startwert hier
        // nur, damit `effectView` vor dem ersten `applyTheme()`-Aufruf einen
        // gültigen Wert hat.
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true

        brushedMetal.wantsLayer = true
        // Nur im „Beautifull"-Erscheinungsbild sichtbar (siehe `applyTheme`),
        // dort mit stark reduzierter Deckkraft — ein Korn unter dem Verlauf,
        // nicht die dominante Fläche (das Referenzfoto zeigt glatte
        // Paletten, keine sichtbar raue Textur).
        brushedMetal.isHidden = true

        tint.wantsLayer = true
        tint.layer?.addSublayer(gradientLayer)
        tint.layer?.addSublayer(highlightLayer)
        gradientLayer.isHidden = true
        highlightLayer.isHidden = true

        contentContainer.wantsLayer = true

        for view in [effectView, brushedMetal, tint, contentContainer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        layer?.borderWidth = 1
        layer?.shadowOpacity = 1
        applyTheme()

        // Auf den nächsten Durchlauf verschieben: `sink` feuert, *bevor*
        // `@Published` den neuen Wert geschrieben hat (siehe auch
        // `CanvasViewController.viewDidLoad`) — `applyTheme()` läse sonst
        // noch das alte Erscheinungsbild.
        themeSubscription = ThemeManager.shared.$current
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyTheme() } }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    override func layout() {
        super.layout()
        applyCornerRadius(isPill ? bounds.height / 2 : fixedCornerRadius)
        gradientLayer.frame = bounds
        // Schmale Glanzkante exakt an der Oberkante (nicht die halbe Höhe):
        // die Aqua-Titelleisten-Glanzkante im Referenzfoto ist ein paar
        // Pixel hoch, kein grosser Diagonal-Streifen über das ganze Panel.
        let highlightHeight = min(10, bounds.height * 0.3)
        highlightLayer.frame = CGRect(x: 0, y: bounds.height - highlightHeight, width: bounds.width, height: highlightHeight)
    }

    private func applyCornerRadius(_ radius: CGFloat) {
        let curve = AssemblageTheme.cornerCurve
        for target in [layer, effectView.layer, brushedMetal.layer, tint.layer, contentContainer.layer] {
            target?.cornerRadius = radius
            target?.cornerCurve = curve
            target?.masksToBounds = true
        }
        // Der Schatten läuft am Panel selbst, nicht an einer maskierten
        // Ebene (siehe Klassendoku) — `masksToBounds` auf `layer` darf ihn
        // deshalb nicht mitclippen; `layer` maskiert nur seine Sublayer
        // (Rand/Formzuschnitt), der Schatten wird unabhängig davon gezeichnet.
    }

    /// Übernimmt Farben/Material/Radienkurve des aktiven Erscheinungsbilds.
    /// Läuft einmal beim Aufbau und danach bei jedem Themenwechsel — dieselbe
    /// Methode für beide Fälle hält Anfangszustand und Update garantiert
    /// deckungsgleich.
    private func applyTheme() {
        layer?.shadowRadius = AssemblageTheme.glassShadowRadius
        layer?.shadowOffset = AssemblageTheme.glassShadowOffset

        if let aqua = AssemblageTheme.aqua {
            // Nur ein bisschen durchsichtig (Nutzer-Rückmeldung): anders als
            // die Fläche rund um die Leinwand (siehe `CanvasViewController.
            // applyStageBackground`, dort komplett durchsichtig) bleiben die
            // Widgets selbst überwiegend deckend, mit leichter Durchsicht.
            effectView.isHidden = false
            effectView.material = AssemblageTheme.panelMaterial
            // „.behindWindow" statt „.withinWindow": Der Nutzer will durch
            // das Panel hindurch den Schreibtisch/andere Programme sehen,
            // nicht nur die eigene Leinwand innerhalb desselben Fensters —
            // Finder-/Mail-Seitenleisten nutzen denselben Modus für ihren
            // „Vibrancy"-Effekt.
            effectView.blendingMode = .behindWindow
            tint.layer?.backgroundColor = nil

            brushedMetal.isHidden = false
            brushedMetal.tint = aqua.brushedMetalTint
            brushedMetal.alphaValue = 0.12

            gradientLayer.isHidden = false
            gradientLayer.colors = aqua.panelGradient.map(\.cgColor)
            gradientLayer.locations = [0, 0.35, 0.7, 1]
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
            gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
            // Deckkraft statt einzelner Alpha-Werte pro Farbstopp: eine Zahl
            // regelt „wie durchsichtig", ohne die sorgfältig abgestuften
            // `panelGradient`-Farben selbst anfassen zu müssen. Hoch genug,
            // dass Text/Icons in den Widgets klar lesbar bleiben — nur ein
            // Hauch Durchsicht, nicht das durchscheinende Glas der Fläche
            // rundherum.
            gradientLayer.opacity = 0.88

            highlightLayer.isHidden = false
            highlightLayer.colors = [
                aqua.panelHighlight.cgColor,
                aqua.panelHighlight.withAlphaComponent(0).cgColor
            ]
            highlightLayer.startPoint = CGPoint(x: 0.5, y: 1)
            highlightLayer.endPoint = CGPoint(x: 0.5, y: 0)

            // Pillen (Zoom-/Verlaufsleiste) bleiben randlos — der sichtbare
            // Rand wirkte dort wie ein Rahmen um die Prozentanzeige (Nutzer-
            // Rückmeldung). Die grossen Rechteck-Panels (Werkzeugleiste,
            // Ebenen-/Eigenschaften-Panel) behalten ihn, dort liest er als
            // Fensterkante statt als Einrahmung eines einzelnen Werts.
            layer?.borderWidth = isPill ? 0 : 1
            layer?.borderColor = aqua.panelBorder.cgColor
            layer?.shadowColor = AssemblageTheme.glassShadowColor.cgColor
        } else {
            effectView.isHidden = false
            effectView.material = AssemblageTheme.panelMaterial
            effectView.blendingMode = .withinWindow
            tint.layer?.backgroundColor = AssemblageTheme.glassBackground.cgColor

            brushedMetal.isHidden = true
            brushedMetal.alphaValue = 1
            gradientLayer.isHidden = true
            highlightLayer.isHidden = true

            layer?.borderColor = AssemblageTheme.glassBorder.cgColor
            layer?.shadowColor = AssemblageTheme.glassShadowColor.cgColor
        }

        applyCornerRadius(isPill ? bounds.height / 2 : fixedCornerRadius)
    }
}
