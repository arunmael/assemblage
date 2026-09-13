import AppKit

/// Wo ein frisch geöffnetes Dokumentfenster steht.
///
/// Eigener Typ statt ein paar Zeilen in `DocumentWindowController`, weil sich
/// nur so prüfen lässt, was ohne Bildschirm nicht prüfbar wäre: Ein Test kann
/// hier beliebige Bildschirmrahmen durchreichen — auch kaputte —, während
/// `NSScreen` im Test immer den echten Monitor der laufenden Maschine liefert.
enum WindowPlacement {

    /// Der Rahmen, mit dem ein Dokumentfenster aufgeht: die gesamte nutzbare
    /// Bildschirmfläche (Nutzer-Auftrag „über den ganzen Bildschirm, nicht
    /// Vollbild").
    ///
    /// `visibleFrame` und nicht `frame`: Menüleiste und Dock bleiben damit
    /// erreichbar, das Fenster ist weiterhin ein gewöhnliches Fenster und
    /// nicht der Vollbild-Modus mit eigenem Space.
    ///
    /// `minimumSize` gewinnt gegen einen zu kleinen Bildschirm — das Layout
    /// aus Plan 8 (Ebenenliste, Leinwand, Eigenschaften) kippt darunter.
    /// Unbrauchbare Werte (kein Bildschirm, NaN) fallen auf die Mindestgrösse
    /// am Ursprung zurück, statt NaN in den Fensterrahmen zu schreiben.
    static func initialFrame(visibleFrame: NSRect, minimumSize: NSSize) -> NSRect {
        let breite = tauglich(visibleFrame.width) ? max(visibleFrame.width, minimumSize.width) : minimumSize.width
        let hoehe = tauglich(visibleFrame.height) ? max(visibleFrame.height, minimumSize.height) : minimumSize.height
        let x = tauglich(visibleFrame.origin.x) ? visibleFrame.origin.x : 0
        let y = tauglich(visibleFrame.origin.y) ? visibleFrame.origin.y : 0
        return NSRect(x: x, y: y, width: breite, height: hoehe)
    }

    private static func tauglich(_ wert: CGFloat) -> Bool {
        wert.isFinite
    }
}
