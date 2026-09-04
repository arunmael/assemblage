import AppKit

/// Ein Eintrag der Werkzeugleiste.
struct ToolSidebarItem: Equatable {
    let tool: CanvasTool
    let title: String
    /// Name eines SF-Symbols.
    let symbolName: String
}

@MainActor
final class ToolSidebarView: NSView {

    /// Die Werkzeuge in der Reihenfolge, in der sie in der Leiste stehen.
    /// Eine Stelle, damit Leiste und Verfügbarkeitsprüfung nicht auseinanderlaufen.
    static let allTools: [CanvasTool] = [.select, .crop, .brush, .distort]

    /// Die Einträge der Leiste, wie sie das Fenster aufbaut.
    static let defaultItems: [ToolSidebarItem] = [
        ToolSidebarItem(tool: .select, title: "Auswählen", symbolName: "cursorarrow"),
        ToolSidebarItem(tool: .crop, title: "Zuschneiden", symbolName: "crop"),
        ToolSidebarItem(tool: .brush, title: "Maske malen", symbolName: "paintbrush"),
        ToolSidebarItem(tool: .distort, title: "Verziehen", symbolName: "skew")
    ]

    /// Breite im zusammengeklappten Zustand — nur Symbole.
    static let collapsedWidth: CGFloat = 44
    /// Breite im aufgeklappten Zustand — Symbol und Name.
    static let expandedWidth: CGFloat = 176

    /// Wird gerufen, wenn ein Werkzeug angetippt wird.
    var onSelect: ((CanvasTool) -> Void)?

    private var _selectedTool: CanvasTool
    /// Das hervorgehobene Werkzeug.
    var selectedTool: CanvasTool {
        get { _selectedTool }
        set {
            guard _selectedTool != newValue else { return }
            _selectedTool = newValue
            updateSelection()
        }
    }

    private var _availableTools: Set<CanvasTool>
    /// Werkzeuge, die gerade nicht benutzbar sind, werden ausgegraut und
    /// nehmen keine Klicks an.
    var availableTools: Set<CanvasTool> {
        get { _availableTools }
        set {
            guard _availableTools != newValue else { return }
            _availableTools = newValue
            updateAvailability()
        }
    }

    /// Ob die Leiste gerade aufgeklappt ist.
    private(set) var isExpanded: Bool = false

    /// Erst nach `super.init` zu bilden: Vorher gibt es kein `widthAnchor`.
    private var widthConstraint = NSLayoutConstraint()
    private let stackView = NSStackView()
    private var itemViews: [CanvasTool: ToolItemView] = [:]
    private var trackingArea: NSTrackingArea?

    init(items: [ToolSidebarItem]) {
        self._selectedTool = items.first?.tool ?? .select
        self._availableTools = Set(items.map { $0.tool })

        super.init(frame: .zero)

        widthConstraint = widthAnchor.constraint(equalToConstant: Self.collapsedWidth)
        widthConstraint.isActive = true

        self.translatesAutoresizingMaskIntoConstraints = false
        self.wantsLayer = true

        setupStackView()
        buildItems(items)
        updateSelection()
        updateAvailability()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func setupStackView() {
        stackView.orientation = .vertical
        // `.leading` und nicht `.stretch`: Auf macOS kennt NSStackView kein
        // Strecken; die Zeilen bekommen ihre Breite stattdessen unten
        // ausdrücklich von der Leiste.
        stackView.alignment = .leading
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        // Platzierung am oberen Rand mit leichtem Abstand für ein ausgewogenes Layout.
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
    }

    private func buildItems(_ items: [ToolSidebarItem]) {
        for item in items {
            let itemView = ToolItemView(item: item)
            itemView.onClick = { [weak self] in
                self?.onSelect?(item.tool)
            }
            stackView.addArrangedSubview(itemView)
            itemView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            itemViews[item.tool] = itemView
        }
    }

    // MARK: - Zugang für Tests

    // Über den Zustand der Zeilen statt über deren Position im Ansichtsbaum:
    // Ein Index bräche, sobald eine weitere Zeile dazwischenkommt.
    var labelsHiddenForTesting: Bool {
        itemViews.values.allSatisfy { $0.label.isHidden }
    }

    var toolTipsForTesting: [String] {
        itemViews.values.compactMap { $0.toolTip }
    }

    /// Tippt eine Zeile an, ohne ein echtes Mausereignis zu bauen.
    func simulateTapForTesting(_ tool: CanvasTool) {
        itemViews[tool]?.simulateTapForTesting()
    }

    private func updateSelection() {
        for (tool, itemView) in itemViews {
            itemView.isSelected = (tool == _selectedTool)
        }
    }

    private func updateAvailability() {
        for (tool, itemView) in itemViews {
            itemView.isAvailable = _availableTools.contains(tool)
        }
    }

    // Ermöglicht dem System, die Hintergrundfarbe bei Theme-Wechseln (Light/Dark Mode) automatisch anzupassen.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // Überwachung des gesamten sichtbaren Bereichs für das geschmeidige Auf-/Zuklappen bei Mausbewegung.
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        let newTrackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(newTrackingArea)
        self.trackingArea = newTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        setExpanded(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        setExpanded(false, animated: true)
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded

        let targetWidth = expanded ? Self.expandedWidth : Self.collapsedWidth

        // Um ein unschönes Abschneiden des Textes während der Breitenänderung zu verhindern,
        // werden die Labels beim Einklappen sofort versteckt und beim Ausklappen sofort eingeblendet.
        for itemView in itemViews.values {
            itemView.label.isHidden = !expanded
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                widthConstraint.animator().constant = targetWidth
            }
        } else {
            widthConstraint.constant = targetWidth
        }
    }
}

// MARK: - Helper Views

@MainActor
private final class ToolItemView: NSView {
    let tool: CanvasTool
    let imageView = NSImageView()
    let label = NSTextField()
    var onClick: (() -> Void)?

    var isSelected: Bool = false {
        didSet {
            needsDisplay = true
        }
    }

    var isAvailable: Bool = true {
        didSet {
            alphaValue = isAvailable ? 1.0 : 0.35
        }
    }

    init(item: ToolSidebarItem) {
        self.tool = item.tool
        super.init(frame: .zero)

        self.wantsLayer = true
        self.layer?.cornerRadius = 6
        self.toolTip = item.title

        setupImageView(symbolName: item.symbolName, title: item.title)
        setupLabel(title: item.title)
        setupConstraints()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func setupImageView(symbolName: String, title: String) {
        // Fallback auf ein Standard-Symbol, falls das gewünschte SF Symbol auf dem System fehlt.
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
            ?? NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: title)
        imageView.image = image
        imageView.contentTintColor = .labelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
    }

    private func setupLabel(title: String) {
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        addSubview(label)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),

            // Das Symbol bleibt fest auf seiner horizontalen Position fixiert (zentriert im eingeklappten Zustand),
            // damit es sich beim Aufklappen der Seitenleiste nicht unruhig nach rechts verschiebt.
            imageView.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 20),
            imageView.heightAnchor.constraint(equalToConstant: 20),

            // Das Label startet exakt rechts neben dem eingeklappten Bereich.
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    // Ermöglicht dem System, die Hintergrundfarbe bei Theme-Wechseln (Light/Dark Mode) automatisch anzupassen.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        simulateTapForTesting()
    }

    /// Derselbe Weg wie ein Mausklick, nur ohne Ereignis — die Prüfung auf
    /// Verfügbarkeit liegt bewusst hier und nicht im Aufrufer, damit sie im
    /// Test nicht versehentlich umgangen wird.
    func simulateTapForTesting() {
        guard isAvailable else { return }
        onClick?()
    }
}
