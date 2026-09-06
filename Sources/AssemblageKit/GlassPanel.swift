import AppKit

/// Ein schwebendes „Glas"-Panel, wie es das Liquid-Glass-Mockup für jede
/// aufgesetzte Fläche verwendet (Werkzeugleisten-Cluster, Ebenenliste,
/// Eigenschaften-Panel, Zoom- und Verlaufs-Pille).
///
/// `NSVisualEffectView` liefert den eigentlichen Weichzeichner (macOS kann
/// `backdrop-filter: blur() saturate()` nicht 1:1 als CSS-Wert annehmen —
/// das System-Material ist die nächstliegende native Entsprechung). Eine
/// zusätzliche Farbebene darüber gleicht den im Mockup vorgegebenen Farbton
/// an, den das reine Systemmaterial nicht trifft. Rand, Ecken-Radius und
/// Schatten kommen zuletzt vom Panel selbst, nicht vom Weichzeichner-View —
/// der maskiert an seinen eigenen Ecken, ein Schatten auf einer maskierten
/// Ebene würde aber mitmaskiert und verschwinden.
@MainActor
final class GlassPanel: NSView {

    /// Bei `true` wird der Ecken-Radius bei jedem Layout auf die halbe Höhe
    /// gesetzt (Kapsel-/Pillenform, z. B. Zoom- und Verlaufsleiste) statt
    /// einen festen Radius zu behalten.
    var isPill: Bool {
        didSet { needsLayout = true }
    }

    private var fixedCornerRadius: CGFloat
    private let effectView = NSVisualEffectView()
    private let tint = NSView()
    /// Maskiert wie `effectView`/`tint`, aus demselben Grund: Ohne eigene
    /// Maskierung lief Inhalt, der die verfügbare Höhe sprengt (z. B. ein
    /// zu langer Hinweistext im Eigenschaften-Panel), einfach über die
    /// abgerundete Ecke hinaus auf den nackten Fensterhintergrund weiter,
    /// statt sauber am Panelrand abgeschnitten zu werden.
    private let contentContainer = NSView()

    /// Die eigentliche Inhaltsansicht des Panels (z. B. ein `NSStackView`
    /// oder eine `NSHostingView`). Füllt den Innenraum vollständig aus.
    var content: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let content else { return }
            content.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
        }
    }

    init(cornerRadius: CGFloat, isPill: Bool = false) {
        self.fixedCornerRadius = cornerRadius
        self.isPill = isPill
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true

        tint.wantsLayer = true
        tint.layer?.backgroundColor = AssemblageTheme.glassBackground.cgColor

        contentContainer.wantsLayer = true

        for view in [effectView, tint, contentContainer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        layer?.borderWidth = 1
        layer?.borderColor = AssemblageTheme.glassBorder.cgColor
        layer?.shadowColor = AssemblageTheme.glassShadowColor.cgColor
        layer?.shadowRadius = AssemblageTheme.glassShadowRadius
        layer?.shadowOffset = AssemblageTheme.glassShadowOffset
        layer?.shadowOpacity = 1
        applyCornerRadius(fixedCornerRadius)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    override func layout() {
        super.layout()
        applyCornerRadius(isPill ? bounds.height / 2 : fixedCornerRadius)
    }

    private func applyCornerRadius(_ radius: CGFloat) {
        layer?.cornerRadius = radius
        effectView.layer?.cornerRadius = radius
        effectView.layer?.masksToBounds = true
        tint.layer?.cornerRadius = radius
        tint.layer?.masksToBounds = true
        contentContainer.layer?.cornerRadius = radius
        contentContainer.layer?.masksToBounds = true
    }
}
