import AppKit
import SwiftUI
import Combine
import AssemblageModel

/// Ersetzt den bisherigen `NSSplitViewController` (Ebenen | Werkzeuge |
/// Leinwand | Eigenschaften): Der Canvas füllt jetzt das ganze Fenster, alle
/// anderen Bereiche schweben als abgerundete Glas-Panels darüber — genau wie
/// im Claude-Design-Mockup „Assemblage UI" (Liquid Glass).
///
/// Ein einzelner Container statt mehrerer schwebender Einzel-Controller: Die
/// Positionierung aller Panels relativ zueinander (Werkzeugleiste über dem
/// Eigenschaften-Panel, Zoom-Pille neben statt unter der Ebenenliste) ist
/// eine einzige, zusammenhängende Layout-Entscheidung.
@MainActor
final class DocumentStageViewController: NSViewController {

    let canvasViewController: CanvasViewController
    let layersHostingController: NSHostingController<LayerListView>
    let inspectorHostingController: NSHostingController<InspectorView>
    let toolbarController: ToolbarController

    /// Direkte Referenzen halten Layouttests unabhängig von der Reihenfolge
    /// der mehreren gleichartigen `GlassPanel`-Subviews.
    private(set) weak var settingsBar: GlassPanel?
    private(set) weak var inspectorPanel: GlassPanel?
    private(set) weak var horizontalRuler: CanvasRulerView?
    private(set) weak var verticalRuler: CanvasRulerView?

    private let state: DocumentState
    private var observations: Set<AnyCancellable> = []

    private weak var duplicateButton: NSButton?
    private weak var deleteButton: NSButton?
    private weak var blendModeButton: NSPopUpButton?

    /// Nimmt die drei echten Fenster-Knöpfe auf (siehe `adoptTrafficLights()`).
    private let trafficLightHost = TrafficLightHostView()
    private var windowUpdateObservation: NSObjectProtocol?

    /// Zwei sich ausschliessende Anker für die Oberkante des Eigenschaften-
    /// Panels: normalerweise ein fester Abstand unter der Werkzeugleiste,
    /// aber bei sichtbarem Regler-Streifen (Pinsel/Farbe) statt dessen direkt
    /// darunter — sonst überlappten sich beide Panels, weil der Streifen bei
    /// diesen Werkzeugen höher ist als der Normalabstand.
    private var inspectorTopBelowToolbar: NSLayoutConstraint?
    private var inspectorTopBelowSettingsBar: NSLayoutConstraint?

    /// Feste Referenzen für den Themenwechsel — anders als `ToolbarController`
    /// hat dieser Controller nur zwei fest verdrahtete Icon-Knöpfe, eine
    /// eigene Registrierungsliste wäre hier Overkill.
    private weak var layersHeaderLabel: NSTextField?
    private weak var duplicateButtonRef: NSButton?
    private weak var deleteButtonRef: NSButton?
    private var themeSubscription: AnyCancellable?
    private var backgroundOpacitySubscription: AnyCancellable?
    private(set) var autoHideController: WidgetAutoHideController?

    init(
        state: DocumentState,
        canvasViewController: CanvasViewController,
        commandTarget: DocumentWindowController
    ) {
        self.state = state
        self.canvasViewController = canvasViewController
        self.layersHostingController = NSHostingController(rootView: LayerListView(state: state))
        self.inspectorHostingController = NSHostingController(rootView: InspectorView(state: state))
        self.toolbarController = ToolbarController(
            state: state,
            canvasViewController: canvasViewController,
            commandTarget: commandTarget
        )
        super.init(nibName: nil, bundle: nil)

        addChild(canvasViewController)
        addChild(layersHostingController)
        addChild(inspectorHostingController)

        // Auf den nächsten Durchlauf verschieben: `sink` feuert, *bevor*
        // `@Published` den neuen Wert geschrieben hat (siehe auch
        // `CanvasViewController.viewDidLoad`) — `refreshTheme()` läse sonst
        // noch das alte Erscheinungsbild.
        themeSubscription = ThemeManager.shared.$current
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshTheme() } }
        backgroundOpacitySubscription = BackgroundOpacityManager.shared.$opacity
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyStageTint() } }
    }

    /// Zieht Kopfzeilen-Beschriftung und Fusszeilen-Icons des Ebenen-Panels
    /// auf das aktive Erscheinungsbild nach. Alle übrigen schwebenden Panels
    /// (Werkzeugleiste, Eigenschaften-Panel, Zoom-/Verlaufsleiste) kümmern
    /// sich über ihre eigenen Abonnements selbst darum (`GlassPanel`,
    /// `ToolbarController`).
    private func refreshTheme() {
        layersHeaderLabel?.textColor = AssemblageTheme.textSecondary
        if let duplicateButtonRef {
            duplicateButtonRef.image = MockupIcons.image(.duplicate, pointSize: 14, tintColor: AssemblageTheme.textPrimary)
            duplicateButtonRef.needsDisplay = true
        }
        if let deleteButtonRef {
            deleteButtonRef.image = MockupIcons.image(.delete, pointSize: 14, tintColor: AssemblageTheme.textPrimary)
            deleteButtonRef.needsDisplay = true
        }
        applyStageTint()
    }

    /// Der milchige Schleier über der ganzen Fensterfläche im
    /// Erscheinungsbild „Beautifull".
    ///
    /// Bewusst hier auf der Container-Ansicht und nicht im
    /// `CanvasViewController`: Der Bildlauf verwaltet seine eigene Ebene
    /// mit (Bildlauf-Optimierung) und räumte eine dort gesetzte
    /// Hintergrundfarbe wieder weg. Der Container gehört dagegen
    /// ausschliesslich uns. Zusammen mit dem nicht-deckenden Fenster
    /// (`DocumentWindowController.applyWindowOpacity`) und dem Bildlauf, der
    /// nichts mehr malt, ergibt das die halbdurchsichtige Scheibe, durch die
    /// Schreibtisch und andere Programme gedämpft durchscheinen.
    ///
    /// In „Soulless" bleibt der Container wie bisher ohne eigene Farbe.
    private func applyStageTint() {
        let opacity = BackgroundOpacityManager.shared.opacity
        view.layer?.backgroundColor = AssemblageTheme.aqua?.stageMilkTint
            .withAlphaComponent(opacity)
            .cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    deinit {
        if let windowUpdateObservation {
            NotificationCenter.default.removeObserver(windowUpdateObservation)
        }
    }

    /// Legt die beiden Lineale an — jedes als eigenes schwebendes Widget im
    /// selben Glas-Panel wie Werkzeugleiste und Ebenenliste (Nutzer-Auftrag:
    /// „innerhalb der Widgets, nicht ausserhalb"), statt als nackte Leiste am
    /// Fensterrand.
    ///
    /// Beide säumen die freie Arbeitsfläche: das waagerechte unter der
    /// Werkzeugleiste, das senkrechte darunter an dessen linker Flucht (siehe
    /// `constrainRulers`).
    ///
    /// Getrennt vom Setzen der Zwänge, weil der Regler-Streifen unter dem
    /// waagerechten Lineal hängt und deshalb früher gebaut werden muss, als
    /// Eigenschaften-Panel und Verlaufsleiste bereitstehen.
    private func makeRulerPanels(in container: NSView) -> (horizontal: GlassPanel, vertical: GlassPanel) {
        let waagerecht = CanvasRulerView(orientation: .horizontal)
        let senkrecht = CanvasRulerView(orientation: .vertical)
        horizontalRuler = waagerecht
        verticalRuler = senkrecht

        // Fester, moderater Radius statt `panelCornerRadius`: Bei nur 24 pt
        // Dicke würde der grosse Panelradius die Leiste zur Kapsel runden und
        // die äusseren Striche unter der Wölbung verschlucken.
        let waagerechtPanel = GlassPanel(cornerRadius: AssemblageTheme.toolButtonCornerRadius)
        waagerechtPanel.content = waagerecht
        let senkrechtPanel = GlassPanel(cornerRadius: AssemblageTheme.toolButtonCornerRadius)
        senkrechtPanel.content = senkrecht

        for panel in [waagerechtPanel, senkrechtPanel] {
            panel.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(panel)
        }
        return (waagerechtPanel, senkrechtPanel)
    }

    /// Setzt die Lineale an ihren Platz: das waagerechte unter die
    /// Werkzeugleiste, beide innerhalb der freien Arbeitsfläche zwischen
    /// Ebenen- und Eigenschaften-Panel (Nutzer-Auftrag: unterhalb der
    /// Werkzeuge, endend vor dem Ebenen-Widget).
    @discardableResult
    private func constrainRulers(
        horizontal waagerechtPanel: GlassPanel,
        vertical senkrechtPanel: GlassPanel,
        in container: NSView,
        rightOf layersPanel: NSView,
        leftOf inspectorPanel: NSView,
        above undoBar: NSView
    ) -> NSLayoutConstraint {
        let dicke = AssemblageTheme.rulerThickness
        // Am Container statt an der Werkzeugleiste, obwohl es optisch unter ihr
        // sitzt: Beim automatischen Ausblenden fährt die Werkzeugleiste aus dem
        // Fenster, das Lineal soll aber sichtbar bleiben (Nutzer-Auftrag) und
        // darf ihr deshalb nicht angehängt sein.
        let waagerechtTop = waagerechtPanel.topAnchor.constraint(
            equalTo: container.topAnchor, constant: Self.rulerTopWhenToolbarVisible
        )
        NSLayoutConstraint.activate([
            waagerechtTop,
            waagerechtPanel.heightAnchor.constraint(equalToConstant: dicke),
            // Beginnt erst nach dem Ebenen-Panel und endet vor dem
            // Eigenschaften-Panel: Das Lineal misst genau den Ausschnitt der
            // Leinwand, den man zwischen den beiden auch sieht.
            waagerechtPanel.leadingAnchor.constraint(
                equalTo: layersPanel.trailingAnchor, constant: AssemblageTheme.margin
            ),
            waagerechtPanel.trailingAnchor.constraint(
                equalTo: inspectorPanel.leadingAnchor, constant: -AssemblageTheme.margin
            ),

            senkrechtPanel.topAnchor.constraint(equalTo: waagerechtPanel.bottomAnchor, constant: 10),
            senkrechtPanel.leadingAnchor.constraint(equalTo: waagerechtPanel.leadingAnchor),
            senkrechtPanel.widthAnchor.constraint(equalToConstant: dicke),
            // Endet über der Verlaufsleiste, die unten an derselben Flucht
            // beginnt.
            senkrechtPanel.bottomAnchor.constraint(equalTo: undoBar.topAnchor, constant: -10)
        ])
        guard let waagerecht = horizontalRuler, let senkrecht = verticalRuler else { return waagerechtTop }

        // Nullpunkt und Massstab werden bei jedem Zeichnen frisch aus der Lage
        // der Leinwand abgeleitet, statt sie zwischenzuspeichern — `convert`
        // rechnet Zoom und Bildlauf bereits mit, und beides ändert sich
        // laufend.
        waagerecht.geometryProvider = { [weak self, weak waagerecht] in
            guard let self, let waagerecht else { return nil }
            let groesse = canvasViewController.canvasDocumentSize
            guard groesse.width > 0 else { return nil }
            let leinwand = waagerecht.convert(canvasViewController.canvasRectInWindow, from: nil)
            // Nullpunkt in der Leinwandmitte, nicht an ihrer Kante.
            return RulerGeometry(
                zero: leinwand.midX,
                scale: leinwand.width / groesse.width,
                documentLength: groesse.width
            )
        }
        senkrecht.geometryProvider = { [weak self, weak senkrecht] in
            guard let self, let senkrecht else { return nil }
            let groesse = canvasViewController.canvasDocumentSize
            guard groesse.height > 0 else { return nil }
            let leinwand = senkrecht.convert(canvasViewController.canvasRectInWindow, from: nil)
            // Nullpunkt in der Leinwandmitte. Nach oben zählt das Lineal
            // positiv — das besorgt `CanvasRulerView.achsenrichtung`.
            return RulerGeometry(
                zero: leinwand.midY,
                scale: leinwand.height / groesse.height,
                documentLength: groesse.height
            )
        }

        canvasViewController.onCanvasGeometryChange = { [weak waagerecht, weak senkrecht] in
            waagerecht?.refresh()
            senkrecht?.refresh()
        }
        return waagerechtTop
    }

    /// Oberkante des waagerechten Lineals bei sichtbarer Werkzeugleiste:
    /// direkt darunter. Als Rechnung statt als feste Zahl, damit eine andere
    /// Zeilenhöhe nicht stillschweigend zu einer Überlappung führt.
    private static var rulerTopWhenToolbarVisible: CGFloat {
        AssemblageTheme.margin + ToolbarController.toolbarRowHeight + 10
    }

    /// Oberkante des Lineals, wenn die Werkzeugleiste ausgefahren ist: knapp
    /// unter den Ampel-Knöpfen, die im obersten Streifen liegen bleiben.
    private static let rulerTopWhenToolbarHidden: CGFloat = 30

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        let canvasView = canvasViewController.view
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: container.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        let layersPanel = GlassPanel(cornerRadius: AssemblageTheme.panelCornerRadius)
        layersPanel.content = makeLayersPanelContent()
        layersPanel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(layersPanel)
        // Als Variable, weil das automatische Ausblenden genau diese Konstante
        // verschiebt (siehe `makeAutoHideController`).
        let layersLeading = layersPanel.leadingAnchor.constraint(
            equalTo: container.leadingAnchor, constant: AssemblageTheme.margin
        )
        NSLayoutConstraint.activate([
            // Der Streifen ganz oben gehört den echten Ampel-Knöpfen (siehe
            // unten und `adoptTrafficLights()`).
            layersPanel.topAnchor.constraint(equalTo: container.topAnchor, constant: AssemblageTheme.margin),
            layersPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -AssemblageTheme.margin),
            layersLeading,
            layersPanel.widthAnchor.constraint(equalToConstant: AssemblageTheme.layersPanelWidth)
        ])

        // Die echten Fenster-Knöpfe sitzen im freien Streifen über dem
        // Ebenen-Panel, in derselben Flucht. Grösse kommt aus der
        // intrinsischen Grösse des Hosts, der sie erst zur Laufzeit aufnimmt
        // (`adoptTrafficLights()`).
        trafficLightHost.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(trafficLightHost)
        NSLayoutConstraint.activate([
            // Am Container statt am Ebenen-Panel: Sonst führe beim
            // automatischen Ausblenden das Panel die Schliessen-, Ablegen- und
            // Vollbild-Knöpfe mit aus dem Fenster hinaus.
            trafficLightHost.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: AssemblageTheme.margin
            ),
            trafficLightHost.centerYAnchor.constraint(
                equalTo: container.topAnchor, constant: AssemblageTheme.margin / 2
            )
        ])

        let toolbarRow = toolbarController.buildFloatingToolbarRow()
        container.addSubview(toolbarRow)
        let toolbarTop = toolbarRow.topAnchor.constraint(
            equalTo: container.topAnchor, constant: AssemblageTheme.margin
        )
        NSLayoutConstraint.activate([
            toolbarTop,
            toolbarRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -AssemblageTheme.margin)
        ])
        let toolbarLeading = toolbarRow.leadingAnchor.constraint(
            greaterThanOrEqualTo: layersPanel.trailingAnchor,
            constant: AssemblageTheme.margin
        )
        // Bewusst zwingend: Die Werkzeugleiste ist so breit, wie ihre
        // Cluster es verlangen, und darf nie unter das Ebenen-Panel
        // geraten. AppKit leitet daraus die tatsächliche Mindestbreite des
        // Fensters ab (Ebenen-Panel + Ränder + Zeilenbreite) — sie liegt
        // damit über der in `DocumentWindowController` gesetzten
        // `contentMinSize`, die nur die untere Schranke bleibt. Eine
        // nachgiebige Priorität wäre hier nutzlos: AppKit zieht sie bei der
        // Mindestgrösse trotzdem heran, sodass das Fenster gar nicht erst
        // in den Überlappungsbereich käme.
        toolbarLeading.isActive = true

        // Die Lineale entstehen schon hier, weil der Regler-Streifen gleich
        // unter dem waagerechten hängt; ihre eigenen Zwänge kommen erst am
        // Ende, wenn auch Eigenschaften-Panel und Verlaufsleiste stehen.
        let (horizontalRulerPanel, verticalRulerPanel) = makeRulerPanels(in: container)

        // Regler für Pinsel/Lasso/Farbe — im Mockup nicht vorgesehen (siehe
        // `ToolbarController.buildToolSettingsBar`), deshalb als eigene,
        // nur bei Bedarf sichtbare Pille unter Werkzeugleiste und Lineal.
        let settingsBar = toolbarController.buildToolSettingsBar()
        self.settingsBar = settingsBar
        settingsBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(settingsBar)
        NSLayoutConstraint.activate([
            settingsBar.topAnchor.constraint(equalTo: horizontalRulerPanel.bottomAnchor, constant: 10),
            settingsBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -AssemblageTheme.margin),
            settingsBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        let inspectorPanel = GlassPanel(cornerRadius: AssemblageTheme.panelCornerRadius)
        self.inspectorPanel = inspectorPanel
        inspectorPanel.content = inspectorHostingController.view
        inspectorPanel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inspectorPanel)
        // Feste statt „höchstens so gross"-Unterkante: Erst dadurch bekommt
        // das SwiftUI-`Form` darin immer die volle verfügbare Höhe und kann
        // bei zu langem Inhalt sauber selbst scrollen, statt dass ihm Auto
        // Layout nur so viel Höhe zugesteht, wie sein eigener Inhalt „will"
        // — das liess längere Hinweistexte (Zuschneiden/Pinsel/Verziehen)
        // abgeschnitten wirken.
        let inspectorTopBelowToolbar = inspectorPanel.topAnchor.constraint(
            equalTo: container.topAnchor, constant: AssemblageTheme.topContentInset
        )
        let inspectorTopBelowSettingsBar = inspectorPanel.topAnchor.constraint(
            equalTo: settingsBar.bottomAnchor, constant: 10
        )
        self.inspectorTopBelowToolbar = inspectorTopBelowToolbar
        self.inspectorTopBelowSettingsBar = inspectorTopBelowSettingsBar
        let inspectorTrailing = inspectorPanel.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -AssemblageTheme.margin
        )
        NSLayoutConstraint.activate([
            inspectorTopBelowToolbar,
            inspectorPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -AssemblageTheme.margin),
            inspectorTrailing,
            inspectorPanel.widthAnchor.constraint(equalToConstant: AssemblageTheme.inspectorPanelWidth),
            // Nur die linke Kante begrenzt die Mindestbreite: Pinsel- und
            // Farbregler brauchen rund 570 pt und dürfen deshalb weiter nach
            // links wachsen; eine feste Gleichbreite mit den 248 pt des
            // Inspectors würde diese Regler unbedienbar zusammendrücken.
            settingsBar.leadingAnchor.constraint(lessThanOrEqualTo: inspectorPanel.leadingAnchor)
        ])
        toolbarController.onSettingsBarVisibilityChange = { [weak self] isVisible in
            self?.inspectorTopBelowToolbar?.isActive = !isVisible
            self?.inspectorTopBelowSettingsBar?.isActive = isVisible
        }

        // Getauscht gegenüber der ersten Fassung (auf Wunsch): die
        // Verlaufsleiste steht jetzt neben dem Ebenen-Panel unten links, der
        // Zoom unten rechts auf der freien Leinwand.
        let undoBar = toolbarController.buildUndoBar()
        undoBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(undoBar)
        let undoBottom = undoBar.bottomAnchor.constraint(
            equalTo: container.bottomAnchor, constant: -AssemblageTheme.margin
        )
        NSLayoutConstraint.activate([
            undoBar.leadingAnchor.constraint(equalTo: layersPanel.trailingAnchor, constant: AssemblageTheme.margin),
            undoBottom,
            undoBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        // Erst hier, weil die Lineale sich an Ebenen-Panel, Eigenschaften-Panel
        // und Verlaufsleiste ausrichten — die muss es dafür alle schon geben.
        let rulerTop = constrainRulers(
            horizontal: horizontalRulerPanel,
            vertical: verticalRulerPanel,
            in: container,
            rightOf: layersPanel,
            leftOf: inspectorPanel,
            above: undoBar
        )

        let zoomBar = toolbarController.buildZoomBar()
        zoomBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(zoomBar)
        let zoomBottom = zoomBar.bottomAnchor.constraint(
            equalTo: container.bottomAnchor, constant: -AssemblageTheme.margin
        )
        NSLayoutConstraint.activate([
            // Das Eigenschaften-Panel klebt selbst am rechten Fensterrand;
            // rechts daneben gibt es keinen Platz. Links davon bleibt die
            // Pille unten rechts auf der Leinwand, ohne Inhalt zu überdecken.
            zoomBar.trailingAnchor.constraint(equalTo: inspectorPanel.leadingAnchor, constant: -AssemblageTheme.margin),
            zoomBottom,
            zoomBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        autoHideController = makeAutoHideController(
            container: container,
            layersPanel: (layersPanel, layersLeading),
            toolbarRow: (toolbarRow, toolbarTop),
            settingsBar: settingsBar,
            inspectorPanel: (inspectorPanel, inspectorTrailing),
            ruler: (horizontalRulerPanel, rulerTop),
            undoBar: (undoBar, undoBottom),
            zoomBar: (zoomBar, zoomBottom)
        )

        view = container
        applyStageTint()
    }

    /// Verdrahtet das automatische Ausblenden (Menü „Darstellung").
    ///
    /// Welches Widget wohin fährt, steht hier an einer Stelle beisammen:
    /// Ebenen-Panel nach links, Werkzeugleiste nach oben, Eigenschaften-Panel
    /// nach rechts — die drei verschwinden ganz. Verlaufs- und Zoomleiste
    /// rücken nur an die Unterkante, das Lineal nach oben unter die
    /// Ampel-Knöpfe: Diese drei bleiben immer sichtbar (Nutzer-Auftrag).
    ///
    /// Das senkrechte Lineal braucht keinen eigenen Eintrag — es hängt am
    /// waagerechten und am Ebenen-Panel und rückt dadurch von selbst an den
    /// linken Rand, sobald das Panel hinausfährt.
    private func makeAutoHideController(
        container: NSView,
        layersPanel: (view: NSView, leading: NSLayoutConstraint),
        toolbarRow: (view: NSView, top: NSLayoutConstraint),
        settingsBar: NSView,
        inspectorPanel: (view: NSView, trailing: NSLayoutConstraint),
        ruler: (view: NSView, top: NSLayoutConstraint),
        undoBar: (view: NSView, bottom: NSLayoutConstraint),
        zoomBar: (view: NSView, bottom: NSLayoutConstraint)
    ) -> WidgetAutoHideController {
        let rand = AssemblageTheme.margin
        // Nur noch ein Hauch Abstand zur Kante für die Widgets, die sichtbar
        // bleiben, aber Platz machen sollen.
        let anDerKante: CGFloat = 4

        let items: [WidgetAutoHideController.Item] = [
            .init(
                view: layersPanel.view, edge: .left, constraint: layersPanel.leading,
                shownConstant: rand,
                hiddenConstant: -(AssemblageTheme.layersPanelWidth + rand),
                pinnable: true
            ),
            .init(
                view: toolbarRow.view, edge: .top, constraint: toolbarRow.top,
                shownConstant: rand,
                hiddenConstant: -(ToolbarController.toolbarRowHeight + rand),
                pinnable: true
            ),
            .init(
                view: inspectorPanel.view, edge: .right, constraint: inspectorPanel.trailing,
                shownConstant: -rand,
                hiddenConstant: AssemblageTheme.inspectorPanelWidth + rand,
                pinnable: true
            ),
            .init(
                view: ruler.view, edge: .top, constraint: ruler.top,
                shownConstant: Self.rulerTopWhenToolbarVisible,
                hiddenConstant: Self.rulerTopWhenToolbarHidden
            ),
            .init(
                view: undoBar.view, edge: .bottom, constraint: undoBar.bottom,
                shownConstant: -rand, hiddenConstant: -anDerKante
            ),
            .init(
                view: zoomBar.view, edge: .bottom, constraint: zoomBar.bottom,
                shownConstant: -rand, hiddenConstant: -anDerKante
            ),
            // Hängt unter dem Lineal, kann also nicht mit hinausfahren —
            // blendet deshalb weich aus.
            .init(
                view: settingsBar, edge: .top, constraint: ruler.top,
                shownConstant: Self.rulerTopWhenToolbarVisible,
                hiddenConstant: Self.rulerTopWhenToolbarHidden,
                fadesOut: true
            )
        ]
        return WidgetAutoHideController(container: container, items: items)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        adoptTrafficLights()
    }

    /// Hängt die drei echten Fenster-Knöpfe (Schliessen/Einklappen/Vollbild)
    /// aus der System-Titelleiste in `trafficLightHost` um — also in den
    /// Streifen über dem Ebenen-Panel, linksbündig mit dessen Kante.
    ///
    /// Umhängen statt bloss verschieben: Die Knöpfe per `setFrameOrigin` an
    /// die Wunschstelle zu schieben hielt nicht, weil AppKit die Titelleiste
    /// nach `viewDidLayout` noch einmal selbst anordnet und die Knöpfe dabei
    /// kommentarlos auf ihre Standardposition zurücksetzt — genau das liess
    /// sie scheinbar zufällig mal hier, mal dort sitzen. In unserer eigenen
    /// Ansichtshierarchie greift AppKits Titelleisten-Layout nicht mehr zu.
    ///
    /// Läuft bei jedem Layout statt nur einmal, weil AppKit sich die Knöpfe
    /// bei manchen Fenstervorgängen (z. B. Vollbild) zurückholt; die
    /// `superview`-Prüfung macht jeden weiteren Aufruf zum No-op.
    private func adoptTrafficLights() {
        guard let window = view.window,
              let close = window.standardWindowButton(.closeButton),
              let miniaturize = window.standardWindowButton(.miniaturizeButton),
              let zoomButton = window.standardWindowButton(.zoomButton),
              close.superview !== trafficLightHost
        else { return }

        trafficLightHost.adopt([close, miniaturize, zoomButton])
    }

    // MARK: - Ebenen-Panel: Kopf- und Fusszeile

    /// Baut das ganze Ebenen-Panel: Kopfzeile („EBENEN" + Hinzufügen-Menü),
    /// die bestehende `LayerListView` in der Mitte, Fusszeile (Duplizieren/
    /// Löschen/Blend-Modus). Kopf- und Fusszeile bleiben reines AppKit statt
    /// Teil von `LayerListView`, damit deren eigener, unabhängig
    /// restylter Zustand nicht mit dieser Layout-Entscheidung kollidiert.
    private func makeLayersPanelContent() -> NSView {
        let header = makeLayersHeader()
        let list = layersHostingController.view
        let footer = makeLayersFooter()

        // Mehr Luft an allen vier Seiten als im Mockup-Rohwert (14/18): Bei
        // exakt 14 pt sassen Kopf- und Fusszeilen-Symbole sichtbar zu nah an
        // der abgerundeten Panel-Kante.
        let insets = NSEdgeInsets(top: 18, left: 22, bottom: 22, right: 22)

        let stack = NSStackView(views: [header, list, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = insets

        // Auf die *Innenbreite* festnageln, nicht auf `stack.widthAnchor`:
        // Ein vertikaler `NSStackView` mit `alignment = .leading` streckt
        // seine Kinder nicht selbst auf die volle Breite, ein Constraint auf
        // die volle Stack-Breite liess sie aber links und rechts genau um die
        // `edgeInsets` überstehen — Kopf-/Fusszeile klebten dadurch bündig an
        // der Panel-Kante, statt den vorgesehenen Rand zu haben.
        let seitenraender = insets.left + insets.right
        for view in [header, list, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -seitenraender
            ).isActive = true
        }

        return stack
    }

    /// Kein Hinzufügen-Menü mehr in der Kopfzeile: „Text einfügen“,
    /// „Rechteck“ und „Ellipse“ gab es bereits redundant über die
    /// Werkzeugleiste (Text-Button, Formen-Menü) und die ⌘K-Suche — das
    /// Plus hier bot keinen eigenen Mehrwert.
    private func makeLayersHeader() -> NSView {
        let title = NSTextField(labelWithString: "EBENEN")
        title.font = .systemFont(ofSize: 11, weight: .bold)
        title.textColor = AssemblageTheme.textSecondary
        layersHeaderLabel = title

        let row = NSStackView(views: [title])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        observeWindowUpdatesForTrafficLights()
        // Erst jetzt gibt es ein Fenster, dessen Mausbewegungen der
        // Ausblend-Controller mitlesen kann.
        autoHideController?.activateIfEnabled()
    }

    /// AppKit holt sich die umgehängten Ampel-Knöpfe von sich aus in die
    /// Titelleiste zurück — nachgemessen unter anderem beim Fensterwechsel,
    /// und zwar ohne dass dabei zwingend ein Layout unserer Ansichten läuft.
    /// `NSWindow.didUpdateNotification` kommt in jedem Ereignisschleifen-
    /// Durchlauf dieses Fensters und ist damit der einzige Haken, der das
    /// zuverlässig auffängt; teuer ist das nicht, weil `adoptTrafficLights()`
    /// im Normalfall nach einem Zeigervergleich zurückkehrt.
    private func observeWindowUpdatesForTrafficLights() {
        guard let window = view.window, windowUpdateObservation == nil else { return }
        windowUpdateObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.adoptTrafficLights() }
        }
    }

    private func makeLayersFooter() -> NSView {
        // Leer erstellen und `cell` vor Bild/Ziel tauschen — siehe
        // ausführlicher Kommentar zum selben Muster in
        // `ToolbarController.makeToolButton`.
        let duplicate = NSButton()
        duplicate.cell = AquaButtonCell()
        duplicate.target = self
        duplicate.action = #selector(duplicateSelected(_:))
        duplicate.image = MockupIcons.image(.duplicate, pointSize: 14, tintColor: AssemblageTheme.textPrimary)
        duplicate.isBordered = true
        duplicate.wantsLayer = true
        duplicate.toolTip = "Duplizieren"
        self.duplicateButton = duplicate
        self.duplicateButtonRef = duplicate

        let delete = NSButton()
        delete.cell = AquaButtonCell()
        delete.target = self
        delete.action = #selector(deleteSelected(_:))
        delete.image = MockupIcons.image(.delete, pointSize: 14, tintColor: AssemblageTheme.textPrimary)
        delete.isBordered = true
        delete.wantsLayer = true
        delete.toolTip = "Löschen"
        self.deleteButton = delete
        self.deleteButtonRef = delete

        let blendMenu = NSPopUpButton(frame: .zero, pullsDown: false)
        blendMenu.bezelStyle = .texturedRounded
        blendMenu.isBordered = false
        for mode in BlendMode.allCases {
            blendMenu.addItem(withTitle: mode.localizedName)
        }
        blendMenu.target = self
        blendMenu.action = #selector(blendModeChanged(_:))
        self.blendModeButton = blendMenu

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView(views: [duplicate, delete, NSView(), blendMenu])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        let stack = NSStackView(views: [divider, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        // `alignment = .leading` streckt Kind-Ansichten in einem vertikalen
        // Stack nicht automatisch auf die volle Breite — ohne diese Zeile
        // wäre die Trennlinie nur so breit wie ihre eigene Mindestgrösse.
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        controls.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        observeSelection()
        return stack
    }

    private func observeSelection() {
        state.$document
            .combineLatest(state.$selectedLayerID)
            .sink { [weak self] document, selectedLayerID in
                self?.updateFooter(document: document, selectedLayerID: selectedLayerID)
            }
            .store(in: &observations)
    }

    private func updateFooter(document: AssemblageModel.Document, selectedLayerID: UUID?) {
        let layer = selectedLayerID.flatMap { document.layer(withID: $0) }
        duplicateButton?.isEnabled = layer != nil
        deleteButton?.isEnabled = layer != nil
        blendModeButton?.isEnabled = layer != nil
        if let layer, let index = BlendMode.allCases.firstIndex(of: layer.blendMode) {
            blendModeButton?.selectItem(at: index)
        }
    }

    @objc private func duplicateSelected(_ sender: Any?) {
        guard let id = state.selectedLayerID else { return }
        _ = LayerListEditing(state: state).duplicate(id)
    }

    @objc private func deleteSelected(_ sender: Any?) {
        guard let id = state.selectedLayerID else { return }
        LayerListEditing(state: state).delete(id)
    }

    @objc private func blendModeChanged(_ sender: NSPopUpButton) {
        guard let id = state.selectedLayerID,
              let mode = BlendMode.allCases[safe: sender.indexOfSelectedItem]
        else { return }
        InspectorEditing(state: state).updateSelectedLayer(actionName: "Blend-Modus ändern") {
            $0.blendMode = mode
        }
        _ = id
    }
}

/// Trägt die aus der Titelleiste umgehängten Ampel-Knöpfe (siehe
/// `DocumentStageViewController.adoptTrafficLights()`).
///
/// Übernimmt zwei Aufgaben, die AppKits eigener Titelleisten-Container
/// erledigt hatte und die beim Umhängen verloren gehen:
///
/// 1. Das Anordnen der Knöpfe. Bewusst von Hand in `layout()` statt über
///    Constraints: AppKit setzt die Rahmen der Ampel-Knöpfe auch dann noch
///    gelegentlich selbst (z. B. beim Aktivieren des Fensters), und ein
///    Auto-Layout-Durchlauf, der das wieder geradezieht, folgt nicht
///    zuverlässig. Hier wird jede fremde Verschiebung über die
///    Rahmen-Benachrichtigung bemerkt und sofort zurückgesetzt.
/// 2. Den Gruppen-Hover: In der Titelleiste erscheinen alle drei Symbole
///    (×, −, ⤢), sobald die Maus über *einen* der Knöpfe fährt.
@MainActor
final class TrafficLightHostView: NSView {

    private static let buttonSize: CGFloat = 14
    private static let gap: CGFloat = 6

    private var buttons: [NSButton] = []
    private var frameObservations: [NSObjectProtocol] = []
    private var hoverArea: NSTrackingArea?

    deinit {
        frameObservations.forEach(NotificationCenter.default.removeObserver)
    }

    override var intrinsicContentSize: NSSize {
        guard !buttons.isEmpty else {
            return NSSize(width: 3 * Self.buttonSize + 2 * Self.gap, height: Self.buttonSize)
        }
        let count = CGFloat(buttons.count)
        return NSSize(
            width: count * Self.buttonSize + (count - 1) * Self.gap,
            height: Self.buttonSize
        )
    }

    /// Hängt die übergebenen Fenster-Knöpfe hier herein (in Reihenfolge von
    /// links nach rechts).
    func adopt(_ buttons: [NSButton]) {
        let center = NotificationCenter.default
        frameObservations.forEach(center.removeObserver)
        frameObservations.removeAll()

        self.buttons = buttons
        for button in buttons {
            button.removeFromSuperview()
            button.translatesAutoresizingMaskIntoConstraints = true
            addSubview(button)
            button.postsFrameChangedNotifications = true
            frameObservations.append(center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: button,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsLayout = true }
            })
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let y = ((bounds.height - Self.buttonSize) / 2).rounded()
        for (index, button) in buttons.enumerated() {
            let ziel = NSRect(
                x: CGFloat(index) * (Self.buttonSize + Self.gap),
                y: y,
                width: Self.buttonSize,
                height: Self.buttonSize
            )
            // Nur bei Abweichung zuweisen: Sonst löste jede Zuweisung wieder
            // die eigene Rahmen-Benachrichtigung aus und das Layout liefe
            // endlos im Kreis.
            if button.frame != ziel { button.frame = ziel }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { setSymbolsVisible(true) }
    override func mouseExited(with event: NSEvent) { setSymbolsVisible(false) }

    private func setSymbolsVisible(_ visible: Bool) {
        for button in buttons {
            button.isHighlighted = visible
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
