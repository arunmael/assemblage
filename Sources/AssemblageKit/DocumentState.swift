import Foundation
import Combine
import AssemblageModel

/// Der beobachtbare Zustand eines geöffneten Dokuments.
///
/// Die Bindeglied-Klasse zwischen den beiden UI-Welten aus Plan 7.1: Der
/// AppKit-Canvas und die SwiftUI-Paletten (Ebenenliste, Inspector) hängen
/// beide hier dran und sehen dadurch immer denselben Stand.
///
/// Geändert wird ausschliesslich über `AssemblageDocument.modify(_:_:)` —
/// nur so landet jede Änderung im Undo-Stack.
@MainActor
final class DocumentState: ObservableObject {

    @Published fileprivate(set) var document: AssemblageModel.Document
    /// Assemblage kennt bewusst nur Einfachauswahl — Mehrfachauswahl würde
    /// jedes Werkzeug und jeden Inspector-Regler verdoppeln (Plan 4: „Ein
    /// Fenster, ein Fokus").
    @Published var selectedLayerID: UUID?

    private(set) var resources: DocumentResources
    private(set) var images: ImageStore

    /// Das Dokument, dem dieser Zustand gehört.
    ///
    /// Schwach, weil das Dokument den Zustand besitzt — andersherum wäre es
    /// ein Zyklus und das Dokument bliebe nach dem Schliessen im Speicher.
    /// Ansichten ändern über `owner?.modify(_:_:)`; nur so landet alles im
    /// Undo-Stack.
    weak var owner: AssemblageDocument?

    init(document: AssemblageModel.Document, resources: DocumentResources) {
        self.document = document
        self.resources = resources
        self.images = ImageStore(resources: resources)
    }

    /// Übernimmt einen frisch von der Platte gelesenen Stand.
    ///
    /// Ersetzt bewusst den *Inhalt* statt das ganze Objekt: Bei „Zurücksetzen
    /// auf…" und beim Versions-Browser (Plan 2.1) hängen Ebenenliste,
    /// Inspector und Canvas bereits an diesem `DocumentState`. Ein neues
    /// Objekt würden sie nicht bemerken — das Fenster zeigte weiter den alten
    /// Stand.
    func replaceContents(document newDocument: AssemblageModel.Document, resources newResources: DocumentResources) {
        resources = newResources
        images = ImageStore(resources: newResources)
        selectedLayerID = nil
        document = newDocument
    }

    var selectedLayer: Layer? {
        selectedLayerID.flatMap { document.layer(withID: $0) }
    }

    /// Nur `AssemblageDocument` darf schreiben (siehe `fileprivate(set)`).
    fileprivate func setDocument(_ newValue: AssemblageModel.Document) {
        document = newValue
        // Zeigt die Auswahl auf eine gelöschte Ebene (etwa nach einem Undo),
        // wird sie aufgehoben statt ins Leere zu zeigen.
        if let id = selectedLayerID, document.layer(withID: id) == nil {
            selectedLayerID = nil
        }
    }
}

extension AssemblageDocument {

    /// Einziger Weg, das Dokument zu ändern.
    ///
    /// Für Undo wird der komplette vorherige `Document`-Wert festgehalten.
    /// Das ist hier bewusst so: `Document` enthält nur Zahlen, Text und
    /// Datei-*Referenzen* — keine Bildpuffer. Ein Schnappschuss kostet also
    /// wenige Kilobyte, und der Undo-Stack kann keine grossen `CIImage`-Puffer
    /// festhalten, wovor Plan 2.1 ausdrücklich warnt. Ein feingliedriger
    /// Undo-Stack mit Einzeloperationen wäre komplizierter und würde genau
    /// diese Garantie aufgeben.
    func modify(_ actionName: String, _ body: (inout AssemblageModel.Document) -> Void) {
        let before = state.document
        var updated = before
        body(&updated)

        // Ein Regler, der auf demselben Wert stehen bleibt, soll keinen
        // Undo-Schritt erzeugen.
        guard updated != before else { return }

        state.setDocument(updated)

        // Während einer Interaktion nicht einzeln registrieren — den einen
        // Schritt setzt `endInteraction(actionName:)` ans Ende.
        guard !isInteracting else { return }

        registerUndo(restoring: before, actionName: actionName)
    }

    private func registerUndo(restoring before: AssemblageModel.Document, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.modify(actionName) { $0 = before }
            }
        }
        undoManager?.setActionName(actionName)
    }

    // MARK: - Zusammenhängende Änderungen

    /// Beginnt eine Interaktion — ein Ziehen auf dem Canvas, ein gehaltener
    /// Regler.
    ///
    /// Alles zwischen hier und `endInteraction(actionName:)` wird zu **einem**
    /// Undo-Schritt zusammengefasst. Ohne das hinterlässt ein einziges
    /// Verschieben so viele Schritte, wie die Maus Zwischenmeldungen liefert,
    /// und man drückt vierzigmal ⌘Z, bis sichtbar etwas passiert.
    func beginInteraction() {
        // Verschachtelte Aufrufe ignorieren: Der äusserste Zustand ist der,
        // auf den zurückgesetzt werden soll.
        guard interactionSnapshot == nil else { return }
        interactionSnapshot = state.document
    }

    /// Schliesst die Interaktion ab und setzt den einen Undo-Schritt.
    ///
    /// Gefahrlos, wenn keine Interaktion läuft oder wenn sich nichts geändert
    /// hat (ein Klick, der die Ebene nur berührt hat) — beides kommt in der
    /// Praxis vor und darf den Undo-Stack nicht verwirren.
    func endInteraction(actionName: String) {
        guard let before = interactionSnapshot else { return }
        interactionSnapshot = nil

        guard state.document != before else { return }
        registerUndo(restoring: before, actionName: actionName)
    }

    var isInteracting: Bool { interactionSnapshot != nil }
}
