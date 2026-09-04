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

/// Hilfsklasse, da NSCache nur Objective-C-kompatible Klassenreferenzen akzeptiert
/// und CGImage ein Core-Foundation-Typ ist.
private final class CachedImage: Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Lädt Bildschirmfassungen der Originalbilder und hält sie zwischengespeichert.
///
/// NSCache wird verwendet, weil das System diesen Speicher bei akutem Speicherdruck
/// selbstständig freigeben kann. Ein manuell implementiertes LRU-Verfahren mit fester
/// Obergrenze würde den Speicher auch dann blockieren, wenn das System bereits auslagert.
@MainActor
final class ImageStore {

    private static let maximumPreviewPixelSize = 4_096

    let resources: DocumentResources
    private let cache = NSCache<NSString, CachedImage>()
    private var pixelSizes: [String: CGSize] = [:]

    /// Verhindert, dass eine defekte Datei bei jedem Frame-Rendering-Versuch
    /// erneut geladen und dekodiert wird, was die Performance ruinieren würde.
    private var failed: Set<String> = []

    init(resources: DocumentResources) {
        self.resources = resources

        // Ein Viertel des physischen Speichers ist ein ausgewogener Kompromiss, um
        // genügend Bilder für flüssiges Arbeiten vorzuhalten, ohne das System zu belasten.
        let quarterMemory = ProcessInfo.processInfo.physicalMemory / 4

        // Unter 256 MB würden Bilder auf schwachen Geräten zu schnell verworfen,
        // was zu ständigem, spürbarem Neudekodieren führt.
        let minLimit: UInt64 = 256 * 1024 * 1024

        // Über 2 GB bringt keinen spürbaren Vorteil mehr, da ohnehin nur ein
        // Dokument gleichzeitig aktiv im Fokus des Benutzers steht.
        let maxLimit: UInt64 = 2 * 1024 * 1024 * 1024

        let clamped = max(minLimit, min(quarterMemory, maxLimit))

        // Die Konvertierung ist sicher, da das Limit durch die 2-GB-Grenze
        // weit unter dem maximalen Wert eines 64-Bit-Int liegt.
        cache.totalCostLimit = Int(clamped)
    }

    func image(named name: String) -> CGImage? {
        let key = name as NSString
        if let cached = cache.object(forKey: key) {
            return cached.image
        }

        guard !failed.contains(name) else { return nil }

        guard let data = resources.data(for: name),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            failed.insert(name)
            return nil
        }
        if let size = Self.pixelSize(from: source) {
            pixelSizes[name] = size
        }

        // 4096 Pixel reichen für jeden Bildschirm samt beherzter Vergrösserung;
        // mehr Bildpunkte wären auf dem Bildschirm ohnehin nicht zu sehen.
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumPreviewPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            failed.insert(name)
            return nil
        }

        let cost = image.bytesPerRow * image.height
        cache.setObject(CachedImage(image), forKey: key, cost: cost)
        return image
    }

    /// Die Pixelmasse des Originals — unabhängig davon, wie fein das Bild
    /// gerade für den Bildschirm vorgehalten wird.
    func pixelSize(named name: String) -> CGSize? {
        if let cached = pixelSizes[name] { return cached }

        guard let data = resources.data(for: name),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let size = Self.pixelSize(from: source)
        else { return nil }

        pixelSizes[name] = size
        return size
    }

    private static func pixelSize(from source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let size = if (5...8).contains(orientation) {
            CGSize(width: height, height: width)
        } else {
            CGSize(width: width, height: height)
        }
        return size
    }

    func forget(_ name: String) {
        cache.removeObject(forKey: name as NSString)
        pixelSizes.removeValue(forKey: name)
        failed.remove(name)
    }

    /// Obergrenze des Zwischenspeichers in Bytes. Nur zum Prüfen.
    var cacheCostLimitForTesting: Int {
        cache.totalCostLimit
    }

    /// Leert den Zwischenspeicher, nicht aber das Wissen über kaputte Dateien.
    /// Wird beim Schliessen eines Dokuments gebraucht — und im Test, um das
    /// Verhalten nach einer Freigabe nachzustellen.
    func evictAllForTesting() {
        cache.removeAllObjects()
    }
}
