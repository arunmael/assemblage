import AssemblageModel

/// Legt aus den Rohpunkten eines Mauszugs eine neue Freihand-Ebene an.
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
              let owner = state.owner
        else { return }

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

        owner.modify("Freihand zeichnen") { dokument in
            _ = try? dokument.addLayer(ebene)
        }
        state.selectedLayerID = ebene.id
    }
}
