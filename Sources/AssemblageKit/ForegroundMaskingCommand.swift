import AppKit
import Foundation
import AssemblageModel

// MARK: - Dokumentlogik (ohne Darstellung testbar)

/// Ergebnis des Befehls, getrennt von den Maskenpixeln selbst. Dadurch kann
/// die Darstellung den normalen Kein-Motiv-Fall ruhig erklären, während nur
/// echte Fehler über `throws` in den Fehlerdialog gelangen.
enum ForegroundMaskingCommandOutcome: Equatable {
    case applied
    case noSubjectFound
    case notApplicable
}

/// Fehler der Befehlsanbindung; Vision-eigene Fehler werden unverändert
/// weitergereicht, damit ihre verständlichen Hinweise erhalten bleiben.
enum ForegroundMaskingCommandError: LocalizedError {
    case missingOriginal

    var errorDescription: String? {
        switch self {
        case .missingOriginal:
            return "Das Originalbild der Ebene fehlt oder ist beschädigt."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .missingOriginal:
            return "Bitte das Dokument aus einer früheren Version wiederherstellen oder das Bild erneut einsetzen."
        }
    }
}

enum ForegroundMaskingCommandLogic {

    /// Austauschbare Abhängigkeit für Tests: Vision ist ein Modell und darf
    /// auf demselben Bild zwischen Systemversionen anders entscheiden. Die
    /// Befehlslogik muss dagegen deterministisch auf die drei möglichen
    /// Resultate reagieren.
    typealias MaskGenerator = (Data) async throws -> ForegroundMasking.Result

    /// Nur eine ausgewählte Bildebene ist ein gültiges Befehlsziel.
    @MainActor
    static func selectedImageLayerID(in state: DocumentState) -> UUID? {
        guard let layer = state.selectedLayer, case .image = layer.content else { return nil }
        return layer.id
    }

    /// Holt das Original, lässt die Maske asynchron erzeugen und übernimmt
    /// sie als genau eine widerrufbare Dokumentänderung. Vor dem Schreiben
    /// wird das Ziel nochmals geprüft: Die Ebene könnte während der laufenden
    /// Vision-Anfrage gelöscht worden sein.
    @MainActor
    static func perform(
        in state: DocumentState,
        generateMask: MaskGenerator
    ) async throws -> ForegroundMaskingCommandOutcome {
        try await perform(
            layerID: selectedImageLayerID(in: state),
            in: state,
            generateMask: generateMask
        )
    }

    /// Variante mit beim Anstoss festgehaltener Ebene. Während die Analyse
    /// läuft, darf die Auswahl wechseln, ohne dass dadurch ein anderes Bild
    /// als das ursprünglich beauftragte bearbeitet wird.
    @MainActor
    static func perform(
        layerID: UUID?,
        in state: DocumentState,
        generateMask: MaskGenerator
    ) async throws -> ForegroundMaskingCommandOutcome {
        guard let layerID,
              let layer = state.document.layer(withID: layerID),
              case .image(let imageContent) = layer.content,
              let owner = state.owner
        else {
            return .notApplicable
        }

        guard let originalData = state.resources.data(for: imageContent.originalFileReference) else {
            throw ForegroundMaskingCommandError.missingOriginal
        }

        let result = try await generateMask(originalData)
        guard case .mask(let maskData) = result else {
            return .noSubjectFound
        }

        guard let currentLayer = state.document.layer(withID: layerID),
              case .image(let currentImageContent) = currentLayer.content,
              currentImageContent.originalFileReference == imageContent.originalFileReference
        else {
            return .notApplicable
        }

        let maskReference = state.resources.addMask(maskData)
        owner.modify("Motiv freistellen") { document in
            _ = try? document.updateLayer(id: layerID) { layer in
                layer.mask = LayerMask(
                    maskImageReference: maskReference,
                    source: .automaticForegroundInstance
                )
            }
        }
        return .applied
    }
}

// MARK: - AppKit-Darstellung

/// Bindet die testbare Logik an Fortschrittsanzeige und Hinweise. Laufende
/// Vorgänge werden pro Dokument und Ebene gehalten; dadurch wird ein zweiter
/// Anstoss für dieselbe Ebene auch aus einem weiteren Fenster ignoriert.
@MainActor
final class ForegroundMaskingCommandController {

    private struct OperationKey: Hashable {
        let document: ObjectIdentifier
        let layerID: UUID
    }

    private static var activeControllers: [OperationKey: ForegroundMaskingCommandController] = [:]

    private let document: AssemblageDocument
    private weak var window: NSWindow?
    private let key: OperationKey
    private var progressAlert: NSAlert?
    private var progressIndicator: NSProgressIndicator?

    private init(document: AssemblageDocument, window: NSWindow, key: OperationKey) {
        self.document = document
        self.window = window
        self.key = key
    }

    static func canPerform(in document: AssemblageDocument) -> Bool {
        guard let layerID = ForegroundMaskingCommandLogic.selectedImageLayerID(in: document.state) else {
            return false
        }
        return activeControllers[OperationKey(document: ObjectIdentifier(document), layerID: layerID)] == nil
    }

    static func perform(in document: AssemblageDocument, host window: NSWindow) {
        guard let layerID = ForegroundMaskingCommandLogic.selectedImageLayerID(in: document.state) else { return }
        let key = OperationKey(document: ObjectIdentifier(document), layerID: layerID)
        guard activeControllers[key] == nil else { return }

        let controller = ForegroundMaskingCommandController(document: document, window: window, key: key)
        activeControllers[key] = controller
        controller.begin()
    }

    private func begin() {
        showProgress()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let outcome = try await ForegroundMaskingCommandLogic.perform(
                    layerID: key.layerID,
                    in: document.state
                ) { data in
                    try await ForegroundMasking.generateMask(from: data)
                }
                hideProgress()
                if outcome == .noSubjectFound {
                    presentNoSubjectFound()
                }
            } catch {
                hideProgress()
                document.presentError(error)
            }
            Self.activeControllers[key] = nil
        }
    }

    private func showProgress() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Motiv wird freigestellt…"
        alert.informativeText = "Assemblage analysiert das Originalbild und erstellt eine Maske."

        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        alert.accessoryView = indicator
        progressAlert = alert
        progressIndicator = indicator

        alert.beginSheetModal(for: window)
    }

    private func hideProgress() {
        progressIndicator?.stopAnimation(nil)
        if let sheetWindow = progressAlert?.window, let window {
            window.endSheet(sheetWindow)
        }
        progressAlert = nil
        progressIndicator = nil
    }

    /// Bewusst kein `presentError`: Ein Bild ohne erkennbares Motiv ist ein
    /// normales Analyseergebnis und erhält deshalb einen ruhigen Hinweis mit
    /// neutralem Symbol statt eines Fehlerdialogs.
    private func presentNoSubjectFound() {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Kein Motiv gefunden"
        alert.informativeText = "Auf diesem Bild konnte kein klar vom Hintergrund getrenntes Motiv erkannt werden. Die Ebene blieb unverändert."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
