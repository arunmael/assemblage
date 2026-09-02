import Foundation

/// Eine Farbe mit Komponenten im Bereich 0…1.
///
/// Im Dokument werden Farben als Hex-String gespeichert (`#RRGGBB` bzw.
/// `#RRGGBBAA`) — gut lesbar und stabil über Formatversionen hinweg. Die
/// Umrechnung liegt bewusst hier im plattformunabhängigen Modell und nicht
/// im AppKit-Code, damit sie in der CI getestet wird.
public struct RGBA: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `nil` bei ungültiger Eingabe — der Aufrufer weicht dann auf eine
    /// Ersatzfarbe aus, statt abzustürzen (Plan 2.1).
    public init?(hex: String) {
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        digits = digits.uppercased()

        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy({ $0.isHexDigit }),
              let value = UInt32(digits, radix: 16)
        else { return nil }

        // Sechsstellig: implizit voll deckend.
        let bits = digits.count == 8 ? value : (value << 8) | 0xFF

        self.init(
            red: Double((bits >> 24) & 0xFF) / 255,
            green: Double((bits >> 16) & 0xFF) / 255,
            blue: Double((bits >> 8) & 0xFF) / 255,
            alpha: Double(bits & 0xFF) / 255
        )
    }

    public var hexString: String {
        func byte(_ component: Double) -> Int {
            Int((component.clamped(to: 0...1) * 255).rounded())
        }
        let base = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        // Deckende Farben ohne Alpha-Anteil schreiben: hält document.json
        // lesbar und vermeidet unnötige Unterschiede zwischen Versionen.
        guard byte(alpha) != 255 else { return base }
        return base + String(format: "%02X", byte(alpha))
    }

    public static let black = RGBA(red: 0, green: 0, blue: 0)
    public static let white = RGBA(red: 1, green: 1, blue: 1)
}
