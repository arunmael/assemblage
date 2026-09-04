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

/// Lädt die Originalbilder eines Dokuments und hält sie zwischengespeichert.
///
/// NSCache wird verwendet, weil das System diesen Speicher bei akutem Speicherdruck
/// selbstständig freigeben kann. Ein manuell implementiertes LRU-Verfahren mit fester
/// Obergrenze würde den Speicher auch dann blockieren, wenn das System bereits auslagert.
@MainActor
final class ImageStore {

    let resources: DocumentResources
    private let cache = NSCache<NSString, CachedImage>()

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
              let image = ImageDecoding.decode(data)
        else {
            failed.insert(name)
            return nil
        }

        let cost = image.bytesPerRow * image.height
        cache.setObject(CachedImage(image), forKey: key, cost: cost)
        return image
    }

    func forget(_ name: String) {
        cache.removeObject(forKey: name as NSString)
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
