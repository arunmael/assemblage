import AppKit

// MARK: - Minimal SVG path support

/// A deliberately small scanner for the subset of SVG path syntax used by
/// the mockup icons. Arc flags are read separately because SVG permits them
/// to follow each other without whitespace (for example `0 002 2`).
private struct SVGPathScanner {
    private let bytes: [UInt8]
    private(set) var index = 0

    init(_ data: String) {
        bytes = Array(data.utf8)
    }

    var isAtEnd: Bool {
        var cursor = index
        skipSeparators(from: &cursor)
        return cursor == bytes.count
    }

    mutating func readCommand() -> UInt8? {
        skipSeparators()
        guard index < bytes.count, isLetter(bytes[index]) else { return nil }
        defer { index += 1 }
        return bytes[index]
    }

    func nextIsCommand() -> Bool {
        var cursor = index
        skipSeparators(from: &cursor)
        return cursor < bytes.count && isLetter(bytes[cursor])
    }

    func nextIsNumber() -> Bool {
        var cursor = index
        skipSeparators(from: &cursor)
        guard cursor < bytes.count else { return false }
        let byte = bytes[cursor]
        return byte == 43 || byte == 45 || byte == 46 || isDigit(byte)
    }

    mutating func readNumber() -> CGFloat? {
        skipSeparators()
        let start = index

        if currentByte == 43 || currentByte == 45 { index += 1 }

        var hasDigits = false
        while let byte = currentByte, isDigit(byte) {
            hasDigits = true
            index += 1
        }
        if currentByte == 46 {
            index += 1
            while let byte = currentByte, isDigit(byte) {
                hasDigits = true
                index += 1
            }
        }
        guard hasDigits else {
            index = start
            return nil
        }

        if currentByte == 69 || currentByte == 101 {
            let exponentStart = index
            index += 1
            if currentByte == 43 || currentByte == 45 { index += 1 }
            let digitsStart = index
            while let byte = currentByte, isDigit(byte) { index += 1 }
            if digitsStart == index { index = exponentStart }
        }

        return Double(String(decoding: bytes[start..<index], as: UTF8.self)).map { CGFloat($0) }
    }

    mutating func readFlag() -> Bool? {
        skipSeparators()
        guard let byte = currentByte, byte == 48 || byte == 49 else { return nil }
        index += 1
        return byte == 49
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipSeparators() {
        skipSeparators(from: &index)
    }

    private func skipSeparators(from cursor: inout Int) {
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte == 44 || byte == 32 || byte == 9 || byte == 10 || byte == 13 {
                cursor += 1
            } else {
                break
            }
        }
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }

    private func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }
}

private func cgPath(fromSVGPathData data: String) -> CGPath {
    var scanner = SVGPathScanner(data)
    let path = CGMutablePath()
    var command: UInt8?
    var current = CGPoint.zero
    var subpathStart = CGPoint.zero
    var lastCubicControl: CGPoint?

    func point(_ x: CGFloat, _ y: CGFloat, relative: Bool) -> CGPoint {
        relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
    }

    func numbers(_ count: Int) -> [CGFloat]? {
        var values: [CGFloat] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            guard let value = scanner.readNumber() else { return nil }
            values.append(value)
        }
        return values
    }

    while !scanner.isAtEnd {
        if scanner.nextIsCommand() {
            command = scanner.readCommand()
        }
        guard let activeCommand = command else { break }

        let relative = activeCommand >= 97 && activeCommand <= 122
        switch activeCommand {
        case 77, 109: // M/m
            guard let values = numbers(2) else { return path }
            current = point(values[0], values[1], relative: relative)
            path.move(to: current)
            subpathStart = current
            lastCubicControl = nil
            // Further coordinate pairs after moveto are implicit lineto.
            command = relative ? 108 : 76

        case 76, 108: // L/l
            guard let values = numbers(2) else { return path }
            current = point(values[0], values[1], relative: relative)
            path.addLine(to: current)
            lastCubicControl = nil

        case 72, 104: // H/h
            guard let value = scanner.readNumber() else { return path }
            current.x = relative ? current.x + value : value
            path.addLine(to: current)
            lastCubicControl = nil

        case 86, 118: // V/v
            guard let value = scanner.readNumber() else { return path }
            current.y = relative ? current.y + value : value
            path.addLine(to: current)
            lastCubicControl = nil

        case 83, 115: // S/s
            guard let values = numbers(4) else { return path }
            let control1: CGPoint
            if let previousControl = lastCubicControl {
                control1 = CGPoint(
                    x: 2 * current.x - previousControl.x,
                    y: 2 * current.y - previousControl.y
                )
            } else {
                control1 = current
            }
            let control2 = point(values[0], values[1], relative: relative)
            let destination = point(values[2], values[3], relative: relative)
            path.addCurve(to: destination, control1: control1, control2: control2)
            current = destination
            lastCubicControl = control2

        case 65, 97: // A/a
            guard
                let radiiAndRotation = numbers(3),
                let largeArc = scanner.readFlag(),
                let sweep = scanner.readFlag(),
                let destinationValues = numbers(2)
            else { return path }
            let destination = point(
                destinationValues[0], destinationValues[1], relative: relative
            )
            addSVGArc(
                to: path,
                from: current,
                to: destination,
                radiusX: radiiAndRotation[0],
                radiusY: radiiAndRotation[1],
                xAxisRotation: radiiAndRotation[2],
                largeArc: largeArc,
                sweep: sweep
            )
            current = destination
            lastCubicControl = nil

        case 90, 122: // Z/z
            path.closeSubpath()
            current = subpathStart
            lastCubicControl = nil
            command = nil

        default:
            // Unknown commands cannot be skipped safely because their arity is
            // unknown. The icon data intentionally uses only the cases above.
            return path
        }

        if command != nil, !scanner.nextIsCommand(), !scanner.nextIsNumber() {
            break
        }
    }
    return path
}

/// Converts SVG's endpoint arc representation to cubic Bezier segments as
/// described by the SVG 1.1 elliptical arc implementation notes.
private func addSVGArc(
    to path: CGMutablePath,
    from start: CGPoint,
    to end: CGPoint,
    radiusX inputRadiusX: CGFloat,
    radiusY inputRadiusY: CGFloat,
    xAxisRotation: CGFloat,
    largeArc: Bool,
    sweep: Bool
) {
    guard start != end else { return }

    var radiusX = abs(inputRadiusX)
    var radiusY = abs(inputRadiusY)
    guard radiusX > 0, radiusY > 0 else {
        path.addLine(to: end)
        return
    }

    let phi = xAxisRotation.truncatingRemainder(dividingBy: 360) * .pi / 180
    let cosPhi = cos(phi)
    let sinPhi = sin(phi)
    let halfDX = (start.x - end.x) / 2
    let halfDY = (start.y - end.y) / 2
    let transformedX = cosPhi * halfDX + sinPhi * halfDY
    let transformedY = -sinPhi * halfDX + cosPhi * halfDY

    let radiiScale = transformedX * transformedX / (radiusX * radiusX)
        + transformedY * transformedY / (radiusY * radiusY)
    if radiiScale > 1 {
        let scale = sqrt(radiiScale)
        radiusX *= scale
        radiusY *= scale
    }

    let radiusXSquared = radiusX * radiusX
    let radiusYSquared = radiusY * radiusY
    let xSquared = transformedX * transformedX
    let ySquared = transformedY * transformedY
    let denominator = radiusXSquared * ySquared + radiusYSquared * xSquared
    let numerator = max(
        0,
        radiusXSquared * radiusYSquared
            - radiusXSquared * ySquared
            - radiusYSquared * xSquared
    )
    let sign: CGFloat = largeArc == sweep ? -1 : 1
    let coefficient = denominator > 0 ? sign * sqrt(numerator / denominator) : 0
    let centerXPrime = coefficient * radiusX * transformedY / radiusY
    let centerYPrime = coefficient * -radiusY * transformedX / radiusX
    let center = CGPoint(
        x: cosPhi * centerXPrime - sinPhi * centerYPrime + (start.x + end.x) / 2,
        y: sinPhi * centerXPrime + cosPhi * centerYPrime + (start.y + end.y) / 2
    )

    let startVector = CGPoint(
        x: (transformedX - centerXPrime) / radiusX,
        y: (transformedY - centerYPrime) / radiusY
    )
    let endVector = CGPoint(
        x: (-transformedX - centerXPrime) / radiusX,
        y: (-transformedY - centerYPrime) / radiusY
    )
    var startAngle = atan2(startVector.y, startVector.x)
    var angleDelta = atan2(
        startVector.x * endVector.y - startVector.y * endVector.x,
        startVector.x * endVector.x + startVector.y * endVector.y
    )
    if !sweep, angleDelta > 0 { angleDelta -= 2 * .pi }
    if sweep, angleDelta < 0 { angleDelta += 2 * .pi }

    let segmentCount = max(1, Int(ceil(abs(angleDelta) / (.pi / 2))))
    let segmentAngle = angleDelta / CGFloat(segmentCount)

    func ellipsePoint(at angle: CGFloat) -> CGPoint {
        CGPoint(
            x: center.x + cosPhi * radiusX * cos(angle) - sinPhi * radiusY * sin(angle),
            y: center.y + sinPhi * radiusX * cos(angle) + cosPhi * radiusY * sin(angle)
        )
    }

    func ellipseDerivative(at angle: CGFloat) -> CGPoint {
        CGPoint(
            x: -cosPhi * radiusX * sin(angle) - sinPhi * radiusY * cos(angle),
            y: -sinPhi * radiusX * sin(angle) + cosPhi * radiusY * cos(angle)
        )
    }

    for segment in 0..<segmentCount {
        let endAngle = startAngle + segmentAngle
        let factor = 4 / 3 * tan(segmentAngle / 4)
        let segmentStart = ellipsePoint(at: startAngle)
        let segmentEnd = segment == segmentCount - 1 ? end : ellipsePoint(at: endAngle)
        let startDerivative = ellipseDerivative(at: startAngle)
        let endDerivative = ellipseDerivative(at: endAngle)
        path.addCurve(
            to: segmentEnd,
            control1: CGPoint(
                x: segmentStart.x + factor * startDerivative.x,
                y: segmentStart.y + factor * startDerivative.y
            ),
            control2: CGPoint(
                x: segmentEnd.x - factor * endDerivative.x,
                y: segmentEnd.y - factor * endDerivative.y
            )
        )
        startAngle = endAngle
    }
}

private func cgPath(
    rectX x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    cornerRadius: CGFloat
) -> CGPath {
    CGPath(
        roundedRect: CGRect(x: x, y: y, width: width, height: height),
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
}

private func cgPath(circleCenterX cx: CGFloat, y cy: CGFloat, radius r: CGFloat) -> CGPath {
    CGPath(
        ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r),
        transform: nil
    )
}

// MARK: - Mockup icons

enum MockupIcon: CaseIterable {
    case select, crop, brush, warp, removeSubject, insertText, insertShape, collageGrid
    case search, share, layersAdd, eyeVisible, duplicate, delete, chevronDown
    case mirrorHorizontal, mirrorVertical, zoomOut, zoomIn, undo, timeline, redo
}

enum MockupIcons {
    /// Draws an explicitly tinted, non-template icon at the requested square size.
    static func image(
        _ icon: MockupIcon,
        pointSize: CGFloat,
        tintColor: NSColor,
        strokeWidth: CGFloat = 1.8
    ) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = pointSize / 24

            context.saveGState()
            defer { context.restoreGState() }

            // Convert AppKit's bottom-left coordinate system to SVG's
            // top-left system, then map the 24 x 24 viewBox to the image.
            context.translateBy(x: 0, y: pointSize)
            context.scaleBy(x: scale, y: -scale)
            context.setLineWidth(strokeWidth / scale)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(tintColor.cgColor)

            for path in paths(for: icon) {
                context.addPath(path)
            }
            context.strokePath()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func paths(for icon: MockupIcon) -> [CGPath] {
        switch icon {
        case .select:
            return paths("M5 3l6.5 16.5 2-7.2 7.2-2z")
        case .crop:
            return paths("M7 2v15a2 2 0 002 2h13", "M2 7h15a2 2 0 012 2v13")
        case .brush:
            return paths("M9.5 14.5L18 6", "M14 4.2l5.8 5.8-8.8 8.8-6-2 2-6z")
        case .warp:
            return paths("M3 9V3h6", "M21 15v6h-6", "M3 3l7 7", "M21 21l-7-7")
        case .removeSubject:
            return paths(
                "M4 20l8.5-8.5",
                "M14 4l1.4 3.3L19 8.7l-3.6 1.4L14 13.4l-1.4-3.3L9 8.7l3.6-1.4z"
            )
        case .insertText:
            return paths("M4 5h16", "M12 5v14")
        case .insertShape:
            return paths("M12 3l8.5 6.2-3.3 10H6.8l-3.3-10z")
        case .collageGrid:
            return [(3, 3), (13, 3), (3, 13), (13, 13)].map { x, y in
                cgPath(rectX: CGFloat(x), y: CGFloat(y), width: 8, height: 8, cornerRadius: 1.5)
            }
        case .search:
            return [
                cgPath(circleCenterX: 11, y: 11, radius: 7),
                cgPath(fromSVGPathData: "M21 21l-4.3-4.3")
            ]
        case .share:
            return paths("M12 3v12", "M8 7l4-4 4 4", "M5 13v6a2 2 0 002 2h10a2 2 0 002-2v-6")
        case .layersAdd:
            return paths("M12 5v14M5 12h14")
        case .eyeVisible:
            return [
                cgPath(fromSVGPathData: "M2 12s4-7 10-7 10 7 10 7-4 7-10 7-10-7-10-7z"),
                cgPath(circleCenterX: 12, y: 12, radius: 3)
            ]
        case .duplicate:
            return [
                cgPath(rectX: 9, y: 9, width: 12, height: 12, cornerRadius: 2),
                cgPath(fromSVGPathData: "M5 15V5a2 2 0 012-2h10")
            ]
        case .delete:
            return paths("M4 7h16", "M9 7V4h6v3", "M6 7l1 13h10l1-13")
        case .chevronDown:
            return paths("M6 9l6 6 6-6")
        case .mirrorHorizontal:
            return mirrorPaths
        case .mirrorVertical:
            // Clockwise in SVG's y-down coordinate system, around (12, 12).
            var rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 24, ty: 0)
            return mirrorPaths.compactMap { $0.copy(using: &rotation) }
        case .zoomOut:
            return paths("M5 12h14")
        case .zoomIn:
            return paths("M12 5v14M5 12h14")
        case .undo:
            return paths("M15 6l-6 6 6 6")
        case .timeline:
            return paths("M6 9v6", "M10 6v12", "M14 8v8", "M18 10v4")
        case .redo:
            return paths("M9 6l6 6-6 6")
        }
    }

    private static var mirrorPaths: [CGPath] {
        paths("M12 3v18", "M6 8l-3 4 3 4", "M18 8l3 4-3 4")
    }

    private static func paths(_ data: String...) -> [CGPath] {
        data.map(cgPath(fromSVGPathData:))
    }
}
