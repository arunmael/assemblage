import AppKit
import Combine

/// Ob sich die schwebenden Widgets von selbst verstecken (Menü „Darstellung").
/// Gleiche Bauart wie `ThemeManager`/`RulerSettings`.
@MainActor
final class WidgetAutoHideSettings: ObservableObject {
    static let shared = WidgetAutoHideSettings()

    private static let defaultsKey = "AssemblageAutoHideWidgets"

    @Published private(set) var isEnabled: Bool

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
    }
}

/// Blendet die schwebenden Widgets aus und wieder ein — nach dem Vorbild des
/// macOS-Docks: Sie fahren an ihre Fensterkante hinaus und kommen zurück,
/// sobald der Zeiger dort hin kommt (Nutzer-Auftrag).
///
/// Bewegt werden ausschliesslich die Konstanten der Kanten-Zwänge, nicht die
/// Rahmen selbst. Nur so bleibt das übrige Layout heil: Lineale, Regler-
/// Streifen und Eigenschaften-Panel hängen aneinander, und diese Kette zieht
/// beim Ausfahren automatisch mit — das senkrechte Lineal rückt an den linken
/// Rand, weil das Ebenen-Panel vor ihm hinausfährt.
@MainActor
final class WidgetAutoHideController {

    /// An welcher Fensterkante ein Widget hängt. Der Zeiger weckt immer nur
    /// die Kante, an der er sich befindet — sonst spränge beim Griff zur
    /// Zoomleiste unten auch die ganze obere Werkzeugleiste heraus.
    enum Edge: Hashable {
        case left, top, right, bottom
    }

    /// Ein verwaltetes Widget. Klasse statt Struktur, weil das Schloss seinen
    /// Eintrag festhält und `isPinned` darin umlegt.
    @MainActor
    final class Item {
        weak var view: NSView?
        let edge: Edge
        /// Der Zwang, der das Widget an seiner Kante hält — oder `nil` für
        /// Widgets, die gar nicht hinausfahren, sondern nur aus- und
        /// einblenden (der Regler-Streifen hängt am Lineal und kann sich
        /// nicht selbst bewegen).
        let constraint: NSLayoutConstraint?
        /// Konstante im sichtbaren Zustand …
        let shownConstant: CGFloat
        /// … und im versteckten. Bei den Widgets, die sichtbar bleiben sollen
        /// (Zoom, Verlauf, Lineal), ist der Unterschied nur klein: Sie rücken
        /// an den Rand, statt zu verschwinden.
        ///
        /// Veränderbar, weil die seitlichen Panels sich in der Breite ziehen
        /// lassen (siehe `PanelResizing.swift`): Wie weit ein Panel hinaus
        /// muss, um zu verschwinden, ist genau seine Breite.
        var hiddenConstant: CGFloat
        /// Widgets, die beim Verstecken zusätzlich ausblenden, weil sie an
        /// einem sichtbar bleibenden Widget hängen und deshalb nicht
        /// hinausfahren können (der Regler-Streifen unter dem Lineal).
        let fadesOut: Bool
        /// Ob das Widget ein Schloss bekommt, mit dem es sich offen halten
        /// lässt. Nur sinnvoll bei den Widgets, die überhaupt verschwinden.
        let pinnable: Bool
        /// Wohin das Schloss gehört. `nil` heisst: neben das Widget, auf die
        /// Leinwandseite (die Vorgabe, siehe `addLocks`).
        ///
        /// Als Rückruf und nicht als Aufzählung von Ecken, weil nur der
        /// Aufrufer den Ort kennt: Beim Ebenen-Panel gehört das Schloss in
        /// dessen Fusszeile neben den Mülleimer, beim Eigenschaften-Panel
        /// unten rechts hinein — beides liegt *innerhalb* fremder
        /// Ansichtsbäume, die dieser Controller nicht kennen sollte.
        let placeLock: ((NSButton) -> Void)?
        /// Vom Nutzer festgestellt: bleibt draussen, bis er es wieder löst.
        var isPinned = false
        /// Ein anderes Widget, dessen Sichtbarkeit dieses hier übernimmt.
        ///
        /// Nötig für die beiden Anhängsel: Das Lineal sitzt unter der
        /// Werkzeugleiste und der Regler-Streifen gehört zu den
        /// Werkzeug-Spezifikationen. Nur die Kante zu vergleichen reichte
        /// nicht — stellt man die Werkzeugleiste mit dem Schloss fest, ist
        /// ihre Kante trotzdem „nicht geweckt", und das Lineal rückte unter
        /// die stehengebliebene Leiste (Nutzer-Rückmeldung). Dasselbe liess
        /// den Regler-Streifen bei festgestelltem Eigenschaften-Panel ganz
        /// verschwinden.
        ///
        /// Schwach, weil der Controller die Einträge ohnehin am Leben hält
        /// und ein Zyklus zwischen zwei Einträgen sonst beide festhielte.
        weak var follows: Item?

        init(
            view: NSView?,
            edge: Edge,
            constraint: NSLayoutConstraint?,
            shownConstant: CGFloat,
            hiddenConstant: CGFloat,
            fadesOut: Bool = false,
            pinnable: Bool = false,
            placeLock: ((NSButton) -> Void)? = nil
        ) {
            self.view = view
            self.edge = edge
            self.constraint = constraint
            self.shownConstant = shownConstant
            self.hiddenConstant = hiddenConstant
            self.fadesOut = fadesOut
            self.pinnable = pinnable
            self.placeLock = placeLock
        }
    }

    /// Wann ein Eintrag draussen steht: entweder ist seine Kante geweckt oder
    /// er ist festgestellt — beides gemessen an dem Widget, an dem er hängt
    /// (siehe `Item.follows`).
    private func isVisible(_ item: Item, revealed: Set<Edge>) -> Bool {
        let massgeblich = item.follows ?? item
        return revealed.contains(massgeblich.edge) || massgeblich.isPinned
    }

    /// Wie nah der Zeiger einer Kante kommen muss, damit ihre Widgets
    /// zurückkommen. Grosszügiger als ein blosser Fensterrand-Streifen: Zu
    /// schmal getroffen wirkte das Einblenden launisch (Nutzer-Rückmeldung).
    nonisolated static let revealBand: CGFloat = 32

    /// Zusätzlicher Fangbereich rings um den Platzhalter-Griff. Er ist das
    /// sichtbare Ziel, also darf man ihn auch grosszügig treffen.
    nonisolated static let handleReach: CGFloat = 44

    /// Dicke eines Platzhalters und sein Abstand zur Fensterkante.
    nonisolated static let handleThickness: CGFloat = 9
    nonisolated static let handleInset: CGFloat = 3

    /// Wie weit ein Widget von der Fensterkante wegbleiben muss, damit es dem
    /// Platzhalter nicht ins Gehege kommt.
    ///
    /// Betrifft alles, was beim Ausblenden der Panels an den Rand nachrückt:
    /// die beiden Lineale und die Zoom-/Verlaufsleiste. Ohne diese Schranke
    /// rutschten sie bis auf x = 0 und lagen genau über dem grauen Rahmen
    /// (Nutzer-Rückmeldung).
    nonisolated static let placeholderClearance: CGFloat = handleInset + handleThickness + 6

    private weak var container: NSView?
    private var items: [Item] = []
    private var monitor: Any?
    private var settingsSubscription: AnyCancellable?
    private var resizeObservation: NSObjectProtocol?
    private var keyObservation: NSObjectProtocol?
    private var revealed: Set<Edge> = [.left, .top, .right, .bottom]
    /// Die Platzhalter — je verschwindendem Widget einer, genau so lang wie
    /// das Widget selbst. Sie zeigen, wo etwas versteckt ist, damit die leere
    /// Fläche nicht ratlos macht (Nutzer-Auftrag).
    private var handles: [(item: Item, view: NSView)] = []
    private var locks: [(item: Item, button: NSButton)] = []

    init(container: NSView, items: [Item]) {
        self.container = container
        self.items = items

        addHandles(to: container)
        addLocks(to: container)

        settingsSubscription = WidgetAutoHideSettings.shared.$isEnabled
            .sink { [weak self] enabled in
                DispatchQueue.main.async { self?.settingChanged(to: enabled) }
            }
        observeContainerResize()
        observeKeyWindow()
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        if let resizeObservation {
            NotificationCenter.default.removeObserver(resizeObservation)
        }
        if let keyObservation {
            NotificationCenter.default.removeObserver(keyObservation)
        }
    }

    // MARK: - Griffe und Schlösser

    /// Ein grauer Platzhalter-Rahmen je verschwindendem Widget, an dessen
    /// Fensterkante — so lang wie das Widget selbst, von dessen Anfang bis zu
    /// dessen Ende (Nutzer-Auftrag).
    ///
    /// Die frühere Fassung war ein kurzer Strich mittig an jeder Fensterkante:
    /// zu klein, und vier gleich aussehende Striche waren nicht
    /// auseinanderzuhalten. Der Platzhalter zeigt jetzt die *Ausdehnung*
    /// dessen, was dort herauskommt.
    ///
    /// Nur für Widgets, die wirklich verschwinden (`pinnable`): Zoom-,
    /// Verlaufsleiste und Lineal bleiben ohnehin sichtbar, ein Platzhalter
    /// neben ihnen wäre eine Ankündigung von nichts.
    ///
    /// Der Trick beim Anhängen: Auf der Achse, an der das Widget hinausfährt,
    /// hängt der Platzhalter am Container (er bleibt am Rand stehen), quer
    /// dazu am Widget selbst — und *diese* Anker bewegen sich beim Ausfahren
    /// nicht. So passt der Rahmen ohne eine einzige nachgeführte Konstante.
    private func addHandles(to container: NSView) {
        let dicke = Self.handleThickness
        let abstand = Self.handleInset

        for item in items where item.pinnable {
            guard let widget = item.view else { continue }

            let griff = AutoHideHandleView()
            griff.translatesAutoresizingMaskIntoConstraints = false
            griff.alphaValue = 0
            container.addSubview(griff)
            handles.append((item, griff))

            switch item.edge {
            case .left:
                NSLayoutConstraint.activate([
                    griff.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: abstand),
                    griff.widthAnchor.constraint(equalToConstant: dicke),
                    griff.topAnchor.constraint(equalTo: widget.topAnchor),
                    griff.bottomAnchor.constraint(equalTo: widget.bottomAnchor)
                ])
            case .right:
                NSLayoutConstraint.activate([
                    griff.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -abstand),
                    griff.widthAnchor.constraint(equalToConstant: dicke),
                    griff.topAnchor.constraint(equalTo: widget.topAnchor),
                    griff.bottomAnchor.constraint(equalTo: widget.bottomAnchor)
                ])
            case .top:
                NSLayoutConstraint.activate([
                    griff.topAnchor.constraint(equalTo: container.topAnchor, constant: abstand),
                    griff.heightAnchor.constraint(equalToConstant: dicke),
                    griff.leadingAnchor.constraint(equalTo: widget.leadingAnchor),
                    griff.trailingAnchor.constraint(equalTo: widget.trailingAnchor)
                ])
            case .bottom:
                NSLayoutConstraint.activate([
                    griff.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -abstand),
                    griff.heightAnchor.constraint(equalToConstant: dicke),
                    griff.leadingAnchor.constraint(equalTo: widget.leadingAnchor),
                    griff.trailingAnchor.constraint(equalTo: widget.trailingAnchor)
                ])
            }
        }
    }

    /// Je verschwindendem Widget ein kleines Schloss (Nutzer-Auftrag).
    ///
    /// Wo es sitzt, bestimmt der Aufrufer über `Item.placeLock`. Die frühere
    /// Fassung setzte es immer *neben* das Widget, auf die Leinwandseite —
    /// dort war es beim Ebenen- und beim Eigenschaften-Panel unerreichbar:
    /// Ein Schloss ausserhalb des Widgets liegt nicht mehr über dem Widget,
    /// also verschwand dieses, sobald man mit dem Zeiger hinfuhr.
    ///
    /// Ohne eigene Angabe bleibt es bei der alten Regel — die passt für die
    /// Werkzeugleiste, deren Schloss links daneben liegt und mit ihr wandert.
    private func addLocks(to container: NSView) {
        for item in items where item.pinnable {
            guard let widget = item.view else { continue }

            let knopf = NSButton()
            knopf.isBordered = false
            knopf.bezelStyle = .regularSquare
            knopf.imagePosition = .imageOnly
            knopf.target = self
            knopf.action = #selector(togglePin(_:))
            knopf.alphaValue = 0
            // Ausgeblendet statt nur durchsichtig: In der Fusszeile des
            // Ebenen-Panels sitzt es in einem `NSStackView`, der ihm sonst
            // auch bei ausgeschaltetem Ausblenden Platz freihielte.
            knopf.isHidden = !WidgetAutoHideSettings.shared.isEnabled
            knopf.toolTip = "Widget offen halten"
            knopf.setAccessibilityLabel("Widget offen halten")
            knopf.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                knopf.widthAnchor.constraint(equalToConstant: 20),
                knopf.heightAnchor.constraint(equalToConstant: 20)
            ])

            if let placeLock = item.placeLock {
                placeLock(knopf)
            } else {
                container.addSubview(knopf)
                NSLayoutConstraint.activate([
                    knopf.centerYAnchor.constraint(equalTo: widget.centerYAnchor),
                    // Links hängende Widgets bekommen das Schloss rechts von
                    // sich, alle anderen links — immer auf der Leinwandseite.
                    item.edge == .left
                        ? knopf.leadingAnchor.constraint(equalTo: widget.trailingAnchor, constant: 6)
                        : knopf.trailingAnchor.constraint(equalTo: widget.leadingAnchor, constant: -6)
                ])
            }
            locks.append((item, knopf))
        }
        refreshLockIcons()
    }

    @objc private func togglePin(_ sender: NSButton) {
        guard let treffer = locks.first(where: { $0.button === sender }) else { return }
        treffer.item.isPinned.toggle()
        refreshLockIcons()
        apply(revealed: revealed, animated: true)
    }

    /// Nur für Tests: stellt die Widgets einer Kante fest, ohne dass jemand
    /// auf das Schloss klicken müsste.
    ///
    /// Nur die Einträge mit Schloss — genau die kann der Nutzer feststellen.
    /// Anhängsel wie Lineal und Regler-Streifen folgen ihrem Widget von
    /// selbst (siehe `Item.follows`); sie hier mitzusetzen würde den
    /// Zusammenhang im Test verdecken.
    func setPinnedForTesting(edge: Edge, pinned: Bool) {
        for item in items where item.edge == edge && item.pinnable {
            item.isPinned = pinned
        }
        refreshLockIcons()
    }

    private func refreshLockIcons() {
        for (item, knopf) in locks {
            knopf.image = MockupIcons.image(
                item.isPinned ? .lockClosed : .lockOpen,
                pointSize: 13,
                tintColor: item.isPinned ? AssemblageTheme.accentDark : AssemblageTheme.textTertiary
            )
        }
    }

    // MARK: - Regel

    /// Welche Kanten der Zeiger gerade weckt.
    ///
    /// Rein rechnerisch und ohne Fenster, damit die Regel prüfbar bleibt: Eine
    /// Kante ist wach, wenn der Zeiger in ihrem Randstreifen liegt **oder**
    /// über einem ihrer bereits ausgefahrenen Widgets steht — sonst versteckte
    /// sich ein Panel wieder, sobald man vom Rand aus hineinfährt, um es zu
    /// benutzen.
    nonisolated static func revealedEdges(
        mouse: NSPoint,
        in bounds: NSRect,
        flipped: Bool,
        band: CGFloat = revealBand,
        widgets: [(edge: Edge, frame: NSRect)] = []
    ) -> Set<Edge> {
        var wach: Set<Edge> = []

        if mouse.x <= bounds.minX + band { wach.insert(.left) }
        if mouse.x >= bounds.maxX - band { wach.insert(.right) }
        // In einer geflippten Ansicht liegt oben bei den kleinen y-Werten.
        let obenNah = flipped ? mouse.y <= bounds.minY + band : mouse.y >= bounds.maxY - band
        let untenNah = flipped ? mouse.y >= bounds.maxY - band : mouse.y <= bounds.minY + band
        if obenNah { wach.insert(.top) }
        if untenNah { wach.insert(.bottom) }

        for widget in widgets where widget.frame.contains(mouse) {
            wach.insert(widget.edge)
        }
        return wach
    }

    /// Dasselbe, zusätzlich mit den Griffen: Wer sich einem Griff nähert,
    /// weckt dessen Kante, auch wenn er den schmalen Randstreifen selbst noch
    /// nicht erreicht hat.
    nonisolated static func revealedEdges(
        mouse: NSPoint,
        in bounds: NSRect,
        flipped: Bool,
        band: CGFloat = revealBand,
        widgets: [(edge: Edge, frame: NSRect)] = [],
        handles: [(edge: Edge, frame: NSRect)]
    ) -> Set<Edge> {
        var wach = revealedEdges(
            mouse: mouse, in: bounds, flipped: flipped, band: band, widgets: widgets
        )
        for griff in handles where griff.frame.insetBy(dx: -handleReach, dy: -handleReach).contains(mouse) {
            wach.insert(griff.edge)
        }
        return wach
    }

    // MARK: - Ablauf

    private func settingChanged(to enabled: Bool) {
        if enabled {
            startTracking()
            // Einen Durchlauf später: Beim Einschalten steht das Layout der
            // Bühne noch nicht, und aus einer halbfertigen Fenstergrösse käme
            // ein falscher Randstreifen heraus — bei zu schmal geratener
            // Fläche etwa läge der Zeiger scheinbar schon am rechten Rand.
            DispatchQueue.main.async { [weak self] in
                self?.updateFromCurrentMouseLocation()
            }
        } else {
            stopTracking()
            apply(revealed: [.left, .top, .right, .bottom], animated: true)
        }
    }

    /// Nach einer Grössenänderung des Fensters neu entscheiden: Die
    /// Randstreifen sitzen dann woanders, ohne dass sich die Maus bewegt hat.
    private func observeContainerResize() {
        guard let container else { return }
        container.postsFrameChangedNotifications = true
        resizeObservation = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: container,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard WidgetAutoHideSettings.shared.isEnabled else { return }
                self?.updateFromCurrentMouseLocation()
            }
        }
    }

    /// Nach dem Aufbau der Bühne einmal aufrufen, damit ein bereits
    /// eingeschaltetes Ausblenden sofort greift.
    func activateIfEnabled() {
        settingChanged(to: WidgetAutoHideSettings.shared.isEnabled)
    }

    private func startTracking() {
        container?.window?.acceptsMouseMovedEvents = true
        guard monitor == nil else { return }
        // Ein lokaler Monitor statt eines `NSTrackingArea`: Die Bühne ist
        // vollständig von Leinwand und Panels überdeckt, die
        // Mausbewegungen selbst behandeln — über den Monitor kommen sie
        // trotzdem alle an, ohne irgendwo einzugreifen.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func stopTracking() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard let container else { return }
        guard event.window === container.window else {
            // Der Zeiger ist in einem anderen Fenster der App — dann gehört er
            // sicher nicht an eine unserer Kanten.
            hideEverythingNotPinned()
            return
        }
        update(mouse: container.convert(event.locationInWindow, from: nil))
    }

    /// Verliert das Fenster den Fokus, verschwinden die Widgets ebenfalls:
    /// Ohne das blieben sie stehen, bis das Fenster wieder Mausereignisse
    /// bekommt — das war der Hauptgrund, warum das Einblenden launisch wirkte.
    private func observeKeyWindow() {
        keyObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let container = self.container,
                      notification.object as? NSWindow === container.window,
                      WidgetAutoHideSettings.shared.isEnabled
                else { return }
                self.hideEverythingNotPinned()
            }
        }
    }

    private func hideEverythingNotPinned() {
        guard WidgetAutoHideSettings.shared.isEnabled, !revealed.isEmpty else { return }
        apply(revealed: [], animated: true)
    }

    private func updateFromCurrentMouseLocation() {
        guard let container, let window = container.window else { return }
        let imFenster = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        update(mouse: container.convert(imFenster, from: nil))
    }

    /// Nicht privat, damit Tests die Regel ohne echte Mausbewegung auslösen können.
    func update(mouse: NSPoint) {
        // Aus einer leeren Fläche käme nur Unsinn heraus — dann lieber
        // gar nichts entscheiden und auf das nächste Layout warten.
        guard let container, !container.bounds.isEmpty else { return }
        var sichtbare = items.compactMap { item -> (edge: Edge, frame: NSRect)? in
            guard let view = item.view, isVisible(item, revealed: revealed) else { return nil }
            return (item.edge, view.frame)
        }
        // Die Schlösser zählen zu ihrem Widget: Beim Werkzeugleisten-Schloss
        // liegt der Knopf neben der Leiste, also ausserhalb ihres Rahmens —
        // ohne diese Zeilen fuhr die Leiste genau dann ein, wenn man das
        // Schloss anklicken wollte (Nutzer-Rückmeldung).
        sichtbare += locks.compactMap { item, knopf -> (edge: Edge, frame: NSRect)? in
            guard isVisible(item, revealed: revealed), let eltern = knopf.superview else { return nil }
            let imContainer = container.convert(knopf.bounds, from: eltern)
            // Etwas grosszügiger als der Knopf selbst: 20 pt sind ein kleines
            // Ziel, und der Weg dorthin darf nicht schon zu spät sein.
            return (item.edge, imContainer.insetBy(dx: -10, dy: -10))
        }
        let griffe = handles.map { (edge: $0.item.edge, frame: $0.view.frame) }
        let neu = Self.revealedEdges(
            mouse: mouse,
            in: container.bounds,
            flipped: container.isFlipped,
            widgets: sichtbare,
            handles: griffe
        )
        guard neu != revealed else { return }
        apply(revealed: neu, animated: true)
    }

    private func apply(revealed neu: Set<Edge>, animated: Bool) {
        revealed = neu
        guard let container else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.22 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true

            let eingeschaltet = WidgetAutoHideSettings.shared.isEnabled

            for item in items {
                // Ein festgestelltes Widget bleibt draussen, egal wo der
                // Zeiger steht.
                let sichtbar = isVisible(item, revealed: neu)
                item.constraint?.constant = sichtbar ? item.shownConstant : item.hiddenConstant
                if item.fadesOut {
                    item.view?.animator().alphaValue = sichtbar ? 1 : 0
                }
            }

            // Ein Platzhalter zeigt sich nur, solange sein Widget wirklich
            // versteckt ist — und nur bei eingeschaltetem Ausblenden.
            for (item, griff) in handles {
                let versteckt = !isVisible(item, revealed: neu)
                griff.animator().alphaValue = eingeschaltet && versteckt ? 1 : 0
            }

            // Schlösser gibt es nur im Ausblende-Betrieb; sie erscheinen mit
            // ihrem Widget.
            for (item, knopf) in locks {
                let sichtbar = isVisible(item, revealed: neu)
                knopf.isHidden = !eingeschaltet
                knopf.animator().alphaValue = eingeschaltet && sichtbar ? 1 : 0
                knopf.isEnabled = eingeschaltet && sichtbar
            }

            container.layoutSubtreeIfNeeded()
        }
    }
}

/// Der Platzhalter an einer Fensterkante: ein grauer Rahmen genau dort, wo ein
/// verstecktes Widget wieder herauskommt — ohne selbst bedienbar zu sein.
///
/// Nimmt ausdrücklich keine Klicks an (`hitTest` gibt `nil` zurück) — er liegt
/// über der Leinwand, und ein Rahmen, der Werkzeugklicks schluckt, wäre ein
/// Ärgernis.
@MainActor
final class AutoHideHandleView: NSView {

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Rahmen statt Vollfläche: Ein leerer Umriss liest sich als „hier ist
        // Platz für etwas", ein gefüllter Balken als Bedienelement.
        let strichbreite: CGFloat = 1
        let flaeche = bounds.insetBy(dx: strichbreite / 2, dy: strichbreite / 2)
        let radius = min(flaeche.width, flaeche.height) / 2
        let form = NSBezierPath(roundedRect: flaeche, xRadius: radius, yRadius: radius)

        let grau = AssemblageTheme.aqua?.panelBorder ?? AssemblageTheme.textTertiary
        grau.withAlphaComponent(0.12).setFill()
        form.fill()
        grau.setStroke()
        form.lineWidth = strichbreite
        form.stroke()
    }
}
