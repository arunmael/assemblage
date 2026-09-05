import AppKit
import AssemblageModel

/// „Teilen"-Knopf (aus Anpassungen.md: „Exportier-Button fehlt … nutze dafür
/// bitte den normalen Apple-Teilen-Button").
///
/// Bewusst getrennt von `ExportPanel`: Der Sichern-Dialog ist für die
/// bewusste Wahl von Format, Grösse und Ort gedacht — der Teilen-Knopf für
/// den schnellen Weg direkt an eine App oder einen Kontakt, mit dem
/// systemweiten Rahmen (`NSSharingServicePicker`), den Nutzer aus jeder
/// Mac-App kennen.
@MainActor
enum ShareCommand {

    /// Rendert das Dokument für den Teilen-Dialog: PNG in Leinwandgrösse
    /// (Faktor 1×). Ein höherer Faktor wie beim Export wäre hier nur
    /// unnötig grosser Speicher — geteilt wird üblicherweise ein Bild zum
    /// Ansehen, nicht zum Drucken.
    static func renderedImage(
        of document: AssemblageModel.Document,
        resources: DocumentResources
    ) async throws -> NSImage {
        let zielgroesse = DocumentExporter.targetSize(forCanvas: document.canvas, scale: 1)
        let bild = try await DocumentExporter.image(
            of: document, resources: resources, targetSize: zielgroesse)
        return NSImage(cgImage: bild, size: NSSize(width: bild.width, height: bild.height))
    }
}
