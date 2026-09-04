import AppKit
import AssemblageModel

/// Ein geöffnetes Assemblage-Dokument (Plan 7.4).
///
/// `NSDocument` statt Eigenbau, weil daran drei Anforderungen aus Plan 2.1
/// kostenlos hängen: Autosave in kurzen Intervallen, die Wiederherstellung
/// offener Dokumente nach einem Absturz und der eingebaute Versions-Browser
/// („Alle Versionen durchsuchen…") über `NSFileVersion`.
@MainActor
final class AssemblageDocument: NSDocument {

    /// Dateiendung und UTI des Dokumentpakets — muss zu den Einträgen in der
    /// Info.plist passen, die Scripts/make-app.sh erzeugt.
    static let fileType = "de.arun.assemblage.document"
    static let fileExtension = "assemblage"

    private(set) lazy var state: DocumentState = {
        let zustand = DocumentState(
            document: AssemblageModel.Document(preset: .instagramPost),
            resources: DocumentResources()
        )
        zustand.owner = self
        return zustand
    }()

    /// Zustand vor Beginn einer Interaktion (Ziehen, gehaltener Regler).
    /// `nil`, solange keine läuft — siehe `beginInteraction()`.
    var interactionSnapshot: AssemblageModel.Document?

    /// Zustand für `modifyCoalescing(_:at:within:_:)`.
    var coalescingActionName: String?
    var coalescingTargetID: UUID?
    var lastCoalescedAt: Date?
    var coalescingTimer: Timer?

    // MARK: - Verhalten

    /// Schaltet Autosave, Absturz-Wiederherstellung und die Versionsverwaltung
    /// ein (Plan 2.1). Ohne das speichert `NSDocument` erst auf Befehl.
    override class var autosavesInPlace: Bool { true }

    override class var preservesVersions: Bool { true }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController())
    }

    // MARK: - Lesen & Schreiben

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        guard let documentData = fileWrapper.fileWrappers?[DocumentPackage.documentFileName]?
            .regularFileContents
        else {
            throw DocumentReadError.missingDocumentFile
        }

        let loaded = try DocumentPackage.decode(documentData)
        let resources = DocumentResources(root: fileWrapper)

        // Fehlende Originale werden hier erkannt und benannt, statt später
        // beim Rendern als leere Fläche aufzufallen (Plan 2.1).
        try DocumentPackage.validate(loaded, against: resources.fileNames)

        // AppKit deklariert das Lesen ausdrücklich als nicht an den
        // Haupt-Thread gebunden. Der beobachtbare Zustand gehört aber dorthin
        // (SwiftUI-Paletten und Canvas hängen daran), also wird hier nur
        // geparst und die Übernahme auf den Haupt-Thread geschoben.
        let parsed = ParsedContents(document: loaded, resources: resources)
        if Thread.isMainThread {
            MainActor.assumeIsolated { adopt(parsed) }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { self.adopt(parsed) } }
        }
    }

    private func adopt(_ parsed: ParsedContents) {
        state.replaceContents(document: parsed.document, resources: parsed.resources)
    }

    /// Transportkiste vom Lese- zum Haupt-Thread.
    ///
    /// `@unchecked Sendable` ist hier vertretbar und nicht bloss beschwichtigt:
    /// Die Instanz wird in `read(from:ofType:)` erzeugt, genau einmal
    /// weitergereicht und danach nie wieder angefasst — es gibt keinen zweiten
    /// Zugriff, der sich mit dem ersten überschneiden könnte.
    private final class ParsedContents: @unchecked Sendable {
        let document: AssemblageModel.Document
        let resources: DocumentResources

        init(document: AssemblageModel.Document, resources: DocumentResources) {
            self.document = document
            self.resources = resources
        }
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let document = state.document
        // Originale gelöschter Ebenen mitschleppen wäre teuer: ein Paket
        // würde mit jedem Import wachsen und nie kleiner werden.
        state.resources.removeUnreferencedFiles(for: document)
        return state.resources.makeFileWrapper(
            documentData: try DocumentPackage.encode(document)
        )
    }
}

/// Fehler, die nur beim Öffnen auftreten können; die Formatfehler selbst
/// kommen aus `DocumentPackageError` im portablen Modell.
enum DocumentReadError: LocalizedError {
    case missingDocumentFile

    var errorDescription: String? {
        switch self {
        case .missingDocumentFile:
            return "Dem Dokument fehlt die Datei „\(DocumentPackage.documentFileName)“."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .missingDocumentFile:
            return "Das Paket ist beschädigt oder gar kein Assemblage-Dokument. "
                + "Über „Ablage › Zurücksetzen auf“ lässt sich eine ältere Version öffnen."
        }
    }
}

extension DocumentPackageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            return "Das Dokument wurde mit einer neueren Version von Assemblage "
                + "erstellt (Format \(version))."
        case .missingReferencedFiles(let names):
            return "Im Dokument fehlen \(names.count) Bilddatei(en)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedFormatVersion:
            // Öffnen und Sichern würde die unbekannten Daten wegwerfen.
            return "Bitte Assemblage aktualisieren."
        case .missingReferencedFiles(let names):
            return "Fehlend: " + names.joined(separator: ", ")
        }
    }
}
