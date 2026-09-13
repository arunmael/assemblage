import Foundation

extension Layer {

    /// Hängt einen in **Leinwandkoordinaten** gezeichneten Zug an eine
    /// Freihand-Formebene an und richtet Grösse und Lage der Ebene so nach,
    /// dass sich am bereits Gezeichneten nichts sichtbar verschiebt.
    /// Gibt `nil` zurück, wenn diese Ebene keine Freihand-Formebene ist oder
    /// der Zug unbrauchbar ist.
    public func appendingFreehandStroke(canvasPath: VectorPath) -> Layer? {
        guard case .shape(var content) = self.content,
              content.kind == .freehand,
              !canvasPath.isEmpty,
              canvasPath.subpaths.contains(where: { $0.anchors.count >= 2 }),
              transformIsUsable,
              content.size.width.isFinite, content.size.height.isFinite,
              content.size.width >= 0, content.size.height >= 0,
              content.strokeWidth.isFinite
        else { return nil }

        let vorhandenerPfad = content.path ?? VectorPath()
        guard pathIsFinite(vorhandenerPfad), pathIsFinite(canvasPath) else { return nil }

        let alteGroesse = content.size
        let umgerechnet = VectorPath(subpaths: canvasPath.subpaths.map { teilpfad in
            PathSubpath(
                anchors: teilpfad.anchors.map { anker in
                    PathAnchor(
                        point: localPoint(fromCanvas: anker.point, oldSize: alteGroesse),
                        controlIn: localPoint(fromCanvas: anker.controlIn, oldSize: alteGroesse),
                        controlOut: localPoint(fromCanvas: anker.controlOut, oldSize: alteGroesse)
                    )
                },
                isClosed: teilpfad.isClosed
            )
        })
        guard pathIsFinite(umgerechnet) else { return nil }

        let gemeinsam = VectorPath(subpaths: vorhandenerPfad.subpaths + umgerechnet.subpaths)
        guard let rahmen = gemeinsam.boundingBox,
              rectIsFinite(rahmen)
        else { return nil }

        let mindestbreite = max(content.strokeWidth, 0)
        let neueBreite = rahmen.width == 0 ? mindestbreite : rahmen.width
        let neueHoehe = rahmen.height == 0 ? mindestbreite : rahmen.height
        guard neueBreite.isFinite, neueHoehe.isFinite else { return nil }

        let versatzX = -rahmen.x + (rahmen.width == 0 ? neueBreite / 2 : 0)
        let versatzY = -rahmen.y + (rahmen.height == 0 ? neueHoehe / 2 : 0)
        let normalisiert = VectorPath(subpaths: gemeinsam.subpaths.map { teilpfad in
            PathSubpath(
                anchors: teilpfad.anchors.map { $0.moved(by: versatzX, versatzY) },
                isClosed: teilpfad.isClosed
            )
        })

        let mittelpunkt = Point(
            x: rahmen.x + rahmen.width / 2,
            y: rahmen.y + rahmen.height / 2
        )
        let unskaliert = Point(
            x: mittelpunkt.x - alteGroesse.width / 2,
            y: mittelpunkt.y - alteGroesse.height / 2
        )
        let skaliert = Point(
            x: unskaliert.x * transform.scaleX,
            y: unskaliert.y * transform.scaleY
        )
        let winkel = transform.rotationDegrees * .pi / 180
        let cosine = cos(winkel)
        let sine = sin(winkel)
        let dx = skaliert.x * cosine - skaliert.y * sine
        let dy = skaliert.x * sine + skaliert.y * cosine
        guard dx.isFinite, dy.isFinite else { return nil }

        var ergebnis = self
        ergebnis.transform.x += dx
        ergebnis.transform.y += dy
        guard ergebnis.transform.x.isFinite, ergebnis.transform.y.isFinite else { return nil }
        content.size = Size(width: neueBreite, height: neueHoehe)
        content.path = normalisiert
        ergebnis.content = .shape(content)
        return ergebnis
    }

    private var transformIsUsable: Bool {
        transform.x.isFinite && transform.y.isFinite
            && transform.scaleX.isFinite && transform.scaleY.isFinite
            && transform.scaleX != 0 && transform.scaleY != 0
            && transform.rotationDegrees.isFinite
    }

    private func localPoint(fromCanvas point: Point, oldSize: Size) -> Point {
        let skaliert = transform.pointInLayerSpace(point)
        return Point(
            x: skaliert.x / transform.scaleX + oldSize.width / 2,
            y: skaliert.y / transform.scaleY + oldSize.height / 2
        )
    }

    private func pathIsFinite(_ path: VectorPath) -> Bool {
        path.subpaths.flatMap(\.anchors).allSatisfy { anker in
            [anker.point, anker.controlIn, anker.controlOut].allSatisfy {
                $0.x.isFinite && $0.y.isFinite
            }
        }
    }

    private func rectIsFinite(_ rect: Rect) -> Bool {
        rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}
