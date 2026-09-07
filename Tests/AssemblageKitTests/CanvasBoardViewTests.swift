import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Die Leinwand liegt nicht direkt in der Bildlauffläche, sondern auf einem
/// deutlich grösseren Brett (`CanvasBoardView`). Nur was innerhalb des
/// `documentView` liegt, lässt AppKit wirklich anfahren — jenseits davon
/// federt der elastische Bildlauf sofort zurück. Der Rand ringsum ist damit
/// der eigentliche freie Bildlauf: Man kann die Leinwand ganz aus dem Bild
/// schieben und trotzdem weiterscrollen.
@MainActor
final class CanvasBoardViewTests: XCTestCase {

    private func board(canvas: CanvasSize = CanvasSize(width: 400, height: 300)) -> CanvasBoardView {
        let canvasView = CanvasView(
            document: AssemblageModel.Document(canvas: canvas),
            images: ImageStore(resources: DocumentResources())
        )
        return CanvasBoardView(canvasView: canvasView)
    }

    /// Das Brett ist ringsum um `margin` grösser als die Leinwand, und die
    /// Leinwand sitzt genau in seiner Mitte.
    func testBoardSurroundsTheCanvasWithMarginOnAllSides() {
        let brett = board()
        let rand = CanvasBoardView.margin

        XCTAssertEqual(brett.frame.width, 400 + 2 * rand)
        XCTAssertEqual(brett.frame.height, 300 + 2 * rand)
        XCTAssertEqual(brett.canvasView.frame, NSRect(x: rand, y: rand, width: 400, height: 300))
        XCTAssertEqual(brett.canvasView.superview, brett)
    }

    /// Mitte des Bretts = Mitte der Leinwand: Sonst zielte „ins Fenster
    /// einpassen" (das über den `documentView`-Mittelpunkt zentriert) neben
    /// die Leinwand.
    func testBoardCentreIsTheCanvasCentre() {
        let brett = board()

        XCTAssertEqual(brett.frame.midX - brett.frame.minX, brett.canvasView.frame.midX, accuracy: 0.001)
        XCTAssertEqual(brett.frame.midY - brett.frame.minY, brett.canvasView.frame.midY, accuracy: 0.001)
    }

    /// Ändert sich die Leinwandgrösse (Menü „Leinwandgrösse…", Öffnen eines
    /// anderen Dokuments), wächst das Brett mit und die Leinwand bleibt
    /// mittig — sonst klebte sie nach einer Vergrösserung am Rand des
    /// Bildlaufbereichs.
    func testBoardGrowsWithTheCanvasAndKeepsItCentred() {
        let brett = board()
        let rand = CanvasBoardView.margin

        brett.canvasView.update(to: AssemblageModel.Document(canvas: CanvasSize(width: 1000, height: 800)))
        brett.layoutCanvas()

        XCTAssertEqual(brett.frame.width, 1000 + 2 * rand)
        XCTAssertEqual(brett.frame.height, 800 + 2 * rand)
        XCTAssertEqual(brett.canvasView.frame, NSRect(x: rand, y: rand, width: 1000, height: 800))
    }

    /// Der Rand ist gross genug, um die Leinwand vollständig aus einem
    /// üblichen Fenster hinauszuschieben — daran misst sich „überall hin
    /// scrollen können".
    func testMarginIsLargerThanATypicalWindow() {
        XCTAssertGreaterThanOrEqual(CanvasBoardView.margin, 2_000)
    }
}
