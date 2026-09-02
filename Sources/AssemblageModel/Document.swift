import Foundation

/// Fehler bei Ebenen-Operationen. Laut Plan (2.1 „Fehler abfangen statt
/// abstürzen") dürfen ungültige Operationen (z. B. unbekannte Ebenen-ID)
/// nie zum Absturz führen, sondern müssen als Fehler zurückgemeldet werden.
public enum DocumentError: Error, Equatable, Sendable {
    case layerNotFound(UUID)
    case invalidIndex(Int)
}

/// Das Dokument-Wurzelobjekt (7.4): Canvas-Grösse plus flacher Ebenenbaum.
/// Wird am Mac in ein `NSDocument`-Bundle serialisiert (JSON + referenzierte
/// Originalbilder/Masken); hier nur die reine, testbare Datenstruktur.
public struct Document: Codable, Equatable, Sendable {
    public var canvas: CanvasSize
    /// Reihenfolge = Kompositing-Reihenfolge, Index 0 liegt zuunterst.
    public var layers: [Layer]

    public init(canvas: CanvasSize, layers: [Layer] = []) {
        self.canvas = canvas
        self.layers = layers
    }

    public init(preset: CanvasPreset, layers: [Layer] = []) {
        self.init(canvas: preset.size, layers: layers)
    }

    // MARK: - Ebenen-Operationen

    /// Fügt eine Ebene an gegebenem Index ein (Standard: ganz oben/zuoberst).
    @discardableResult
    public mutating func addLayer(_ layer: Layer, at index: Int? = nil) throws -> Layer {
        let insertionIndex = index ?? layers.count
        guard insertionIndex >= 0, insertionIndex <= layers.count else {
            throw DocumentError.invalidIndex(insertionIndex)
        }
        layers.insert(layer, at: insertionIndex)
        return layer
    }

    @discardableResult
    public mutating func removeLayer(id: UUID) throws -> Layer {
        guard let index = layers.firstIndex(where: { $0.id == id }) else {
            throw DocumentError.layerNotFound(id)
        }
        return layers.remove(at: index)
    }

    /// Verschiebt eine Ebene an eine neue Position (Drag & Drop in der
    /// Ebenenliste, Plan 5.2).
    public mutating func moveLayer(id: UUID, toIndex newIndex: Int) throws {
        guard let currentIndex = layers.firstIndex(where: { $0.id == id }) else {
            throw DocumentError.layerNotFound(id)
        }
        guard newIndex >= 0, newIndex < layers.count else {
            throw DocumentError.invalidIndex(newIndex)
        }
        let layer = layers.remove(at: currentIndex)
        layers.insert(layer, at: newIndex)
    }

    public func index(ofLayerID id: UUID) -> Int? {
        layers.firstIndex(where: { $0.id == id })
    }

    public func layer(withID id: UUID) -> Layer? {
        layers.first(where: { $0.id == id })
    }

    /// Wendet eine Änderung auf eine bestehende Ebene an (z. B. ein
    /// verschobener Regler im Eigenschaften-Inspector) und gibt einen
    /// klaren Fehler statt eines Absturzes, falls die Ebene nicht mehr
    /// existiert (z. B. zwischenzeitlich gelöscht).
    public mutating func updateLayer(id: UUID, _ transform: (inout Layer) -> Void) throws {
        guard let index = layers.firstIndex(where: { $0.id == id }) else {
            throw DocumentError.layerNotFound(id)
        }
        transform(&layers[index])
    }
}
