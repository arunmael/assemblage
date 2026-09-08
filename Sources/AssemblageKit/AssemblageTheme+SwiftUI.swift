import SwiftUI

/// SwiftUI-Brücke zu `AssemblageTheme`, für `LayerListView`/`InspectorView` —
/// dieselben Werte wie auf der AppKit-Seite, nur als `Color` statt `NSColor`.
///
/// Bewusst berechnete statt gespeicherter Eigenschaften: `AssemblageTheme`
/// liefert seit dem zweiten Erscheinungsbild je nach Nutzerwahl
/// unterschiedliche Werte — `static let` würde den zuerst gelesenen Wert für
/// die Lebensdauer des Prozesses einfrieren.
extension AssemblageTheme {
    @MainActor
    enum SwiftUIColor {
        static var textPrimary: Color { Color(AssemblageTheme.textPrimary) }
        static var textSecondary: Color { Color(AssemblageTheme.textSecondary) }
        static var textTertiary: Color { Color(AssemblageTheme.textTertiary) }
        static var accent: Color { Color(AssemblageTheme.accent) }
        static var accentDark: Color { Color(AssemblageTheme.accentDark) }
        static var accentSoft: Color { Color(AssemblageTheme.accentSoft) }
        static var divider: Color { Color(AssemblageTheme.divider) }
        static var inputBackground: Color { Color(AssemblageTheme.inputBackground) }
    }
}
