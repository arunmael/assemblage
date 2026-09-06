import SwiftUI

/// SwiftUI-Brücke zu `AssemblageTheme`, für `LayerListView`/`InspectorView` —
/// dieselben Werte wie auf der AppKit-Seite, nur als `Color` statt `NSColor`.
extension AssemblageTheme {
    enum SwiftUIColor {
        static let textPrimary = Color(AssemblageTheme.textPrimary)
        static let textSecondary = Color(AssemblageTheme.textSecondary)
        static let textTertiary = Color(AssemblageTheme.textTertiary)
        static let accent = Color(AssemblageTheme.accent)
        static let accentDark = Color(AssemblageTheme.accentDark)
        static let accentSoft = Color(AssemblageTheme.accentSoft)
        static let divider = Color(AssemblageTheme.divider)
        static let inputBackground = Color(AssemblageTheme.inputBackground)
    }
}
