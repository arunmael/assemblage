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
    /// Leuchten und Schlagschatten. `nil` heisst: keine — der Normalfall.
    public var effects: LayerEffects?
    /// Eine über die Ebene gelegte Textur. `nil` heisst: keine.
    public var texture: LayerTexture?
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
        effects: LayerEffects? = nil,
        texture: LayerTexture? = nil,
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
        self.effects = effects
        self.texture = texture
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

extension Layer {

    /// Diese Ebene ohne alles, was nachträglich an ihr eingestellt wurde:
    /// ohne Anpassungen, Maske, Verzerrung, Effekte und Textur.
    ///
    /// Grundlage für den Vorher/Nachher-Vergleich (aus missing.md). Lage,
    /// Grösse, Drehung und Zuschnitt bleiben absichtlich erhalten — sonst
    /// spränge die Ebene beim Vergleichen an eine andere Stelle, und man
    /// vergliche zwei Bilder, die nebeneinander gar nicht deckungsgleich sind.
    ///
    /// Auch Deckkraft und Blend-Modus bleiben: Sie beschreiben, wie die Ebene
    /// zu den anderen steht, nicht wie sie selbst bearbeitet wurde.
    public func withoutEdits() -> Layer {
        var ergebnis = self
        ergebnis.mask = nil
        ergebnis.distortion = nil
        ergebnis.effects = nil
        ergebnis.texture = nil

        if case .image(var inhalt) = content {
            inhalt.adjustments = .neutral
            ergebnis.content = .image(inhalt)
        }

        return ergebnis
    }

    /// Ob es überhaupt etwas zu vergleichen gibt. Ohne diese Prüfung böte die
    /// App einen Vergleich an, der nichts zeigt.
    public var hasEdits: Bool {
        if mask != nil || distortion != nil || effects != nil || texture != nil { return true }
        if case .image(let inhalt) = content, inhalt.adjustments != .neutral { return true }
        return false
    }
}
