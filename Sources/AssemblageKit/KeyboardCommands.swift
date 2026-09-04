import AppKit
import AssemblageModel

/// Was eine Taste auslöst (Plan 9, Phase 4: „Tastenkürzel für Power-User").
enum KeyboardCommand: Equatable {
    case selectTool(CanvasTool)
    /// Versatz in Leinwandpunkten.
    case nudge(dx: Double, dy: Double)
    case setOpacity(Double)
}

@MainActor
enum KeyboardCommands {

    /// Versatz pro Tastendruck, mit Umschalttaste gröber.
    private static let nudgeStep: Double = 1
    private static let coarseNudgeStep: Double = 10

    /// Übersetzt eine Taste in einen Befehl.
    ///
    /// `isEditingText` ist keine Feinheit, sondern der Kern: Diese Tasten
    /// tragen bewusst **keine** Befehlstaste — sonst wären sie im Alltag zu
    /// umständlich. Genau deshalb kollidieren sie mit jedem Textfeld. Wer
    /// einen Titel schreibt, würde bei jedem „b" das Werkzeug wechseln.
    static func command(
        forCharacters characters: String,
        modifiers: NSEvent.ModifierFlags,
        isEditingText: Bool
    ) -> KeyboardCommand? {
        guard !isEditingText else { return nil }

        // Mit Befehlstaste gehören die Tasten dem Menü — ⌘V ist Einsetzen,
        // ⌘0 ist Originalgrösse.
        guard !modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option) else {
            return nil
        }
        guard let zeichen = characters.lowercased().first else { return nil }

        if let richtung = arrowDirection(zeichen) {
            let schritt = modifiers.contains(.shift) ? coarseNudgeStep : nudgeStep
            return .nudge(dx: richtung.dx * schritt, dy: richtung.dy * schritt)
        }

        // Umschalttaste ist nur für die Pfeiltasten vorgesehen; „B" und „b"
        // sollen dasselbe tun, aber ⇧1 ist ein Ausrufezeichen und kein Befehl.
        guard !modifiers.contains(.shift) else { return nil }

        // Werkzeugtasten nach der Konvention verbreiteter
        // Gestaltungsprogramme — wer von dort kommt, kennt sie bereits.
        switch zeichen {
        case "v": return .selectTool(.select)
        case "c": return .selectTool(.crop)
        case "b": return .selectTool(.brush)
        default: break
        }

        // Ziffern setzen die Deckkraft, ebenfalls verbreitete Konvention.
        // „0" steht dabei für volle Deckkraft, nicht für null — eine Ebene
        // versehentlich unsichtbar zu machen wäre die unangenehmere Deutung.
        if let ziffer = zeichen.wholeNumberValue, (0...9).contains(ziffer) {
            return .setOpacity(ziffer == 0 ? 1 : Double(ziffer) / 10)
        }
        return nil
    }

    private static func arrowDirection(_ zeichen: Character) -> (dx: Double, dy: Double)? {
        switch zeichen.unicodeScalars.first?.value {
        case UInt32(NSLeftArrowFunctionKey): return (-1, 0)
        case UInt32(NSRightArrowFunctionKey): return (1, 0)
        // y wächst nach unten: „oben" heisst kleineres y.
        case UInt32(NSUpArrowFunctionKey): return (0, -1)
        case UInt32(NSDownArrowFunctionKey): return (0, 1)
        default: return nil
        }
    }

    /// Führt einen Befehl aus. Ohne ausgewählte Ebene passiert nichts.
    static func perform(_ command: KeyboardCommand, in state: DocumentState) {
        guard let id = state.selectedLayerID, let document = state.owner else { return }

        switch command {
        case .selectTool:
            // Der Werkzeugwechsel gehört der Werkzeugleiste, nicht dem
            // Dokument — er ist keine Änderung, die man widerrufen können soll.
            break

        case .nudge(let dx, let dy):
            // Zusammengefasst, damit zehn Tastendrücke nicht zehn
            // Undo-Schritte ergeben.
            document.modifyCoalescing("Ebene bewegen", targetID: id) {
                try? $0.updateLayer(id: id) { ebene in
                    ebene.transform.x += dx
                    ebene.transform.y += dy
                }
            }

        case .setOpacity(let wert):
            document.modify("Deckkraft ändern") {
                try? $0.updateLayer(id: id) { $0.opacity = wert.clamped(to: 0...1) }
            }
        }
    }
}
