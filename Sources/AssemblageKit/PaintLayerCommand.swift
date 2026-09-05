import AppKit
import CoreGraphics
import AssemblageModel

/// Fügt eine leere Malebene ein (aus Anpassungen.md: „Das Malen auf einem
/// Foto sollte ... auf einer eigenen Ebene sein").
///
/// Der Farbpinsel (`ColorPainter`) kann grundsätzlich auf jeder Bildebene
/// malen — genau wie in Procreate, wo ein Pinsel jede angewählte Ebene
/// anfasst. Wer aber nicht versehentlich ein eingesetztes Foto dauerhaft
/// übermalen will, braucht eine frische, leere Fläche zum Anfangen. Dieser
/// Befehl legt genau die an: eine vollständig durchsichtige Bildebene in
/// Leinwandgrösse.
///
/// Ein eigener, kleiner Befehl statt eines weiteren `NewLayerKind`-Falls:
/// `LayerCreation.makeLayer` kennt keine `DocumentResources` und legt keine
/// Dateien an — für jeden bisherigen Fall reichte das, weil keiner von ihnen
/// eine eigene Bilddatei braucht. Eine leere Malebene aber schon.
@MainActor
enum PaintLayerCommand {

    static let defaultName = "Malebene"

    @discardableResult
    static func insertBlankLayer(into state: DocumentState) -> Bool {
        guard let owner = state.owner else { return false }
        let canvas = state.document.canvas
        guard canvas.width.isFinite, canvas.height.isFinite,
              canvas.width > 0, canvas.height > 0,
              canvas.width <= Double(Int32.max), canvas.height <= Double(Int32.max),
              let png = blankTransparentPNG(
                  width: Int(canvas.width.rounded()),
                  height: Int(canvas.height.rounded())
              )
        else { return false }

        let referenz = state.resources.addOriginal(png, fileExtension: "png")
        let layer = Layer(
            name: defaultName,
            // Deckt die Leinwand exakt ab — dieselbe Grösse wie das Bild.
            transform: Transform2D(x: canvas.width / 2, y: canvas.height / 2),
            content: .image(ImageLayerContent(originalFileReference: referenz))
        )

        owner.modify("Malebene einfügen") { document in
            _ = try? document.addLayer(layer)
        }
        state.selectedLayerID = layer.id
        return true
    }

    /// Eine vollständig durchsichtige RGBA-Fläche der gegebenen Grösse.
    private static func blankTransparentPNG(width: Int, height: Int) -> Data? {
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        // Nicht auf zufälligen Anfangsspeicher verlassen — derselbe Grund
        // wie bei `ColorPainter.init`.
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
