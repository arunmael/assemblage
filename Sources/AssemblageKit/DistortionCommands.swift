import AssemblageModel

/// Befehle für Verzerrungen, getrennt von der Darstellung im Canvas.
@MainActor
enum DistortionCommands {
    static func resetSelected(in state: DocumentState) {
        guard let id = state.selectedLayerID,
              state.document.layer(withID: id)?.distortion != nil
        else { return }
        state.owner?.modify("Verzerrung zurücksetzen") {
            try? $0.updateLayer(id: id) { $0.distortion = nil }
        }
    }
}
