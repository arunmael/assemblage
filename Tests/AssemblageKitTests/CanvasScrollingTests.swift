import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Der Bildlauf der Leinwand — insbesondere der Vertrag, den
/// `constrainBoundsRect` gegenüber AppKit einhalten muss.
@MainActor
final class CanvasScrollingTests: XCTestCase {

    /// Leinwand 400×300 in einem Sichtfeld von 200×150.
    private func clipView(
        canvas: CGSize = CGSize(width: 400, height: 300),
        viewport: CGSize = CGSize(width: 200, height: 150)
    ) -> CenteringClipView {
        let scrollView = NSScrollView(frame: CGRect(origin: .zero, size: viewport))
        let clip = CenteringClipView()
        scrollView.contentView = clip
        let document = NSView(frame: CGRect(origin: .zero, size: canvas))
        scrollView.documentView = document
        clip.frame = CGRect(origin: .zero, size: viewport)
        return clip
    }

    private func proposal(_ x: CGFloat, _ y: CGFloat, in clip: CenteringClipView) -> NSRect {
        NSRect(origin: CGPoint(x: x, y: y), size: clip.bounds.size)
    }

    /// Der eigentliche Absturz: Beim Zwei-Finger-Bildlauf berechnet AppKit
    /// aus dem erlaubten Bereich einen Ruhepunkt. Ein `constrainBoundsRect`,
    /// das jeden Vorschlag unverändert durchreicht, macht diesen Bereich
    /// unendlich — heraus kam ein NaN und „Invalid view geometry: x is NaN".
    func testConstrainedBoundsStayFiniteForExtremeProposals() {
        let clip = clipView()

        for (x, y) in [(1e9, 1e9), (-1e9, -1e9), (.greatestFiniteMagnitude, 0)] as [(CGFloat, CGFloat)] {
            let rect = clip.constrainBoundsRect(proposal(x, y, in: clip))
            XCTAssertTrue(rect.hasFiniteGeometry, "Vorschlag (\(x), \(y)) ergab \(rect)")
        }
    }

    /// Auch ein bereits unbrauchbarer Vorschlag darf nie unverändert
    /// weitergereicht werden.
    func testNonFiniteProposalNeverPassesThrough() {
        let clip = clipView()

        for (x, y) in [(CGFloat.nan, 0), (0, CGFloat.nan), (.infinity, 0)] as [(CGFloat, CGFloat)] {
            let rect = clip.constrainBoundsRect(proposal(x, y, in: clip))
            XCTAssertTrue(rect.hasFiniteGeometry, "Vorschlag (\(x), \(y)) ergab \(rect)")
        }
    }

    /// Der Sinn der Klasse: Die Leinwand klebt nicht am Dokumentrahmen,
    /// sondern lässt sich darüber hinausschieben.
    func testViewMayScrollBeyondTheDocumentFrame() {
        let clip = clipView()

        let nachLinks = clip.constrainBoundsRect(proposal(-120, 0, in: clip))
        XCTAssertEqual(nachLinks.origin.x, -120,
                       "über den linken Dokumentrand hinaus muss erlaubt sein")

        let nachRechts = clip.constrainBoundsRect(proposal(380, 0, in: clip))
        XCTAssertEqual(nachRechts.origin.x, 380,
                       "über den rechten Dokumentrand hinaus muss erlaubt sein")
    }

    /// Aber nicht endlos: Der Vertrag bleibt endlich (sonst der alte NaN-
    /// Absturz beim Zwei-Finger-Bildlauf), erlaubt aber grosszügig freien
    /// Bildlauf jenseits des Leinwandrands — eine Sichtfeldbreite Rand
    /// (wie zuvor) blockierte spürbar, sobald die Leinwand gerade aus dem
    /// Bild lief. `CenteringClipView.freeScrollMargin` ist der zusätzliche,
    /// von der Sichtfeldgrösse unabhängige Puffer.
    func testScrollingStopsFarBeyondTheViewportButNotAtItsEdge() {
        let clip = clipView()
        let margin = CenteringClipView.freeScrollMargin

        // Sichtfeld 200×150, Leinwand 0…400×0…300: der erlaubte Bereich
        // reicht eine Sichtfeldbreite/-höhe plus den grosszügigen Puffer
        // über den Leinwandrand hinaus — deutlich mehr als die alte, knappe
        // „gerade eben aus dem Bild"-Grenze.
        XCTAssertEqual(clip.constrainBoundsRect(proposal(-1e6, 0, in: clip)).origin.x, -200 - margin)
        XCTAssertEqual(clip.constrainBoundsRect(proposal(1e6, 0, in: clip)).origin.x, 400 + margin)
        XCTAssertEqual(clip.constrainBoundsRect(proposal(0, -1e6, in: clip)).origin.y, -150 - margin)
        XCTAssertEqual(clip.constrainBoundsRect(proposal(0, 1e6, in: clip)).origin.y, 300 + margin)

        // Und der alte, enge Anschlag ist jetzt klar innerhalb des erlaubten
        // Bereichs erreichbar, statt bereits die Grenze zu sein.
        let knappAusserhalb = clip.constrainBoundsRect(proposal(-200, 0, in: clip))
        XCTAssertEqual(knappAusserhalb.origin.x, -200)
    }

    /// Eine kleinere Leinwand als das Fenster darf sich ebenfalls verschieben
    /// lassen — genau dort liess AppKit den Bildlauf früher ganz aus.
    func testSmallCanvasInLargeViewportStillScrollsWithinFiniteBounds() {
        let clip = clipView(canvas: CGSize(width: 100, height: 80),
                            viewport: CGSize(width: 600, height: 400))
        let margin = CenteringClipView.freeScrollMargin

        let rect = clip.constrainBoundsRect(proposal(-1e6, -1e6, in: clip))
        XCTAssertTrue(rect.hasFiniteGeometry)
        XCTAssertEqual(rect.origin.x, -600 - margin)
        XCTAssertEqual(rect.origin.y, -400 - margin)
    }

    /// „Ins Fenster einpassen" holt die Leinwand mittig zurück.
    func testCenterDocumentPutsTheCanvasMiddleIntoTheViewportMiddle() {
        let clip = clipView()
        clip.scroll(to: CGPoint(x: 380, y: 290))

        clip.centerDocument()

        XCTAssertEqual(clip.bounds.origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(clip.bounds.origin.y, 75, accuracy: 0.001)
    }
}
