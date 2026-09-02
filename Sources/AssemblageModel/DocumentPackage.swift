import Foundation

/// Fehler beim Lesen/Schreiben eines Dokumentpakets. Plan 2.1 verlangt, dass
/// Datei-Ein-/Ausgabe grundsätzlich Fehler zurückmeldet statt abzustürzen.
public enum DocumentPackageError: Error, Equatable, Sendable {
    /// Das Paket stammt aus einer neueren App-Version. Es wird bewusst nicht
    /// „so gut es geht" geöffnet — sonst würde das nächste Speichern die
    /// unbekannten Daten stillschweigend wegwerfen.
    case unsupportedFormatVersion(Int)
    /// Referenzierte Originale/Masken fehlen im Paket.
    case missingReferencedFiles([String])
}

/// Das Dokumentpaket (Plan 7.4): ein Bundle aus `document.json` plus den
/// referenzierten Original-Bilddateien und Masken-Bitmaps.
///
/// Bewusst reine Funktionen ohne Dateisystem-Zugriff: am Mac setzt
/// `AssemblageDocument` daraus einen `FileWrapper` zusammen (das ist die
/// Voraussetzung für Autosave und die eingebaute Versionsverwaltung aus
/// Plan 2.1). So bleibt die fehleranfällige Logik hier testbar — auch in der
/// Linux-CI, die kein AppKit hat.
public enum DocumentPackage {

    /// Version des Paketformats. Bei jeder inkompatiblen Änderung an
    /// `Document` erhöhen — ältere Apps erkennen daran, dass sie das Dokument
    /// nicht gefahrlos öffnen können.
    public static let currentFormatVersion = 1

    /// Dateiname der JSON-Struktur innerhalb des Pakets.
    public static let documentFileName = "document.json"
    /// Unterordner für die unveränderten Originalbilder (Plan 7.4:
    /// „Originale bleiben erhalten").
    public static let originalsDirectoryName = "originals"
    /// Unterordner für die gemalten/automatisch erzeugten Masken-Bitmaps.
    public static let masksDirectoryName = "masks"

    /// Umschlag um das eigentliche Dokument — trägt die Formatversion, damit
    /// künftige Formatwechsel erkennbar sind.
    private struct Envelope: Codable {
        var formatVersion: Int
        var document: Document
    }

    public static func encode(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        // Sortierte Schlüssel: sonst erzeugt jedes Speichern eine andere
        // Byte-Reihenfolge, was die Versionsverwaltung mit sinnlosen
        // Unterschieden füllt.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(formatVersion: currentFormatVersion, document: document))
    }

    public static func decode(_ data: Data) throws -> Document {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.formatVersion <= currentFormatVersion else {
            throw DocumentPackageError.unsupportedFormatVersion(envelope.formatVersion)
        }
        return envelope.document
    }

    /// Prüft beim Öffnen, ob alle referenzierten Dateien im Paket liegen.
    /// `availableFileNames` sind die tatsächlich vorhandenen relativen Pfade.
    public static func validate(
        _ document: Document,
        against availableFileNames: some Sequence<String>
    ) throws {
        let available = Set(availableFileNames)
        let missing = document.referencedFileNames.filter { !available.contains($0) }
        guard missing.isEmpty else {
            throw DocumentPackageError.missingReferencedFiles(missing)
        }
    }

    /// Dateien im Paket, auf die keine Ebene mehr zeigt — etwa das Original
    /// einer gelöschten Ebene. Beim Speichern aussortieren, damit Pakete nicht
    /// unbegrenzt wachsen (Plan 2.1).
    public static func unreferencedFileNames(
        in availableFileNames: some Sequence<String>,
        for document: Document
    ) -> [String] {
        let referenced = Set(document.referencedFileNames)
        return availableFileNames.filter { !referenced.contains($0) }
    }
}

extension Document {
    /// Alle vom Dokument referenzierten Paket-Dateien, in Ebenenreihenfolge.
    /// Eine Maske ohne Bitmap (Vision-Anfrage noch unterwegs) zählt nicht mit.
    public var referencedFileNames: [String] {
        layers.flatMap { layer -> [String] in
            var names: [String] = []
            if case .image(let content) = layer.content {
                names.append(content.originalFileReference)
            }
            if let maskReference = layer.mask?.maskImageReference {
                names.append(maskReference)
            }
            return names
        }
    }
}
