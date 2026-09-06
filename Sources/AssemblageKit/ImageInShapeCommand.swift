import Foundation
import AssemblageModel

/// Setzt eine Bildebene in den Umriss einer Formebene („Bild auf eine Form
/// ziehen", aus der UI-Sammlung).
///
/// Die Form wird dabei **aufgebraucht**: Sie verschwindet als eigene Ebene und
/// lebt als Zuschnitt der Bildebene weiter. Zwei Ebenen übereinander, von
/// denen die obere die untere nur beschneidet, wären sonst ein Zustand, den
/// man versehentlich auseinanderziehen kann — und dann wäre unklar, welche
/// von beiden „das Bild" ist.
///
/// Der Zuschnitt selbst ist nicht-destruktiv: `clipShape` merkt sich nur den
/// Umriss, das Original bleibt unangetastet und der Schritt ist widerrufbar.
@MainActor
enum ImageInShapeCommand {

    /// Wie das Bild in den Umriss gebracht wird.
    enum Fit: Equatable {
        /// Seitenverhältnis bleibt erhalten; was nicht in die Form passt,
        /// wird abgeschnitten.
        case cover
        /// Das ganze Bild wird auf die Form gezogen — nichts fällt weg,
        /// dafür verzieht es sich.
        case stretch

        var undoActionName: String {
            switch self {
            case .cover: "Bild in Form einsetzen"
            case .stretch: "Bild in Form ziehen"
            }
        }
    }

    /// Lässt sich `imageLayerID` in `shapeLayerID` setzen? Beide müssen
    /// existieren und den passenden Inhaltstyp haben.
    static func canApply(
        imageLayerID: UUID,
        shapeLayerID: UUID,
        in document: AssemblageModel.Document
    ) -> Bool {
        imageLayerID != shapeLayerID
            && imageContent(of: imageLayerID, in: document) != nil
            && shapeLayer(shapeLayerID, in: document) != nil
    }

    /// Oberste sichtbare Form am Punkt. Die eigentliche Treffergeometrie
    /// kommt aus `HitTesting.Transform2D.contains`; hier wird nur der
    /// Ebenenstapel nach Inhaltstyp gefiltert.
    static func topmostShapeLayer(
        at point: Point,
        excluding excludedID: UUID? = nil,
        in document: AssemblageModel.Document
    ) -> Layer? {
        document.layers.reversed().first { layer in
            guard layer.id != excludedID, layer.isVisible,
                  case .shape(let shape) = layer.content
            else { return false }
            return layer.transform.contains(point, contentSize: shape.size)
        }
    }

    static func apply(
        imageLayerID: UUID,
        shapeLayerID: UUID,
        fit: Fit,
        to state: DocumentState
    ) {
        apply(imageLayerID: imageLayerID, shapeLayerID: shapeLayerID, fit: fit, to: state) { content in
            state.images.pixelSize(named: content.originalFileReference).map(Size.init)
        }
    }

    /// Die auflösbare Bildgrösse ist injizierbar, damit die Dokumentlogik ohne
    /// GPU und Dateidekodierung geprüft werden kann — wie bei
    /// `CollageTemplateCommand`.
    static func apply(
        imageLayerID: UUID,
        shapeLayerID: UUID,
        fit: Fit,
        to state: DocumentState,
        imageSize: (ImageLayerContent) -> Size?
    ) {
        guard let owner = state.owner,
              let inhalt = imageContent(of: imageLayerID, in: state.document),
              let form = shapeLayer(shapeLayerID, in: state.document),
              case .shape(let formInhalt) = form.content,
              let bildgroesse = imageSize(inhalt)
        else { return }

        let rahmen = frame(of: form, content: formInhalt)
        guard rahmen.width > 0, rahmen.height > 0 else { return }

        let platzierung = switch fit {
        case .cover:
            ContentPlacement.fill(
                contentSize: bildgroesse,
                frame: rahmen,
                rotationDegrees: form.transform.rotationDegrees
            )
        case .stretch:
            ContentPlacement.stretch(
                contentSize: bildgroesse,
                frame: rahmen,
                rotationDegrees: form.transform.rotationDegrees
            )
        }

        owner.modify(fit.undoActionName) { document in
            try? document.updateLayer(id: imageLayerID) { layer in
                guard case .image(var content) = layer.content else { return }
                content.cropRect = platzierung.cropRect
                content.clipShape = formInhalt.kind
                // Der sichtbare Rand der Form wird zum Rahmen des Bildes —
                // sonst ginge er beim Aufbrauchen der Formebene verloren.
                if formInhalt.strokeWidth > 0 {
                    content.borderWidth = formInhalt.strokeWidth
                    content.borderColorHex = formInhalt.strokeColorHex
                }
                layer.content = .image(content)
                layer.transform = platzierung.transform
            }
            _ = try? document.removeLayer(id: shapeLayerID)
        }

        // Die Formebene ist weg; eine Auswahl, die auf sie zeigte, wäre ins
        // Leere gerichtet.
        if state.selectedLayerID == shapeLayerID {
            state.selectedLayerID = imageLayerID
        }
    }

    /// Nimmt den Formzuschnitt wieder zurück. Die Form selbst kommt nicht
    /// zurück — sie war beim Einsetzen aufgebraucht.
    static func removeClipShape(from imageLayerID: UUID, in state: DocumentState) {
        guard let owner = state.owner,
              let inhalt = imageContent(of: imageLayerID, in: state.document),
              inhalt.clipShape != nil
        else { return }

        owner.modify("Form-Zuschnitt aufheben") { document in
            try? document.updateLayer(id: imageLayerID) { layer in
                guard case .image(var content) = layer.content else { return }
                content.clipShape = nil
                layer.content = .image(content)
            }
        }
    }

    // MARK: - Hilfen

    /// Der achsenparallele Rahmen, den die Form auf der Leinwand einnimmt.
    private static func frame(of layer: Layer, content: ShapeLayerContent) -> Rect {
        let breite = content.size.width * abs(layer.transform.scaleX)
        let hoehe = content.size.height * abs(layer.transform.scaleY)
        return Rect(
            x: layer.transform.x - breite / 2,
            y: layer.transform.y - hoehe / 2,
            width: breite,
            height: hoehe
        )
    }

    private static func imageContent(
        of id: UUID,
        in document: AssemblageModel.Document
    ) -> ImageLayerContent? {
        guard let layer = document.layer(withID: id),
              case .image(let content) = layer.content
        else { return nil }
        return content
    }

    private static func shapeLayer(
        _ id: UUID,
        in document: AssemblageModel.Document
    ) -> Layer? {
        guard let layer = document.layer(withID: id),
              case .shape = layer.content
        else { return nil }
        return layer
    }
}
