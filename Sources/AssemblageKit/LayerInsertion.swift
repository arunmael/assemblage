import AssemblageModel

@MainActor
enum LayerInsertion {

    /// Der Index, an dem eine neu eingefügte Ebene landen soll: direkt
    /// **über** der ausgewählten. `nil` heisst „ganz oben" — das ist der Fall,
    /// wenn nichts ausgewählt ist oder die Auswahl nicht mehr existiert.
    static func indexAboveSelection(in state: DocumentState) -> Int? {
        guard let selectedLayerID = state.selectedLayerID else { return nil }
        return state.document.layers.firstIndex { $0.id == selectedLayerID }.map { $0 + 1 }
    }
}
