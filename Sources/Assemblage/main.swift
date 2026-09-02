import AppKit
import AssemblageKit

// Einstiegspunkt der App. Eine SwiftPM-App hat kein MainMenu.nib und keinen
// NSPrincipalClass-Aufhänger, der das sonst erledigt — Delegate und Menü
// werden deshalb hier von Hand gesetzt (siehe AppDelegate).

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
