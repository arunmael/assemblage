import SwiftUI
import AssemblageModel

/// Die Ebenenliste (Plan 8, links im Fenster).
///
/// SwiftUI statt AppKit, weil hier nur Standard-UI nötig ist — genau die
/// Arbeitsteilung aus Plan 7.1: Canvas in AppKit, Paletten in SwiftUI.
struct LayerListView: View {

    @ObservedObject var state: DocumentState

    private var editing: LayerListEditing {
        LayerListEditing(state: state)
    }

    var body: some View {
        List(selection: $state.selectedLayerID) {
            ForEach(editing.layersInListOrder) { layer in
                LayerRow(layer: layer, state: state, editing: editing)
                    .tag(layer.id)
            }
            .onMove(perform: editing.move)
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            guard let id = state.selectedLayerID else { return }
            editing.delete(id)
        }
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
    let editing: LayerListEditing

    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                LayerThumbnail(layer: layer, state: state)

                VStack(alignment: .leading, spacing: 1) {
                    name
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .opacity(layer.isVisible ? 1 : 0.5)

            Spacer(minLength: 0)

            Button {
                editing.toggleVisibility(of: layer.id)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(layer.isVisible ? "Ebene ausblenden" : "Ebene einblenden")
            .help(layer.isVisible ? "Ebene ausblenden" : "Ebene einblenden")
        }
        .contextMenu {
            Button(layer.isVisible ? "Ausblenden" : "Einblenden") {
                editing.toggleVisibility(of: layer.id)
            }
            Button("Umbenennen") {
                beginRenaming()
            }
            Divider()
            Button("Löschen", role: .destructive) {
                editing.delete(layer.id)
            }
        }
    }

    @ViewBuilder
    private var name: some View {
        if isRenaming {
            TextField("Ebenenname", text: $draftName)
                .textFieldStyle(.plain)
                .focused($isNameFocused)
                .onSubmit { finishRenaming() }
                .onExitCommand { cancelRenaming() }
                .onChange(of: isNameFocused) { _, focused in
                    guard isRenaming, !focused else { return }
                    finishRenaming()
                }
        } else {
            Text(layer.name)
                .lineLimit(1)
                .onTapGesture(count: 2) { beginRenaming() }
        }
    }

    private func beginRenaming() {
        draftName = layer.name
        isRenaming = true
        isNameFocused = true
    }

    private func finishRenaming() {
        editing.rename(layer.id, to: draftName)
        isRenaming = false
    }

    private func cancelRenaming() {
        draftName = layer.name
        isRenaming = false
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
        default:
            // Vorlagen über denselben Pfadbau wie Leinwand und Export: Eine
            // eigene SwiftUI-Nachbildung wäre eine zweite Wahrheit über die
            // Form und liefe irgendwann auseinander.
            TemplateShape(content: shape).fill(color).padding(4)
        }
    }
}


/// Miniaturansicht einer Formvorlage in der Ebenenliste.
private struct TemplateShape: Shape {
    let content: ShapeLayerContent

    func path(in rect: CGRect) -> Path {
        guard let pfad = ShapePath.cgPath(for: content, in: rect) else { return Path() }
        return Path(pfad)
    }
}
