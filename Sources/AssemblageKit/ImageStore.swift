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

    private nonisolated static let maximumPreviewPixelSize = 4_096
    private nonisolated static let thumbnailPixelSize = 96

    /// Was die Leinwand für ein Original gerade zeigen kann.
    enum Availability {
        case ready(CGImage)
        /// Wird im Hintergrund dekodiert; der Rückruf meldet, wenn es fertig ist.
        case loading
        /// Fehlt oder ist unlesbar.
        case unavailable
    }

    let resources: DocumentResources
    /// Dekodiert Originale abseits des Hauptthreads (siehe `availability`).
    ///
    /// Abschaltbar, weil Tests und Befehle, die ein Bild sofort brauchen, sonst
    /// auf einen Hintergrundlauf warten müssten.
    let loadsInBackground: Bool
    private let cache = NSCache<NSString, CachedImage>()
    private let thumbnails = NSCache<NSString, CachedImage>()
    private var pixelSizes: [String: CGSize] = [:]

    /// Laufende Hintergrund-Dekodierungen und wer auf sie wartet. Verhindert,
    /// dass dasselbe Foto zweimal parallel dekodiert wird, wenn es während
    /// des Ladens erneut angefragt wird.
    private var pending: [String: [@MainActor (String) -> Void]] = [:]

    /// Begrenzt, wie viele Fotos gleichzeitig dekodiert werden. Alle Kerne
    /// voll auszulasten, hielte zwar die Warteschlange kurz, liesse aber die
    /// Oberfläche und den Compositor verhungern — und jeder laufende
    /// Vorgang hält kurzzeitig die volle Originaldatei im Speicher.
    private static let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Assemblage.ImageStore.decode"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        return queue
    }()

    /// Verhindert, dass eine defekte Datei bei jedem Frame-Rendering-Versuch
    /// erneut geladen und dekodiert wird, was die Performance ruinieren würde.
    private var failed: Set<String> = []

    init(resources: DocumentResources, loadsInBackground: Bool = false) {
        self.resources = resources
        self.loadsInBackground = loadsInBackground

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

    /// Dekodiert bei Bedarf **synchron**. Für Stellen, die das Bild sofort
    /// brauchen (Zuschneiden, Maskenmalen); die Leinwand nimmt
    /// `availability(of:whenLoaded:)`.
    func image(named name: String) -> CGImage? {
        if let cached = cache.object(forKey: name as NSString) {
            return cached.image
        }
        guard !failed.contains(name) else { return nil }
        let result = Self.decodePreview(resources.data(for: name))
        store(result, for: name)
        return result.image
    }

    /// Nicht blockierend: Liegt das Bild schon dekodiert vor, kommt es sofort;
    /// sonst wird es im Hintergrund dekodiert und `whenLoaded` danach auf dem
    /// Hauptthread aufgerufen.
    ///
    /// Warum das zählt: Ein Projekt mit vielen Fotos zu öffnen oder viele
    /// auf einmal hereinzuziehen, hiess bisher, jedes einzelne auf dem
    /// Hauptthread zu dekodieren — die App stand, obwohl nur ein Kern
    /// arbeitete und die Auslastung harmlos aussah.
    func availability(
        of name: String,
        whenLoaded: @escaping @MainActor (String) -> Void
    ) -> Availability {
        if let cached = cache.object(forKey: name as NSString) {
            return .ready(cached.image)
        }
        guard !failed.contains(name) else { return .unavailable }
        guard loadsInBackground else {
            return image(named: name).map(Availability.ready) ?? .unavailable
        }

        if pending[name] != nil {
            pending[name]?.append(whenLoaded)
            return .loading
        }
        pending[name] = [whenLoaded]

        let resources = resources
        Self.decodeQueue.addOperation { [weak self] in
            let result = Self.decodePreview(resources.data(for: name))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishDecoding(result, for: name)
                }
            }
        }
        return .loading
    }

    /// Ob ein Original vorhanden und lesbar ist, ohne es zu dekodieren.
    /// Die Kopfdaten zu lesen reicht dafür und kostet nur Millisekunden.
    func canDisplay(named name: String) -> Bool {
        if cache.object(forKey: name as NSString) != nil { return true }
        guard !failed.contains(name) else { return false }
        return pixelSize(named: name) != nil
    }

    /// Eine kleine Fassung für die Ebenenliste, im Hintergrund erzeugt.
    ///
    /// Eigener Zwischenspeicher, weil ein 30-Punkte-Vorschaubild sonst das
    /// volle 4096er-Bild im Speicher festhielte — und dessen Dekodieren die
    /// Liste bei vielen Fotos zum Stocken brachte.
    func thumbnail(named name: String) async -> CGImage? {
        if let cached = thumbnails.object(forKey: name as NSString) {
            return cached.image
        }
        guard !failed.contains(name) else { return nil }

        let resources = resources
        let image = await Task.detached(priority: .utility) {
            Self.decodeThumbnail(resources.data(for: name))
        }.value
        if let image {
            thumbnails.setObject(CachedImage(image), forKey: name as NSString)
        }
        return image
    }

    private func finishDecoding(_ result: DecodedPreview, for name: String) {
        store(result, for: name)
        let callbacks = pending.removeValue(forKey: name) ?? []
        for callback in callbacks { callback(name) }
    }

    private func store(_ result: DecodedPreview, for name: String) {
        if let size = result.pixelSize {
            pixelSizes[name] = size
        }
        guard let image = result.image else {
            failed.insert(name)
            return
        }
        let cost = image.bytesPerRow * image.height
        cache.setObject(CachedImage(image), forKey: name as NSString, cost: cost)
    }

    private struct DecodedPreview: @unchecked Sendable {
        let image: CGImage?
        let pixelSize: CGSize?
    }

    /// Reine Funktion ohne Zustand, damit sie auf jedem Thread laufen darf.
    private nonisolated static func decodePreview(_ data: Data?) -> DecodedPreview {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return DecodedPreview(image: nil, pixelSize: nil) }

        // 4096 Pixel reichen für jeden Bildschirm samt beherzter Vergrösserung;
        // mehr Bildpunkte wären auf dem Bildschirm ohnehin nicht zu sehen.
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maximumPreviewPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Sofort dekodieren statt beim ersten Zeichnen: Sonst holte Core
            // Animation das Dekodieren doch wieder auf dem Hauptthread nach.
            kCGImageSourceShouldCacheImmediately: true
        ]
        return DecodedPreview(
            image: CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            pixelSize: pixelSize(from: source)
        )
    }

    private nonisolated static func decodeThumbnail(_ data: Data?) -> CGImage? {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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

    private nonisolated static func pixelSize(from source: CGImageSource) -> CGSize? {
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
        thumbnails.removeObject(forKey: name as NSString)
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
