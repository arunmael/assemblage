import CoreGraphics
import CoreImage
import ImageIO
import Foundation

/// Der gemeinsame Core-Image-Kontext der App (Plan 7.2).
///
/// Bewusst genau einer: Ein `CIContext` baut beim Erzeugen die komplette
/// GPU-Pipeline auf. Einen pro Bild oder pro Frame anzulegen, ist der
/// klassische Weg, eine Core-Image-App zum Ruckeln zu bringen.
enum RenderContext {
    static let shared = CIContext(options: [.useSoftwareRenderer: false])
}

/// Lädt die Originalbilder eines Dokuments und hält sie zwischengespeichert.
///
/// Ohne Zwischenspeicher würde jede Neuzeichnung des Canvas jedes Foto neu
/// dekodieren — bei einer Collage aus zehn Handyfotos wäre schon das Ziehen
/// einer Ebene ruckelig (Plan 2.1).
@MainActor
final class ImageStore {

    private let resources: DocumentResources
    private var cache: [String: CGImage] = [:]
    /// Namen, deren Laden bereits fehlgeschlagen ist — verhindert, dass eine
    /// kaputte Datei bei jedem Frame erneut erfolglos dekodiert wird.
    private var failed: Set<String> = []

    init(resources: DocumentResources) {
        self.resources = resources
    }

    /// `nil` bei fehlender oder unlesbarer Datei. Der Renderer zeichnet dann
    /// einen Platzhalter — abstürzen darf er nicht (Plan 2.1).
    func image(named name: String) -> CGImage? {
        if let cached = cache[name] { return cached }
        guard !failed.contains(name) else { return nil }

        guard let data = resources.data(for: name),
              let image = Self.decode(data)
        else {
            failed.insert(name)
            return nil
        }

        cache[name] = image
        return image
    }

    func forget(_ name: String) {
        cache.removeValue(forKey: name)
        failed.remove(name)
    }

    // MARK: - Dekodierung

    /// Dekodiert Bilddaten und richtet sie nach ihrer EXIF-Orientierung aus.
    ///
    /// Ohne diesen Schritt liegen Fotos vom iPhone quer auf der Leinwand: die
    /// Kamera speichert sie in Sensor-Lage und vermerkt die Drehung nur als
    /// Metadatum, das `CGImage` von sich aus ignoriert.
    ///
    /// Die Drehung übernimmt Core Image statt einer selbstgebauten Matrix —
    /// die acht EXIF-Fälle (besonders die gespiegelten 5 und 7) falsch
    /// zusammenzusetzen ist ein klassischer, schwer zu bemerkender Fehler.
    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        guard orientation > 1, orientation <= 8 else { return image }

        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        // Scheitert das Neuzeichnen, lieber das ungedrehte Bild zeigen als gar keines.
        return RenderContext.shared.createCGImage(oriented, from: oriented.extent) ?? image
    }
}
