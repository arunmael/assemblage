import AppKit
import UniformTypeIdentifiers
import AssemblageModel

/// Bedienung rund um den Export (Plan 5.8): Menübefehl „Exportieren…" und der
/// dazugehörige `NSSavePanel` mit Zubehöransicht für Format, Qualität und
/// Grösse.
///
/// Ein `NSSavePanel` lässt sich nicht sinnvoll automatisiert bedienen, daher
/// steckt die eigentliche Logik in `ExportPanelLogic` — reine, von AppKit-
/// Präsentation unabhängige Funktionen/Typen, die `ExportPanelTests` direkt
/// prüft. `ExportPanelController` bindet das nur noch an `NSSavePanel`,
/// `NSPopUpButton` &c.

// MARK: - Logik (testbar ohne NSSavePanel)

/// Export-Dateiformat zur Auswahl im Sichern-Dialog.
enum ExportFormat: String, CaseIterable, Equatable {
    case png
    case jpeg

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        }
    }

    /// PNG ist verlustfrei und kennt keine Qualitätsstufe — der Regler ergibt
    /// nur bei JPEG einen Sinn (Aufgabe Punkt 2).
    var supportsQuality: Bool { self == .jpeg }
}

/// Skalierungsfaktor-Presets für den Export, passend zu den Canvas-Vorlagen
/// aus Plan 5.1 (Aufgabe Punkt 2: „1×, 2×, 3×").
enum ExportScaleOption: CaseIterable, Equatable {
    case x1
    case x2
    case x3

    var factor: Double {
        switch self {
        case .x1: return 1
        case .x2: return 2
        case .x3: return 3
        }
    }

    var displayName: String {
        switch self {
        case .x1: return "1×"
        case .x2: return "2×"
        case .x3: return "3×"
        }
    }
}

/// Fehler beim Schreiben der Export-Datei — getrennt von
/// `DocumentExporter.ExportError`, das nur das *Rendern* betrifft. Ein
/// gerendertes Bild kann trotzdem am Schreiben scheitern (kein
/// Schreibrecht, Platte voll, Ziel existiert nicht mehr).
enum ExportWriteError: LocalizedError {
    case writeFailed(underlying: Error)

    var errorDescription: String? {
        "Die exportierte Datei liess sich nicht speichern."
    }

    var failureReason: String? {
        switch self {
        case .writeFailed(let underlying):
            return underlying.localizedDescription
        }
    }
}

enum ExportPanelLogic {

    /// Leitet den vorgeschlagenen Dateinamen aus dem Dokumentnamen ab
    /// (Aufgabe Punkt 3): ohne die `.assemblage`-Endung, mit sinnvollem
    /// Ersatz für einen leeren Namen. Namen mit anderen Punkten (Daten,
    /// Versionsnummern) bleiben unangetastet — nur ein exaktes
    /// `.assemblage`-Suffix wird entfernt.
    @MainActor
    static func suggestedFileName(forDocumentDisplayName displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Export" }

        let suffix = "." + AssemblageDocument.fileExtension
        if trimmed.lowercased().hasSuffix(suffix.lowercased()) {
            return String(trimmed.dropLast(suffix.count))
        }
        return trimmed
    }

    /// Zielgrösse in Pixeln für einen Skalierungsfaktor — dieselbe Rechnung
    /// wie `DocumentExporter.targetSize(forCanvas:scale:)`, hier nur erneut
    /// benannt, damit die Zubehöransicht nicht direkt vom Export-Kern
    /// abhängen muss.
    static func pixelSize(canvas: CanvasSize, scale: Double) -> CGSize {
        DocumentExporter.targetSize(forCanvas: canvas, scale: scale)
    }

    /// Menschenlesbare Pixelgrösse für die Zubehöransicht (Aufgabe Punkt 2:
    /// „2160 × 2160 Pixel").
    static func formattedPixelSize(canvas: CanvasSize, scale: Double) -> String {
        let size = pixelSize(canvas: canvas, scale: scale)
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        return "\(width) × \(height) Pixel"
    }

    /// Rendert und schreibt die Export-Datei. Läuft komplett asynchron
    /// (Plan 2.1) über `DocumentExporter`; Schreibfehler werden als
    /// `ExportWriteError` gemeldet statt still zu verschwinden.
    static func performExport(
        document: AssemblageModel.Document,
        resources: DocumentResources,
        format: ExportFormat,
        scale: Double,
        quality: Double,
        to url: URL
    ) async throws {
        let targetSize = pixelSize(canvas: document.canvas, scale: scale)

        let data: Data
        switch format {
        case .png:
            data = try await DocumentExporter.pngData(of: document, resources: resources, targetSize: targetSize)
        case .jpeg:
            data = try await DocumentExporter.jpegData(of: document, resources: resources, targetSize: targetSize, quality: quality)
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportWriteError.writeFailed(underlying: error)
        }
    }
}

// MARK: - Präsentation

/// Baut den Sichern-Dialog auf und führt den Export durch. Eine Instanz pro
/// laufendem Export, gehalten in `activeControllers`, damit sie weder
/// vorzeitig freigegeben wird noch derselbe Export doppelt angestossen
/// werden kann (Aufgabe Punkt 4).
@MainActor
final class ExportPanelController: NSObject {

    /// Ein laufender Export pro Dokument — verhindert doppeltes Anstossen
    /// und hält den Controller (und damit seine Closures) am Leben, bis der
    /// Hintergrund-Task fertig ist.
    private static var activeControllers: [ObjectIdentifier: ExportPanelController] = [:]

    private let document: AssemblageDocument
    private weak var window: NSWindow?

    private var format: ExportFormat = .png
    private var scaleOption: ExportScaleOption = .x1
    private var quality: Double = 0.9

    private var savePanel: NSSavePanel?
    private var formatPopUp: NSPopUpButton!
    private var scalePopUp: NSPopUpButton!
    private var qualitySlider: NSSlider!
    private var qualityValueLabel: NSTextField!
    private var qualityRowViews: [NSView] = []
    private var pixelSizeLabel: NSTextField!

    private var progressAlert: NSAlert?
    private var progressIndicator: NSProgressIndicator?

    private init(document: AssemblageDocument, window: NSWindow) {
        self.document = document
        self.window = window
    }

    /// Einstiegspunkt aus dem Menü. Läuft für dasselbe Dokument bereits ein
    /// Export, wird der Aufruf ignoriert statt einen zweiten Dialog/Export
    /// zu starten.
    static func present(for document: AssemblageDocument, host window: NSWindow) {
        let key = ObjectIdentifier(document)
        guard activeControllers[key] == nil else { return }

        let controller = ExportPanelController(document: document, window: window)
        activeControllers[key] = controller
        controller.presentSavePanel {
            activeControllers[key] = nil
        }
    }

    // MARK: - Sichern-Dialog

    private func presentSavePanel(completion: @escaping () -> Void) {
        let panel = NSSavePanel()
        savePanel = panel
        panel.title = "Exportieren"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ExportPanelLogic.suggestedFileName(forDocumentDisplayName: document.displayName)
        panel.allowedContentTypes = [format.contentType]
        panel.accessoryView = makeAccessoryView()
        applyFileExtension()
        updatePixelSizeLabel()

        guard let window else {
            completion()
            return
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { completion(); return }
            guard response == .OK, let url = panel.url else {
                completion()
                return
            }
            self.beginExport(to: url, completion: completion)
        }
    }

    // MARK: - Zubehöransicht

    private func makeAccessoryView() -> NSView {
        formatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        for option in ExportFormat.allCases {
            formatPopUp.addItem(withTitle: option.displayName)
        }
        formatPopUp.selectItem(at: ExportFormat.allCases.firstIndex(of: format) ?? 0)
        formatPopUp.target = self
        formatPopUp.action = #selector(formatChanged(_:))

        let formatRow = labelledRow(label: "Format:", control: formatPopUp)

        qualitySlider = NSSlider(value: quality, minValue: 0, maxValue: 1, target: self, action: #selector(qualityChanged(_:)))
        qualitySlider.isContinuous = true
        qualityValueLabel = NSTextField(labelWithString: percentageText(quality))
        qualityValueLabel.alignment = .right
        qualityValueLabel.translatesAutoresizingMaskIntoConstraints = false
        qualityValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let qualityControls = NSStackView(views: [qualitySlider, qualityValueLabel])
        qualityControls.orientation = .horizontal
        qualityControls.spacing = 6
        let qualityRow = labelledRow(label: "Qualität:", control: qualityControls)
        qualityRowViews = [qualityRow]

        scalePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        for option in ExportScaleOption.allCases {
            scalePopUp.addItem(withTitle: option.displayName)
        }
        scalePopUp.selectItem(at: ExportScaleOption.allCases.firstIndex(of: scaleOption) ?? 0)
        scalePopUp.target = self
        scalePopUp.action = #selector(scaleChanged(_:))

        pixelSizeLabel = NSTextField(labelWithString: "")
        pixelSizeLabel.textColor = .secondaryLabelColor

        let sizeControls = NSStackView(views: [scalePopUp, pixelSizeLabel])
        sizeControls.orientation = .horizontal
        sizeControls.spacing = 8
        let sizeRow = labelledRow(label: "Grösse:", control: sizeControls)

        let stack = NSStackView(views: [formatRow, qualityRow, sizeRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        updateQualityRowVisibility()
        return container
    }

    private func labelledRow(label: String, control: NSView) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let row = NSStackView(views: [labelField, control])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func percentageText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // MARK: - Steuerelement-Reaktionen

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        format = ExportFormat.allCases[sender.indexOfSelectedItem]
        applyFileExtension()
        updateQualityRowVisibility()
    }

    @objc private func qualityChanged(_ sender: NSSlider) {
        quality = sender.doubleValue
        qualityValueLabel.stringValue = percentageText(quality)
    }

    @objc private func scaleChanged(_ sender: NSPopUpButton) {
        scaleOption = ExportScaleOption.allCases[sender.indexOfSelectedItem]
        updatePixelSizeLabel()
    }

    /// Die Dateiendung des Panels muss der Formatwahl folgen (Aufgabe
    /// Punkt 2) — sonst exportiert man ein PNG namens „bild.jpg".
    private func applyFileExtension() {
        guard let panel = savePanel else { return }
        panel.allowedContentTypes = [format.contentType]

        let currentName = panel.nameFieldStringValue as NSString
        let baseName = currentName.deletingPathExtension.isEmpty ? currentName as String : currentName.deletingPathExtension
        panel.nameFieldStringValue = baseName + "." + format.fileExtension
    }

    private func updateQualityRowVisibility() {
        let showsQuality = format.supportsQuality
        for view in qualityRowViews {
            view.isHidden = !showsQuality
        }
        qualitySlider.isEnabled = showsQuality
    }

    private func updatePixelSizeLabel() {
        pixelSizeLabel.stringValue = ExportPanelLogic.formattedPixelSize(
            canvas: document.state.document.canvas,
            scale: scaleOption.factor
        )
    }

    // MARK: - Export durchführen

    private func beginExport(to url: URL, completion: @escaping () -> Void) {
        showProgress()

        let exportDocument = document.state.document
        let resources = document.state.resources
        let format = self.format
        let scale = scaleOption.factor
        let quality = self.quality

        Task { @MainActor [weak self] in
            do {
                try await ExportPanelLogic.performExport(
                    document: exportDocument,
                    resources: resources,
                    format: format,
                    scale: scale,
                    quality: quality,
                    to: url
                )
            } catch {
                self?.presentError(error)
            }
            self?.hideProgress()
            completion()
        }
    }

    /// Ein sichtbarer Hinweis, dass gearbeitet wird (Aufgabe Punkt 4) —
    /// blockiert dabei nichts anderes im System, nur den erneuten Aufruf
    /// über `activeControllers`.
    private func showProgress() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Exportiere…"
        alert.informativeText = "Das Bild wird gerendert und gespeichert."

        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        alert.accessoryView = indicator
        progressIndicator = indicator
        progressAlert = alert

        alert.beginSheetModal(for: window)
    }

    private func hideProgress() {
        progressIndicator?.stopAnimation(nil)
        if let sheetWindow = progressAlert?.window, let parent = window {
            parent.endSheet(sheetWindow)
        }
        progressAlert = nil
        progressIndicator = nil
    }

    /// Verständlicher deutscher Fehlerdialog statt stillem Scheitern
    /// (Aufgabe Punkt 5) — über den Dokument-Mechanismus, damit er an
    /// dasselbe Fenster gehängt wird wie andere Dokumentfehler.
    private func presentError(_ error: Error) {
        document.presentError(error)
    }
}
