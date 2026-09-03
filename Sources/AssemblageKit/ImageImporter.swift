import AppKit
import Foundation
import UniformTypeIdentifiers
import AssemblageModel

/// Die **Logik** des Bildimports (Plan 5.1): ermittelt aus einem
/// `NSPasteboard` oder einer Liste von Datei-URLs die importierbaren Bilder,
/// legt sie im Dokumentpaket ab und baut die fertigen `Layer`s dafür.
///
/// Bewusst **ohne** Drag-&-Drop-Anbindung: Kein `NSDraggingDestination`, kein
/// Zugriff auf `CanvasView`/`CanvasViewController`. Die Idee ist, dass ein
/// `performDragOperation` genau einen Aufruf hierher macht:
///
/// ```swift
/// let result = ImageImporter.import(
///     from: sender.draggingPasteboard,
///     resources: document.state.resources,
///     canvas: document.state.document.canvas
/// )
/// document.modify("Bilder importieren") { doc in
///     for image in result.images { try? doc.addLayer(image.layer) }
/// }
/// // result.failures dem Nutzer anzeigen, falls nicht leer.
/// ```
///
/// **Undo:** Verwirft der Aufrufer ein `Result`, ohne seine `Layer`s je über
/// `addLayer` einzufügen (z. B. weil `performDragOperation` doch noch
/// abbricht), passiert nichts weiter Schädliches — die Originaldatei wurde
/// zwar schon über `DocumentResources.addOriginal` in den Paket-`FileWrapper`
/// gehängt, aber an nichts im Dokument referenziert. Sie wird beim nächsten
/// Sichern von `removeUnreferencedFiles` wieder entfernt, und bis dahin liegt
/// sie nur im Speicher, nicht auf der Platte. Fügt der Aufrufer die Ebenen
/// ein und macht das per ⌘Z rückgängig, entfernt das nur die Ebenen aus
/// `Document.layers` — die Originaldatei bleibt bewusst im Paket liegen,
/// sonst würde ein anschliessendes Wiederholen (⇧⌘Z) sie erneut von der
/// Platte lesen müssen. Auch das räumt `removeUnreferencedFiles` beim
/// nächsten Sichern auf. Es braucht also keinen eigenen Undo-Mechanismus in
/// dieser Datei.
enum ImageImporter {

    // MARK: - Unterstützte Formate

    /// Plan 5.1: JPEG, PNG, HEIC, TIFF. Alles andere wird beim Ermitteln der
    /// importierbaren Dateien übergangen, nicht als Fehler gemeldet — wer
    /// fünf Dateien auf die Leinwand zieht, von denen eine ein PDF ist, will
    /// die vier Bilder importiert bekommen.
    static let supportedTypes: Set<UTType> = [.jpeg, .png, .heic, .tiff]

    // MARK: - Ergebnis

    /// Eine erfolgreich importierte Ebene plus die Paket-Referenz ihres
    /// bereits abgelegten Originals.
    struct ImportedImage {
        let layer: Layer
        let originalFileReference: String
    }

    /// Ein Bild, das nicht importiert werden konnte, obwohl es als Bilddatei
    /// erkannt wurde (kaputte Datei, unlesbare Kodierung) — im Unterschied zu
    /// einer schlicht nicht unterstützten Datei, die gar nicht erst auftaucht.
    struct Failure {
        let name: String
        let error: ImportError
    }

    struct Result {
        let images: [ImportedImage]
        let failures: [Failure]

        static let empty = Result(images: [], failures: [])
    }

    enum ImportError: LocalizedError, Equatable {
        case unreadableFile(String)
        case unreadableImage(String)

        var errorDescription: String? {
            switch self {
            case .unreadableFile(let name):
                return "Die Datei „\(name)“ liess sich nicht lesen."
            case .unreadableImage(let name):
                return "„\(name)“ ist kein lesbares Bild."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .unreadableFile:
                return "Vermutlich ist die Datei beschädigt, gesperrt oder nicht mehr vorhanden."
            case .unreadableImage:
                return "Die Bilddaten sind beschädigt oder liegen in einem nicht unterstützten Format vor."
            }
        }
    }

    // MARK: - Öffentliche Schnittstelle

    /// Filtert eine Liste von Datei-URLs (z. B. aus einem `NSOpenPanel` oder
    /// direkt aus `performDragOperation`) auf die unterstützten Bildformate.
    static func importableFileURLs(from urls: [URL]) -> [URL] {
        urls.filter { supportedType(forFileURL: $0) != nil }
    }

    /// Importiert eine Liste von Datei-URLs. Nicht unterstützte Dateien
    /// werden stillschweigend übergangen (siehe `importableFileURLs`);
    /// unterstützte, aber kaputte Dateien landen als `Failure` im Ergebnis.
    static func `import`(fileURLs: [URL], resources: DocumentResources, canvas: CanvasSize) -> Result {
        let sources: [ImportSource] = fileURLs.compactMap { url in
            supportedType(forFileURL: url) != nil ? .fileURL(url) : nil
        }
        return process(sources, resources: resources, canvas: canvas)
    }

    /// Ist auf dem Pasteboard überhaupt etwas Importierbares?
    ///
    /// Für Drag & Drop: Der Canvas muss beim Darüberziehen Bereitschaft
    /// melden oder eben nicht — und zwar **bevor** etwas importiert wird.
    /// Meldet er Bereitschaft für etwas, das er dann doch nicht annimmt, sieht
    /// der Nutzer ein Pluszeichen und danach passiert nichts.
    ///
    /// Liest bewusst nur die Typen, nicht die Daten: Die Prüfung läuft bei
    /// jeder Mausbewegung über der Leinwand.
    static func canImport(from pasteboard: NSPasteboard) -> Bool {
        !importableSources(from: pasteboard).isEmpty
    }

    /// Importiert alles Importierbare von einem Pasteboard — die Quelle
    /// sowohl für Drag & Drop aus Finder/Fotos-App als auch für „Einfügen“.
    /// Deckt zwei Fälle ab: Dateien (Finder legt Datei-URLs ab) und reine
    /// Bilddaten ohne Datei-Backing (die Fotos-App legt beim Ziehen z. B.
    /// oft direkt TIFF-/HEIC-Daten ab statt eines Pfads).
    static func `import`(from pasteboard: NSPasteboard, resources: DocumentResources, canvas: CanvasSize) -> Result {
        process(importableSources(from: pasteboard), resources: resources, canvas: canvas)
    }

    // MARK: - Quellen ermitteln

    /// Eine einzelne importierbare Fundstelle, bevor sie gelesen wurde.
    private enum ImportSource {
        case fileURL(URL)
        case pasteboardData(Data, UTType)
    }

    private static func importableSources(from pasteboard: NSPasteboard) -> [ImportSource] {
        (pasteboard.pasteboardItems ?? []).compactMap(source(from:))
    }

    private static func source(from item: NSPasteboardItem) -> ImportSource? {
        // Zuerst nach einer Datei-URL suchen — sie ist der Regelfall beim
        // Ziehen aus dem Finder und erlaubt es, den echten Dateinamen für die
        // Ebenenbezeichnung zu übernehmen.
        if let urlString = item.string(forType: .fileURL),
           let url = URL(string: urlString), url.isFileURL {
            return supportedType(forFileURL: url) != nil ? .fileURL(url) : nil
        }

        // Kein Datei-Backing: rohe Bilddaten direkt auf dem Pasteboard.
        for type in supportedTypes {
            let pbType = NSPasteboard.PasteboardType(type.identifier)
            if item.types.contains(pbType), let data = item.data(forType: pbType) {
                return .pasteboardData(data, type)
            }
        }
        return nil
    }

    private static func supportedType(forFileURL url: URL) -> UTType? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        return supportedTypes.first { type.conforms(to: $0) }
    }

    // MARK: - Verarbeitung

    /// Verarbeitet Quellen **nacheinander**, nicht parallel — bewusst, siehe
    /// Speicher-Hinweis unten. Eine kaputte Quelle bricht die Schleife nicht
    /// ab (Plan 2.1: Fehler abfangen statt abstürzen), sie landet als
    /// `Failure` und die übrigen laufen weiter.
    ///
    /// **Speicher (Plan 2.1):** `ImageDecoding.decode(_:)` dekodiert die
    /// vollen Pixel, nicht nur die Kopfdaten — nötig, weil die Anfangsgrösse
    /// aus der **angezeigten** (EXIF-gedrehten) Grösse kommen muss, und genau
    /// das übernimmt `decode(_:)` bereits korrekt; sie hier selbst aus den
    /// rohen Bildeigenschaften nachzubauen, hiesse die heikle
    /// EXIF-Orientierungslogik ein zweites Mal zu schreiben (siehe Warnung
    /// oben in `ContentRendering.swift`). Die Grenze liegt entsprechend beim
    /// grössten einzelnen Bild: ein 45-Megapixel-Foto braucht dekodiert
    /// (4 Byte/Pixel, unkomprimiert) kurzzeitig rund 180 MB RAM, bevor das
    /// dekodierte `CGImage` diese Methode wieder verlässt und freigegeben
    /// werden kann — nicht die Summe aller importierten Bilder, weil hier
    /// sequenziell verarbeitet wird und jeweils nur ein dekodiertes Bild
    /// gleichzeitig lebt. Für Formate mit deutlich grösseren Sensoren (hohe
    /// Megapixelzahl bei Panoramen o.ä.) wäre das der Punkt, an dem sich
    /// Kachelung/Downsampling beim Import lohnen würde; für Fotoimport in der
    /// hier vorgesehenen Grössenordnung (Handyfotos, gescannte Bilder) ist
    /// das unproblematisch. `Data(contentsOf:options:.mappedIfSafe)` beim
    /// Lesen der Originaldatei vermeidet zusätzlich, die komprimierten
    /// Rohbytes ein zweites Mal unnötig zu kopieren.
    private static func process(_ sources: [ImportSource], resources: DocumentResources, canvas: CanvasSize) -> Result {
        var images: [ImportedImage] = []
        var failures: [Failure] = []

        for (index, source) in sources.enumerated() {
            let displayName = name(for: source, index: index, total: sources.count)
            switch load(source) {
            case .failure(let error):
                failures.append(Failure(name: displayName, error: error))

            case .success(let (data, fileExtension)):
                guard let decoded = ImageDecoding.decode(data) else {
                    failures.append(Failure(name: displayName, error: .unreadableImage(displayName)))
                    continue
                }

                let contentSize = Size(width: Double(decoded.width), height: Double(decoded.height))
                let transform = cascaded(
                    Transform2D.fitting(contentSize: contentSize, into: canvas),
                    index: index,
                    total: sources.count
                )

                let reference = resources.addOriginal(data, fileExtension: fileExtension)
                let layer = Layer(
                    name: displayName,
                    transform: transform,
                    content: .image(ImageLayerContent(originalFileReference: reference))
                )
                images.append(ImportedImage(layer: layer, originalFileReference: reference))
            }
        }

        return Result(images: images, failures: failures)
    }

    private static func load(_ source: ImportSource) -> Swift.Result<(Data, String), ImportError> {
        switch source {
        case .fileURL(let url):
            do {
                // `.mappedIfSafe`: für grosse Originaldateien wird die Datei
                // per mmap eingeblendet statt sofort komplett in den Speicher
                // kopiert (Plan 2.1 „Speicher-Management bei grossen
                // Bildern") — dieselbe Überlegung wie bei `FileWrapper` in
                // `DocumentResources`.
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let fileExtension = url.pathExtension.isEmpty ? "dat" : url.pathExtension.lowercased()
                return .success((data, fileExtension))
            } catch {
                return .failure(.unreadableFile(url.lastPathComponent))
            }
        case .pasteboardData(let data, let type):
            return .success((data, type.preferredFilenameExtension ?? "dat"))
        }
    }

    private static func name(for source: ImportSource, index: Int, total: Int) -> String {
        switch source {
        case .fileURL(let url):
            let base = url.deletingPathExtension().lastPathComponent
            return base.isEmpty ? genericName(index: index, total: total) : base
        case .pasteboardData:
            // Bild ohne Datei (z. B. direkt aus der Fotos-App gezogen): kein
            // Dateiname vorhanden, also ein durchnummerierter Ersatzname.
            return genericName(index: index, total: total)
        }
    }

    private static func genericName(index: Int, total: Int) -> String {
        total > 1 ? "Importiertes Bild \(index + 1)" : "Importiertes Bild"
    }

    // MARK: - Versatz bei Mehrfachimport

    /// Abstand zweier aufeinanderfolgender Bilder in der Kaskade, in Punkten.
    private static let cascadeStep: Double = 28

    /// Nach so vielen Bildern beginnt der Versatz wieder bei null.
    ///
    /// Ohne Wiederholung würde das zwanzigste von zwanzig gleichzeitig
    /// importierten Fotos halb ausserhalb kleiner Leinwände (z. B. eines
    /// 1080×1080-Instagram-Posts) landen. Der Wert 6 hält die Kaskade auf
    /// dem kleinsten Preset (Instagram Post, 1080 Punkte) klar innerhalb der
    /// Leinwand (6 × 28 = 168 Punkte Versatz), und zwei Bilder mit
    /// gleichem Kaskaden-Rest (7. und 1. Bild) liegen dank der
    /// unterschiedlichen `fitting`-Grösse ihres jeweiligen Fotos in aller
    /// Regel trotzdem nicht deckungsgleich übereinander.
    private static let cascadeCycle = 6

    /// Versetzt jedes weitere gleichzeitig importierte Bild leicht nach
    /// rechts unten — nach dem Vorbild der klassischen Fenster-Kaskade
    /// (`NSWindow.cascadeTopLeft`). Ohne diesen Versatz läge ein
    /// Mehrfachimport exakt übereinander: Sichtbar wäre nur das oberste Bild,
    /// und wer fünf Fotos auf einmal hereinzieht, hielte den Import für
    /// kaputt, weil scheinbar nur eines ankam.
    private static func cascaded(_ transform: Transform2D, index: Int, total: Int) -> Transform2D {
        guard total > 1 else { return transform }
        var result = transform
        let step = Double(index % cascadeCycle) * cascadeStep
        result.x += step
        result.y += step
        return result
    }
}
