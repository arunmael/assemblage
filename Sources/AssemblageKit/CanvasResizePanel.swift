import AppKit
import AssemblageModel

/// Die Eingabeprüfung bleibt vom Dialog getrennt, damit Dezimaltrennzeichen
/// und ungültige Grössen ohne UI-Automation geprüft werden können.
enum CanvasResizePanelLogic {

    /// Dieselbe Zahlenkonvention wie der Inspector verhindert, dass ein Wert
    /// je nach Eingabestelle einmal mit Komma und einmal nur mit Punkt gilt.
    static func validate(widthText: String, heightText: String) -> CanvasSize? {
        guard let width = InspectorEditing.number(from: widthText),
              let height = InspectorEditing.number(from: heightText),
              width.isFinite, height.isFinite,
              width > 0, height > 0
        else { return nil }

        return CanvasSize(width: width, height: height)
    }

    /// Beschriftung eines Vorlagen-Eintrags: Name plus Masse, damit man im
    /// Menü sieht, was man bekommt, ohne es erst auszuwählen.
    static func menuTitle(for preset: CanvasPreset) -> String {
        let size = preset.size
        return "\(preset.displayName)  —  \(Int(size.width)) × \(Int(size.height))"
    }
}

/// Bindet die testbare Grössenprüfung an einen AppKit-Sheet. Die Leinwand ist
/// die einzige geänderte Modelleigenschaft; Ebenen bleiben dadurch an ihrer
/// bisherigen, oben links verankerten Position und behalten ihre Transforms.
@MainActor
final class CanvasResizePanelController: NSObject {

    /// Der Sheet-Handler muss bis zum Schliessen des Dialogs einen Besitzer
    /// haben. UUID-Schlüssel erlauben trotzdem mehrere unabhängige Fenster
    /// oder Dialoge, ohne sie versehentlich zusammenzufassen.
    private static var activeControllers: [UUID: CanvasResizePanelController] = [:]

    /// Ob der Dialog eine bestehende Leinwand ändert oder die eines gerade
    /// erst angelegten Dokuments festlegt. Der zweite Fall hat andere
    /// Beschriftungen und lässt hinterher weder einen Widerrufsschritt noch
    /// ein ungesichertes Dokument zurück (siehe `apply(_:)`).
    enum Purpose {
        case resizeExisting
        case newDocument
    }

    private let document: AssemblageDocument
    private let purpose: Purpose
    private weak var window: NSWindow?
    private var widthField: NSTextField!
    private var heightField: NSTextField!
    private var presetMenu: NSPopUpButton!
    private weak var customMenuItem: NSMenuItem?

    private init(document: AssemblageDocument, window: NSWindow, purpose: Purpose) {
        self.document = document
        self.window = window
        self.purpose = purpose
    }

    static func present(
        for document: AssemblageDocument,
        host window: NSWindow,
        purpose: Purpose = .resizeExisting
    ) {
        let key = UUID()
        let controller = CanvasResizePanelController(
            document: document, window: window, purpose: purpose
        )
        activeControllers[key] = controller
        controller.presentAlert {
            activeControllers[key] = nil
        }
    }

    private func presentAlert(completion: @escaping () -> Void) {
        let alert = NSAlert()
        switch purpose {
        case .resizeExisting:
            alert.messageText = "Leinwandgrösse ändern"
            alert.informativeText = "Die Ebenen behalten ihre Grösse und Position relativ zur oberen linken Ecke."
            alert.addButton(withTitle: "Anwenden")
            alert.addButton(withTitle: "Abbrechen")
        case .newDocument:
            alert.messageText = "Neues Dokument"
            alert.informativeText = "Wähle eine Vorlage oder gib eine eigene Leinwandgrösse ein."
            alert.addButton(withTitle: "Erstellen")
            alert.addButton(withTitle: "Vorgabe behalten")
        }
        alert.accessoryView = makeAccessoryView()

        guard let window else {
            completion()
            return
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else {
                completion()
                return
            }
            guard response == .alertFirstButtonReturn else {
                completion()
                return
            }

            guard let newSize = CanvasResizePanelLogic.validate(
                widthText: self.widthField.stringValue,
                heightText: self.heightField.stringValue
            ) else {
                self.presentValidationError(completion: completion)
                return
            }

            self.apply(newSize)
            completion()
        }
    }

    /// Übernimmt die Grösse ins Dokument.
    ///
    /// Beim frisch angelegten Dokument bleibt danach weder ein Widerrufsschritt
    /// noch der „geändert"-Zustand zurück: Die Leinwandgrösse ist dort keine
    /// Bearbeitung, sondern gehört zum Anlegen — sonst fragte das Fenster beim
    /// Schliessen nach dem Sichern, obwohl noch niemand etwas gemacht hat.
    private func apply(_ newSize: CanvasSize) {
        document.modify("Leinwandgrösse ändern") { document in
            document.canvas = newSize
        }
        guard purpose == .newDocument else { return }
        document.undoManager?.removeAllActions()
        document.updateChangeCount(.changeCleared)
    }

    private func makeAccessoryView() -> NSView {
        let canvas = document.state.document.canvas
        widthField = NSTextField(string: String(format: "%g", canvas.width))
        heightField = NSTextField(string: String(format: "%g", canvas.height))
        widthField.setAccessibilityLabel("Breite")
        heightField.setAccessibilityLabel("Höhe")
        // Tippt jemand eine eigene Zahl, passt keine Vorlage mehr — das Menü
        // springt dann auf „Eigene Grösse", statt eine Vorlage anzuzeigen, die
        // gar nicht mehr gilt.
        widthField.target = self
        heightField.target = self
        widthField.action = #selector(sizeFieldChanged)
        heightField.action = #selector(sizeFieldChanged)

        presetMenu = NSPopUpButton(frame: .zero, pullsDown: false)
        presetMenu.setAccessibilityLabel("Vorlage")
        presetMenu.target = self
        presetMenu.action = #selector(presetChosen)
        var vorherPapier = false
        for vorlage in CanvasPreset.selectable {
            if vorlage.isPaperFormat, !vorherPapier, presetMenu.menu?.items.isEmpty == false {
                presetMenu.menu?.addItem(.separator())
            }
            vorherPapier = vorlage.isPaperFormat
            let eintrag = NSMenuItem(
                title: CanvasResizePanelLogic.menuTitle(for: vorlage), action: nil, keyEquivalent: ""
            )
            eintrag.representedObject = vorlage
            presetMenu.menu?.addItem(eintrag)
        }
        presetMenu.menu?.addItem(.separator())
        let eigene = NSMenuItem(title: CanvasPreset.custom(canvas).displayName, action: nil, keyEquivalent: "")
        presetMenu.menu?.addItem(eigene)
        customMenuItem = eigene
        selectMenuItem(matching: canvas)

        let presetLabel = NSTextField(labelWithString: "Vorlage:")
        let widthLabel = NSTextField(labelWithString: "Breite:")
        let heightLabel = NSTextField(labelWithString: "Höhe:")
        let grid = NSGridView(views: [
            [presetLabel, presetMenu],
            [widthLabel, widthField],
            [heightLabel, heightField]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 260
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 92))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    /// Vorlage gewählt → Breite und Höhe eintragen.
    @objc private func presetChosen() {
        guard let vorlage = presetMenu.selectedItem?.representedObject as? CanvasPreset else { return }
        widthField.stringValue = String(format: "%g", vorlage.size.width)
        heightField.stringValue = String(format: "%g", vorlage.size.height)
    }

    /// Zahl von Hand geändert → passende Vorlage einstellen, sonst „Eigene".
    @objc private func sizeFieldChanged() {
        guard let groesse = CanvasResizePanelLogic.validate(
            widthText: widthField.stringValue, heightText: heightField.stringValue
        ) else { return }
        selectMenuItem(matching: groesse)
    }

    private func selectMenuItem(matching size: CanvasSize) {
        if let vorlage = CanvasPreset.matching(size),
           let eintrag = presetMenu.menu?.items.first(where: {
               ($0.representedObject as? CanvasPreset) == vorlage
           }) {
            presetMenu.select(eintrag)
        } else {
            presetMenu.select(customMenuItem)
        }
    }

    private func presentValidationError(completion: @escaping () -> Void) {
        guard let window else {
            completion()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Ungültige Leinwandgrösse"
        alert.informativeText = "Bitte gib eine gültige Breite und Höhe grösser als 0 ein."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in completion() }
    }
}
