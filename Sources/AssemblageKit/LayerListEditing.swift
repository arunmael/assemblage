import Foundation
import AssemblageModel

/// Ziel eines Befehls, der die ausgewählte Ebene im Stapel verschiebt.
enum LayerOrderCommand: CaseIterable {
    case up
    case down
    case toTop
    case toBottom

    var actionName: String {
        switch self {
        case .up: "Ebene nach oben"
        case .down: "Ebene nach unten"
        case .toTop: "Ebene ganz nach oben"
        case .toBottom: "Ebene ganz nach unten"
        }
    }
}

/// Kapselt Änderungen aus der Ebenenliste, damit Reihenfolge, Validierung
/// und Undo-Verhalten unabhängig von der SwiftUI-Darstellung prüfbar sind.
@MainActor
struct LayerListEditing {
    let state: DocumentState

    func toggleVisibility(of id: UUID) {
        guard let layer = state.document.layer(withID: id) else { return }
        let actionName = layer.isVisible ? "Ebene ausblenden" : "Ebene einblenden"

        state.owner?.modify(actionName) { document in
            try? document.updateLayer(id: id) { $0.isVisible.toggle() }
        }
    }

    func rename(_ id: UUID, to name: String) {
        let bereinigterName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bereinigterName.isEmpty else { return }

        state.owner?.modify("Ebene umbenennen") { document in
            try? document.updateLayer(id: id) { $0.name = bereinigterName }
        }
    }

    func delete(_ id: UUID) {
        state.owner?.modify("Ebene löschen") { document in
            _ = try? document.removeLayer(id: id)
        }
    }

    /// Verschiebt die Auswahl in Modellreihenfolge: Index 0 liegt zuunterst,
    /// deshalb bedeutet „nach oben“ ausdrücklich einen höheren Index.
    func moveSelected(_ command: LayerOrderCommand) {
        guard let id = state.selectedLayerID,
              let currentIndex = state.document.index(ofLayerID: id)
        else { return }

        let targetIndex: Int
        switch command {
        case .up:
            targetIndex = min(currentIndex + 1, state.document.layers.count - 1)
        case .down:
            targetIndex = max(currentIndex - 1, 0)
        case .toTop:
            targetIndex = state.document.layers.count - 1
        case .toBottom:
            targetIndex = 0
        }
        guard targetIndex != currentIndex else { return }

        state.owner?.modify(command.actionName) { document in
            try? document.moveLayer(id: id, toIndex: targetIndex)
        }
    }

    /// Verschiebt Ebenen in den Koordinaten der sichtbaren Liste. Das Ziel
    /// entspricht dabei der SwiftUI-Semantik: Es bezeichnet die Einfügestelle
    /// vor dem Entfernen der gezogenen Zeilen.
    func move(fromListOffsets offsets: IndexSet, toListOffset destination: Int) {
        let currentList = layersInListOrder
        guard !offsets.isEmpty,
              destination >= 0,
              destination <= currentList.count,
              offsets.allSatisfy({ currentList.indices.contains($0) })
        else { return }

        let movedLayers = offsets.map { currentList[$0] }
        let remainingLayers = currentList.enumerated().compactMap { index, layer in
            offsets.contains(index) ? nil : layer
        }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertionIndex = destination - removedBeforeDestination
        guard remainingLayers.indices.contains(insertionIndex) || insertionIndex == remainingLayers.endIndex else {
            return
        }

        var desiredList = remainingLayers
        desiredList.insert(contentsOf: movedLayers, at: insertionIndex)
        let desiredModelIDs = desiredList.reversed().map(\.id)

        state.owner?.modify("Reihenfolge ändern") { document in
            // Das Modell liegt entgegengesetzt zur Liste. Nach der Umkehrung
            // wird jede Ebene an ihren endgültigen Modellindex verschoben.
            for (modelIndex, id) in desiredModelIDs.enumerated() {
                guard document.index(ofLayerID: id) != modelIndex else { continue }
                try? document.moveLayer(id: id, toIndex: modelIndex)
            }
        }
    }

    /// Die Ebenen in Listenreihenfolge: oberste zuerst.
    var layersInListOrder: [Layer] {
        Array(state.document.layers.reversed())
    }
}
