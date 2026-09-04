import AppKit

/// Trägt die aufklappende Werkzeugleiste als Spalte des Fensters.
///
/// Eine eigene Spalte statt einer schwebenden Ansicht über der Leinwand: Beim
/// Aufklappen verdeckte eine schwebende Leiste genau den Bildrand, an dem man
/// gerade arbeitet.
///
/// Die Spalte bleibt dabei durchgehend schmal. Nur die Leiste **darin** wird
/// beim Überfahren breiter und legt sich über die Leinwand — genau so, wie
/// sich das ausgeblendete Dock hervorschiebt, ohne dass der Bildschirm
/// darunter kleiner wird. Würde stattdessen die Spalte wachsen, rückte die
/// ganze Leinwand bei jeder Mausbewegung zur Seite.
@MainActor
final class ToolSidebarViewController: NSViewController {

    let sidebar = ToolSidebarView(items: ToolSidebarView.defaultItems)

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sidebar)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            // Die Spalte selbst behält die schmale Breite; die Leiste darf
            // darüber hinauswachsen, ohne das Layout zu verschieben.
            container.widthAnchor.constraint(equalToConstant: ToolSidebarView.collapsedWidth)
        ])

        view = container
    }
}
