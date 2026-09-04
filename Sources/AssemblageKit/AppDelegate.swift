import AppKit

/// Baut das Menü von Hand auf.
///
/// Eine SwiftPM-App hat kein MainMenu.nib — ohne dieses Menü gäbe es weder
/// „Ablage › Öffnen" noch „Bearbeiten › Widerrufen", und beides ist für eine
/// dokumentbasierte App nicht optional.
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private let crashReporter = CrashReporter()

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        crashReporter.start()
    }

    /// Beim Klick aufs Dock-Symbol ohne offenes Fenster: leeres Dokument
    /// anlegen, statt gar nichts zu tun.
    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Menüaufbau

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        for menu in [appMenu(), fileMenu(), editMenu(), layerMenu(), insertMenu(), viewMenu(), windowMenu(), helpMenu()] {
            let item = NSMenuItem()
            item.submenu = menu
            mainMenu.addItem(item)
        }
        return mainMenu
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Assemblage")
        menu.addItem(withTitle: "Über Assemblage", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        let services = NSMenuItem(title: "Dienste", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Assemblage ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Andere ausblenden", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "Alle einblenden", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Assemblage beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "Ablage")
        menu.addItem(withTitle: "Neu", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        menu.addItem(withTitle: "Öffnen…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")

        let recent = NSMenuItem(title: "Benutzte Dokumente", action: nil, keyEquivalent: "")
        // Genau dieser Menütitel lässt AppKit die Liste selbst füllen.
        recent.submenu = NSMenu(title: "Benutzte Dokumente")
        recent.submenu?.addItem(withTitle: "Einträge löschen", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        menu.addItem(recent)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Schliessen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Sichern…", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")

        let duplicate = NSMenuItem(title: "Duplizieren", action: #selector(NSDocument.duplicate(_:)), keyEquivalent: "s")
        duplicate.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(duplicate)

        let export = NSMenuItem(title: "Exportieren…", action: #selector(DocumentWindowController.exportDocument(_:)), keyEquivalent: "e")
        export.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(export)

        menu.addItem(withTitle: "Zurücksetzen auf…", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        // „Alle Versionen durchsuchen…" — der Zeitmaschinen-Browser aus
        // Plan 2.1, den NSDocument mitbringt.
        menu.addItem(withTitle: "Alle Versionen durchsuchen…", action: #selector(NSDocument.browseVersions(_:)), keyEquivalent: "")
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Bearbeiten")
        menu.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")

        let redo = NSMenuItem(title: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Löschen", action: #selector(NSText.delete(_:)), keyEquivalent: "\u{8}")
        menu.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())

        let foregroundMask = NSMenuItem(
            title: "Motiv freistellen",
            action: #selector(DocumentWindowController.removeSubjectBackground(_:)),
            keyEquivalent: "m"
        )
        foregroundMask.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(foregroundMask)
        return menu
    }

    private func shapeTemplateMenu() -> NSMenuItem {
        let vorlagen = NSMenu(title: "Formvorlage")
        vorlagen.addItem(withTitle: "Dreieck",
                         action: #selector(DocumentWindowController.insertTriangleLayer(_:)),
                         keyEquivalent: "")
        vorlagen.addItem(withTitle: "Fünfeck",
                         action: #selector(DocumentWindowController.insertPentagonLayer(_:)),
                         keyEquivalent: "")
        vorlagen.addItem(withTitle: "Sechseck",
                         action: #selector(DocumentWindowController.insertHexagonLayer(_:)),
                         keyEquivalent: "")
        vorlagen.addItem(withTitle: "Stern",
                         action: #selector(DocumentWindowController.insertStarLayer(_:)),
                         keyEquivalent: "")
        vorlagen.addItem(withTitle: "Herz",
                         action: #selector(DocumentWindowController.insertHeartLayer(_:)),
                         keyEquivalent: "")
        vorlagen.addItem(withTitle: "Pfeil",
                         action: #selector(DocumentWindowController.insertArrowLayer(_:)),
                         keyEquivalent: "")
        vorlagen.addItem(withTitle: "Sprechblase",
                         action: #selector(DocumentWindowController.insertSpeechBubbleLayer(_:)),
                         keyEquivalent: "")

        let eintrag = NSMenuItem(title: "Formvorlage", action: nil, keyEquivalent: "")
        eintrag.submenu = vorlagen
        return eintrag
    }

    private func insertMenu() -> NSMenu {
        let menu = NSMenu(title: "Einfügen")
        let text = NSMenuItem(
            title: "Text",
            action: #selector(DocumentWindowController.insertTextLayer(_:)),
            keyEquivalent: "t"
        )
        text.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(text)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rechteck", action: #selector(DocumentWindowController.insertRectangleLayer(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Abgerundetes Rechteck", action: #selector(DocumentWindowController.insertRoundedRectangleLayer(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Ellipse", action: #selector(DocumentWindowController.insertEllipseLayer(_:)), keyEquivalent: "")
        menu.addItem(shapeTemplateMenu())
        menu.addItem(.separator())

        let templates = NSMenu(title: "Collage-Vorlage")
        templates.addItem(
            withTitle: "2×2-Raster",
            action: #selector(DocumentWindowController.applyGrid2x2Template(_:)),
            keyEquivalent: ""
        )
        templates.addItem(
            withTitle: "3×3-Raster",
            action: #selector(DocumentWindowController.applyGrid3x3Template(_:)),
            keyEquivalent: ""
        )
        templates.addItem(
            withTitle: "Polaroid-Stapel",
            action: #selector(DocumentWindowController.applyPolaroidStackTemplate(_:)),
            keyEquivalent: ""
        )
        let templateItem = NSMenuItem(title: "Collage-Vorlage", action: nil, keyEquivalent: "")
        templateItem.submenu = templates
        menu.addItem(templateItem)
        return menu
    }

    /// Ebenenbefehle stehen in einem eigenen Menü: Sie wirken auf die
    /// Dokumentauswahl, während „Bearbeiten“ die systemweiten Text- und
    /// Zwischenablagebefehle enthält.
    private func layerMenu() -> NSMenu {
        let menu = NSMenu(title: "Ebene")

        let visibility = NSMenuItem(
            title: "Ebene ein-/ausblenden",
            action: #selector(DocumentWindowController.toggleSelectedLayerVisibility(_:)),
            keyEquivalent: "h"
        )
        visibility.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(visibility)

        let delete = NSMenuItem(
            title: "Ebene löschen",
            action: #selector(DocumentWindowController.deleteSelectedLayer(_:)),
            keyEquivalent: "\u{8}"
        )
        delete.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(delete)
        menu.addItem(.separator())

        let vergleich = NSMenuItem(
            title: "Vorher/Nachher vergleichen",
            action: #selector(DocumentWindowController.toggleLayerComparison(_:)),
            keyEquivalent: "\\"
        )
        vergleich.keyEquivalentModifierMask = [.command]
        menu.addItem(vergleich)
        menu.addItem(.separator())

        let distort = NSMenuItem(
            title: "Verziehen",
            action: #selector(DocumentWindowController.selectDistortTool(_:)),
            keyEquivalent: "d"
        )
        distort.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(distort)
        menu.addItem(
            withTitle: "Verzerrung zurücksetzen",
            action: #selector(DocumentWindowController.resetSelectedLayerDistortion(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())

        // „Rasterbild“ macht die Einbahnstrasse im Titel sichtbar. Eine
        // Rückfrage bei jeder Umwandlung wäre unnötig bevormundend, weil der
        // Vorgang vollständig widerrufbar ist.
        menu.addItem(
            withTitle: "In Objekt umwandeln (Rasterbild)",
            action: #selector(DocumentWindowController.flattenSelectedLayer(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())

        menu.addItem(withTitle: "Ebene nach oben", action: #selector(DocumentWindowController.moveSelectedLayerUp(_:)), keyEquivalent: "]")
        menu.addItem(withTitle: "Ebene nach unten", action: #selector(DocumentWindowController.moveSelectedLayerDown(_:)), keyEquivalent: "[")

        let toTop = NSMenuItem(
            title: "Ebene ganz nach oben",
            action: #selector(DocumentWindowController.moveSelectedLayerToTop(_:)),
            keyEquivalent: "]"
        )
        toTop.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(toTop)

        let toBottom = NSMenuItem(
            title: "Ebene ganz nach unten",
            action: #selector(DocumentWindowController.moveSelectedLayerToBottom(_:)),
            keyEquivalent: "["
        )
        toBottom.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(toBottom)
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "Darstellung")
        menu.addItem(withTitle: "Einzoomen", action: #selector(DocumentWindowController.zoomIn(_:)), keyEquivalent: "+")
        menu.addItem(withTitle: "Auszoomen", action: #selector(DocumentWindowController.zoomOut(_:)), keyEquivalent: "-")
        menu.addItem(withTitle: "Originalgrösse", action: #selector(DocumentWindowController.zoomToActualSize(_:)), keyEquivalent: "0")
        menu.addItem(withTitle: "Ins Fenster einpassen", action: #selector(DocumentWindowController.zoomToFit(_:)), keyEquivalent: "9")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Vollbild", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Fenster")
        menu.addItem(withTitle: "Im Dock ablegen", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoomen", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Alle nach vorne bringen", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Hilfe")
        let reports = NSMenuItem(
            title: "Diagnoseberichte anzeigen",
            action: #selector(showDiagnosticsReports(_:)),
            keyEquivalent: ""
        )
        reports.target = self
        menu.addItem(reports)
        NSApp.helpMenu = menu
        return menu
    }

    @objc private func showDiagnosticsReports(_ sender: Any?) {
        do {
            try FileManager.default.createDirectory(
                at: CrashReporter.diagnosticsDirectory,
                withIntermediateDirectories: true
            )
            guard NSWorkspace.shared.open(CrashReporter.diagnosticsDirectory) else {
                throw DiagnosticsFolderError.couldNotOpen
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

enum DiagnosticsFolderError: LocalizedError {
    case couldNotOpen

    var errorDescription: String? {
        "Der Ordner mit den Diagnoseberichten konnte nicht geöffnet werden."
    }

    var recoverySuggestion: String? {
        "Die Berichte liegen unter ~/Library/Logs/Assemblage/."
    }
}
