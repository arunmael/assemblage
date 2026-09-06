import Foundation

/// Wie ein Bildinhalt in ein rechteckiges Fach gebracht wird.
///
/// Eine Stelle für alle Aufrufer: Die Collage-Vorlagen setzen ihre Bilder in
/// die Rasterfächer, „Bild in Form" setzt eines in den Rahmen einer Form.
/// Beide meinen dasselbe Einpassen — zwei Kopien dieser Rechnung würden
/// auseinanderlaufen, und das fiele erst an einem schief sitzenden Bild auf.
public enum ContentPlacement {

    /// Füllt `frame` vollständig: Der Inhalt wird mittig auf das
    /// Seitenverhältnis des Fachs zugeschnitten und danach auf beiden Achsen
    /// **gleich** skaliert. Kein Verzerren, dafür fällt der Überstand weg.
    ///
    /// `cropRect` ist `nil`, wenn das ganze Bild ohnehin passt.
    public static func fill(
        contentSize: Size,
        frame: Rect,
        rotationDegrees: Double = 0
    ) -> (transform: Transform2D, cropRect: Rect?) {
        guard contentSize.width > 0, contentSize.height > 0,
              frame.width > 0, frame.height > 0
        else {
            return (Transform2D(x: frame.x, y: frame.y), nil)
        }

        let contentRatio = contentSize.width / contentSize.height
        let frameRatio = frame.width / frame.height
        let crop: Rect

        if contentRatio > frameRatio {
            let width = contentSize.height * frameRatio
            crop = Rect(
                x: (contentSize.width - width) / 2,
                y: 0,
                width: width,
                height: contentSize.height
            )
        } else {
            let height = contentSize.width / frameRatio
            crop = Rect(
                x: 0,
                y: (contentSize.height - height) / 2,
                width: contentSize.width,
                height: height
            )
        }

        let scale = frame.width / crop.width
        let wholeImage = Rect(x: 0, y: 0, width: contentSize.width, height: contentSize.height)
        return (
            Transform2D(
                x: frame.x + frame.width / 2,
                y: frame.y + frame.height / 2,
                scaleX: scale,
                scaleY: scale,
                rotationDegrees: rotationDegrees
            ),
            crop == wholeImage ? nil : crop
        )
    }

    /// Zieht den **ganzen** Inhalt auf `frame` — auf beiden Achsen getrennt.
    /// Nichts fällt weg, dafür verzieht sich das Bild, wenn die
    /// Seitenverhältnisse nicht zusammenpassen.
    public static func stretch(
        contentSize: Size,
        frame: Rect,
        rotationDegrees: Double = 0
    ) -> (transform: Transform2D, cropRect: Rect?) {
        guard contentSize.width > 0, contentSize.height > 0 else {
            return (Transform2D(x: frame.x, y: frame.y), nil)
        }
        return (
            Transform2D(
                x: frame.x + frame.width / 2,
                y: frame.y + frame.height / 2,
                scaleX: frame.width / contentSize.width,
                scaleY: frame.height / contentSize.height,
                rotationDegrees: rotationDegrees
            ),
            nil
        )
    }
}
