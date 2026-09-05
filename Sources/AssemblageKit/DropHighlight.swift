import AppKit

/// Der sichtbare Hinweis, dass eine Ansicht eine gezogene Datei gerade
/// annehmen würde (aus Anpassungen.md: „… dann verändert sich das Aussehen
/// des Fensters, damit man weiss, dass es erkannt hat, dass ich ein File
/// loslassen möchte").
///
/// Reine Anzeige, kein eigener Drag-Mechanismus: Die jeweilige Ansicht bleibt
/// selbst `NSDraggingDestination` und schaltet diesen Regler nur ein und aus.
/// Als eigener kleiner Typ, weil dieselbe Anzeige an zwei Stellen gebraucht
/// wird — dem Canvas (bereits ein Ablageziel) und der neuen fensterweiten
/// Ablagezone — und zwei Kopien mit der Zeit auseinanderliefen.
@MainActor
final class DropHighlightController {

    private weak var view: NSView?
    private var overlay: NSView?

    init(view: NSView) {
        self.view = view
    }

    /// Blendet den Hinweis ein oder aus. Ungefährlich, mehrfach mit demselben
    /// Wert aufgerufen zu werden — ein zweites `draggingUpdated` während
    /// desselben Ziehens etwa.
    func setActive(_ active: Bool) {
        guard active != (overlay != nil), let view else { return }

        if active {
            let hinweis = NSView(frame: view.bounds)
            hinweis.autoresizingMask = [.width, .height]
            hinweis.wantsLayer = true
            hinweis.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            hinweis.layer?.borderColor = NSColor.controlAccentColor.cgColor
            hinweis.layer?.borderWidth = 4
            hinweis.layer?.cornerRadius = 6
            // Als letzte (also oberste) Unteransicht: Sie muss über allem
            // liegen, was `view` sonst zeigt — bei der fensterweiten Zone
            // etwa über der ganzen Ebenenliste und dem Canvas.
            view.addSubview(hinweis)
            overlay = hinweis
        } else {
            overlay?.removeFromSuperview()
            overlay = nil
        }
    }
}
