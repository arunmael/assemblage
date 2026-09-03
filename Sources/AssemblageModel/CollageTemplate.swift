import Foundation

/// Die kuratierten Vorlagen aus Plan 5.3.
public enum CollageTemplate: CaseIterable, Sendable {
    case grid2x2
    case grid3x3
    case polaroidStack

    /// Wie viele Bilder die Vorlage aufnimmt.
    public var capacity: Int {
        switch self {
        case .grid2x2: 4
        case .grid3x3: 9
        case .polaroidStack: 5
        }
    }
}

extension CollageTemplate {

    /// Die Platzierung für das Bild an Position `index`.
    /// `contentSize` ist die Grösse des Bildinhalts in Bildpunkten.
    /// Gibt `nil` zurück, wenn die Vorlage keinen Platz mehr hat.
    public func placement(
        forIndex index: Int,
        contentSize: Size,
        canvas: CanvasSize
    ) -> (transform: Transform2D, cropRect: Rect?)? {
        guard index >= 0, index < capacity,
              contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width > 0, contentSize.height > 0,
              canvas.width.isFinite, canvas.height.isFinite,
              canvas.width > 0, canvas.height > 0
        else { return nil }

        switch self {
        case .grid2x2:
            return gridPlacement(
                index: index,
                columns: 2,
                rows: 2,
                contentSize: contentSize,
                canvas: canvas
            )
        case .grid3x3:
            return gridPlacement(
                index: index,
                columns: 3,
                rows: 3,
                contentSize: contentSize,
                canvas: canvas
            )
        case .polaroidStack:
            return polaroidPlacement(index: index, contentSize: contentSize, canvas: canvas)
        }
    }

    private func gridPlacement(
        index: Int,
        columns: Int,
        rows: Int,
        contentSize: Size,
        canvas: CanvasSize
    ) -> (transform: Transform2D, cropRect: Rect?) {
        // Zwei Prozent der kurzen Seite wirken auf quadratischen, breiten und
        // hochformatigen Leinwänden gleich zurückhaltend. Derselbe Abstand
        // liegt auch am Rand, damit das Raster ruhig eingefasst ist.
        let gap = min(canvas.width, canvas.height) * 0.02
        let width = (canvas.width - Double(columns + 1) * gap) / Double(columns)
        let height = (canvas.height - Double(rows + 1) * gap) / Double(rows)
        let column = index % columns
        let row = index / columns
        let frame = Rect(
            x: gap + Double(column) * (width + gap),
            y: gap + Double(row) * (height + gap),
            width: width,
            height: height
        )
        return fill(contentSize: contentSize, frame: frame, rotationDegrees: 0)
    }

    private func polaroidPlacement(
        index: Int,
        contentSize: Size,
        canvas: CanvasSize
    ) -> (transform: Transform2D, cropRect: Rect?) {
        // Das etwas höhere 4:5-Format erinnert an Sofortbilder. Die Grösse
        // wird von beiden Leinwandachsen begrenzt, damit der Stapel auch auf
        // einer schmalen Story-Leinwand vollständig handlich bleibt.
        let aspectRatio = 4.0 / 5.0
        let height = min(canvas.height * 0.62, canvas.width * 0.58 / aspectRatio)
        let width = height * aspectRatio
        let shortSide = min(canvas.width, canvas.height)
        let offsets: [(x: Double, y: Double)] = [
            (-0.045, 0.018),
            (0.035, -0.030),
            (-0.018, -0.012),
            (0.048, 0.026),
            (0, 0)
        ]
        let rotations = [-8.0, 6.0, -4.0, 9.0, 1.0]
        let offset = offsets[index]
        let frame = Rect(
            x: (canvas.width - width) / 2 + offset.x * shortSide,
            y: (canvas.height - height) / 2 + offset.y * shortSide,
            width: width,
            height: height
        )
        return fill(
            contentSize: contentSize,
            frame: frame,
            rotationDegrees: rotations[index]
        )
    }

    /// Schneidet den Inhalt mittig auf das Seitenverhältnis des Zielfachs zu
    /// und skaliert danach auf beiden Achsen gleich. So füllt das Bild sein
    /// Fach ohne Verzerrung und ohne leere Balken.
    private func fill(
        contentSize: Size,
        frame: Rect,
        rotationDegrees: Double
    ) -> (transform: Transform2D, cropRect: Rect?) {
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
}
