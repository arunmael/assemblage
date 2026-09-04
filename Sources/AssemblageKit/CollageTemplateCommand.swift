import Foundation
import AssemblageModel

/// Wendet eine kuratierte Collage-Vorlage auf die sichtbaren Bildebenen an.
///
/// Die Vorlage bleibt ein frei editierbarer Startpunkt: Sie ändert nur
/// Transformation und Zuschnitt bestehender Bilder und legt keine Ebenen an.
@MainActor
enum CollageTemplateCommand {

    static func canApply(to state: DocumentState) -> Bool {
        state.document.layers.contains { layer in
            guard layer.isVisible, case .image = layer.content else { return false }
            return true
        }
    }

    static func apply(_ template: CollageTemplate, to state: DocumentState) {
        apply(template, to: state) { content in
            guard state.images.image(named: content.originalFileReference) != nil,
                  let pixelSize = state.images.pixelSize(named: content.originalFileReference)
            else {
                return nil
            }
            return Size(pixelSize)
        }
    }

    /// Die auflösbare Bildgrösse ist injizierbar, damit die Dokumentlogik
    /// ohne GPU, Pasteboard oder Dateidekodierung getestet werden kann.
    static func apply(
        _ template: CollageTemplate,
        to state: DocumentState,
        imageSize: (ImageLayerContent) -> Size?
    ) {
        guard let owner = state.owner else { return }

        let candidates = state.document.layers.filter { layer in
            guard layer.isVisible, case .image = layer.content else { return false }
            return true
        }

        let placements: [(id: UUID, placement: (transform: Transform2D, cropRect: Rect?), size: Size)] =
            candidates.prefix(template.capacity).enumerated().compactMap { index, layer in
                guard case .image(let content) = layer.content,
                      let size = imageSize(content),
                      let placement = template.placement(
                        forIndex: index,
                        contentSize: size,
                        canvas: state.document.canvas
                      )
                else { return nil }
                return (layer.id, placement, size)
            }

        guard !placements.isEmpty else { return }

        owner.modify("Collage-Vorlage anwenden") { document in
            for item in placements {
                try? document.updateLayer(id: item.id) { layer in
                    let wholeImage = Rect(
                        x: 0,
                        y: 0,
                        width: item.size.width,
                        height: item.size.height
                    )
                    layer = layer.cropped(
                        to: item.placement.cropRect ?? wholeImage,
                        imageSize: item.size
                    )
                    layer.transform = item.placement.transform
                }
            }
        }
    }
}
