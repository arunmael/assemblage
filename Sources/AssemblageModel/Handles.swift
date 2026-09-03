import Foundation

/// Die acht Griffpunkte am Rand einer ausgewählten Ebene (Plan 4.3).
///
/// Bewusst acht und nicht vier: Nur mit den Kantengriffen lässt sich eine
/// Ebene in einer Richtung strecken, ohne die andere anzufassen.
public enum ResizeHandle: CaseIterable, Sendable {
    case topLeft, top, topRight
    case right
    case bottomRight, bottom, bottomLeft
    case left

    /// Anteilige Lage im Rahmen der Ebene, jeweils -1 (links/oben),
    /// 0 (Mitte) oder 1 (rechts/unten).
    var unitOffset: (x: Double, y: Double) {
        switch self {
        case .topLeft: return (-1, -1)
        case .top: return (0, -1)
        case .topRight: return (1, -1)
        case .right: return (1, 0)
        case .bottomRight: return (1, 1)
        case .bottom: return (0, 1)
        case .bottomLeft: return (-1, 1)
        case .left: return (-1, 0)
        }
    }

    /// Verändert dieser Griff die Breite? Die Kantengriffe oben und unten tun
    /// es nicht — daran zu ziehen darf die Breite nicht anfassen.
    var changesWidth: Bool { unitOffset.x != 0 }
    var changesHeight: Bool { unitOffset.y != 0 }
}

extension Transform2D {

    // MARK: - Wo die Griffe sitzen

    /// Lage eines Griffs auf der Leinwand — dreht und skaliert mit der Ebene.
    public func position(of handle: ResizeHandle, contentSize: Size) -> Point {
        let halfWidth = contentSize.width * abs(scaleX) / 2
        let halfHeight = contentSize.height * abs(scaleY) / 2
        let offset = handle.unitOffset

        return pointOnCanvas(Point(x: offset.x * halfWidth, y: offset.y * halfHeight))
    }

    /// Lage des Drehgriffs: ausserhalb der Oberkante.
    ///
    /// Ausserhalb, damit er nicht mit den Eckgriffen kollidiert. Plan 2.2
    /// weist ausdrücklich darauf hin, dass kleine, dicht beieinander liegende
    /// Elemente bei Fingerbedienung über Sidecar zu Fehltippern führen.
    public func rotationHandlePosition(contentSize: Size, distance: Double) -> Point {
        let halfHeight = contentSize.height * abs(scaleY) / 2
        return pointOnCanvas(Point(x: 0, y: -halfHeight - distance))
    }

    /// Der Griff unter dem Zeiger, oder `nil`.
    ///
    /// Bei sehr kleinen Ebenen überlappen sich die Fangbereiche benachbarter
    /// Griffe; dann gewinnt der nächstliegende, damit das Ergebnis
    /// vorhersagbar bleibt.
    public func handle(at point: Point, contentSize: Size, tolerance: Double) -> ResizeHandle? {
        var bester: (handle: ResizeHandle, distanz: Double)?

        for kandidat in ResizeHandle.allCases {
            let griff = position(of: kandidat, contentSize: contentSize)
            let dx = griff.x - point.x
            let dy = griff.y - point.y
            let distanz = (dx * dx + dy * dy).squareRoot()

            guard distanz <= tolerance else { continue }
            if bester == nil || distanz < bester!.distanz {
                bester = (kandidat, distanz)
            }
        }
        return bester?.handle
    }

    // MARK: - Skalieren

    /// Kleinste Ausdehnung, auf die sich eine Ebene schrumpfen lässt.
    ///
    /// Eine Ebene mit Ausdehnung null hätte keine Griffe mehr und wäre auf dem
    /// Canvas nicht wiederzufinden — man könnte sie nur noch über die
    /// Ebenenliste löschen.
    private static let minimumExtent: Double = 1

    /// Neue Transformation, nachdem ein Griff an `point` gezogen wurde.
    ///
    /// Gerechnet wird im **ungedrehten** Koordinatensystem der Ebene: Der
    /// Zeigerpunkt wird dorthin zurückgerechnet, die betroffenen Kanten werden
    /// verschoben, und das Ergebnis wandert zurück auf die Leinwand. Nur so
    /// bewegt sich der Griff einer gedrehten Ebene entlang ihrer eigenen
    /// Achsen und nicht entlang der Bildschirmachsen.
    ///
    /// Die dem Griff **gegenüberliegende** Kante bleibt dabei fest — zieht man
    /// oben links, bleibt unten rechts, wo es war. Alles andere fühlt sich an,
    /// als rutschte die Ebene unter dem Zeiger weg.
    public func resized(
        handle: ResizeHandle,
        draggedTo point: Point,
        contentSize: Size,
        keepingAspectRatio: Bool = false
    ) -> Transform2D {
        guard contentSize.width > 0, contentSize.height > 0 else { return self }

        let halfWidth = contentSize.width * abs(scaleX) / 2
        let halfHeight = contentSize.height * abs(scaleY) / 2
        let local = pointInLayerSpace(point)

        // Kanten im lokalen System, Ursprung im bisherigen Mittelpunkt.
        var left = -halfWidth, right = halfWidth
        var top = -halfHeight, bottom = halfHeight

        let offset = handle.unitOffset
        if offset.x < 0 { left = local.x } else if offset.x > 0 { right = local.x }
        if offset.y < 0 { top = local.y } else if offset.y > 0 { bottom = local.y }

        var width = right - left
        var height = bottom - top

        if keepingAspectRatio, handle.changesWidth, handle.changesHeight {
            // Auf die grössere der beiden Änderungen einrasten, damit das
            // Ziehen der Bewegung folgt statt hinter ihr zurückzubleiben.
            let ratio = contentSize.height / contentSize.width
            if abs(height) < abs(width) * ratio {
                height = abs(width) * ratio * (height < 0 ? -1 : 1)
            } else {
                width = abs(height) / ratio * (width < 0 ? -1 : 1)
            }
            // Die feste Kante liegt gegenüber dem Griff — von dort aus neu messen.
            if offset.x < 0 { left = right - width } else { right = left + width }
            if offset.y < 0 { top = bottom - height } else { bottom = top + height }
        }

        // Nicht auf null zusammenfallen lassen; das Vorzeichen (und damit eine
        // Spiegelung durch Ziehen über die feste Kante hinaus) bleibt erhalten.
        if abs(width) < Self.minimumExtent {
            width = Self.minimumExtent * (width < 0 ? -1 : 1)
            if offset.x < 0 { left = right - width } else { right = left + width }
        }
        if abs(height) < Self.minimumExtent {
            height = Self.minimumExtent * (height < 0 ? -1 : 1)
            if offset.y < 0 { top = bottom - height } else { bottom = top + height }
        }

        let neueMitte = pointOnCanvas(Point(x: (left + right) / 2, y: (top + bottom) / 2))

        var ergebnis = self
        ergebnis.x = neueMitte.x
        ergebnis.y = neueMitte.y
        ergebnis.scaleX = width / contentSize.width * (scaleX < 0 ? -1 : 1)
        ergebnis.scaleY = height / contentSize.height * (scaleY < 0 ? -1 : 1)
        return ergebnis
    }

    // MARK: - Drehen

    /// Neue Transformation, nachdem der Drehgriff auf `point` gezogen wurde.
    ///
    /// Gemessen wird der Winkel zwischen „senkrecht nach oben" und der
    /// Richtung vom Mittelpunkt zum Zeiger — der Drehgriff sitzt oben, also
    /// zeigt die Ebene dorthin, wohin man ihn zieht.
    ///
    /// `snappingTo` rastet in Schritten ein (Umschalttaste): Genau 90° von
    /// Hand zu treffen gelingt sonst praktisch nie.
    public func rotated(towards point: Point, snappingTo step: Double? = nil) -> Transform2D {
        let dx = point.x - x
        let dy = point.y - y

        // Zeigt der Zeiger auf den Mittelpunkt, gibt es keine Richtung. Dann
        // die bisherige Drehung behalten, statt auf einen willkürlichen Wert
        // zu springen.
        guard dx != 0 || dy != 0 else { return self }

        // y wächst nach unten, positive Winkel drehen im Uhrzeigersinn —
        // dieselbe Festlegung wie im Renderer.
        var winkel = atan2(dx, -dy) * 180 / .pi

        if let step, step > 0 {
            winkel = (winkel / step).rounded() * step
        }

        var ergebnis = self
        ergebnis.rotationDegrees = winkel
        return ergebnis
    }
}
