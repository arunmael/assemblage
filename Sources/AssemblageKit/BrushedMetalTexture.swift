import AppKit

/// Erzeugt und zeichnet eine gebürstete Metall-Textur für die grossen
/// Panel-Flächen im Erscheinungsbild „Beautifull" (Regel B der Theme-Vorgabe:
/// „Brushed Metal: Use multi-stop linear gradients … Apply a subtle noise/
/// grain texture overlay").
///
/// Die Rauschmathematik (Streifen aus wertbasiertem Rauschen + eine breite,
/// „wolkige" Glanzzone) ist inhaltlich von jolonf/BrushedMetalShader
/// (`BrushedMetal.metal`, ein SwiftUI-`[[stitchable]]`-Metal-Shader) auf
/// CPU-Pixel übertragen, nicht Code-Zeile für Zeile übernommen: Ein
/// Metal-Shader bräuchte einen `.metallib`-Kompilierschritt, den dieses
/// reine SwiftPM-Ziel (`Scripts/make-app.sh`, `swift build`) nicht hat —
/// eine einmalig gezeichnete, gecachte Kachel ist hier die robustere Wahl
/// als ein Live-Shader, der beim App-Start ins Leere greifen könnte.
enum BrushedMetalTexture {

    /// Eine Kachel pro (Kantenlänge, Tönung) reicht aus — `BrushedMetalView`
    /// zeichnet dieselbe Kachel in jede Instanz, das Rauschen selbst hat kein
    /// erkennbares Wiederholungsmuster in Panelgrösse.
    private static var cache: [String: NSImage] = [:]

    static func makeTile(edge: Int = 128, tint: NSColor) -> NSImage {
        let converted = tint.usingColorSpace(.deviceRGB) ?? tint
        let key = "\(edge)-\(converted.redComponent)-\(converted.greenComponent)-\(converted.blueComponent)"
        if let cached = cache[key] { return cached }

        let image = render(edge: edge, tint: converted)
        cache[key] = image
        return image
    }

    // MARK: - Rauschen

    /// Deterministisches „weisses" Rauschen aus einer Koordinate — dieselbe
    /// Hash-Formel wie im Metal-Original (`sin`/`fract` als billiger
    /// Pseudozufall, kein echter Zufallsgenerator nötig).
    private static func whiteNoise(_ x: Double, _ y: Double) -> Double {
        let value = sin(x * 12.9898 + y * 78.233) * 43758.5453
        return value - floor(value)
    }

    /// Wertrauschen: bilinear zwischen vier `whiteNoise`-Ecken interpoliert,
    /// dadurch räumlich zusammenhängend statt Pixel-für-Pixel-Rauschen —
    /// ergibt die weichen Streifen/Wolken statt reinem Bildrauschen.
    private static func valueNoise(_ x: Double, _ y: Double) -> Double {
        let ix = floor(x), iy = floor(y)
        let fx = x - ix, fy = y - iy
        let a = whiteNoise(ix, iy)
        let b = whiteNoise(ix + 1, iy)
        let c = whiteNoise(ix, iy + 1)
        let d = whiteNoise(ix + 1, iy + 1)
        let ux = fx * fx * (3 - 2 * fx)
        let uy = fy * fy * (3 - 2 * fy)
        return a + (b - a) * ux + (c - a) * uy * (1 - ux) + (d - b) * ux * uy
    }

    private static func render(edge: Int, tint: NSColor) -> NSImage {
        let width = max(8, edge)
        let height = max(8, edge)
        // Selbst verwaltete Pufferzuweisung statt eines Swift-Arrays: `&array`
        // ergibt nur für den einen Aufruf, dem er übergeben wird, einen
        // gültigen Zeiger — `CGContext` hält ihn aber über `makeImage()`
        // hinaus, ein Array-Zeiger wäre dann bereits ungültig (das erste
        // Ergebnis war deshalb eine leere/zufällige Textur statt Rauschen).
        let byteCount = width * height * 4
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        pixels.initialize(repeating: 0, count: byteCount)
        defer { pixels.deallocate() }

        // Dieselben Grössenordnungen wie die Shader-Parameter im Original
        // (streakDensity/highlightScale/…), fest verdrahtet statt als
        // Parameter: Die Textur ist ein einzelner, fertig abgestimmter
        // Materialeindruck, kein einstellbarer Effekt.
        let streakDensity = 1.0
        let highlightScale = 3.0
        let streakStrength = 0.55
        let highlightStrength = 0.5
        let n = 16.0

        let r = Double(tint.redComponent)
        let g = Double(tint.greenComponent)
        let b = Double(tint.blueComponent)

        for py in 0..<height {
            let v = Double(py) / Double(height)
            for px in 0..<width {
                let u = Double(px) / Double(width)

                var streak = 0.0
                var highlight = 0.0
                for i in 0..<Int(n) {
                    let fi = Double(i)
                    let streakBase = v * streakDensity * 16
                    let breakup = u * 6
                    streak += sqrt(1 / n) * (-0.5 + valueNoise(streakBase, fi + breakup))

                    let hx = u * highlightScale + fi * (10 + 1 / n) / 256
                    let hy = 0.5 + v * 0.004
                    highlight += sqrt(1 / n) * (-0.5 + valueNoise(hx * 64, hy * 64))
                }
                let l = exp(4 * highlight - 1.5)
                let sVal = exp(1.2 * streak - 1.5)
                let value = streakStrength * sVal + highlightStrength * l + 2 * sVal * l
                // Gamma-Korrektur wie im Original (`pow(col, 1/2.2)`), dann
                // mit der Panel-Tönung multipliziert statt reinem Graustufen-
                // Grau — sonst wirkt „gebürstetes Metall" wie ein
                // schwarz-weisses Rauschbild statt wie Metall in der
                // Palette des Erscheinungsbilds.
                let shade = min(1, max(0, pow(value, 1 / 2.2)))
                // Breitere Spanne als eine reine Gamma-Kurve (0.15…1.0 statt
                // 0.35…1.0): Unter der halbtransparenten Glas-Farbschicht
                // von `GlassPanel` briet die Textur bei der schmaleren Spanne
                // zu flach zu Grau statt sichtbar gebürstet zu wirken.
                let mix = 0.15 + shade * 0.85

                let offset = (py * width + px) * 4
                pixels[offset] = UInt8(max(0, min(255, r * mix * 255)))
                pixels[offset + 1] = UInt8(max(0, min(255, g * mix * 255)))
                pixels[offset + 2] = UInt8(max(0, min(255, b * mix * 255)))
                pixels[offset + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let cgImage = context.makeImage() else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}

/// Trägt die Textur aus `BrushedMetalTexture` als kachelnden Hintergrund —
/// `NSColor(patternImage:)` übernimmt das Kacheln selbst, dadurch passt sich
/// die Fläche jeder Panelgrösse an, ohne die Textur selbst neu zu berechnen.
@MainActor
final class BrushedMetalView: NSView {
    var tint: NSColor {
        didSet { needsDisplay = true }
    }

    init(tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    override func draw(_ dirtyRect: NSRect) {
        let tile = BrushedMetalTexture.makeTile(tint: tint)
        NSColor(patternImage: tile).set()
        dirtyRect.fill()
    }
}
