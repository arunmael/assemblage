import AppKit
import AssemblageModel
import Combine

/// Liest ein Dokumentpaket und erzeugt die Vorschau. Fehler bleiben hier
/// bewusst lokal: Eine defekte Vorschau darf die Projektübersicht nicht
/// blockieren und wird durch ein neutrales Symbol ersetzt.
enum ProjectThumbnailRenderer {
    static let placeholderDescription = "Projektvorschau nicht verfügbar"

    static func image(at url: URL, targetSize: CGSize) -> NSImage {
        do {
            let wrapper = try FileWrapper(url: url, options: [])
            guard let data = wrapper.fileWrappers?[DocumentPackage.documentFileName]?.regularFileContents else {
                throw ProjectThumbnailError.missingDocument
            }
            let document = try DocumentPackage.decode(data)
            let resources = DocumentResources(root: wrapper)
            try DocumentPackage.validate(document, against: resources.fileNames)
            let grösse = constrainedSize(for: document.canvas, requested: targetSize)
            let cgImage = try DocumentExporter.renderedImage(
                of: document,
                resources: resources,
                targetSize: grösse
            )
            return NSImage(cgImage: cgImage, size: grösse)
        } catch {
            return placeholder()
        }
    }

    private static func constrainedSize(for canvas: CanvasSize, requested: CGSize) -> CGSize {
        let maximaleKante = min(max(requested.width, 1), max(requested.height, 1), 400)
        let breite = CGFloat(canvas.width)
        let höhe = CGFloat(canvas.height)
        guard breite.isFinite, höhe.isFinite, breite > 0, höhe > 0 else {
            return CGSize(width: maximaleKante, height: maximaleKante)
        }
        let faktor = maximaleKante / max(breite, höhe)
        return CGSize(width: breite * faktor, height: höhe * faktor)
    }

    static func placeholder() -> NSImage {
        let image = NSImage(
            systemSymbolName: "photo.on.rectangle.angled",
            accessibilityDescription: placeholderDescription
        ) ?? NSImage(size: CGSize(width: 96, height: 72))
        image.accessibilityDescription = placeholderDescription
        return image
    }
}

private enum ProjectThumbnailError: Error {
    case missingDocument
}

/// Behält die Zeilenbildung des AppKit-Flusslayouts bei, lässt überschüssige
/// Breite aber rechts stehen, statt sie zwischen den Kacheln zu verteilen.
private final class LeftAlignedFlowLayout: NSCollectionViewFlowLayout {
    private static let zeilenToleranz: CGFloat = 1

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard let collectionView else { return super.layoutAttributesForElements(in: rect) }
        let abfrage = NSRect(
            x: 0,
            y: rect.minY - Self.zeilenToleranz,
            width: max(collectionView.bounds.width, collectionViewContentSize.width),
            height: rect.height + 2 * Self.zeilenToleranz
        )
        return ausgerichteteAttribute(in: abfrage).filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let original = super.layoutAttributesForItem(at: indexPath),
              let collectionView
        else { return nil }
        let zeilenbereich = NSRect(
            x: 0,
            y: original.frame.minY - Self.zeilenToleranz,
            width: max(collectionView.bounds.width, collectionViewContentSize.width),
            height: original.frame.height + 2 * Self.zeilenToleranz
        )
        return ausgerichteteAttribute(in: zeilenbereich)
            .first { $0.representedElementCategory == .item && $0.indexPath == indexPath }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else { return super.shouldInvalidateLayout(forBoundsChange: newBounds) }
        return collectionView.bounds.width != newBounds.width
            || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }

    private func ausgerichteteAttribute(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let originale = super.layoutAttributesForElements(in: rect)
        let kopien = originale.compactMap { $0.copy() as? NSCollectionViewLayoutAttributes }
        let kacheln = kopien
            .filter { $0.representedElementCategory == .item }
            .sorted {
                abs($0.frame.minY - $1.frame.minY) <= Self.zeilenToleranz
                    ? $0.frame.minX < $1.frame.minX
                    : $0.frame.minY < $1.frame.minY
            }

        var letzterZeilenwert: CGFloat?
        var nächsteX = sectionInset.left
        for attribut in kacheln {
            if letzterZeilenwert.map({ abs($0 - attribut.frame.minY) > Self.zeilenToleranz }) ?? true {
                letzterZeilenwert = attribut.frame.minY
                nächsteX = sectionInset.left
            }
            attribut.frame.origin.x = nächsteX
            nächsteX = attribut.frame.maxX + minimumInteritemSpacing
        }
        return kopien
    }
}

@MainActor
private final class ProjectThumbnailCache {
    private let cache = NSCache<NSString, NSImage>()

    func load(_ entry: ProjectEntry, completion: @escaping (NSImage) -> Void) {
        let key = "\(entry.url.standardizedFileURL.resolvingSymlinksInPath().path)|\(entry.modifiedAt.timeIntervalSinceReferenceDate)"
        if let image = cache.object(forKey: key as NSString) {
            completion(image)
            return
        }

        let url = entry.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = ProjectThumbnailRenderer.image(
                at: url,
                targetSize: CGSize(width: 400, height: 300)
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.cache.setObject(image, forKey: key as NSString)
                completion(image)
            }
        }
    }
}

/// Eigenständige Projektübersicht. `shared` garantiert, dass beide
/// Menüzugänge immer dasselbe Fenster nach vorne holen.
@MainActor
final class ProjectsWindowController: NSWindowController {
    static let shared = ProjectsWindowController()

    private static let itemIdentifier = NSUserInterfaceItemIdentifier("ProjectCollectionViewItem")

    private let collectionView = NSCollectionView()
    private let searchField = NSSearchField()
    private let thumbnailCache = ProjectThumbnailCache()
    private var themeSubscription: AnyCancellable?
    private var backgroundOpacitySubscription: AnyCancellable?
    private var headerButtons: [NSButton] = []
    private weak var rootView: NSView?
    private weak var projectsScrollView: NSScrollView?
    private(set) weak var headerPanelForTesting: NSView?
    private var finder: ProjectFinder?
    private var foundURLs: [URL] = []
    private var allEntries: [ProjectEntry] = []
    private let startsFinder: Bool
    private(set) var displayedEntries: [ProjectEntry] = []
    var displayedItemCount: Int { collectionView.numberOfItems(inSection: 0) }

    init(initialEntries: [ProjectEntry]? = nil, startsFinder: Bool = true) {
        self.startsFinder = startsFinder
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Projekte"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.setFrameAutosaveName("AssemblageProjectsWindow")

        // Wie beim Dokumentfenster (`DocumentWindowController`): bewusst
        // *nach* dem gesicherten Rahmen, der sonst — einmal klein gespeichert,
        // etwa durch einen Testlauf, der denselben Autosave-Namen benutzt —
        // für immer klein bliebe. `center()` allein reichte nicht: Es
        // zentriert nur die feste 900×620-Grösse, statt den ganzen
        // Bildschirm zu nutzen.
        window.setFrame(
            WindowPlacement.initialFrame(
                visibleFrame: (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? window.frame,
                minimumSize: window.frameRect(
                    forContentRect: NSRect(origin: .zero, size: window.contentMinSize)
                ).size
            ),
            display: false
        )
        super.init(window: window)
        window.delegate = self
        buildContent()
        applyTheme()
        // `@Published` benachrichtigt vor dem Schreiben des neuen Werts.
        // Deshalb erst im nächsten Hauptschleifendurchlauf neu einfärben.
        themeSubscription = ThemeManager.shared.$current
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.applyTheme() }
            }
        backgroundOpacitySubscription = BackgroundOpacityManager.shared.$opacity
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.applyBackground() }
            }

        if let initialEntries {
            allEntries = initialEntries
            applyFilter()
        } else {
            refreshEntries()
        }
        if startsFinder {
            startFinder()
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    static func showProjects() {
        shared.prepareForPresentation()
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func prepareForPresentation() {
        refreshEntries()
        if startsFinder { startFinder() }
    }

    private func startFinder() {
        if finder == nil {
            finder = ProjectFinder { [weak self] urls in
                guard let self else { return }
                self.foundURLs = urls
                self.refreshEntries()
            }
        }
        finder?.start()
    }

    private func refreshEntries() {
        allEntries = ProjectLibrary.entries(
            recent: NSDocumentController.shared.recentDocumentURLs,
            found: foundURLs,
            modificationDate: { url in
                try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
        )
        applyFilter()
    }

    private func buildContent() {
        guard let window else { return }
        let root = NSView()
        root.wantsLayer = true
        rootView = root

        let neu = themedTextButton(title: "Neues Projekt", action: #selector(newProject(_:)))
        let öffnen = themedTextButton(title: "Öffnen…", action: #selector(openDocumentPanel(_:)))
        searchField.placeholderString = "Projekte suchen"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.isBezeled = true
        searchField.bezelStyle = .roundedBezel
        searchField.drawsBackground = true

        let header = NSStackView(views: [neu, öffnen, searchField])
        header.orientation = .horizontal
        header.spacing = 10
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        searchField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        searchField.heightAnchor.constraint(equalToConstant: 30).isActive = true

        // Derselbe Radius wie bei den Werkzeugleisten-Clustern: Die
        // Kopfzeile ist die funktionale, über dem Projektraster schwebende
        // Ebene und soll sich deshalb wie deren Verwandte lesen.
        let headerPanel = GlassPanel(cornerRadius: AssemblageTheme.toolClusterCornerRadius)
        headerPanel.content = header
        headerPanelForTesting = headerPanel

        let layout = LeftAlignedFlowLayout()
        layout.itemSize = ProjectCollectionViewItem.itemSize
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 20
        layout.sectionInset = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            ProjectCollectionViewItem.self,
            forItemWithIdentifier: Self.itemIdentifier
        )
        let doppelklick = NSClickGestureRecognizer(target: self, action: #selector(openSelectedProject(_:)))
        doppelklick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doppelklick)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = collectionView
        projectsScrollView = scrollView

        for view in [root, headerPanel, scrollView] { view.translatesAutoresizingMaskIntoConstraints = false }
        window.contentViewController = NSViewController()
        window.contentViewController?.view = root
        root.addSubview(headerPanel)
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerPanel.topAnchor.constraint(equalTo: root.topAnchor, constant: AssemblageTheme.margin),
            headerPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -AssemblageTheme.margin),
            scrollView.topAnchor.constraint(equalTo: headerPanel.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    private func themedTextButton(title: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.cell = AquaButtonCell()
        button.title = title
        button.target = self
        button.action = action
        button.isBordered = true
        button.wantsLayer = true
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.setAccessibilityLabel(title)
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        headerButtons.append(button)
        return button
    }

    private func applyTheme() {
        guard let window else { return }
        applyWindowOpacity(to: window)
        applyBackground()
        projectsScrollView?.drawsBackground = false
        collectionView.backgroundColors = [.clear]

        for button in headerButtons {
            button.layer?.backgroundColor = AssemblageTheme.aqua == nil
                ? AssemblageTheme.inputBackground.cgColor
                : nil
            button.layer?.cornerRadius = AssemblageTheme.toolButtonCornerRadius
            button.layer?.cornerCurve = AssemblageTheme.cornerCurve
        }
        collectionView.reloadData()
    }

    private func applyBackground() {
        if let stageMilkTint = AssemblageTheme.aqua?.stageMilkTint {
            rootView?.layer?.backgroundColor = stageMilkTint
                .withAlphaComponent(BackgroundOpacityManager.shared.opacity)
                .cgColor
        } else {
            rootView?.layer?.backgroundColor = NSColor.white.cgColor
        }
    }

    /// Nur ein nicht-deckendes Fenster lässt im Aqua-Erscheinungsbild den
    /// Schreibtisch beziehungsweise andere Programme durchscheinen.
    private func applyWindowOpacity(to window: NSWindow) {
        if AssemblageTheme.aqua != nil {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }
    }

    private func applyFilter() {
        let text = searchField.stringValue
        displayedEntries = text.isEmpty
            ? allEntries
            : allEntries.filter { $0.name.localizedCaseInsensitiveContains(text) }
        collectionView.reloadData()
    }

    func setSearchTextForTesting(_ text: String) {
        searchField.stringValue = text
        applyFilter()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        applyFilter()
    }

    @objc private func newProject(_ sender: Any?) {
        NSDocumentController.shared.newDocument(sender)
    }

    @objc private func openDocumentPanel(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }

    @objc private func openSelectedProject(_ sender: NSClickGestureRecognizer) {
        let point = sender.location(in: collectionView)
        guard let index = collectionView.indexPathForItem(at: point)?.item,
              displayedEntries.indices.contains(index)
        else { return }
        open(displayedEntries[index].url)
    }

    @objc fileprivate func openProjectFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open(url)
    }

    @objc fileprivate func revealProjectFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] document, _, _ in
            if document != nil { self?.close() }
        }
    }
}

extension ProjectsWindowController: NSCollectionViewDataSource, NSCollectionViewDelegate, NSWindowDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayedEntries.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemIdentifier, for: indexPath)
        guard let projectItem = item as? ProjectCollectionViewItem else { return item }
        projectItem.configure(
            with: displayedEntries[indexPath.item],
            owner: self,
            placeholder: ProjectThumbnailRenderer.placeholder()
        )
        return projectItem
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        willDisplay item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        guard let projectItem = item as? ProjectCollectionViewItem,
              displayedEntries.indices.contains(indexPath.item)
        else { return }
        let entry = displayedEntries[indexPath.item]
        thumbnailCache.load(entry) { [weak projectItem] image in
            projectItem?.setThumbnail(image, ifStillRepresenting: entry.url)
        }
    }

    func windowWillClose(_ notification: Notification) {
        finder?.stop()
    }
}

@MainActor
final class ProjectCollectionViewItem: NSCollectionViewItem {
    static let itemWidth: CGFloat = 260
    static let topInset: CGFloat = 8
    static let horizontalThumbnailInset: CGFloat = 8
    static let thumbnailAspectRatio: CGFloat = 204 / 137
    static let thumbnailHeight = (itemWidth - 2 * horizontalThumbnailInset) / thumbnailAspectRatio
    static let labelsTopSpacing: CGFloat = 8
    static let labelsSpacing: CGFloat = 2
    static let bottomInset: CGFloat = 8
    static let nameFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let dateFont = NSFont.systemFont(ofSize: 12)
    static let nameLineHeight = ceil(nameFont.boundingRectForFont.height)
    static let dateLineHeight = ceil(dateFont.boundingRectForFont.height)
    static let requiredHeight = ceil(
        topInset + thumbnailHeight + labelsTopSpacing
            + nameLineHeight + labelsSpacing + dateLineHeight + bottomInset
    )
    static let itemSize = NSSize(width: itemWidth, height: requiredHeight)

    private let thumbnail = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private var representedURL: URL?
    var tileBackgroundColorForTesting: NSColor? {
        view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
    }
    var tileBorderColorForTesting: NSColor? {
        view.layer?.borderColor.flatMap(NSColor.init(cgColor:))
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.masksToBounds = true
        nameLabel.font = Self.nameFont
        nameLabel.lineBreakMode = .byTruncatingTail
        dateLabel.font = Self.dateFont

        let labels = NSStackView(views: [nameLabel, dateLabel])
        labels.orientation = .vertical
        labels.spacing = 2
        labels.alignment = .leading
        for child in [thumbnail, labels] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.topInset),
            thumbnail.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.horizontalThumbnailInset),
            thumbnail.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.horizontalThumbnailInset),
            thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailHeight),
            labels.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: Self.labelsTopSpacing),
            labels.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            labels.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.bottomInset),
            nameLabel.heightAnchor.constraint(equalToConstant: Self.nameLineHeight),
            dateLabel.heightAnchor.constraint(equalToConstant: Self.dateLineHeight)
        ])
        applyTheme()
    }

    func configure(with entry: ProjectEntry, owner: ProjectsWindowController, placeholder: NSImage) {
        loadViewIfNeeded()
        representedURL = entry.url
        thumbnail.image = placeholder
        nameLabel.stringValue = entry.name
        nameLabel.toolTip = entry.name
        view.toolTip = entry.name
        dateLabel.stringValue = Self.dateFormatter.string(from: entry.modifiedAt)

        let menu = NSMenu()
        let öffnen = NSMenuItem(title: "Öffnen", action: #selector(ProjectsWindowController.openProjectFromMenu(_:)), keyEquivalent: "")
        öffnen.target = owner
        öffnen.representedObject = entry.url
        menu.addItem(öffnen)
        let zeigen = NSMenuItem(title: "Im Finder zeigen", action: #selector(ProjectsWindowController.revealProjectFromMenu(_:)), keyEquivalent: "")
        zeigen.target = owner
        zeigen.representedObject = entry.url
        menu.addItem(zeigen)
        view.menu = menu
        applyTheme()
    }

    private func applyTheme() {
        view.layer?.cornerRadius = AssemblageTheme.thumbnailCornerRadius
        view.layer?.cornerCurve = AssemblageTheme.cornerCurve
        view.layer?.backgroundColor = AssemblageTheme.glassBackground.cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = AssemblageTheme.glassBorder.cgColor
        view.layer?.shadowColor = AssemblageTheme.glassShadowColor.cgColor
        view.layer?.shadowRadius = min(12, AssemblageTheme.glassShadowRadius)
        view.layer?.shadowOffset = CGSize(width: 0, height: -3)
        view.layer?.shadowOpacity = 1

        thumbnail.layer?.cornerRadius = AssemblageTheme.thumbnailCornerRadius
        thumbnail.layer?.cornerCurve = AssemblageTheme.cornerCurve
        thumbnail.layer?.backgroundColor = AssemblageTheme.inputBackground.cgColor
        nameLabel.textColor = AssemblageTheme.textPrimary
        dateLabel.textColor = AssemblageTheme.textSecondary
    }

    func setThumbnail(_ image: NSImage, ifStillRepresenting url: URL) {
        guard representedURL == url else { return }
        thumbnail.image = image
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
