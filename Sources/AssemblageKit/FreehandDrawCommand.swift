import AssemblageModel

/// Legt aus den Rohpunkten eines Mauszugs einen Freihand-Zug an oder hängt
/// ihn an die ausgewählte, passende Zeichenebene an.
@MainActor
enum FreehandDrawCommand {

    static func insert(
        rawPoints: [Point],
        strokeColorHex: String,
        strokeWidth: Double,
        into state: DocumentState
    ) {
        let pfad = FreehandStroke.path(from: rawPoints)
        guard !pfad.isEmpty,
              let ersterTeilpfad = pfad.subpaths.first,
              ersterTeilpfad.anchors.count >= 2,
              let rahmen = pfad.boundingBox,
              rahmen.x.isFinite, rahmen.y.isFinite,
              rahmen.width.isFinite, rahmen.height.isFinite,
              strokeWidth.isFinite,
              let owner = state.owner
        else { return }

        if let id = state.selectedLayerID,
           var ausgewaehlt = state.document.layer(withID: id),
           case .shape(var ausgewaehlterInhalt) = ausgewaehlt.content,
           ausgewaehlterInhalt.kind == .freehand {
            let istLeer = ausgewaehlterInhalt.path?.isEmpty ?? true
            let stiftPasst = ausgewaehlterInhalt.strokeColorHex.caseInsensitiveCompare(strokeColorHex) == .orderedSame
                && abs(ausgewaehlterInhalt.strokeWidth - strokeWidth) <= 0.001
            if istLeer || stiftPasst {
                if istLeer {
                    ausgewaehlterInhalt.strokeColorHex = strokeColorHex
                    ausgewaehlterInhalt.strokeWidth = strokeWidth
                    ausgewaehlt.content = .shape(ausgewaehlterInhalt)
                }
                if let ergebnis = ausgewaehlt.appendingFreehandStroke(canvasPath: pfad) {
                    owner.modify("Freihand zeichnen") { dokument in
                        try? dokument.updateLayer(id: id) { $0 = ergebnis }
                    }
                    state.selectedLayerID = id
                    return
                }
            }
        }

        let normalisiert = pfad.normalized()
        let mindestbreite = max(strokeWidth, 0)
        let breite = normalisiert.size.width == 0 ? mindestbreite : normalisiert.size.width
        let hoehe = normalisiert.size.height == 0 ? mindestbreite : normalisiert.size.height

        // Bei einer entarteten Achse liegt der normalisierte Pfad auf deren
        // Nullkante. Nach dem Aufpolstern muss er in die Mitte der neuen
        // Fläche rücken, damit der sichtbare Strich weiterhin auf dem
        // ursprünglichen Mauszug und damit auf `transform` liegt.
        let versatzX = normalisiert.size.width == 0 ? breite / 2 : 0
        let versatzY = normalisiert.size.height == 0 ? hoehe / 2 : 0
        let gespeicherterPfad = VectorPath(subpaths: normalisiert.path.subpaths.map { teilpfad in
            PathSubpath(
                anchors: teilpfad.anchors.map { $0.moved(by: versatzX, versatzY) },
                isClosed: teilpfad.isClosed
            )
        })

        let ebene = Layer(
            name: "Freihand",
            transform: Transform2D(
                x: rahmen.x + rahmen.width / 2,
                y: rahmen.y + rahmen.height / 2
            ),
            content: .shape(ShapeLayerContent(
                kind: .freehand,
                size: Size(width: breite, height: hoehe),
                fillColorHex: "#00000000",
                strokeColorHex: strokeColorHex,
                strokeWidth: strokeWidth,
                path: gespeicherterPfad
            ))
        )

        let index = LayerInsertion.indexAboveSelection(in: state)
        owner.modify("Freihand zeichnen") { dokument in
            _ = try? dokument.addLayer(ebene, at: index)
        }
        state.selectedLayerID = ebene.id
    }
}
