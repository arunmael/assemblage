import AppKit
import QuartzCore

/// Die gerenderte Bildebene: Bitmap und Rahmen als benannte Felder.
///
/// Zwei Schichten statt einer, weil ein Rahmen genau das zeigen soll, was die
/// Maske wegnimmt — den Rand. Läge er unter derselben Maske wie der Inhalt,
/// schnitte sie ihn gleich mit weg. Der Inhalt trägt deshalb Maske, Zuschnitt,
/// Anpassungsfilter und Textur, die Hülle bleibt unmaskiert und hält den
/// Rahmen darüber.
///
/// Eigene Klasse statt einer Suche nach Schichtnamen im Baum: Ein Tippfehler
/// im Namen ergäbe sonst stillschweigend `nil`, der Aufrufer fiele auf die
/// Hülle zurück, und das Bild bekäme Maske und Filter an der falschen Stelle —
/// sichtbar erst am fertigen Bild, nicht beim Übersetzen.
final class ImageContentLayer: CALayer {

    /// Trägt das Bild selbst, dazu Maske, Zuschnitt, Filter und Textur.
    let bitmap = CALayer()
    /// Liegt über dem Inhalt und bleibt bewusst unmaskiert.
    let border = CAShapeLayer()

    override init() {
        super.init()
        // `.resize` und nicht `.resizeAspect`: die Ebene hat bereits exakt das
        // Seitenverhältnis ihres Inhalts, ein Einpassen würde nur Rundungs-
        // ränder erzeugen.
        bitmap.contentsGravity = .resize
        bitmap.magnificationFilter = .trilinear
        bitmap.minificationFilter = .trilinear
        border.fillColor = nil
        addSublayer(bitmap)
        addSublayer(border)
    }

    /// Wird von Core Animation beim Kopieren einer Schicht aufgerufen (z. B.
    /// für die Darstellung während einer Animation). Ohne diesen Weg
    /// verlöre die Kopie ihre beiden Felder.
    override init(layer: Any) {
        super.init(layer: layer)
        if let vorlage = layer as? ImageContentLayer {
            bitmap.contents = vorlage.bitmap.contents
            border.path = vorlage.border.path
        }
        addSublayer(bitmap)
        addSublayer(border)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    /// Legt beide Unterschichten auf die eigene Grösse.
    func layoutContents() {
        let flaeche = CGRect(origin: .zero, size: bounds.size)
        for schicht in [bitmap, border] as [CALayer] {
            schicht.frame = flaeche
            schicht.contentsScale = contentsScale
        }
    }

    func clearBorder() {
        border.path = nil
        border.lineWidth = 0
        border.mask = nil
    }

    /// Zeichnet den Rahmen nach innen.
    ///
    /// Der Pfad dient zugleich als Maske und wird mit doppelter Strichbreite
    /// gezeichnet: Übrig bleibt die innere Hälfte des Strichs, der Rahmen ragt
    /// also nicht über die Ebenenkante hinaus. Den Pfad stattdessen um die
    /// halbe Strichbreite einwärts zu rechnen ginge nur beim Rechteck sauber —
    /// bei einem Stern oder einer Sichel ist „einwärts" keine blosse
    /// Verkleinerung.
    func drawBorder(_ pfad: CGPath, width: Double, color: CGColor) {
        border.path = pfad
        border.strokeColor = color
        border.lineWidth = width * 2

        let clip = CAShapeLayer()
        clip.frame = border.frame
        clip.contentsScale = contentsScale
        clip.path = pfad
        border.mask = clip
    }

    /// Kennzeichnet eine Bildebene, deren Originaldatei fehlt.
    static func markAsPlaceholder(_ layer: CALayer) {
        layer.contents = nil
        layer.backgroundColor = NSColor.systemGray.withAlphaComponent(0.25).cgColor
        layer.borderColor = NSColor.systemRed.cgColor
        layer.borderWidth = 2
    }
}
