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
    ///
    /// Ohne Zwischenergebnis-Speicher: Core Image hielte sonst die Bitmaps
    /// jeder Filterkette vor, obwohl hier fast jedes Bild nur einmal
    /// durchläuft (Maske, Drehung, Export). Auf Apple-Chips teilen sich CPU
    /// und GPU denselben Speicher — was Core Image hortet, fehlt der App.
    static let shared = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false,
        .name: "Assemblage"
    ])
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

    private nonisolated static let thumbnailPixelSize = 96

    /// Die Auflösungsstufen, in denen ein Original vorgehalten wird (längste
    /// Kante in Pixeln).
    ///
    /// Eine Ebene bekommt die kleinste Stufe, die bei aktuellem Zoom scharf
    /// aussieht — statt pauschal 4096 px. Ein Foto, das auf der Leinwand
    /// 300 Punkte breit ist, belegt so rund 4 MB statt 64 MB. Stufen statt
    /// exakter Grössen, damit ein leichtes Zoomen nicht jedes Mal neu
    /// dekodiert und der Zwischenspeicher wiederverwendbare Fassungen hält.
    nonisolated static let tiers = [256, 1_024, 2_048, 4_096]
    /// Mehr Bildpunkte wären auf keinem Bildschirm zu sehen.
    nonisolated static let fullTier = 4_096
    /// Die „ungefähre" Fassung für Ebenen, die weder sichtbar sind noch
    /// kürzlich angefasst wurden: rund 0,25 MB statt bis zu 64 MB.
    nonisolated static let approximateTier = 256

    /// Die kleinste Stufe, die `neededPixels` (längste Kante) abdeckt.
    nonisolated static func tier(forPixelEdge neededPixels: CGFloat) -> Int {
        guard neededPixels.isFinite else { return fullTier }
        return tiers.first { CGFloat($0) >= neededPixels } ?? fullTier
    }

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

    private static func cacheKey(_ name: String, tier: Int) -> NSString {
        "\(name)#\(tier)" as NSString
    }

    /// Begrenzt, wie viele Fotos gleichzeitig dekodiert werden. Alle Kerne
    /// voll auszulasten, hielte zwar die Warteschlange kurz, liesse aber die
    /// Oberfläche und den Compositor verhungern — und jeder laufende
    /// Vorgang hält kurzzeitig die volle Originaldatei im Speicher.
    private static let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Assemblage.ImageStore.decode"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = decodeConcurrency()
        // Bei Hitze oder im Stromsparmodus weniger parallel dekodieren: Auf
        // einem MacBook Air ohne Lüfter drosselt der Chip sonst ohnehin, und
        // die Oberfläche bekäme die gedrosselte Leistung zu spüren.
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                queue.maxConcurrentOperationCount = decodeConcurrency()
            }
        }
        return queue
    }()

    private nonisolated static func decodeConcurrency() -> Int {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical {
            return 1
        }
        return max(2, info.activeProcessorCount / 2)
    }

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

    /// Dekodiert bei Bedarf **synchron** in voller Vorschauauflösung. Für
    /// Stellen, die das Bild sofort brauchen (Zuschneiden, Maskenmalen); die
    /// Leinwand nimmt `availability(of:tier:urgent:whenLoaded:)`.
    func image(named name: String) -> CGImage? {
        let key = Self.cacheKey(name, tier: Self.fullTier)
        if let cached = cache.object(forKey: key) {
            return cached.image
        }
        guard !failed.contains(name) else { return nil }
        let result = Self.decodePreview(resources.data(for: name), maxPixelEdge: Self.fullTier)
        store(result, for: name, tier: Self.fullTier)
        return result.image
    }

    /// Nicht blockierend: Liegt das Bild in der Stufe schon dekodiert vor,
    /// kommt es sofort; sonst wird es im Hintergrund dekodiert und
    /// `whenLoaded` danach auf dem Hauptthread aufgerufen.
    ///
    /// Warum das zählt: Ein Projekt mit vielen Fotos zu öffnen oder viele
    /// auf einmal hereinzuziehen, hiess bisher, jedes einzelne auf dem
    /// Hauptthread zu dekodieren — die App stand, obwohl nur ein Kern
    /// arbeitete und die Auslastung harmlos aussah.
    ///
    /// `urgent` für sichtbare Ebenen: Sie werden vor denen dekodiert, die
    /// gerade nur auf eine kleinere Stufe wechseln.
    func availability(
        of name: String,
        tier requestedTier: Int = fullTier,
        urgent: Bool = true,
        whenLoaded: @escaping @MainActor (String) -> Void
    ) -> Availability {
        let tier = effectiveTier(requestedTier, for: name)
        let key = Self.cacheKey(name, tier: tier)
        if let cached = cache.object(forKey: key) {
            return .ready(cached.image)
        }
        guard !failed.contains(name) else { return .unavailable }
        guard loadsInBackground else {
            let result = Self.decodePreview(resources.data(for: name), maxPixelEdge: tier)
            store(result, for: name, tier: tier)
            return result.image.map(Availability.ready) ?? .unavailable
        }

        let pendingKey = key as String
        if pending[pendingKey] != nil {
            pending[pendingKey]?.append(whenLoaded)
            return .loading
        }
        pending[pendingKey] = [whenLoaded]

        let resources = resources
        let operation = BlockOperation { [weak self] in
            let result = Self.decodePreview(resources.data(for: name), maxPixelEdge: tier)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishDecoding(result, for: name, tier: tier)
                }
            }
        }
        operation.queuePriority = urgent ? .high : .low
        operation.qualityOfService = urgent ? .userInitiated : .utility
        Self.decodeQueue.addOperation(operation)
        return .loading
    }

    /// Welche Stufe tatsächlich dekodiert wird. Ist das Original nicht
    /// grösser als die Stufe, ergäben alle höheren Stufen dasselbe Bild —
    /// sie teilen sich deshalb einen Eintrag, statt es mehrfach zu halten.
    func effectiveTier(_ tier: Int, for name: String) -> Int {
        let begrenzt = Self.tiers.first { $0 >= tier } ?? Self.fullTier
        guard let size = pixelSize(named: name) else { return begrenzt }
        return CGFloat(begrenzt) >= max(size.width, size.height) ? Self.fullTier : begrenzt
    }

    /// Gibt alles frei, was sich jederzeit neu dekodieren lässt. Bilder, die
    /// eine Ebene gerade zeigt, bleiben über die Ebene selbst erhalten.
    func releaseCachedImages() {
        cache.removeAllObjects()
        thumbnails.removeAllObjects()
    }

    /// Ob ein Original vorhanden und lesbar ist, ohne es zu dekodieren.
    /// Die Kopfdaten zu lesen reicht dafür und kostet nur Millisekunden.
    func canDisplay(named name: String) -> Bool {
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

    private func finishDecoding(_ result: DecodedPreview, for name: String, tier: Int) {
        store(result, for: name, tier: tier)
        let callbacks = pending.removeValue(forKey: Self.cacheKey(name, tier: tier) as String) ?? []
        for callback in callbacks { callback(name) }
    }

    private func store(_ result: DecodedPreview, for name: String, tier: Int) {
        if let size = result.pixelSize {
            pixelSizes[name] = size
        }
        guard let image = result.image else {
            failed.insert(name)
            return
        }
        let cost = image.bytesPerRow * image.height
        cache.setObject(CachedImage(image), forKey: Self.cacheKey(name, tier: tier), cost: cost)
    }

    private struct DecodedPreview: @unchecked Sendable {
        let image: CGImage?
        let pixelSize: CGSize?
    }

    /// Reine Funktion ohne Zustand, damit sie auf jedem Thread laufen darf.
    private nonisolated static func decodePreview(_ data: Data?, maxPixelEdge: Int) -> DecodedPreview {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return DecodedPreview(image: nil, pixelSize: nil) }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelEdge,
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
        for tier in Self.tiers {
            cache.removeObject(forKey: Self.cacheKey(name, tier: tier))
        }
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
