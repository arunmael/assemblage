import AppKit
import AssemblageModel

/// Nimmt einen Bilder-Wurf entgegen und setzt ihn ins Dokument — der
/// gemeinsame Weg für den Canvas (`CanvasView`, sein angestammtes Ablageziel)
/// und die fensterweite Ablagefläche (`WindowDropZoneView`, aus
/// Anpassungen.md: „überall im Fenster droppen können").
///
/// Eine Stelle statt zwei Kopien: Wo genau im Fenster losgelassen wird, macht
/// für das Ergebnis keinen Unterschied — ein Bild landet immer über
/// `LayerCreation`s Kaskaden-Platzierung mittig auf der Leinwand, nie an der
/// tatsächlichen Wurfstelle. Zwei unabhängige Kopien dieser Logik liefen mit
/// der Zeit auseinander, genau wie die Render- und Bilddekodierpfade, die das
/// Projekt an anderer Stelle schon einmal zusammengeführt hat.
@MainActor
enum ImageDropCommand {

    static func handle(
        pasteboard: NSPasteboard,
        state: DocumentState,
        presentingWindow: NSWindow?
    ) {
        guard let document = state.owner else { return }

        let ergebnis = ImageImporter.import(
            from: pasteboard,
            resources: state.resources,
            canvas: state.document.canvas
        )

        if !ergebnis.images.isEmpty {
            // Alle auf einmal gezogenen Bilder bilden einen Undo-Schritt: Wer
            // fünf Fotos hereinzieht und es sich anders überlegt, will einmal
            // ⌘Z drücken, nicht fünfmal.
            document.beginInteraction()
            document.modify("Bilder einsetzen") { dokument in
                for bild in ergebnis.images {
                    try? dokument.addLayer(bild.layer)
                }
            }
            document.endInteraction(
                actionName: ergebnis.images.count == 1 ? "Bild einsetzen" : "Bilder einsetzen"
            )

            // Das zuletzt eingesetzte Bild auswählen — man will es meist
            // gleich verschieben.
            state.selectedLayerID = ergebnis.images.last?.layer.id
        }

        // Fehlgeschlagene Dateien benennen statt stillschweigend zu schlucken
        // (Plan 2.1). Die erfolgreichen sind zu diesem Zeitpunkt schon drin.
        if let ersterFehler = ergebnis.failures.first {
            let alert = NSAlert()
            alert.messageText = ergebnis.failures.count == 1
                ? "\(ersterFehler.name) konnte nicht importiert werden."
                : "\(ergebnis.failures.count) Dateien konnten nicht importiert werden."
            alert.informativeText = ergebnis.failures
                .map { "\($0.name): \($0.error.localizedDescription)" }
                .joined(separator: "\n")
            alert.alertStyle = .warning
            if let presentingWindow {
                alert.beginSheetModal(for: presentingWindow)
            } else {
                alert.runModal()
            }
        }
    }
}
