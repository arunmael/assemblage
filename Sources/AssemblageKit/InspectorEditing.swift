import Foundation
import AssemblageModel

/// Kapselt Änderungen aus dem Eigenschaften-Inspector, damit ihre
/// Undo- und Begrenzungslogik ohne SwiftUI-Ansicht geprüft werden kann.
@MainActor
struct InspectorEditing {
    let state: DocumentState

    /// Beginnt eine zusammenhängende Änderung (Regler gedrückt).
    func beginEditing() {
        state.owner?.beginInteraction()
    }

    /// Schliesst sie ab und setzt genau einen Undo-Schritt.
    func endEditing(actionName: String) {
        state.owner?.endInteraction(actionName: actionName)
    }

    /// Ändert die ausgewählte Ebene. Tut nichts, wenn keine ausgewählt ist
    /// oder sie zwischenzeitlich gelöscht wurde.
    func updateSelectedLayer(actionName: String, _ body: (inout Layer) -> Void) {
        guard let id = state.selectedLayerID else { return }

        state.owner?.modify(actionName) { document in
            _ = try? document.updateLayer(id: id) { layer in
                body(&layer)
                layer.opacity = layer.opacity.clamped(to: 0...1)

                if case .image(var content) = layer.content {
                    content.adjustments = content.adjustments.clamped()
                    layer.content = .image(content)
                }
            }
        }
    }

    /// Setzt die Bildanpassungen der ausgewählten Ebene zurück.
    func resetAdjustments() {
        updateSelectedLayer(actionName: "Bildanpassungen zurücksetzen") { layer in
            guard case .image(var content) = layer.content else { return }
            content.adjustments = .neutral
            layer.content = .image(content)
        }
    }

    /// Akzeptiert Punkt und Komma als Dezimaltrennzeichen. Gemischte
    /// Schreibweisen bleiben ungültig, weil ihre Bedeutung mehrdeutig ist.
    static func number(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !(trimmed.contains(",") && trimmed.contains(".")) else { return nil }

        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }
}
