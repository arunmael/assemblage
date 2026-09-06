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

    private let state: DocumentState
    private var observations: Set<AnyCancellable> = []

    private weak var duplicateButton: NSButton?
    private weak var deleteButton: NSButton?
    private weak var blendModeButton: NSPopUpButton?

    /// Für die umplatzierten Ampel-Knöpfe (siehe `positionTrafficLights()`).
    private weak var layersPanel: GlassPanel?

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
        // `positionTrafficLights()`), genau wie im Mockup die gemalten Punkte
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
        self.layersPanel = layersPanel

        let toolbarRow = toolbarController.buildFloatingToolbarRow()
        container.addSubview(toolbarRow)
        NSLayoutConstraint.activate([
            toolbarRow.topAnchor.constraint(equalTo: container.topAnchor, constant: AssemblageTheme.margin),
            toolbarRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -AssemblageTheme.margin)
        ])

        // Regler für Pinsel/Lasso/Farbe — im Mockup nicht vorgesehen (siehe
        // `ToolbarController.buildToolSettingsBar`), deshalb als eigene,
        // nur bei Bedarf sichtbare Pille direkt unter der Werkzeugleiste.
        let settingsBar = toolbarController.buildToolSettingsBar()
        settingsBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(settingsBar)
        NSLayoutConstraint.activate([
            settingsBar.topAnchor.constraint(equalTo: toolbarRow.bottomAnchor, constant: 10),
            settingsBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -AssemblageTheme.margin),
            settingsBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        let inspectorPanel = GlassPanel(cornerRadius: AssemblageTheme.panelCornerRadius)
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
            inspectorPanel.widthAnchor.constraint(equalToConstant: AssemblageTheme.inspectorPanelWidth)
        ])
        toolbarController.onSettingsBarVisibilityChange = { [weak self] isVisible in
            self?.inspectorTopBelowToolbar?.isActive = !isVisible
            self?.inspectorTopBelowSettingsBar?.isActive = isVisible
        }

        // Getauscht gegenüber der ersten Fassung (auf Wunsch): die
        // Verlaufsleiste steht jetzt neben dem Ebenen-Panel unten links, der
        // Zoom unten rechts. Beide bleiben durch die feste Fensterbreite
        // dazwischen getrennt — keins darf je unter das andere geraten.
        let undoBar = toolbarController.buildUndoBar()
        undoBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(undoBar)
        NSLayoutConstraint.activate([
            undoBar.leadingAnchor.constraint(equalTo: layersPanel.trailingAnchor, constant: AssemblageTheme.margin),
            undoBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -AssemblageTheme.margin),
            undoBar.widthAnchor.constraint(equalToConstant: 180),
            undoBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        let zoomBar = toolbarController.buildZoomBar()
        zoomBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(zoomBar)
        NSLayoutConstraint.activate([
            zoomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -AssemblageTheme.margin),
            zoomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -AssemblageTheme.margin),
            zoomBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        positionTrafficLights()
    }

    /// Verschiebt die drei echten Fenster-Knöpfe (Schliessen/Einklappen/
    /// Vollbild) an die Stelle, an der das Mockup seine gemalten Ampel-Punkte
    /// zeigt — oben links im Ebenen-Panel statt in der (unsichtbar
    /// gemachten) Titelleiste. Ihr Abstand zueinander bleibt exakt Apples
    /// eigener Wert: Nur die Position der ganzen Dreiergruppe wandert, nicht
    /// ihr Aufbau — ein Nachbau der Ampel wäre unnötig fehleranfällig.
    ///
    /// Läuft bei jedem Layout statt nur einmal, weil AppKit die Knöpfe bei
    /// manchen Fenstervorgängen (z. B. Live-Grössenänderung) sonst auf ihre
    /// Standardposition zurückschnappen liesse.
    private func positionTrafficLights() {
        guard let window = view.window, let layersPanel,
              let close = window.standardWindowButton(.closeButton),
              let miniaturize = window.standardWindowButton(.miniaturizeButton),
              let zoomButton = window.standardWindowButton(.zoomButton)
        else { return }

        let offsetToMiniaturize = CGPoint(
            x: miniaturize.frame.minX - close.frame.minX,
            y: miniaturize.frame.minY - close.frame.minY
        )
        let offsetToZoom = CGPoint(
            x: zoomButton.frame.minX - close.frame.minX,
            y: zoomButton.frame.minY - close.frame.minY
        )

        // 14/18 pt Innenabstand wie das Panel selbst (siehe
        // `makeLayersPanelContent`), in Fensterkoordinaten umgerechnet.
        let targetInPanel = CGPoint(x: 14, y: layersPanel.bounds.height - 18 - close.frame.height)
        let target = layersPanel.convert(targetInPanel, to: nil)

        close.setFrameOrigin(target)
        miniaturize.setFrameOrigin(CGPoint(x: target.x + offsetToMiniaturize.x, y: target.y + offsetToMiniaturize.y))
        zoomButton.setFrameOrigin(CGPoint(x: target.x + offsetToZoom.x, y: target.y + offsetToZoom.y))
    }

    // MARK: - Ebenen-Panel: Kopf- und Fusszeile

    /// Baut das ganze Ebenen-Panel: Kopfzeile („EBENEN" + Hinzufügen-Menü),
    /// die bestehende `LayerListView` in der Mitte, Fusszeile (Duplizieren/
    /// Löschen/Blend-Modus). Kopf- und Fusszeile bleiben reines AppKit statt
    /// Teil von `LayerListView`, damit deren eigener, unabhängig
    /// restylter Zustand nicht mit dieser Layout-Entscheidung kollidiert.
    private func makeLayersPanelContent() -> NSView {
        // Platzhalter für die echten Ampel-Knöpfe, die jetzt oben im Panel
        // sitzen (siehe `positionTrafficLights()`) — sie schweben ausserhalb
        // dieser Ansichtshierarchie in Fensterkoordinaten, brauchen hier aber
        // trotzdem reservierten Platz, sonst überlappte die „EBENEN"-
        // Kopfzeile sie.
        let trafficLightSpacer = NSView()
        trafficLightSpacer.translatesAutoresizingMaskIntoConstraints = false
        trafficLightSpacer.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let header = makeLayersHeader()
        let list = layersHostingController.view
        let footer = makeLayersFooter()

        let stack = NSStackView(views: [trafficLightSpacer, header, list, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        // Mehr Luft an allen vier Seiten als im Mockup-Rohwert (14/18): Bei
        // exakt 14 pt sassen Kopf- und Fusszeilen-Symbole sichtbar zu nah an
        // der abgerundeten Panel-Kante.
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 18, right: 18)

        for view in [trafficLightSpacer, header, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
