import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Hält Leinwand und Export beim freien Verziehen deckungsgleich.
@MainActor
final class DistortRenderingTests: XCTestCase {

    private let canvasSize = CanvasSize(width: 300, height: 300)
    private let nonParallelogram = QuadDistortion(
        topLeft: Point(x: 22, y: 14), topRight: Point(x: -8, y: -12),
        bottomRight: Point(x: 18, y: 9), bottomLeft: Point(x: -15, y: 7)
    )

    private func layer(distortion: QuadDistortion?) -> Layer {
        Layer(
            name: "Verzogene Form",
            transform: Transform2D(x: 150, y: 150),
            distortion: distortion,
            content: .shape(ShapeLayerContent(
                kind: .rectangle,
                size: Size(width: 100, height: 100),
                fillColorHex: "#E02020"
            ))
        )
    }

    private func canvasImage(_ document: AssemblageModel.Document) throws -> CGImage {
        let view = CanvasView(document: document, images: ImageStore(resources: DocumentResources()))
        view.layoutSubtreeIfNeeded()
        view.layer?.layoutIfNeeded()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        try XCTUnwrap(view.layer?.sublayers?.first).render(in: context)
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8, UInt8) {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data)
        let row = image.height - 1 - y
        let p = data.advanced(by: row * context.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return (p[0], p[1], p[2], p[3])
    }

    /// Prüft die vom Live-Renderer gesetzte Matrix statt `CALayer.render(in:)`.
    /// Letzteres flacht nicht-affine Unterebenen ab und bildet daher nicht ab,
    /// was der Core-Animation-Compositor auf dem Bildschirm zeichnet.
    private func canvasLayer(_ rendered: CALayer, covers point: Point) -> Bool {
        let inverse = CATransform3DInvert(rendered.transform)
        let x = point.x - rendered.position.x
        let y = point.y - rendered.position.y
        let w = x * inverse.m14 + y * inverse.m24 + inverse.m44
        guard abs(w) > .leastNormalMagnitude else { return false }
        let localX = (x * inverse.m11 + y * inverse.m21 + inverse.m41) / w
        let localY = (x * inverse.m12 + y * inverse.m22 + inverse.m42) / w
        let tolerance = 0.000_001
        return abs(localX) <= rendered.bounds.width / 2 + tolerance
            && abs(localY) <= rendered.bounds.height / 2 + tolerance
    }

    private func rasterDifferences(
        shape: Layer,
        rendered: CALayer? = nil,
        image: CGImage? = nil
    ) throws -> [(Int, Int)] {
        var differences: [(Int, Int)] = []
        let corners = shape.transform.corners(
            contentSize: Size(width: 100, height: 100),
            distortion: shape.distortion
        )
        for y in stride(from: 80, through: 220, by: 4) {
            for x in stride(from: 80, through: 220, by: 4) {
                let point = Point(x: Double(x), y: Double(y))
                // Genau auf einer geglätteten Kante ist „bedeckt" keine
                // binäre Pixeleigenschaft. Diese wenigen Punkte prüfen weder
                // die Homographie noch ihre Fläche zuverlässig.
                if distanceToQuad(point, corners: corners) < 1.5 { continue }
                let modelCovers = shape.transform.contains(
                    point,
                    contentSize: Size(width: 100, height: 100),
                    distortion: shape.distortion
                )
                let rendererCovers: Bool
                if let rendered {
                    rendererCovers = canvasLayer(rendered, covers: point)
                } else if let image {
                    rendererCovers = try pixel(image, x: x, y: y).3 > 10
                } else {
                    rendererCovers = false
                }
                if modelCovers != rendererCovers { differences.append((x, y)) }
            }
        }
        return differences
    }

    private func distanceToQuad(_ point: Point, corners: [Point]) -> Double {
        guard corners.count == 4 else { return 0 }
        return (0..<4).map { index in
            let a = corners[index]
            let b = corners[(index + 1) % 4]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
            let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
            return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
        }.min() ?? 0
    }

    private func alphaProfile(
        in image: CGImage,
        near point: Point,
        corners: [Point]
    ) throws -> String {
        guard corners.count == 4 else { return "keine vier Ecken" }
        let segments = (0..<4).map { index -> (Point, Point, Double) in
            let a = corners[index]
            let b = corners[(index + 1) % 4]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0
                ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
                : 0
            let nearest = Point(x: a.x + t * dx, y: a.y + t * dy)
            return (a, b, hypot(point.x - nearest.x, point.y - nearest.y))
        }
        guard let edge = segments.min(by: { $0.2 < $1.2 }) else { return "keine Kante" }
        let dx = edge.1.x - edge.0.x
        let dy = edge.1.y - edge.0.y
        let length = hypot(dx, dy)
        guard length > 0 else { return "Kante ohne Länge" }
        let t = ((point.x - edge.0.x) * dx + (point.y - edge.0.y) * dy) / (length * length)
        let foot = Point(x: edge.0.x + t * dx, y: edge.0.y + t * dy)

        var normal = Point(x: -dy / length, y: dx / length)
        let centre = Point(
            x: corners.map(\.x).reduce(0, +) / 4,
            y: corners.map(\.y).reduce(0, +) / 4
        )
        if (centre.x - foot.x) * normal.x + (centre.y - foot.y) * normal.y < 0 {
            normal = Point(x: -normal.x, y: -normal.y)
        }

        var values: [String] = []
        for halfStep in -8...12 {
            let distance = Double(halfStep) / 2
            let sampleX = Int((foot.x + normal.x * distance).rounded())
            let sampleY = Int((foot.y + normal.y * distance).rounded())
            let alpha = try pixel(image, x: sampleX, y: sampleY).3
            values.append(String(format: "%+.1f:%d@(%d,%d)", distance, alpha, sampleX, sampleY))
        }
        return values.joined(separator: " ")
    }

    func testIdentityDistortionDrawsExactlyLikeNil() throws {
        let ohne = AssemblageModel.Document(canvas: canvasSize, layers: [layer(distortion: nil)])
        let neutral = AssemblageModel.Document(canvas: canvasSize, layers: [layer(distortion: .identity)])

        let a = try canvasImage(ohne)
        let b = try canvasImage(neutral)
        XCTAssertEqual(a.dataProvider?.data, b.dataProvider?.data)
    }

    func testCanvasMatchesModelForNonParallelogram() throws {
        let shape = layer(distortion: nonParallelogram)
        let rendered = LayerRenderer(images: ImageStore(resources: DocumentResources())).makeLayer(for: shape)
        let differences = try rasterDifferences(shape: shape, rendered: rendered)

        XCTAssertTrue(
            differences.isEmpty,
            "Canvas-Matrix weicht an \(differences.count) Messpunkten vom Modell ab; erste: \(differences.prefix(8))"
        )
    }

    func testExportMatchesModelForNonParallelogram() async throws {
        let shape = layer(distortion: nonParallelogram)
        let document = AssemblageModel.Document(canvas: canvasSize, layers: [shape])
        let image = try await DocumentExporter.image(
            of: document, resources: DocumentResources(), targetSize: CGSize(width: 300, height: 300)
        )
        let differences = try rasterDifferences(shape: shape, image: image)

        let modelCorners = shape.transform.corners(
            contentSize: Size(width: 100, height: 100),
            distortion: shape.distortion
        )
        let labels = ["oben", "rechts", "unten", "links"]
        let edgeProfiles = try (0..<4).map { index -> String in
            let a = modelCorners[index]
            let b = modelCorners[(index + 1) % 4]
            let midpoint = Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            return "\(labels[index])=[\(try alphaProfile(in: image, near: midpoint, corners: modelCorners))]"
        }
        print("VERZIEHEN-KANTENPROFILE:", edgeProfiles.joined(separator: " | "))

        let profiles = try differences.prefix(2).map {
            try alphaProfile(
                in: image,
                near: Point(x: Double($0.0), y: Double($0.1)),
                corners: shape.transform.corners(
                    contentSize: Size(width: 100, height: 100),
                    distortion: shape.distortion
                )
            )
        }.joined(separator: " | ")
        XCTAssertTrue(
            differences.isEmpty,
            "Export weicht an \(differences.count) Messpunkten vom Modell ab; erste: \(differences.prefix(8)); \(profiles)"
        )
    }

    func testIdentityPerspectivePathPreservesRectangleGeometry() throws {
        let sourceContext = try XCTUnwrap(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        sourceContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        sourceContext.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let sourceImage = try XCTUnwrap(sourceContext.makeImage())

        let targetContext = try XCTUnwrap(CGContext(
            data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        DocumentExporter.drawPerspectiveImage(
            sourceImage,
            corners: [
                CGPoint(x: 100, y: 200), CGPoint(x: 200, y: 200),
                CGPoint(x: 200, y: 100), CGPoint(x: 100, y: 100)
            ],
            targetSize: CGSize(width: 300, height: 300),
            into: targetContext
        )
        let image = try XCTUnwrap(targetContext.makeImage())
        let shape = layer(distortion: nil)
        let corners = shape.transform.corners(
            contentSize: Size(width: 100, height: 100),
            distortion: nil
        )

        var differences: [(Int, Int)] = []
        for y in 80...220 {
            for x in 80...220 {
                let point = Point(x: Double(x), y: Double(y))
                if distanceToQuad(point, corners: corners) < 1.5 { continue }
                let modelCovers = shape.transform.contains(
                    point,
                    contentSize: Size(width: 100, height: 100),
                    distortion: nil
                )
                let exportCovers = try pixel(image, x: x, y: y).3 > 10
                if modelCovers != exportCovers { differences.append((x, y)) }
            }
        }

        let profile = try alphaProfile(
            in: image,
            near: Point(x: 150, y: 100),
            corners: corners
        )
        print("VERZIEHEN-IDENTITAETS-PROFIL:", profile)
        XCTAssertTrue(
            differences.isEmpty,
            "Identitätspfad weicht an \(differences.count) Messpunkten ab; erste: \(differences.prefix(12))"
        )
    }

    func testScaledIdentityPerspectivePathPreservesRectangleGeometry() throws {
        let sourceContext = try XCTUnwrap(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        sourceContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        sourceContext.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let sourceImage = try XCTUnwrap(sourceContext.makeImage())

        let targetContext = try XCTUnwrap(CGContext(
            data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        DocumentExporter.drawPerspectiveImage(
            sourceImage,
            corners: [
                CGPoint(x: 50, y: 250), CGPoint(x: 250, y: 250),
                CGPoint(x: 250, y: 50), CGPoint(x: 50, y: 50)
            ],
            targetSize: CGSize(width: 300, height: 300),
            into: targetContext
        )
        let image = try XCTUnwrap(targetContext.makeImage())
        let transform = Transform2D(x: 150, y: 150, scaleX: 2, scaleY: 2)
        let corners = transform.corners(contentSize: Size(width: 100, height: 100))

        var differences: [(Int, Int)] = []
        for y in 30...270 {
            for x in 30...270 {
                let point = Point(x: Double(x), y: Double(y))
                if distanceToQuad(point, corners: corners) < 1.5 { continue }
                let modelCovers = transform.contains(point, contentSize: Size(width: 100, height: 100))
                let exportCovers = try pixel(image, x: x, y: y).3 > 10
                if modelCovers != exportCovers { differences.append((x, y)) }
            }
        }

        let profile = try alphaProfile(
            in: image,
            near: Point(x: 150, y: 50),
            corners: corners
        )
        print("VERZIEHEN-SKALIERTE-IDENTITAET:", profile)
        XCTAssertTrue(
            differences.isEmpty,
            "Skalierter Identitätspfad weicht an \(differences.count) Messpunkten ab; erste: \(differences.prefix(12))"
        )
    }

    func testCanvasAndExportHaveExactGeometryParity() async throws {
        let shape = layer(distortion: nonParallelogram)
        let document = AssemblageModel.Document(canvas: canvasSize, layers: [shape])
        let rendered = LayerRenderer(images: ImageStore(resources: DocumentResources())).makeLayer(for: shape)
        let exported = try await DocumentExporter.image(
            of: document, resources: DocumentResources(), targetSize: CGSize(width: 300, height: 300)
        )

        var differences: [(Int, Int)] = []
        let corners = shape.transform.corners(
            contentSize: Size(width: 100, height: 100),
            distortion: shape.distortion
        )
        for y in stride(from: 80, through: 220, by: 4) {
            for x in stride(from: 80, through: 220, by: 4) {
                let point = Point(x: Double(x), y: Double(y))
                if distanceToQuad(point, corners: corners) < 1.5 { continue }
                let canvasCovered = canvasLayer(rendered, covers: point)
                let exportCovered = try pixel(exported, x: x, y: y).3 > 10
                if canvasCovered != exportCovered { differences.append((x, y)) }
            }
        }
        XCTAssertTrue(
            differences.isEmpty,
            "abweichende Geometrie an \(differences.count) Messpunkten; erste: \(differences.prefix(8))"
        )
    }

    func testHomographyMapsEveryCornerToTheModelCorner() throws {
        let distortion = QuadDistortion(
            topLeft: Point(x: 12, y: 18), topRight: Point(x: -7, y: 4),
            bottomRight: Point(x: 21, y: -11), bottomLeft: Point(x: -5, y: 9)
        )
        let transform = Transform2D(x: 170, y: 120, scaleX: 1.4, scaleY: 0.8, rotationDegrees: 23)
        let size = Size(width: 100, height: 70)
        let matrix = try XCTUnwrap(transform.renderTransform(contentSize: size, distortion: distortion))
        let actual = matrix.projectedCorners(bounds: CGRect(origin: .zero, size: size.cgSize), position: CGPoint(x: transform.x, y: transform.y))
        let expected = transform.corners(contentSize: size, distortion: distortion)

        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.x, e.x, accuracy: 0.000_001)
            XCTAssertEqual(a.y, e.y, accuracy: 0.000_001)
        }
    }

    func testHomographyMapsCentreToIntersectionOfDiagonalsNotCentroid() throws {
        let transform = Transform2D(x: 150, y: 150)
        let size = Size(width: 100, height: 100)
        let matrix = try XCTUnwrap(transform.renderTransform(contentSize: size, distortion: nonParallelogram))
        let centre = matrix.projectedPoint(.zero, position: CGPoint(x: 150, y: 150))
        let corners = transform.corners(contentSize: size, distortion: nonParallelogram)
        let intersection = try XCTUnwrap(diagonalIntersection(corners))
        let centroid = CGPoint(
            x: corners.map(\.x).reduce(0, +) / 4,
            y: corners.map(\.y).reduce(0, +) / 4
        )

        XCTAssertEqual(centre.x, intersection.x, accuracy: 0.000_001)
        XCTAssertEqual(centre.y, intersection.y, accuracy: 0.000_001)
        XCTAssertGreaterThan(hypot(centre.x - centroid.x, centre.y - centroid.y), 1)
    }

    private func diagonalIntersection(_ corners: [Point]) -> CGPoint? {
        guard corners.count == 4 else { return nil }
        let a = corners[0], b = corners[2], c = corners[1], d = corners[3]
        let denominator = (a.x - b.x) * (c.y - d.y) - (a.y - b.y) * (c.x - d.x)
        guard abs(denominator) > .leastNormalMagnitude else { return nil }
        let determinantAB = a.x * b.y - a.y * b.x
        let determinantCD = c.x * d.y - c.y * d.x
        return CGPoint(
            x: (determinantAB * (c.x - d.x) - (a.x - b.x) * determinantCD) / denominator,
            y: (determinantAB * (c.y - d.y) - (a.y - b.y) * determinantCD) / denominator
        )
    }
}
