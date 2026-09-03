import Foundation

// Zuschneiden pro Ebene (Plan 5.3): nicht-destruktiv, jederzeit änderbar.
// Gespeichert wird nur das Ausschnitt-Rechteck in Bildkoordinaten; das
// Original im Dokumentpaket bleibt unangetastet (Plan 7.4).

extension Rect {

    /// Begradigt negative Ausdehnung — etwa wenn ein Griff über die
    /// gegenüberliegende Kante gezogen wurde.
    public var normalized: Rect {
        Rect(
            x: min(x, x + width),
            y: min(y, y + height),
            width: abs(width),
            height: abs(height)
        )
    }

    /// Auf ein umgebendes Rechteck beschnitten.
    public func clamped(to bounds: Rect) -> Rect {
        let eigen = normalized
        let links = max(eigen.x, bounds.x)
        let oben = max(eigen.y, bounds.y)
        let rechts = min(eigen.x + eigen.width, bounds.x + bounds.width)
        let unten = min(eigen.y + eigen.height, bounds.y + bounds.height)

        return Rect(
            x: links,
            y: oben,
            width: max(0, rechts - links),
            height: max(0, unten - oben)
        )
    }

    var center: Point { Point(x: x + width / 2, y: y + height / 2) }
}

extension Layer {

    /// Kleinster zulässiger Ausschnitt in Bildpunkten.
    ///
    /// Ein auf null geschrumpfter Ausschnitt wäre unsichtbar — und weil man
    /// nichts Unsichtbares anfassen kann, auch nicht wieder aufzuziehen.
    private static let minimumCropExtent: Double = 1

    /// Der tatsächlich sichtbare Ausschnitt. Ohne gespeicherten Zuschnitt ist
    /// das das ganze Bild; bei Text- und Formebenen gibt es keinen.
    public func effectiveCrop(imageSize: Size) -> Rect? {
        guard case .image(let inhalt) = content else { return nil }
        return inhalt.cropRect
            ?? Rect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)
    }

    /// Setzt einen neuen Ausschnitt und führt den Mittelpunkt der Ebene nach,
    /// damit das Bild dabei stehen bleibt.
    ///
    /// Ohne diese Nachführung springt beim Zuschneiden das ganze Bild: Eine
    /// Ebene wird über ihren Mittelpunkt platziert, und der Mittelpunkt eines
    /// Ausschnitts ist ein anderer als der des ganzen Bildes. Man will aber,
    /// dass sich nur die Kante bewegt, an der man zieht.
    public func cropped(to newCrop: Rect, imageSize: Size) -> Layer {
        guard case .image(var inhalt) = content else { return self }

        let ganzesBild = Rect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)
        var ziel = newCrop.clamped(to: ganzesBild)

        // Nicht auf null zusammenfallen lassen.
        ziel.width = max(ziel.width, Self.minimumCropExtent)
        ziel.height = max(ziel.height, Self.minimumCropExtent)
        ziel = ziel.clamped(to: ganzesBild)

        let vorher = effectiveCrop(imageSize: imageSize) ?? ganzesBild

        var ergebnis = self
        // Deckt der Ausschnitt wieder das ganze Bild, gar keinen speichern:
        // Das hält die document.json schlank und macht „unbeschnitten"
        // eindeutig erkennbar.
        inhalt.cropRect = (ziel == ganzesBild) ? nil : ziel
        ergebnis.content = .image(inhalt)

        // Verschiebung des Ausschnitt-Mittelpunkts, in Bildpunkten …
        let versatz = Point(
            x: ziel.center.x - vorher.center.x,
            y: ziel.center.y - vorher.center.y
        )
        // … skaliert und gedreht auf die Leinwand übertragen. Ohne die
        // Drehung rutschte eine gedrehte Ebene schräg weg.
        let radians = transform.rotationDegrees * .pi / 180
        let sx = versatz.x * transform.scaleX
        let sy = versatz.y * transform.scaleY

        ergebnis.transform.x += sx * cos(radians) - sy * sin(radians)
        ergebnis.transform.y += sx * sin(radians) + sy * cos(radians)
        return ergebnis
    }
}

extension Rect {

    /// Verschiebt die vom Griff betroffenen Kanten auf `point`.
    ///
    /// Die dem Griff gegenüberliegende Kante bleibt stehen — dasselbe
    /// Verhalten wie beim Skalieren einer Ebene, damit sich beides gleich
    /// anfühlt. Ergibt sich dabei eine negative Ausdehnung (Griff über die
    /// Gegenkante hinausgezogen), bleibt sie erhalten; `cropped(to:)`
    /// begradigt sie beim Übernehmen.
    public func adjusted(handle: ResizeHandle, to point: Point) -> Rect {
        var links = x, rechts = x + width
        var oben = y, unten = y + height

        let offset = handle.unitOffset
        if offset.x < 0 { links = point.x } else if offset.x > 0 { rechts = point.x }
        if offset.y < 0 { oben = point.y } else if offset.y > 0 { unten = point.y }

        return Rect(x: links, y: oben, width: rechts - links, height: unten - oben)
    }
}

extension Layer {

    /// Rechnet einen Punkt auf der Leinwand in Bildkoordinaten um.
    ///
    /// Bezugspunkt ist immer das **ganze** Bild, nicht der aktuelle
    /// Ausschnitt: Sonst liesse sich ein einmal gesetzter Zuschnitt nie
    /// wieder aufziehen.
    public func imagePoint(forCanvasPoint point: Point, imageSize: Size) -> Point? {
        guard case .image = content else { return nil }
        guard transform.scaleX != 0, transform.scaleY != 0 else { return nil }

        let ausschnitt = effectiveCrop(imageSize: imageSize)
            ?? Rect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)

        // Relativ zum Mittelpunkt der Ebene, zurückgedreht und entskaliert …
        let lokal = transform.pointInLayerSpace(point)
        return Point(
            x: ausschnitt.center.x + lokal.x / transform.scaleX,
            y: ausschnitt.center.y + lokal.y / transform.scaleY
        )
    }
}
