import Foundation

/// Eine einzelne Ebene im Ebenenbaum (Plan 5.2, 7.4). Assemblage kennt laut
/// Plan keine verschachtelten Gruppen (anders als Sceau) — Ebenen liegen
/// flach in `Document.layers`, ihre Reihenfolge bestimmt das Kompositing.
public struct Layer: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isVisible: Bool
    /// 0 (unsichtbar) ... 1 (voll deckend).
    public var opacity: Double
    public var blendMode: BlendMode
    public var transform: Transform2D
    public var mask: LayerMask?
    /// Freies Verziehen der vier Ecken (siehe `QuadDistortion`). `nil` heisst
    /// unverzerrt — der Normalfall, und dann verhält sich alles wie bisher.
    public var distortion: QuadDistortion?
    public var content: LayerContent

    public init(
        id: UUID = UUID(),
        name: String,
        isVisible: Bool = true,
        opacity: Double = 1,
        blendMode: BlendMode = .normal,
        transform: Transform2D = .identity,
        mask: LayerMask? = nil,
        distortion: QuadDistortion? = nil,
        content: LayerContent
    ) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.opacity = opacity
        self.blendMode = blendMode
        self.transform = transform
        self.mask = mask
        self.distortion = distortion
        self.content = content
    }

    /// Deckkraft auf den gültigen Bereich begrenzt zurückgeben (Regler-Eingaben
    /// können durch schnelles Ziehen kurzzeitig ausserhalb liegen).
    public func withClampedOpacity() -> Layer {
        var copy = self
        copy.opacity = opacity.clamped(to: 0...1)
        return copy
    }
}
