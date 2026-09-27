import Foundation
import AssemblageModel

/// Die Binärdateien im Dokumentpaket: Original-Fotos und Masken-Bitmaps
/// (Plan 7.4).
///
/// **Nebenläufigkeit:** Der Export läuft laut Plan 2.1 im Hintergrund, damit
/// die Oberfläche nicht einfriert — währenddessen kann der Nutzer weiter
/// Fotos hereinziehen. Lesen und Schreiben treffen also tatsächlich
/// aufeinander, und ohne Absicherung stürzt die App dabei ab (nachgestellt in
/// `DocumentResourcesConcurrencyTests`). Deshalb liegt jeder Zugriff auf
/// `wrappers` hinter einer Sperre. Sie wird nur für den Wörterbuch-Zugriff
/// gehalten, nicht während des Dekodierens — sonst würde der Export den
/// Hauptthread genau so blockieren, wie es vermieden werden soll.
///
/// Gehalten werden bewusst `FileWrapper`s und **nicht** ausgepackte `Data` —
/// ein `FileWrapper`, der auf eine Datei zeigt, kann ihren Inhalt beim
/// Zugriff in den Speicher einblenden, ohne eine Heap-Kopie zu halten. Ein
/// Paket mit zwanzig 50-MB-Fotos belegt so nicht 1 GB RAM, nur weil es
/// geöffnet ist (Plan 2.1
/// „Speicher-Management bei grossen Bildern"). Beim Sichern reicht
/// `FileWrapper` unveränderte Dateien durch, statt sie neu zu schreiben.
final class DocumentResources {

    /// Relativer Pfad im Paket („originals/….heic") → Datei.
    /// Nur unter `sperre` anfassen.
    private var wrappers: [String: FileWrapper] = [:]
    private let sperre = NSLock()

    private static var spillRootURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Assemblage-Auslagerung", isDirectory: true)
    }

    // Nur die URL entsteht sofort; das Verzeichnis erst beim ersten Schreiben.
    // Unveränderlich, damit auch gleichzeitige Importe dasselbe Ziel verwenden.
    let spillDirectoryURL = DocumentResources.spillRootURL
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: spillDirectoryURL)
    }

    /// Räumt nach einem Absturz liegengebliebene Instanz-Verzeichnisse auf.
    /// Beim Programmstart aufrufen, bevor Dokumente geöffnet werden.
    static func removeStaleSpillDirectories() {
        let manager = FileManager.default
        let grenze = Date().addingTimeInterval(-24 * 60 * 60)
        guard let verzeichnisse = try? manager.contentsOfDirectory(
            at: spillRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        ) else { return }
        for url in verzeichnisse {
            guard let werte = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey
            ]), werte.isDirectory == true, werte.isSymbolicLink != true,
                let datum = werte.contentModificationDate, datum < grenze else { continue }
            try? manager.removeItem(at: url)
        }
    }

    private func ausgelagerterWrapper(_ data: Data) -> FileWrapper {
        // Frühere Dateien bleiben für Leser und Sicherungs-Wrapper erhalten.
        // NSDocument schreibt synchron; erst deinit räumt die Sitzung auf.
        do {
            try FileManager.default.createDirectory(at: spillDirectoryURL, withIntermediateDirectories: true)
            let url = spillDirectoryURL.appendingPathComponent(UUID().uuidString)
            try data.write(to: url, options: .atomic)
            return try FileWrapper(url: url, options: [])
        } catch {
            // Auch bei voller Platte darf ein Import keine Daten verlieren.
            return FileWrapper(regularFileWithContents: data)
        }
    }

    private func unterSperre<T>(_ body: () -> T) -> T {
        sperre.lock()
        defer { sperre.unlock() }
        return body()
    }

    init() {}

    /// Liest die Binärdateien aus einem geöffneten Paket.
    init(root: FileWrapper) {
        // Vor der ersten Weitergabe: keine Sperre nötig, niemand sonst kennt
        // die Instanz schon.
        for directory in [DocumentPackage.originalsDirectoryName, DocumentPackage.masksDirectoryName] {
            guard let subwrappers = root.fileWrappers?[directory]?.fileWrappers else { continue }
            for (name, wrapper) in subwrappers where wrapper.isRegularFile {
                wrappers["\(directory)/\(name)"] = wrapper
            }
        }
    }

    var fileNames: [String] { unterSperre { Array(wrappers.keys) } }

    /// Lädt den Inhalt einer Paketdatei. `nil`, wenn sie fehlt — der Aufrufer
    /// zeigt dann einen Platzhalter an, statt abzustürzen (Plan 2.1).
    func data(for name: String) -> Data? {
        // Bei einem Wrapper auf eine Datei (geöffnetes Paket oder ausgelagerter
        // Import) blendet `regularFileContents` die Datei nur ein: Gemessen
        // wuchs der residente Speicher nach dem Lesen von 200 MB nicht. Ein
        // eigenes `Data(contentsOf:options: .alwaysMapped)` brächte nichts.
        // `regularFileContents` liest hier mit unter der Sperre: `FileWrapper`
        // ist nicht als threadsicher zugesichert, und zwei Leser auf derselben
        // Datei wären sonst ebenfalls ein Wettlauf.
        unterSperre { wrappers[name]?.regularFileContents }
    }

    /// Legt ein importiertes Original ab und gibt seine Paket-Referenz zurück.
    /// Der Dateiname ist eine UUID: Fotos aus der Fotos-App heissen reihenweise
    /// „IMG_0001.heic", und ein Namenskonflikt würde sonst stillschweigend ein
    /// fremdes Bild überschreiben.
    func addOriginal(_ data: Data, fileExtension: String) -> String {
        add(data, to: DocumentPackage.originalsDirectoryName, fileExtension: fileExtension)
    }

    func addMask(_ data: Data) -> String {
        add(data, to: DocumentPackage.masksDirectoryName, fileExtension: "png")
    }

    private func add(_ data: Data, to directory: String, fileExtension: String) -> String {
        let name = "\(directory)/\(UUID().uuidString).\(fileExtension)"
        let wrapper = ausgelagerterWrapper(data)
        wrapper.preferredFilename = (name as NSString).lastPathComponent
        unterSperre { wrappers[name] = wrapper }
        return name
    }

    /// Ersetzt den Inhalt einer bestehenden Datei — beim Übermalen einer Maske.
    func replace(_ name: String, with data: Data) {
        let wrapper = ausgelagerterWrapper(data)
        wrapper.preferredFilename = (name as NSString).lastPathComponent
        unterSperre { wrappers[name] = wrapper }
    }

    /// Nur verwenden, wenn auch Undo/Redo keine dieser Dateien mehr benötigt.
    func removeUnreferencedFiles(for document: AssemblageModel.Document) {
        for name in DocumentPackage.unreferencedFileNames(in: fileNames, for: document) {
            unterSperre { _ = wrappers.removeValue(forKey: name) }
        }
    }

    /// Baut das komplette Paket zum Sichern zusammen.
    func makeFileWrapper(documentData: Data, referencedFileNames: Set<String>? = nil) -> FileWrapper {
        var children: [String: FileWrapper] = [:]

        let documentWrapper = FileWrapper(regularFileWithContents: documentData)
        documentWrapper.preferredFilename = DocumentPackage.documentFileName
        children[DocumentPackage.documentFileName] = documentWrapper

        // Nur das gespeicherte Paket ausdünnen. Die Sitzung benötigt frühere
        // Originale und Masken weiterhin für Undo/Redo und laufende Exporte.
        let momentaufnahme = unterSperre {
            wrappers.filter { referencedFileNames?.contains($0.key) ?? true }
        }
        for directory in [DocumentPackage.originalsDirectoryName, DocumentPackage.masksDirectoryName] {
            let contents = momentaufnahme
                .filter { $0.key.hasPrefix("\(directory)/") }
                .reduce(into: [String: FileWrapper]()) { result, entry in
                    result[(entry.key as NSString).lastPathComponent] = entry.value
                }
            // Leere Ordner weglassen: ein Dokument ohne Masken braucht keinen
            // masks-Ordner.
            guard !contents.isEmpty else { continue }
            let directoryWrapper = FileWrapper(directoryWithFileWrappers: contents)
            directoryWrapper.preferredFilename = directory
            children[directory] = directoryWrapper
        }

        return FileWrapper(directoryWithFileWrappers: children)
    }
}
