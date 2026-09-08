import AppKit

/// Zeichnet einen glänzenden Aqua-Glaskapsel-Knopf (Mac-OS-X-„Aqua"-Optik
/// der frühen 2000er) statt des normalen Knopf-Bezels — nur im
/// Erscheinungsbild „Beautifull" im Einsatz (siehe `AquaStyle`/
/// `BeautifullTokens` in `Theme.swift`).
///
/// Technik angelehnt an zwei recherchierte Referenzprojekte (siehe
/// `UI/second-theme/`-Recherche): die Grundform-plus-Glanzstreifen-Aufteilung
/// von thompsonate/Lickable-Button (zwei übereinanderliegende Formen statt
/// eines Verlaufs mit vielen Stopps) und das Clip-auf-Grundform-Prinzip von
/// rschiang/hydrobolic (`SHButtonCell`) — beide Male eigenständig für unsere
/// `AquaStyle`-Farbwerte neu geschrieben, kein Code übernommen.
///
/// Nur `drawBezel` wird überschrieben: Titel/Icon zeichnet `super` wie
/// gehabt, nur der Hintergrund ändert sich.
///
/// Liest `AssemblageTheme.aqua` bei jedem Zeichnen frisch statt sich einen
/// Stil beim Erstellen zu merken: Knöpfe bekommen diese Zelle dadurch schon
/// bei ihrer Erstellung fest zugewiesen (`button.cell = AquaButtonCell()`,
/// `isBordered = true`) und müssen beim Themenwechsel selbst nicht
/// angefasst werden — ist gerade kein `AquaStyle` aktiv („Soulless"), zeichnet
/// diese Methode schlicht nichts, exakt der bisherige randlose Look.
@MainActor
final class AquaButtonCell: NSButtonCell {

    // Keine eigenen gespeicherten Eigenschaften mehr nötig (siehe oben) —
    // `init(textCell:)`/`init(coder:)` kommen unverändert von `NSButtonCell`.

    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        guard let style = AssemblageTheme.aqua else { return }
        // Radius = halbe Höhe statt eines festen Werts: Das ergibt bei
        // quadratischen Icon-Knöpfen runde Ecken und bei breiten
        // Text-Knöpfen eine echte Kapsel — beides die „Squircle"/Pillen-Form
        // aus der Theme-Vorgabe, ohne zwei Codepfade für zwei Knopfformen.
        let radius = frame.height / 2
        let base = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)

        // Eingesunken beim Klick: Grundform und Glanzstreifen wandern 1pt
        // nach unten, der Rest der Zeichnung bleibt unverändert — genügt für
        // den „physisch gedrückt"-Eindruck, ohne dass die Klickfläche selbst
        // sich verschiebt (die bestimmt weiterhin `frame`).
        let verschiebung = isHighlighted ? CGFloat(-1) : 0
        let baseRect = frame.offsetBy(dx: 0, dy: verschiebung)
        let baseForFill = NSBezierPath(roundedRect: baseRect, xRadius: radius, yRadius: radius)

        let fillGradient = isHighlighted ? style.buttonPressedGradient : style.buttonBackgroundGradient
        if let gradient = NSGradient(colors: fillGradient) {
            gradient.draw(in: baseForFill, angle: 90)
        }

        // Glanzstreifen nur im Normalzustand in voller Stärke — echtes Glas
        // reflektiert im gedrückten Zustand weniger, weil die Lichtquelle
        // relativ zur eingesunkenen Fläche wandert.
        if !isHighlighted {
            NSGraphicsContext.saveGraphicsState()
            base.addClip()

            let shineInset: CGFloat = max(2, radius * 0.25)
            let shineRect = NSRect(
                x: frame.minX + shineInset,
                y: frame.maxY - frame.height * 0.42,
                width: frame.width - shineInset * 2,
                height: frame.height * 0.4
            )
            let shineRadius = max(1, radius - shineInset)
            let shine = NSBezierPath(roundedRect: shineRect, xRadius: shineRadius, yRadius: shineRadius)
            if let shineGradient = NSGradient(colors: style.buttonShineGradient) {
                shineGradient.draw(in: shine, angle: 90)
            }

            NSGraphicsContext.restoreGraphicsState()
        }

        let outlineColor = isHighlighted ? style.buttonPressedOutline : style.buttonOutline
        let outline = NSBezierPath(roundedRect: baseRect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        outline.lineWidth = 1
        outlineColor.setStroke()
        outline.stroke()
    }
}
