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
        zustand.observeUndoManager(undoManager)
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
    private(set) var lastManualBackupAt: Date?

    /// Legt die zusätzliche Dateiversion an.
    ///
    /// Ersetzbar, damit Tests ohne echten Dateizugriff prüfen können, *wann*
    /// gesichert wird. Die Vorgabe kopiert das ganze Dokumentpaket und läuft
    /// deshalb im Hintergrund — auf dem Hauptthread wäre das nach jedem
    /// bewussten Sichern eine sichtbare Blockade.
    var manualFileVersionCreator: (URL) -> Void = { url in
        DispatchQueue.global(qos: .utility).async {
            do {
                try NSFileVersion.addOfItem(at: url, withContentsOf: url, options: [])
            } catch {
                NSLog("Manuelles Backup für %@ fehlgeschlagen: %@", url.path, error.localizedDescription)
            }
        }
    }

    // MARK: - Verhalten

    /// Schaltet Autosave, Absturz-Wiederherstellung und die Versionsverwaltung
    /// ein (Plan 2.1). Ohne das speichert `NSDocument` erst auf Befehl.
    override class var autosavesInPlace: Bool { true }

    override class var preservesVersions: Bool { true }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController())
    }

    /// Frisch angelegt statt aus einer Datei geöffnet — dann fragt das Fenster
    /// beim ersten Anzeigen nach der Leinwandgrösse (Nutzer-Auftrag). `read`
    /// setzt das Kennzeichen zurück, denn ein geöffnetes Dokument bringt seine
    /// Grösse längst mit.
    ///
    /// `nonisolated(unsafe)`, weil `read(from:ofType:)` ausdrücklich nicht an
    /// den Haupt-Thread gebunden ist (siehe dort). Ungefährlich: Geschrieben
    /// wird genau einmal während des Ladens, gelesen erst danach beim Anzeigen
    /// des Fensters — beides nacheinander, nie gleichzeitig.
    ///
    /// Nicht über `fileURL == nil` lösbar: Eine Dokument-Kopie („Duplizieren")
    /// hat ebenfalls keine Datei, bringt ihre Leinwandgrösse aber mit und darf
    /// deshalb nicht danach fragen. Sie läuft — anders als ein neues Dokument —
    /// durch `read`.
    nonisolated(unsafe) private var isNewDocument = true

    /// Fragt beim Anlegen sofort nach der Leinwandgrösse, statt kommentarlos
    /// mit der Vorgabe zu starten.
    ///
    /// In `showWindows()` statt im Fenstercontroller, weil nur hier der
    /// Unterschied zwischen „neu angelegt" und „geöffnet" bekannt ist — und
    /// weil es genau einmal läuft: Das Kennzeichen fällt sofort, bevor der
    /// Dialog überhaupt erscheint.
    override func showWindows() {
        super.showWindows()

        guard isNewDocument else { return }
        isNewDocument = false
        guard let window = windowControllers.first?.window else { return }
        CanvasResizePanelController.present(for: self, host: window, purpose: .newDocument)
    }

    // MARK: - Lesen & Schreiben

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            completionHandler(error)
            self?.handleCompletedSave(error: error, operation: saveOperation)
        }
    }

    /// Eigene Methode, damit der erfolgreiche Abschluss ohne den im
    /// Swift-Package-Testbundle fehlenden AppKit-Dokumenttyp prüfbar bleibt.
    func handleCompletedSave(error: Error?, operation: NSDocument.SaveOperationType) {
        let isManualSave = operation == .saveOperation || operation == .saveAsOperation
        guard error == nil, isManualSave else { return }
        createManualBackupIfNeeded()
    }

    /// Hält einen bewusst gesicherten Stand zusätzlich zu den automatischen
    /// Dokumentversionen fest, höchstens einmal pro halbe Stunde.
    private func createManualBackupIfNeeded() {
        let now = Date()
        if let lastManualBackupAt,
           now.timeIntervalSince(lastManualBackupAt) <= 30 * 60 {
            return
        }

        guard let fileURL else { return }
        manualFileVersionCreator(fileURL)
        lastManualBackupAt = now
    }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        // Ein gelesenes Dokument bringt seine Leinwandgrösse mit; es darf beim
        // Öffnen nicht nach einer neuen gefragt werden (siehe `showWindows`).
        isNewDocument = false

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
