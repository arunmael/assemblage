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

    /// Ein verwaltetes Widget.
    struct Item {
        weak var view: NSView?
        let edge: Edge
        /// Der Zwang, der das Widget an seiner Kante hält.
        let constraint: NSLayoutConstraint
        /// Konstante im sichtbaren Zustand …
        let shownConstant: CGFloat
        /// … und im versteckten. Bei den Widgets, die sichtbar bleiben sollen
        /// (Zoom, Verlauf, Lineal), ist der Unterschied nur klein: Sie rücken
        /// an den Rand, statt zu verschwinden.
        let hiddenConstant: CGFloat
        /// Widgets, die beim Verstecken zusätzlich ausblenden, weil sie an
        /// einem sichtbar bleibenden Widget hängen und deshalb nicht
        /// hinausfahren können (der Regler-Streifen unter dem Lineal).
        var fadesOut: Bool = false
    }

    /// Wie nah der Zeiger einer Kante kommen muss, damit ihre Widgets
    /// zurückkommen.
    nonisolated static let revealBand: CGFloat = 24

    private weak var container: NSView?
    private var items: [Item] = []
    private var monitor: Any?
    private var settingsSubscription: AnyCancellable?
    private var resizeObservation: NSObjectProtocol?
    private var revealed: Set<Edge> = [.left, .top, .right, .bottom]

    init(container: NSView, items: [Item]) {
        self.container = container
        self.items = items

        settingsSubscription = WidgetAutoHideSettings.shared.$isEnabled
            .sink { [weak self] enabled in
                DispatchQueue.main.async { self?.settingChanged(to: enabled) }
            }
        observeContainerResize()
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        if let resizeObservation {
            NotificationCenter.default.removeObserver(resizeObservation)
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
        guard let container, event.window === container.window else { return }
        update(mouse: container.convert(event.locationInWindow, from: nil))
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
        let sichtbare = items.compactMap { item -> (edge: Edge, frame: NSRect)? in
            guard let view = item.view, revealed.contains(item.edge) else { return nil }
            return (item.edge, view.frame)
        }
        let neu = Self.revealedEdges(
            mouse: mouse,
            in: container.bounds,
            flipped: container.isFlipped,
            widgets: sichtbare
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

            for item in items {
                let sichtbar = neu.contains(item.edge)
                item.constraint.constant = sichtbar ? item.shownConstant : item.hiddenConstant
                if item.fadesOut {
                    item.view?.animator().alphaValue = sichtbar ? 1 : 0
                }
            }
            container.layoutSubtreeIfNeeded()
        }
    }
}
