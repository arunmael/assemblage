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

    private let state: DocumentState
    private var observations: Set<AnyCancellable> = []

    private weak var duplicateButton: NSButton?
    private weak var deleteButton: NSButton?
    private weak var blendModeButton: NSPopUpButton?

    /// Nimmt die drei echten Fenster-Knöpfe auf (siehe `adoptTrafficLights()`).
    private let trafficLightHost = TrafficLightHostView()

    /// Zwei sich ausschliessende Anker für die Oberkante des Eigenschaften-
    /// Panels: normalerweise ein fester Abstand unter der Werkzeugleiste,
    /// aber bei sichtbarem Regler-Streifen (Pinsel/Farbe) statt dessen direkt
    /// darunter — sonst überlappten sich beide Panels, weil der Streifen bei
    /// diesen Werkzeugen höher ist als der Normalabstand.
    private var inspectorTopBelowToolbar: NSLayoutConstraint?
    private var inspectorTopBelowSettingsBar: NSLayoutConstraint?

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

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

        // Bis ganz an die Fensteroberkante statt mit 24-pt-Abstand: Dort
        // sitzen jetzt auch die echten Ampel-Knöpfe (siehe
        // `adoptTrafficLights()`), genau wie im Mockup die gemalten Punkte
        // im selben Panel sitzen.
        let layersPanel = GlassPanel(cornerRadius: AssemblageTheme.panelCornerRadius)
        layersPanel.content = makeLayersPanelContent()
        layersPanel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(layersPanel)
        NSLayoutConstraint.activate([
            layersPanel.topAnchor.constraint(equalTo: container.topAnchor),
            layersPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -AssemblageTheme.margin),
            layersPanel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: AssemblageTheme.margin),
            layersPanel.widthAnchor.constraint(equalToConstant: AssemblageTheme.layersPanelWidth)
        ])

        let toolbarRow = toolbarController.buildFloatingToolbarRow()
        container.addSubview(toolbarRow)
        NSLayoutConstraint.activate([
            toolbarRow.topAnchor.constraint(equalTo: container.topAnchor, constant: AssemblageTheme.margin),
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

        // Regler für Pinsel/Lasso/Farbe — im Mockup nicht vorgesehen (siehe
        // `ToolbarController.buildToolSettingsBar`), deshalb als eigene,
        // nur bei Bedarf sichtbare Pille direkt unter der Werkzeugleiste.
        let settingsBar = toolbarController.buildToolSettingsBar()
        self.settingsBar = settingsBar
        settingsBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(settingsBar)
        NSLayoutConstraint.activate([
            settingsBar.topAnchor.constraint(equalTo: toolbarRow.bottomAnchor, constant: 10),
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
        NSLayoutConstraint.activate([
            inspectorTopBelowToolbar,
            inspectorPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -AssemblageTheme.margin),
            inspectorPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -AssemblageTheme.margin),
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
        NSLayoutConstraint.activate([
            undoBar.leadingAnchor.constraint(equalTo: layersPanel.trailingAnchor, constant: AssemblageTheme.margin),
            undoBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -AssemblageTheme.margin),
            undoBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        let zoomBar = toolbarController.buildZoomBar()
        zoomBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(zoomBar)
        NSLayoutConstraint.activate([
            // Das Eigenschaften-Panel klebt selbst am rechten Fensterrand;
            // rechts daneben gibt es keinen Platz. Links davon bleibt die
            // Pille unten rechts auf der Leinwand, ohne Inhalt zu überdecken.
            zoomBar.trailingAnchor.constraint(equalTo: inspectorPanel.leadingAnchor, constant: -AssemblageTheme.margin),
            zoomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -AssemblageTheme.margin),
            zoomBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        adoptTrafficLights()
    }

    /// Hängt die drei echten Fenster-Knöpfe (Schliessen/Einklappen/Vollbild)
    /// aus der System-Titelleiste in `trafficLightHost` um — also nach oben
    /// links ins Ebenen-Panel, wo das Mockup seine gemalten Ampel-Punkte
    /// zeigt.
    ///
    /// Umhängen statt bloss verschieben: Die Knöpfe per `setFrameOrigin` an
    /// die Wunschstelle zu schieben hielt nicht, weil AppKit die Titelleiste
    /// nach `viewDidLayout` noch einmal selbst anordnet und die Knöpfe dabei
    /// kommentarlos auf ihre Standardposition zurücksetzt — genau das liess
    /// sie scheinbar zufällig mal hier, mal dort sitzen. In unserer eigenen
    /// Ansichtshierarchie greift AppKits Titelleisten-Layout nicht mehr zu,
    /// und Auto Layout hält die Position auch bei Grössenänderungen.
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

        var previous: NSView?
        for button in [close, miniaturize, zoomButton] {
            button.removeFromSuperview()
            button.translatesAutoresizingMaskIntoConstraints = false
            trafficLightHost.addSubview(button)
            // 6 pt Lücke zwischen 14 pt breiten Knöpfen — der Abstand, den
            // AppKit in der Titelleiste selbst verwendet.
            let leading = previous.map {
                button.leadingAnchor.constraint(equalTo: $0.trailingAnchor, constant: 6)
            } ?? button.leadingAnchor.constraint(equalTo: trafficLightHost.leadingAnchor)
            NSLayoutConstraint.activate([
                leading,
                button.centerYAnchor.constraint(equalTo: trafficLightHost.centerYAnchor)
            ])
            previous = button
        }
    }

    // MARK: - Ebenen-Panel: Kopf- und Fusszeile

    /// Baut das ganze Ebenen-Panel: Kopfzeile („EBENEN" + Hinzufügen-Menü),
    /// die bestehende `LayerListView` in der Mitte, Fusszeile (Duplizieren/
    /// Löschen/Blend-Modus). Kopf- und Fusszeile bleiben reines AppKit statt
    /// Teil von `LayerListView`, damit deren eigener, unabhängig
    /// restylter Zustand nicht mit dieser Layout-Entscheidung kollidiert.
    private func makeLayersPanelContent() -> NSView {
        // Die echten Ampel-Knöpfe hängen zur Laufzeit hier drin (siehe
        // `adoptTrafficLights()`); vorher ist der Host leer und hält per
        // Höhen-Constraint den Platz frei, damit die „EBENEN"-Kopfzeile nicht
        // nach oben rutscht.
        trafficLightHost.translatesAutoresizingMaskIntoConstraints = false
        trafficLightHost.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let header = makeLayersHeader()
        let list = layersHostingController.view
        let footer = makeLayersFooter()

        // Mehr Luft an allen vier Seiten als im Mockup-Rohwert (14/18): Bei
        // exakt 14 pt sassen Kopf- und Fusszeilen-Symbole sichtbar zu nah an
        // der abgerundeten Panel-Kante.
        let insets = NSEdgeInsets(top: 18, left: 22, bottom: 22, right: 22)

        let stack = NSStackView(views: [trafficLightHost, header, list, footer])
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
        for view in [trafficLightHost, header, list, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -seitenraender
            ).isActive = true
        }

        return stack
    }

    private func makeLayersHeader() -> NSView {
        let title = NSTextField(labelWithString: "EBENEN")
        title.font = .systemFont(ofSize: 11, weight: .bold)
        title.textColor = AssemblageTheme.textSecondary

        let addMenu = NSPopUpButton(frame: .zero, pullsDown: true)
        addMenu.bezelStyle = .texturedRounded
        addMenu.isBordered = false
        addMenu.translatesAutoresizingMaskIntoConstraints = false
        addMenu.widthAnchor.constraint(equalToConstant: 24).isActive = true
        addMenu.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let title0 = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title0.image = MockupIcons.image(.layersAdd, pointSize: 14, tintColor: AssemblageTheme.textPrimary)
        addMenu.menu?.addItem(title0)

        let text = NSMenuItem(title: "Text einfügen", action: #selector(DocumentWindowController.insertTextLayer(_:)), keyEquivalent: "")
        let rectangle = NSMenuItem(title: "Rechteck", action: #selector(DocumentWindowController.insertRectangleLayer(_:)), keyEquivalent: "")
        let ellipse = NSMenuItem(title: "Ellipse", action: #selector(DocumentWindowController.insertEllipseLayer(_:)), keyEquivalent: "")
        for item in [text, rectangle, ellipse] {
            addMenu.menu?.addItem(item)
        }
        // `target` lässt sich erst setzen, sobald das Panel tatsächlich in
        // einem Fenster hängt (`self.view` wäre an dieser Stelle noch
        // innerhalb des eigenen `loadView()` — ein Zugriff darauf würde
        // `loadView()` erneut anstossen). Wird in `viewDidAppear()`
        // nachgezogen.
        addMenuItemsNeedingWindow.append(contentsOf: [text, rectangle, ellipse])

        let row = NSStackView(views: [title, NSView(), addMenu])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .equalSpacing
        return row
    }

    /// Menüeinträge, deren `target` erst gesetzt werden kann, wenn das
    /// Panel tatsächlich in einem Fenster hängt (`commandTarget` ist der
    /// `DocumentWindowController`, an den die Aktionen über die
    /// Responder-Kette ohnehin weitergereicht würden — hier aber explizit
    /// gesetzt, weil ein `NSPopUpButton`-Menü nicht selbst in der
    /// Responder-Kette hängt).
    private var addMenuItemsNeedingWindow: [NSMenuItem] = []

    override func viewDidAppear() {
        super.viewDidAppear()
        let target = view.window?.windowController
        for item in addMenuItemsNeedingWindow {
            item.target = target
        }
    }

    private func makeLayersFooter() -> NSView {
        let duplicate = NSButton(
            image: MockupIcons.image(.duplicate, pointSize: 14, tintColor: AssemblageTheme.textPrimary),
            target: self, action: #selector(duplicateSelected(_:))
        )
        duplicate.isBordered = false
        duplicate.toolTip = "Duplizieren"
        self.duplicateButton = duplicate

        let delete = NSButton(
            image: MockupIcons.image(.delete, pointSize: 14, tintColor: AssemblageTheme.textPrimary),
            target: self, action: #selector(deleteSelected(_:))
        )
        delete.isBordered = false
        delete.toolTip = "Löschen"
        self.deleteButton = delete

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
/// Eigene Klasse nur wegen des Tracking-Bereichs: In der Titelleiste sorgt
/// AppKits eigener Container dafür, dass alle drei Symbole (×, −, ⤢)
/// erscheinen, sobald die Maus über *einen* der Knöpfe fährt. Diese
/// Gruppenlogik hängt an jenem Container und geht beim Umhängen verloren —
/// hier wird sie nachgebildet.
@MainActor
final class TrafficLightHostView: NSView {

    private var hoverArea: NSTrackingArea?

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
        for case let button as NSButton in subviews {
            button.isHighlighted = visible
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
