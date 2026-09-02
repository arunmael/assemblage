import Foundation
import AssemblageModel

/// Die Binärdateien im Dokumentpaket: Original-Fotos und Masken-Bitmaps
/// (Plan 7.4).
///
/// Gehalten werden bewusst `FileWrapper`s und **nicht** ausgepackte `Data` —
/// ein `FileWrapper`, der auf eine Datei zeigt, lädt ihren Inhalt erst beim
/// Zugriff und gibt ihn danach wieder frei. Ein Paket mit zwanzig 50-MB-Fotos
/// belegt so nicht 1 GB RAM, nur weil es geöffnet ist (Plan 2.1
/// „Speicher-Management bei grossen Bildern"). Beim Sichern reicht
/// `FileWrapper` unveränderte Dateien durch, statt sie neu zu schreiben.
final class DocumentResources {

    /// Relativer Pfad im Paket („originals/….heic") → Datei.
    private var wrappers: [String: FileWrapper] = [:]

    init() {}

    /// Liest die Binärdateien aus einem geöffneten Paket.
    init(root: FileWrapper) {
        for directory in [DocumentPackage.originalsDirectoryName, DocumentPackage.masksDirectoryName] {
            guard let subwrappers = root.fileWrappers?[directory]?.fileWrappers else { continue }
            for (name, wrapper) in subwrappers where wrapper.isRegularFile {
                wrappers["\(directory)/\(name)"] = wrapper
            }
        }
    }

    var fileNames: [String] { Array(wrappers.keys) }

    /// Lädt den Inhalt einer Paketdatei. `nil`, wenn sie fehlt — der Aufrufer
    /// zeigt dann einen Platzhalter an, statt abzustürzen (Plan 2.1).
    func data(for name: String) -> Data? {
        wrappers[name]?.regularFileContents
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
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = (name as NSString).lastPathComponent
        wrappers[name] = wrapper
        return name
    }

    /// Ersetzt den Inhalt einer bestehenden Datei — beim Übermalen einer Maske.
    func replace(_ name: String, with data: Data) {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = (name as NSString).lastPathComponent
        wrappers[name] = wrapper
    }

    /// Entfernt Dateien, auf die keine Ebene mehr zeigt. Wird beim Sichern
    /// aufgerufen, damit Pakete nicht unbegrenzt wachsen (Plan 2.1).
    func removeUnreferencedFiles(for document: AssemblageModel.Document) {
        for name in DocumentPackage.unreferencedFileNames(in: fileNames, for: document) {
            wrappers.removeValue(forKey: name)
        }
    }

    /// Baut das komplette Paket zum Sichern zusammen.
    func makeFileWrapper(documentData: Data) -> FileWrapper {
        var children: [String: FileWrapper] = [:]

        let documentWrapper = FileWrapper(regularFileWithContents: documentData)
        documentWrapper.preferredFilename = DocumentPackage.documentFileName
        children[DocumentPackage.documentFileName] = documentWrapper

        for directory in [DocumentPackage.originalsDirectoryName, DocumentPackage.masksDirectoryName] {
            let contents = wrappers
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
