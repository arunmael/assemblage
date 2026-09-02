import SwiftUI
import AssemblageModel

/// Das Eigenschaften-Panel (Plan 8, rechts im Fenster).
///
/// Zeigt kontextabhängig die Eigenschaften der ausgewählten Ebene — bzw. die
/// des Dokuments, wenn nichts ausgewählt ist (Plan 4.2 „Progressive
/// Disclosure": nur zeigen, was gerade relevant ist).
///
/// Phase 0 zeigt nur an. Die Regler zum Bearbeiten kommen mit Phase 1 und 2.
struct InspectorView: View {

    @ObservedObject var state: DocumentState

    var body: some View {
        Form {
            if let layer = state.selectedLayer {
                layerSections(layer)
            } else {
                documentSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Ohne Auswahl: das Dokument

    private var documentSection: some View {
        Section("Dokument") {
            LabeledContent("Leinwand", value: formatted(state.document.canvas))
            LabeledContent("Ebenen", value: "\(state.document.layers.count)")
        }
    }

    // MARK: - Mit Auswahl: die Ebene

    @ViewBuilder
    private func layerSections(_ layer: Layer) -> some View {
        Section("Ebene") {
            LabeledContent("Name", value: layer.name)
            LabeledContent("Deckkraft", value: "\(Int((layer.opacity * 100).rounded())) %")
            LabeledContent("Modus", value: layer.blendMode.localizedName)
        }

        Section("Position") {
            LabeledContent("Mittelpunkt", value: format(layer.transform.x, layer.transform.y))
            LabeledContent("Skalierung", value: formatScale(layer.transform))
            LabeledContent("Drehung", value: "\(number(layer.transform.rotationDegrees))°")
        }

        switch layer.content {
        case .image(let image):
            imageSection(image)
        case .text(let text):
            textSection(text)
        case .shape(let shape):
            shapeSection(shape)
        }

        if let mask = layer.mask {
            maskSection(mask)
        }
    }

    private func imageSection(_ content: ImageLayerContent) -> some View {
        Section("Bild") {
            LabeledContent("Datei", value: (content.originalFileReference as NSString).lastPathComponent)
            if let crop = content.cropRect {
                LabeledContent("Zuschnitt", value: format(crop.width, crop.height))
            }
            // Nur zeigen, wenn tatsächlich etwas verstellt ist.
            if content.adjustments != .neutral {
                LabeledContent("Anpassungen", value: "verändert")
            }
        }
    }

    private func textSection(_ content: TextLayerContent) -> some View {
        Section("Text") {
            LabeledContent("Inhalt", value: content.string)
            LabeledContent("Schrift", value: "\(content.fontName) \(number(content.fontSize))")
        }
    }

    private func shapeSection(_ content: ShapeLayerContent) -> some View {
        Section("Form") {
            LabeledContent("Grösse", value: formatted(content.size))
            LabeledContent("Farbe", value: content.fillColorHex)
        }
    }

    private func maskSection(_ mask: LayerMask) -> some View {
        Section("Maske") {
            LabeledContent("Herkunft", value: mask.source == .manualBrush ? "Pinsel" : "Automatisch")
            LabeledContent("Umgekehrt", value: mask.isInverted ? "Ja" : "Nein")
            LabeledContent("Aktiv", value: mask.isEnabled ? "Ja" : "Nein")
        }
    }

    // MARK: - Zahlenformat

    /// Ganze Punkte reichen — Nachkommastellen bei Bildmassen sind Rauschen.
    private func number(_ value: Double) -> String {
        value.rounded() == value
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    private func formatted(_ size: Size) -> String {
        format(size.width, size.height)
    }

    private func format(_ a: Double, _ b: Double) -> String {
        "\(number(a)) × \(number(b))"
    }

    private func formatScale(_ transform: Transform2D) -> String {
        let x = Int((abs(transform.scaleX) * 100).rounded())
        let y = Int((abs(transform.scaleY) * 100).rounded())
        // Spiegelung steckt im Vorzeichen der Skalierung — das muss sichtbar
        // sein, sonst wirkt eine gespiegelte Ebene unverändert.
        let mirrored = [
            transform.scaleX < 0 ? "horizontal" : nil,
            transform.scaleY < 0 ? "vertikal" : nil
        ].compactMap { $0 }

        let base = x == y ? "\(x) %" : "\(x) % × \(y) %"
        return mirrored.isEmpty ? base : base + " (gespiegelt: \(mirrored.joined(separator: ", ")))"
    }
}
