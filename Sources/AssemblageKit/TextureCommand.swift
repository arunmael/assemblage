import AppKit
import UniformTypeIdentifiers
import AssemblageModel

/// Warum ein Texturbefehl nicht ausgeführt werden konnte.
enum TextureCommandOutcome: Equatable {
    case applied
    case removed
    /// Keine Ebene ausgewählt.
    case noSelection
    /// Die Datei liess sich nicht lesen.
    case unreadableFile
    /// Die ausgewählte Ebene hatte gar keine Textur.
    case nothingToRemove
}

@MainActor
enum TextureCommand {

    /// Hängt die Bilddatei unter `url` als Textur an die ausgewählte Ebene.
    /// Ohne Dialog — dadurch prüfbar.
    @discardableResult
    static func applyTexture(from url: URL, in state: DocumentState) -> TextureCommandOutcome {
        guard let layerID = state.selectedLayerID else {
            return .noSelection
        }

        // Vorab-Prüfung, um unnötige Dateioperationen zu vermeiden, falls die Ebene fehlt.
        guard state.document.layer(withID: layerID) != nil else {
            return .noSelection
        }

        // Einlesen der Datei; schlägt dies fehl, wird die Operation ohne Seiteneffekte abgebrochen.
        guard let data = try? Data(contentsOf: url) else {
            return .unreadableFile
        }

        // Fallback auf PNG für den Fall, dass die URL keine verwertbare Dateiendung liefert.
        let fileExtension = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let reference = state.resources.addOriginal(data, fileExtension: fileExtension)

        guard let owner = state.owner else {
            return .noSelection
        }

        owner.modify("Textur hinzufügen") { document in
            // Erneute Prüfung innerhalb der Transaktion, um Race Conditions bei schnellen Änderungen zu vermeiden.
            try? document.updateLayer(id: layerID) { layer in
                layer.texture = LayerTexture(
                    imageReference: reference,
                    blendMode: .multiply,
                    opacity: 0.5,
                    scale: 1
                )
            }
        }

        return .applied
    }

    /// Nimmt der ausgewählten Ebene ihre Textur.
    @discardableResult
    static func removeTexture(in state: DocumentState) -> TextureCommandOutcome {
        guard let layerID = state.selectedLayerID else {
            return .noSelection
        }

        guard let layer = state.document.layer(withID: layerID) else {
            return .noSelection
        }

        // Verhindert leere Undo-Schritte auf dem Undo-Stack, wenn gar keine Textur vorhanden ist.
        guard layer.texture != nil else {
            return .nothingToRemove
        }

        guard let owner = state.owner else {
            return .noSelection
        }

        owner.modify("Textur entfernen") { document in
            try? document.updateLayer(id: layerID) { layer in
                layer.texture = nil
            }
        }

        return .removed
    }

    /// Fragt nach einer Bilddatei und wendet sie an. Der Dialog gehört
    /// bewusst NICHT in `applyTexture(from:in:)`, damit die Logik ohne
    /// Fenster prüfbar bleibt.
    static func chooseTexture(in state: DocumentState, host: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.message = "Bild als Textur wählen"
        panel.prompt = "Verwenden"

        // Explizite Isolation auf den MainActor, da NSOpenPanel-Callbacks auf dem Main-Thread laufen müssen.
        let completion: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            
            let outcome = applyTexture(from: url, in: state)
            
            // Dem Benutzer wird nur bei einem echten Lesefehler ein Feedback gegeben.
            if outcome == .unreadableFile {
                let alert = NSAlert()
                alert.messageText = "Fehler beim Laden"
                alert.informativeText = "Die ausgewählte Bilddatei konnte nicht gelesen werden."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                
                if let hostWindow = host {
                    alert.beginSheetModal(for: hostWindow)
                } else {
                    alert.runModal()
                }
            }
        }

        if let hostWindow = host {
            panel.beginSheetModal(for: hostWindow, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
