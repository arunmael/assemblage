import Foundation

/// Ein Leuchten um die Ebene herum.
///
/// Plan 6 lässt Ebenenstile nur sparsam zu („falls überhaupt, nur ein simpler
/// Schlagschatten mit 2–3 Reglern"). Deshalb bewusst wenige Regler: Radius,
/// Farbe, Stärke. Kein Winkel, keine Kurven, keine Voreinstellungen.
public struct Glow: Codable, Equatable, Sendable {
    /// Wie weit das Leuchten reicht, in Punkten. 0 heisst: kein Leuchten.
    public var radius: Double
    public var colorHex: String
    /// 0 … 1
    public var intensity: Double

    public init(radius: Double = 0, colorHex: String = "#FFFFFF", intensity: Double = 0.8) {
        self.radius = radius
        self.colorHex = colorHex
        self.intensity = intensity
    }

    var isActive: Bool { radius > 0 && intensity > 0 }

    func clamped() -> Glow {
        Glow(
            radius: max(0, radius),
            colorHex: colorHex,
            intensity: intensity.clamped(to: 0...1)
        )
    }
}

/// Ein Schlagschatten — der eine Ebenenstil, den Plan 6 ausdrücklich erlaubt.
public struct Shadow: Codable, Equatable, Sendable {
    public var offsetX: Double
    public var offsetY: Double
    /// Weichzeichnung des Schattens in Punkten.
    public var radius: Double
    public var colorHex: String
    /// 0 … 1
    public var opacity: Double

    public init(
        offsetX: Double = 0,
        offsetY: Double = 0,
        radius: Double = 0,
        colorHex: String = "#000000",
        opacity: Double = 0.5
    ) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.radius = radius
        self.colorHex = colorHex
        self.opacity = opacity
    }

    /// Ein Schatten ohne Versatz und ohne Weichzeichnung liegt exakt hinter
    /// der Ebene und ist damit unsichtbar — reiner Rechenaufwand.
    var isActive: Bool {
        opacity > 0 && (offsetX != 0 || offsetY != 0 || radius > 0)
    }

    func clamped() -> Shadow {
        Shadow(
            offsetX: offsetX,
            offsetY: offsetY,
            radius: max(0, radius),
            colorHex: colorHex,
            opacity: opacity.clamped(to: 0...1)
        )
    }
}

/// Effekte einer Ebene. Optional an der Ebene, damit für die allermeisten
/// Ebenen weder etwas gespeichert noch gerechnet wird.
public struct LayerEffects: Codable, Equatable, Sendable {
    public var glow: Glow?
    public var shadow: Shadow?

    public init(glow: Glow? = nil, shadow: Shadow? = nil) {
        self.glow = glow
        self.shadow = shadow
    }

    /// Ob überhaupt etwas zu zeichnen ist. Der Renderer fragt das, bevor er
    /// eine Filterkette aufbaut — ein Effekt mit Radius null ist keiner.
    public var isActive: Bool {
        (glow?.isActive ?? false) || (shadow?.isActive ?? false)
    }

    public func clamped() -> LayerEffects {
        LayerEffects(glow: glow?.clamped(), shadow: shadow?.clamped())
    }
}

/// Eine Textur, die über die Ebene gelegt wird — Papier, Korn, Kratzer.
///
/// Bewusst eine Überlagerung **auf** einer Ebene und keine eigene Ebenenart:
/// Eine Textur gehört zu dem, was sie überzieht, und soll mit ihm zusammen
/// verschoben, skaliert und maskiert werden. Als eigene Ebene müsste man sie
/// bei jeder Bewegung nachführen.
public struct LayerTexture: Codable, Equatable, Sendable {
    /// Relativer Pfad im Dokumentpaket, wie bei Bildebenen.
    public var imageReference: String
    public var blendMode: BlendMode
    /// 0 … 1
    public var opacity: Double
    /// Massstab der Textur relativ zur Ebene. Grösser als 0.
    public var scale: Double

    public init(
        imageReference: String,
        blendMode: BlendMode = .multiply,
        opacity: Double = 0.5,
        scale: Double = 1
    ) {
        self.imageReference = imageReference
        self.blendMode = blendMode
        self.opacity = opacity
        self.scale = scale
    }

    public func clamped() -> LayerTexture {
        LayerTexture(
            imageReference: imageReference,
            blendMode: blendMode,
            opacity: opacity.clamped(to: 0...1),
            // Massstab null liesse die Textur verschwinden und wäre nicht
            // wieder aufzuziehen.
            scale: max(0.01, scale)
        )
    }
}
