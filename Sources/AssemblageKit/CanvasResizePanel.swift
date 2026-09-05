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

    private let document: AssemblageDocument
    private weak var window: NSWindow?
    private var widthField: NSTextField!
    private var heightField: NSTextField!

    private init(document: AssemblageDocument, window: NSWindow) {
        self.document = document
        self.window = window
    }

    static func present(for document: AssemblageDocument, host window: NSWindow) {
        let key = UUID()
        let controller = CanvasResizePanelController(document: document, window: window)
        activeControllers[key] = controller
        controller.presentAlert {
            activeControllers[key] = nil
        }
    }

    private func presentAlert(completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Leinwandgrösse ändern"
        alert.informativeText = "Die Ebenen behalten ihre Grösse und Position relativ zur oberen linken Ecke."
        alert.addButton(withTitle: "Anwenden")
        alert.addButton(withTitle: "Abbrechen")
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

            self.document.modify("Leinwandgrösse ändern") { document in
                document.canvas = newSize
            }
            completion()
        }
    }

    private func makeAccessoryView() -> NSView {
        let canvas = document.state.document.canvas
        widthField = NSTextField(string: String(format: "%g", canvas.width))
        heightField = NSTextField(string: String(format: "%g", canvas.height))
        widthField.setAccessibilityLabel("Breite")
        heightField.setAccessibilityLabel("Höhe")

        let widthLabel = NSTextField(labelWithString: "Breite:")
        let heightLabel = NSTextField(labelWithString: "Höhe:")
        let grid = NSGridView(views: [
            [widthLabel, widthField],
            [heightLabel, heightField]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 160
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 58))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
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
