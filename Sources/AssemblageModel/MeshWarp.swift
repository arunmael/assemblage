import Foundation

/// Krumme Acht-Punkt-Verzerrung (aus Anpassungen.md: „8 Punkte … alle
/// Eckpunkte und alle Mitten einer Seite").
///
/// Eine einzelne projektive Abbildung (`CATransform3D`, siehe
/// `Geometry+CoreGraphics.swift`) bildet Geraden immer auf Geraden ab — sie
/// kann eine Kante deshalb grundsätzlich nicht krümmen, egal wie ihre vier
/// Ecken liegen. Sobald ein Kantenmittelpunkt unabhängig von seinen
/// Nachbarecken verschoben wird, reicht eine einzelne Matrix nicht mehr.
///
/// `MeshWarp` löst das mit den aus der Finite-Elemente-Methode bekannten
/// Formfunktionen des „Serendipity"-Achtknoten-Vierecks: eine quadratische,
/// glatte Interpolation durch alle acht Stützpunkte (vier Ecken, vier
/// Kantenmitten). Ihre entscheidende Eigenschaft für dieses Projekt: Liegen
/// alle vier Kantenmitten exakt auf der linearen Verbindung ihrer
/// Nachbarecken (Versatz `.zero`), reduziert sich die Formel **exakt** auf
/// die bisherige bilineare Vier-Ecken-Abbildung — ein bestehendes Dokument
/// mit reiner Eckenverzerrung bleibt dadurch unverändert (siehe
/// `MeshWarpTests`).
///
/// Zum Rendern wird die Fläche in ein Gitter kleiner Vierecke zerlegt
/// (`grid(resolution:contentSize:distortion:)`); jedes einzelne Feld ist so
/// klein, dass es wieder mit der bestehenden, günstigen Vier-Ecken-
/// Homographie gezeichnet werden kann — die neue, krumme Mathematik bleibt
/// auf dieses eine Modul beschränkt.
public enum MeshWarp {

    /// Position eines Punkts der Ebene (im ungedrehten, aber skalierten
    /// Inhaltskoordinatensystem, Ursprung in der Mitte) bei den natürlichen
    /// Koordinaten `xi`/`eta` ∈ [-1, 1] — dieselben Achsen wie
    /// `DistortHandle.naturalCoordinate`.
    ///
    /// `halfWidth`/`halfHeight` sind die unverzogene Halbgrösse des Inhalts
    /// (mit Skalierung bereits verrechnet, siehe `Transform2D.corners`);
    /// `offset(at:)` liefert die acht Versätze aus dem Modell.
    static func position(
        xi: Double,
        eta: Double,
        halfWidth: Double,
        halfHeight: Double,
        distortion: QuadDistortion
    ) -> Point {
        let knoten = nodePositions(halfWidth: halfWidth, halfHeight: halfHeight, distortion: distortion)
        var x = 0.0
        var y = 0.0
        for handle in DistortHandle.allCases {
            let gewicht = shapeFunction(handle, xi: xi, eta: eta)
            guard gewicht != 0 else { continue }
            let punkt = knoten[handle]!
            x += gewicht * punkt.x
            y += gewicht * punkt.y
        }
        return Point(x: x, y: y)
    }

    /// Die tatsächlichen (verschobenen) Positionen aller acht Knoten.
    ///
    /// Eine Ecke liegt bei ihrer Rechteckposition plus eigenem Versatz —
    /// unverändert zur bisherigen Vier-Ecken-Logik. Eine Kantenmitte liegt
    /// dagegen relativ zur **linearen Mitte ihrer beiden (schon verschobenen)
    /// Nachbarecken**, nicht relativ zur festen Rechteckkante: Nur so
    /// verschwindet ihr Beitrag bei Versatz `.zero` unabhängig davon, wie
    /// weit die Nachbarecken selbst schon verzogen sind — die
    /// Kompatibilitätsgarantie aus dem Typkommentar gilt sonst nur für ein
    /// unverzerrtes Rechteck, nicht für eine bereits an den Ecken verzogene
    /// Fläche.
    private static func nodePositions(
        halfWidth: Double,
        halfHeight: Double,
        distortion: QuadDistortion
    ) -> [DistortHandle: Point] {
        func eckposition(_ ecke: DistortHandle) -> Point {
            let (hxi, heta) = ecke.naturalCoordinate
            let versatz = distortion.offset(at: ecke)
            return Point(x: hxi * halfWidth + versatz.x, y: heta * halfHeight + versatz.y)
        }
        let topLeft = eckposition(.topLeft)
        let topRight = eckposition(.topRight)
        let bottomRight = eckposition(.bottomRight)
        let bottomLeft = eckposition(.bottomLeft)

        func mittelposition(_ mitte: DistortHandle, zwischen a: Point, und b: Point) -> Point {
            let versatz = distortion.offset(at: mitte)
            return Point(x: (a.x + b.x) / 2 + versatz.x, y: (a.y + b.y) / 2 + versatz.y)
        }

        return [
            .topLeft: topLeft, .topRight: topRight, .bottomRight: bottomRight, .bottomLeft: bottomLeft,
            .topMid: mittelposition(.topMid, zwischen: topLeft, und: topRight),
            .rightMid: mittelposition(.rightMid, zwischen: topRight, und: bottomRight),
            .bottomMid: mittelposition(.bottomMid, zwischen: bottomRight, und: bottomLeft),
            .leftMid: mittelposition(.leftMid, zwischen: bottomLeft, und: topLeft)
        ]
    }

    /// Formfunktionen des Serendipity-Q8-Elements. Jede ist an ihrem eigenen
    /// Knoten 1 und an allen anderen sieben Knoten 0 (mit
    /// `MeshWarpTests.testShapeFunctionsFormAPartitionOfUnityAndInterpolateExactly`
    /// nachgewiesen statt nur behauptet).
    private static func shapeFunction(_ handle: DistortHandle, xi: Double, eta: Double) -> Double {
        let (hxi, heta) = handle.naturalCoordinate
        switch handle {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            // Eckknoten: bilineare Q4-Funktion abzüglich der halben
            // Nachbar-Kantenmitten — die Standardform, die eine
            // Zerlegung-der-Eins über alle acht Knoten ergibt.
            return 0.25 * (1 + xi * hxi) * (1 + eta * heta) * (xi * hxi + eta * heta - 1)
        case .topMid, .bottomMid:
            // Kantenmitte oben/unten: hxi ist 0, heta ist ±1.
            return 0.5 * (1 - xi * xi) * (1 + eta * heta)
        case .rightMid, .leftMid:
            // Kantenmitte rechts/links: heta ist 0, hxi ist ±1.
            return 0.5 * (1 + xi * hxi) * (1 - eta * eta)
        }
    }

    /// Zerlegt die verzogene Fläche in ein `resolution` × `resolution`
    /// Gitter aus Eckpunkten (im ungedrehten, skalierten Inhaltskoordinaten-
    /// system) — `resolution + 1` Punkte pro Seite, wie bei jeder
    /// Gitterzerlegung.
    ///
    /// Ohne echte Krümmung (`!distortion.hasCurvedEdges`) liefert das
    /// dieselben vier Eckpunkte wie die bisherige Vier-Ecken-Abbildung, nur
    /// zusätzlich linear verfeinert — der Aufrufer sollte diesen Fall aber
    /// meist per `hasCurvedEdges` ausschliessen und stattdessen die
    /// günstigere `CATransform3D`-Homographie nehmen.
    public static func grid(
        resolution: Int,
        halfWidth: Double,
        halfHeight: Double,
        distortion: QuadDistortion
    ) -> [[Point]] {
        precondition(resolution >= 1, "Ein Gitter braucht mindestens ein Feld")
        return (0...resolution).map { row in
            let eta = -1.0 + 2.0 * Double(row) / Double(resolution)
            return (0...resolution).map { column in
                let xi = -1.0 + 2.0 * Double(column) / Double(resolution)
                return position(
                    xi: xi, eta: eta,
                    halfWidth: halfWidth, halfHeight: halfHeight,
                    distortion: distortion
                )
            }
        }
    }
}
