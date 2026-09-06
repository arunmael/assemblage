import Foundation

/// Die kuratierten Vorlagen aus Plan 5.3.
public enum CollageTemplate: CaseIterable, Sendable {
    case grid2x2
    case grid3x3
    case polaroidStack
    case grid1x2
    case grid2x1
    case grid2x3
    case grid3x2
    case grid4x4
    case featureLeft
    case featureTop

    /// Wie viele Bilder die Vorlage aufnimmt.
    public var capacity: Int {
        switch self {
        case .grid2x2: 4
        case .grid3x3: 9
        case .polaroidStack: 5
        case .grid1x2, .grid2x1: 2
        case .grid2x3, .grid3x2: 6
        case .grid4x4: 16
        case .featureLeft: 3
        case .featureTop: 4
        }
    }

    /// Beschriftung für Menüs.
    public var localizedName: String {
        switch self {
        case .grid2x2: "Raster 2×2"
        case .grid3x3: "Raster 3×3"
        case .polaroidStack: "Polaroid-Stapel"
        case .grid1x2: "Zwei nebeneinander"
        case .grid2x1: "Zwei übereinander"
        case .grid2x3: "Raster 2×3"
        case .grid3x2: "Raster 3×2"
        case .grid4x4: "Raster 4×4"
        case .featureLeft: "Gross links, zwei rechts"
        case .featureTop: "Gross oben, drei unten"
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
        case .grid1x2:
            return gridPlacement(index: index, columns: 2, rows: 1, contentSize: contentSize, canvas: canvas)
        case .grid2x1:
            return gridPlacement(index: index, columns: 1, rows: 2, contentSize: contentSize, canvas: canvas)
        case .grid2x3:
            return gridPlacement(index: index, columns: 2, rows: 3, contentSize: contentSize, canvas: canvas)
        case .grid3x2:
            return gridPlacement(index: index, columns: 3, rows: 2, contentSize: contentSize, canvas: canvas)
        case .grid4x4:
            return gridPlacement(index: index, columns: 4, rows: 4, contentSize: contentSize, canvas: canvas)
        case .featureLeft:
            return featureLeftPlacement(index: index, contentSize: contentSize, canvas: canvas)
        case .featureTop:
            return featureTopPlacement(index: index, contentSize: contentSize, canvas: canvas)
        }
    }

    private func featureLeftPlacement(
        index: Int,
        contentSize: Size,
        canvas: CanvasSize
    ) -> (transform: Transform2D, cropRect: Rect?) {
        let gap = min(canvas.width, canvas.height) * 0.02
        let usableWidth = canvas.width - 3.0 * gap
        let usableHeight = canvas.height - 2.0 * gap
        let leftWidth = usableWidth * 0.6
        let rightWidth = usableWidth - leftWidth
        let rightHeight = (usableHeight - gap) / 2.0
        let frame: Rect

        if index == 0 {
            frame = Rect(x: gap, y: gap, width: leftWidth, height: usableHeight)
        } else {
            frame = Rect(
                x: 2.0 * gap + leftWidth,
                y: gap + Double(index - 1) * (rightHeight + gap),
                width: rightWidth,
                height: rightHeight
            )
        }
        return fill(contentSize: contentSize, frame: frame, rotationDegrees: 0)
    }

    private func featureTopPlacement(
        index: Int,
        contentSize: Size,
        canvas: CanvasSize
    ) -> (transform: Transform2D, cropRect: Rect?) {
        let gap = min(canvas.width, canvas.height) * 0.02
        let usableWidth = canvas.width - 2.0 * gap
        let usableHeight = canvas.height - 3.0 * gap
        let topHeight = usableHeight * 0.6
        let bottomHeight = usableHeight - topHeight
        let bottomWidth = (usableWidth - 2.0 * gap) / 3.0
        let frame: Rect

        if index == 0 {
            frame = Rect(x: gap, y: gap, width: usableWidth, height: topHeight)
        } else {
            frame = Rect(
                x: gap + Double(index - 1) * (bottomWidth + gap),
                y: 2.0 * gap + topHeight,
                width: bottomWidth,
                height: bottomHeight
            )
        }
        return fill(contentSize: contentSize, frame: frame, rotationDegrees: 0)
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

    /// Leitet an den gemeinsamen Einpass-Helfer weiter — dieselbe Rechnung
    /// benutzt „Bild in Form".
    private func fill(
        contentSize: Size,
        frame: Rect,
        rotationDegrees: Double
    ) -> (transform: Transform2D, cropRect: Rect?) {
        ContentPlacement.fill(
            contentSize: contentSize, frame: frame, rotationDegrees: rotationDegrees
        )
    }
}
