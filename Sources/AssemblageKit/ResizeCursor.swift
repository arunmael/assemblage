import AppKit
import AssemblageModel

/// Der Mauszeiger über einem Grössen-Griff (aus Anpassungen.md: „Der Cursor
/// sollte sich anpassen, wenn man die Grösse eines Fotos verändert").
///
/// Vorher blieb der Zeiger über jedem Griff ein gewöhnlicher Pfeil — nichts
/// verriet, ob ein Ziehen die Ebene verschiebt oder ihre Grösse ändert.
enum ResizeCursor {

    /// Die vier möglichen Zeigerachsen. Nach den Griffen benannt, die sie
    /// bedienen, statt nach Himmelsrichtung: Das Koordinatensystem des
    /// Projekts zählt y nach unten, und „45°" zeigt darin nach unten rechts,
    /// nicht wie in der üblichen Mathematik-Vorstellung nach oben rechts.
    /// Ein Name wie `.topLeftBottomRight` kann darüber nicht stolpern.
    enum Axis: Equatable, Sendable {
        /// Linker/rechter Griff — ↔
        case horizontal
        /// Oberer/unterer Griff — ↕
        case vertical
        /// Obere-linke/untere-rechte Ecke — ⟍
        case topLeftBottomRight
        /// Obere-rechte/untere-linke Ecke — ⟋
        case topRightBottomLeft
    }

    /// Auf welcher Achse dieser Griff liegt, nachdem die Ebene um
    /// `layerRotationDegrees` gedreht wurde.
    ///
    /// Ein gedrehtes Foto zeigt seine Ecken nicht mehr an ihrer
    /// ungedrehten Stelle — der Zeiger muss der tatsächlichen, sichtbaren
    /// Richtung folgen, nicht der Richtung im ungedrehten Modell.
    static func axis(for handle: ResizeHandle, layerRotationDegrees: Double) -> Axis {
        let offset = handle.unitOffset
        // Winkel der Griff-Achse in Grad. Eine Achse ist ungerichtet (der
        // Griff „oben" und sein Gegenstück „unten" zeigen auf dieselbe
        // Linie), deshalb zählt nur der Winkel modulo 180°.
        let winkel = atan2(offset.y, offset.x) * 180 / .pi + layerRotationDegrees
        var normiert = winkel.truncatingRemainder(dividingBy: 180)
        if normiert < 0 { normiert += 180 }

        // Auf die vier Achsen 0°/45°/90°/135° einrasten. Bei genau der Mitte
        // zwischen zwei Achsen (22.5°, 67.5°, …) entscheidet die niedrigere —
        // eine beliebige, aber stabile Wahl für einen in der Praxis nie
        // exakt erreichten Grenzfall.
        let kandidaten: [(Double, Axis)] = [
            (0, .horizontal), (45, .topLeftBottomRight),
            (90, .vertical), (135, .topRightBottomLeft), (180, .horizontal)
        ]
        let naechster = kandidaten.min {
            abs($0.0 - normiert) < abs($1.0 - normiert)
        }!
        return naechster.1
    }

    /// Der tatsächliche Zeiger für eine Achse.
    ///
    /// Waagrecht und senkrecht liefert AppKit selbst; für die beiden
    /// Diagonalen gibt es kein öffentliches System-Symbol, deshalb werden sie
    /// hier gezeichnet — derselbe Doppelpfeil, nur um 45° gedreht.
    static func cursor(for axis: Axis) -> NSCursor {
        switch axis {
        case .horizontal: return .resizeLeftRight
        case .vertical: return .resizeUpDown
        case .topLeftBottomRight: return topLeftBottomRightCursor
        case .topRightBottomLeft: return topRightBottomLeftCursor
        }
    }

    // Genau einmal gezeichnet und danach wiederverwendet: `NSCursor` bringt
    // keine Wertgleichheit mit (zwei mit gleichem Bild gebaute Instanzen
    // gelten als verschieden), und ein bei jedem Mausereignis neu erzeugtes
    // Zeigerbild wäre reine Verschwendung.
    private static let topLeftBottomRightCursor = diagonalCursor(rotatedDegrees: 45)
    private static let topRightBottomLeftCursor = diagonalCursor(rotatedDegrees: -45)

    /// Zeiger für einen Griff direkt aus Modellwerten — der übliche
    /// Aufrufweg vom Canvas aus.
    static func cursor(for handle: ResizeHandle, layerRotationDegrees: Double) -> NSCursor {
        cursor(for: axis(for: handle, layerRotationDegrees: layerRotationDegrees))
    }

    // MARK: - Gezeichneter Diagonal-Zeiger

    /// Eine Bildgrösse, die auf jedem Bildschirm scharf bleibt: `NSCursor`
    /// rastert sein Bild einmal in Gerätepixel, ein zu kleines Bild wirkt
    /// dann unscharf.
    private static let groesse: CGFloat = 20

    private static func diagonalCursor(rotatedDegrees grad: CGFloat) -> NSCursor {
        let bild = NSImage(size: NSSize(width: groesse, height: groesse), flipped: false) { rahmen in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x: rahmen.midX, y: rahmen.midY)
            context.rotate(by: grad * .pi / 180)

            // Zwei kurze Pfeile, Spitze an Spitze auseinanderzeigend — der
            // klassische „Grösse ändern"-Doppelpfeil, wie ihn andere
            // Zeichen-Apps für diagonale Griffe verwenden.
            let laenge: CGFloat = 7
            let spitzenlaenge: CGFloat = 4
            let spitzenbreite: CGFloat = 3

            let pfad = CGMutablePath()
            for richtung: CGFloat in [1, -1] {
                let spitze = CGPoint(x: richtung * laenge, y: 0)
                let basis = CGPoint(x: richtung * (laenge - spitzenlaenge), y: 0)
                pfad.move(to: .zero)
                pfad.addLine(to: basis)
                pfad.move(to: spitze)
                pfad.addLine(to: CGPoint(x: basis.x, y: spitzenbreite))
                pfad.addLine(to: CGPoint(x: basis.x, y: -spitzenbreite))
                pfad.closeSubpath()
            }

            // Erst ein breiterer weisser Umriss, dann Schwarz darüber — hebt
            // den Zeiger auf jedem Untergrund ab, genau wie die eingebauten
            // Zeiger `resizeLeftRight`/`resizeUpDown` es tun.
            context.addPath(pfad)
            context.setLineWidth(4)
            context.setLineJoin(.round)
            context.setStrokeColor(NSColor.white.cgColor)
            context.strokePath()

            context.addPath(pfad)
            context.setLineWidth(2)
            context.setLineJoin(.round)
            context.setStrokeColor(NSColor.black.cgColor)
            context.strokePath()

            context.addPath(pfad)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .winding)

            context.restoreGState()
            return true
        }
        return NSCursor(image: bild, hotSpot: NSPoint(x: groesse / 2, y: groesse / 2))
    }
}
