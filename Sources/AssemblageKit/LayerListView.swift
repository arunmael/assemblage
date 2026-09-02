import SwiftUI
import AssemblageModel

/// Die Ebenenliste (Plan 8, links im Fenster).
///
/// SwiftUI statt AppKit, weil hier nur Standard-UI nötig ist — genau die
/// Arbeitsteilung aus Plan 7.1: Canvas in AppKit, Paletten in SwiftUI.
///
/// Phase 0 zeigt die Ebenen nur an; Umbenennen, Umsortieren und die
/// Sichtbarkeits-Schalter kommen laut Roadmap in Phase 1.
struct LayerListView: View {

    @ObservedObject var state: DocumentState

    var body: some View {
        List(selection: $state.selectedLayerID) {
            // Oberste Ebene zuoberst — im Modell liegt Index 0 zuunterst
            // (Kompositing-Reihenfolge), in der Liste ist es umgekehrt.
            ForEach(state.document.layers.reversed()) { layer in
                LayerRow(layer: layer, state: state)
                    .tag(layer.id)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if state.document.layers.isEmpty {
                ContentUnavailableView(
                    "Keine Ebenen",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Zieh ein Foto auf die Arbeitsfläche.")
                )
            }
        }
    }
}

private struct LayerRow: View {

    let layer: Layer
    @ObservedObject var state: DocumentState

    var body: some View {
        HStack(spacing: 10) {
            LayerThumbnail(layer: layer, state: state)

            VStack(alignment: .leading, spacing: 1) {
                Text(layer.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if !layer.isVisible {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Ausgeblendet")
            }
        }
        .padding(.vertical, 2)
        // Ausgeblendete Ebenen auch in der Liste zurücknehmen — sonst sucht
        // man bei einer langen Liste, welche gerade nicht sichtbar ist.
        .opacity(layer.isVisible ? 1 : 0.5)
    }

    /// Zeigt nur, was vom Normalfall abweicht — eine Zeile „Normal · 100 %"
    /// bei jeder Ebene wäre reines Rauschen (Plan 4.2).
    private var subtitle: String {
        var parts: [String] = []
        if layer.blendMode != .normal {
            parts.append(layer.blendMode.localizedName)
        }
        if layer.opacity < 1 {
            parts.append("\(Int((layer.opacity * 100).rounded())) %")
        }
        if layer.mask != nil {
            parts.append("Maske")
        }
        return parts.joined(separator: " · ")
    }
}

/// Vorschaubild einer Ebene.
private struct LayerThumbnail: View {

    let layer: Layer
    @ObservedObject var state: DocumentState

    private let side: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary)
            .frame(width: side, height: side)
            .overlay { content }
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var content: some View {
        switch layer.content {
        case .image(let image):
            if let cgImage = state.images.image(named: image.originalFileReference) {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // Fehlendes Original sichtbar machen, statt eine leere
                // Kachel zu zeigen.
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

        case .text:
            Image(systemName: "textformat")
                .foregroundStyle(.secondary)

        case .shape(let shape):
            shapePreview(shape)
        }
    }

    @ViewBuilder
    private func shapePreview(_ shape: ShapeLayerContent) -> some View {
        let color = Color(nsColor: NSColor(cgColor: (RGBA(hex: shape.fillColorHex) ?? .white).cgColor) ?? .white)
        switch shape.kind {
        case .rectangle: Rectangle().fill(color).padding(4)
        case .roundedRectangle: RoundedRectangle(cornerRadius: 4).fill(color).padding(4)
        case .ellipse: Ellipse().fill(color).padding(4)
        }
    }
}
