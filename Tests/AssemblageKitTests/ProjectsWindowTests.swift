import AppKit
import XCTest
@testable import AssemblageKit

@MainActor
final class ProjectsWindowTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssemblageProjectsWindowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ProjectsWindowController.shared.close()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func entry(_ name: String) -> ProjectEntry {
        ProjectEntry(
            url: scratch.appendingPathComponent("\(name).assemblage"),
            name: name,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    func testFensterZeigtDieGesetzteAnzahlKacheln() throws {
        let controller = ProjectsWindowController(initialEntries: [entry("Eins"), entry("Zwei")], startsFinder: false)
        _ = try XCTUnwrap(controller.window)

        XCTAssertEqual(controller.displayedItemCount, 2)
    }

    func testSuchtextFiltertDieAngezeigtenEinträge() {
        let controller = ProjectsWindowController(
            initialEntries: [entry("Sommerferien"), entry("Winterabend")],
            startsFinder: false
        )

        controller.setSearchTextForTesting("sommer")

        XCTAssertEqual(controller.displayedItemCount, 1)
        XCTAssertEqual(controller.displayedEntries.first?.name, "Sommerferien")
    }

    func testZweimalProjekteÖffnenVerwendetDasselbeFenster() throws {
        ProjectsWindowController.showProjects()
        let erstes = try XCTUnwrap(ProjectsWindowController.shared.window)

        ProjectsWindowController.showProjects()
        let zweites = try XCTUnwrap(ProjectsWindowController.shared.window)

        XCTAssertTrue(erstes === zweites)
        XCTAssertEqual(NSApp.windows.filter { $0 === erstes }.count, 1)
    }

    func testKaputtesPaketErzeugtEinenPlatzhalter() throws {
        let paket = scratch.appendingPathComponent("Kaputt.assemblage")
        try FileManager.default.createDirectory(at: paket, withIntermediateDirectories: true)

        let bild = ProjectThumbnailRenderer.image(at: paket, targetSize: CGSize(width: 400, height: 300))

        XCTAssertEqual(bild.accessibilityDescription, ProjectThumbnailRenderer.placeholderDescription)
    }

    func testFensterDeckkraftFolgtDemErscheinungsbild() async throws {
        let ursprünglichesThema = ThemeManager.shared.current
        defer { ThemeManager.shared.setTheme(ursprünglichesThema) }

        ThemeManager.shared.setTheme(.beautifull)
        await nächstenHauptschleifendurchlaufAbwarten()
        let controller = ProjectsWindowController(initialEntries: [], startsFinder: false)
        let window = try XCTUnwrap(controller.window)

        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)

        ThemeManager.shared.setTheme(.soulless)
        await nächstenHauptschleifendurchlaufAbwarten()

        XCTAssertTrue(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .windowBackgroundColor)
    }

    func testKopfzeileLiegtInEinemGlasPanel() throws {
        let controller = ProjectsWindowController(initialEntries: [], startsFinder: false)

        XCTAssertTrue(try XCTUnwrap(controller.headerPanelForTesting) is GlassPanel)
    }

    func testKachelAendertHintergrundUndRandMitDemErscheinungsbild() async throws {
        let ursprünglichesThema = ThemeManager.shared.current
        defer { ThemeManager.shared.setTheme(ursprünglichesThema) }
        let controller = ProjectsWindowController(initialEntries: [], startsFinder: false)

        ThemeManager.shared.setTheme(.soulless)
        await nächstenHauptschleifendurchlaufAbwarten()
        let soulless = ProjectCollectionViewItem()
        soulless.configure(
            with: entry("Soulless"),
            owner: controller,
            placeholder: ProjectThumbnailRenderer.placeholder()
        )

        ThemeManager.shared.setTheme(.beautifull)
        await nächstenHauptschleifendurchlaufAbwarten()
        let beautifull = ProjectCollectionViewItem()
        beautifull.configure(
            with: entry("Beautifull"),
            owner: controller,
            placeholder: ProjectThumbnailRenderer.placeholder()
        )

        XCTAssertNotEqual(soulless.tileBackgroundColorForTesting, beautifull.tileBackgroundColorForTesting)
        XCTAssertNotEqual(soulless.tileBorderColorForTesting, beautifull.tileBorderColorForTesting)
    }

    func testRasterBleibtBeiVerschiedenenFensterbreitenLinksbündigUndGleichmässig() throws {
        let controller = ProjectsWindowController(
            initialEntries: (1...7).map { entry("Projekt \($0)") },
            startsFinder: false
        )
        let window = try XCTUnwrap(controller.window)
        let collectionView: NSCollectionView = try XCTUnwrap(
            ersteUnteransicht(in: window.contentView, vomTyp: NSCollectionView.self)
        )
        let layout = try XCTUnwrap(collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)

        for breite in [CGFloat(900), CGFloat(940)] {
            window.setContentSize(NSSize(width: breite, height: 620))
            window.contentView?.layoutSubtreeIfNeeded()
            layout.invalidateLayout()
            layout.prepare()

            let attribute = try XCTUnwrap(
                layout.layoutAttributesForElements(
                    in: NSRect(x: 0, y: 0, width: collectionView.bounds.width, height: 2_000)
                )
            )
            .filter { $0.representedElementCategory == .item }
            let zeilen = Dictionary(grouping: attribute) { attribut in
                Int((attribut.frame.minY / 2).rounded())
            }

            XCTAssertFalse(zeilen.isEmpty)
            for zeile in zeilen.values {
                let sortiert = zeile.sorted { $0.frame.minX < $1.frame.minX }
                XCTAssertEqual(sortiert[0].frame.minX, layout.sectionInset.left, accuracy: 0.01)
                for (links, rechts) in zip(sortiert, sortiert.dropFirst()) {
                    XCTAssertEqual(
                        rechts.frame.minX - links.frame.maxX,
                        layout.minimumInteritemSpacing,
                        accuracy: 0.01
                    )
                }

                for attribut in sortiert {
                    let indexPath = try XCTUnwrap(attribut.indexPath)
                    let einzelattribut = try XCTUnwrap(
                        layout.layoutAttributesForItem(at: indexPath)
                    )
                    XCTAssertEqual(einzelattribut.frame, attribut.frame)
                }
            }
        }
    }

    func testKachelhöheDecktMiniaturTextzeilenUndRänderAb() throws {
        let controller = ProjectsWindowController(initialEntries: [], startsFinder: false)
        let window = try XCTUnwrap(controller.window)
        let collectionView: NSCollectionView = try XCTUnwrap(
            ersteUnteransicht(in: window.contentView, vomTyp: NSCollectionView.self)
        )
        let layout = try XCTUnwrap(collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)
        let item = ProjectCollectionViewItem()
        item.loadView()
        item.view.frame.size.width = layout.itemSize.width

        XCTAssertGreaterThanOrEqual(layout.itemSize.width, 260)
        XCTAssertGreaterThanOrEqual(layout.itemSize.height, item.view.fittingSize.height)
    }

    func testKachelZeigtVollständigenProjektnamenAlsTooltip() {
        let controller = ProjectsWindowController(initialEntries: [], startsFinder: false)
        let item = ProjectCollectionViewItem()
        let name = "Ein sehr langer vollständiger Projektname"

        item.configure(
            with: entry(name),
            owner: controller,
            placeholder: ProjectThumbnailRenderer.placeholder()
        )

        XCTAssertEqual(item.view.toolTip, name)
    }

    func testBeautifullHintergrundFolgtDerEingestelltenDeckkraft() async throws {
        let ursprünglichesThema = ThemeManager.shared.current
        let ursprünglicheDeckkraft = BackgroundOpacityManager.shared.opacity
        defer {
            BackgroundOpacityManager.shared.setOpacity(ursprünglicheDeckkraft)
            ThemeManager.shared.setTheme(ursprünglichesThema)
        }
        ThemeManager.shared.setTheme(.beautifull)
        await nächstenHauptschleifendurchlaufAbwarten()
        let controller = ProjectsWindowController(initialEntries: [], startsFinder: false)
        let root = try XCTUnwrap(controller.window?.contentViewController?.view)

        BackgroundOpacityManager.shared.setOpacity(0.3)
        await nächstenHauptschleifendurchlaufAbwarten()
        XCTAssertEqual(try hintergrundAlpha(von: root), 0.3, accuracy: 0.01)

        BackgroundOpacityManager.shared.setOpacity(0.9)
        await nächstenHauptschleifendurchlaufAbwarten()
        XCTAssertEqual(try hintergrundAlpha(von: root), 0.9, accuracy: 0.01)
    }

    func testSoullessHintergrundIstWeiss() async throws {
        let ursprünglichesThema = ThemeManager.shared.current
        defer { ThemeManager.shared.setTheme(ursprünglichesThema) }
        ThemeManager.shared.setTheme(.soulless)
        await nächstenHauptschleifendurchlaufAbwarten()
        let controller = ProjectsWindowController(initialEntries: [], startsFinder: false)
        let root = try XCTUnwrap(controller.window?.contentViewController?.view)
        let farbe = try XCTUnwrap(
            root.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.deviceRGB)
        )

        XCTAssertEqual(farbe.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(farbe.greenComponent, 1, accuracy: 0.01)
        XCTAssertEqual(farbe.blueComponent, 1, accuracy: 0.01)
        XCTAssertEqual(farbe.alphaComponent, 1, accuracy: 0.01)
    }

    func testSuchfeldBehältDenSystembezel() throws {
        let controller = ProjectsWindowController(initialEntries: [], startsFinder: false)
        let searchField: NSSearchField = try XCTUnwrap(
            ersteUnteransicht(in: controller.window?.contentView, vomTyp: NSSearchField.self)
        )

        XCTAssertTrue(searchField.isBezeled)
    }

    private func ersteUnteransicht<T: NSView>(in wurzel: NSView?, vomTyp typ: T.Type) -> T? {
        guard let wurzel else { return nil }
        if let treffer = wurzel as? T { return treffer }
        return wurzel.subviews.lazy.compactMap { self.ersteUnteransicht(in: $0, vomTyp: typ) }.first
    }

    private func hintergrundAlpha(von view: NSView) throws -> CGFloat {
        try XCTUnwrap(
            view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.deviceRGB)
        ).alphaComponent
    }

    private func nächstenHauptschleifendurchlaufAbwarten() async {
        await withCheckedContinuation { fortsetzung in
            DispatchQueue.main.async { fortsetzung.resume() }
        }
    }
}
