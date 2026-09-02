#!/usr/bin/env swift
//
// Erzeugt das App-Symbol als .iconset-Ordner.
//
// Als Code statt als Bilddatei, damit das Symbol versionierbar und ohne
// Grafikprogramm änderbar bleibt (gleiches Vorgehen wie bei Regal).
//
// Motiv: drei versetzte Fotos, wie sie beim Collagieren übereinanderliegen —
// das Wort „Assemblage" bezeichnet genau dieses Zusammensetzen.
//
// Aufruf: swift Scripts/make-icon.swift <ziel.iconset>

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("Aufruf: make-icon.swift <ziel.iconset>\n".utf8))
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.removeItem(at: outputDirectory)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// Zeichnet das Symbol in einer beliebigen Kantenlänge. Alle Masse sind
/// Bruchteile der Kantenlänge, damit es in jeder Grösse gleich aussieht.
func drawIcon(side: CGFloat, into context: CGContext) {
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Grundfläche im macOS-Format: abgerundetes Quadrat mit Rand.
    let inset = side * 0.09
    let plate = CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    let plateRadius = side * 0.2

    context.saveGState()
    context.addPath(CGPath(roundedRect: plate, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil))
    context.clip()

    // Sanfter Verlauf statt Volltonfläche — sonst wirkt das Symbol im Dock flach.
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1),
            CGColor(srgbRed: 0.88, green: 0.90, blue: 0.94, alpha: 1)
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )

    // Die drei „Fotos": von hinten nach vorne, jedes leicht gedreht.
    let cards: [(dx: CGFloat, dy: CGFloat, angle: CGFloat, color: CGColor)] = [
        (-0.10, 0.06, 0.16, CGColor(srgbRed: 0.36, green: 0.55, blue: 0.85, alpha: 1)),
        (0.10, 0.02, -0.12, CGColor(srgbRed: 0.95, green: 0.66, blue: 0.30, alpha: 1)),
        (0.00, -0.06, 0.03, CGColor(srgbRed: 0.24, green: 0.24, blue: 0.28, alpha: 1))
    ]

    let cardSize = CGSize(width: side * 0.40, height: side * 0.40)
    let cardRadius = side * 0.035

    for card in cards {
        context.saveGState()
        context.translateBy(x: side / 2 + card.dx * side, y: side / 2 + card.dy * side)
        context.rotate(by: card.angle)

        let rect = CGRect(
            x: -cardSize.width / 2,
            y: -cardSize.height / 2,
            width: cardSize.width,
            height: cardSize.height
        )
        let path = CGPath(roundedRect: rect, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)

        context.setShadow(
            offset: CGSize(width: 0, height: -side * 0.012),
            blur: side * 0.03,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28)
        )
        // Weisser Rand wie bei einem Polaroid — trennt die Karten sichtbar
        // voneinander, auch wenn das Symbol nur 16 px gross ist.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.addPath(path)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)

        let border = side * 0.022
        context.setFillColor(card.color)
        context.addPath(
            CGPath(
                roundedRect: rect.insetBy(dx: border, dy: border),
                cornerWidth: cardRadius * 0.6,
                cornerHeight: cardRadius * 0.6,
                transform: nil
            )
        )
        context.fillPath()
        context.restoreGState()
    }

    context.restoreGState()
}

func writePNG(side: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "make-icon", code: 1)
    }

    drawIcon(side: CGFloat(side), into: context)

    guard let image = context.makeImage() else { throw NSError(domain: "make-icon", code: 2) }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 3)
    }
    try data.write(to: url)
}

// Die von iconutil erwarteten Grössen.
for base in [16, 32, 128, 256, 512] {
    try writePNG(side: base, to: outputDirectory.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(side: base * 2, to: outputDirectory.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

print("✓ Symbol erzeugt: \(outputDirectory.path)")
