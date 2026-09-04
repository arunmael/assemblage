// Diese Datei stellt die Bereinigung von Dokumentdaten vor dem Speichern sicher.
// Da der standardmäßige JSONEncoder bei nicht-endlichen Double-Werten (NaN und Infinity)
// mit einem Fehler abbricht, würde jeder solche Wert im Dokumentmodell das Speichern unmöglich machen.
// Um katastrophalen Datenverlust für den Benutzer zu verhindern, werden diese Werte
// durch visuell sinnvolle und sichere Standardwerte ersetzt.
// Intakte Dokumente bleiben von dieser Bereinigung vollkommen unberührt.

import Foundation

/// Ersetzt nicht endliche Zahlen durch brauchbare Werte.
public protocol Sanitizable {
    /// Diese Struktur ohne `nan` und ohne `infinity`.
    func sanitized() -> Self
}

extension Double {
    /// Dieser Wert, oder `fallback`, wenn er nicht endlich ist.
    public func finite(or fallback: Double) -> Double {
        // Ein nicht-endlicher Wert kann von JSONEncoder nicht serialisiert werden.
        // Wir weichen auf den Fallback aus, um den Speicherprozess zu retten.
        self.isFinite ? self : fallback
    }
}


extension Point: Sanitizable {
    public func sanitized() -> Point {
        // Der Ursprung (0,0) ist der sicherste mathematische Ankerpunkt.
        Point(
            x: x.finite(or: 0),
            y: y.finite(or: 0)
        )
    }
}

extension Rect: Sanitizable {
    public func sanitized() -> Rect {
        // Eine Breite oder Höhe von 0 würde das Element unsichtbar und unselektierbar machen.
        // Daher ist 1 der minimale sichere Standardwert für die Ausdehnung.
        Rect(
            x: x.finite(or: 0),
            y: y.finite(or: 0),
            width: width.finite(or: 1),
            height: height.finite(or: 1)
        )
    }
}

extension Size: Sanitizable {
    /// Eine Ausdehnung ohne Fläche liesse sich weder sehen noch anfassen,
    /// deshalb ein Punkt statt null.
    public func sanitized() -> Size {
        Size(
            width: width.finite(or: 1),
            height: height.finite(or: 1)
        )
    }

    /// Als **Leinwand** gelesen. `CanvasSize` ist nur ein anderer Name für
    /// `Size`, kann also keine eigene Bereinigung haben — der Ersatzwert
    /// unterscheidet sich aber: Eine Leinwand von einem Punkt wäre zwar
    /// gültig, aber unbrauchbar, und der Nutzer hielte sein Dokument für
    /// zerstört.
    func sanitizedAsCanvas() -> Size {
        Size(
            width: width.finite(or: 1000),
            height: height.finite(or: 1000)
        )
    }
}

extension Transform2D: Sanitizable {
    public func sanitized() -> Transform2D {
        // Skalierung von 0 würde das Element verschwinden lassen.
        // Wir fallen auf die neutrale Identitäts-Transformation zurück.
        Transform2D(
            x: x.finite(or: 0),
            y: y.finite(or: 0),
            scaleX: scaleX.finite(or: 1),
            scaleY: scaleY.finite(or: 1),
            rotationDegrees: rotationDegrees.finite(or: 0)
        )
    }
}

extension ImageAdjustments: Sanitizable {
    public func sanitized() -> ImageAdjustments {
        // 0 entspricht dem neutralen Zustand ohne Bildverfremdung.
        ImageAdjustments(
            brightness: brightness.finite(or: 0),
            contrast: contrast.finite(or: 0),
            saturation: saturation.finite(or: 0),
            warmth: warmth.finite(or: 0),
            blurRadius: blurRadius.finite(or: 0),
            sharpenAmount: sharpenAmount.finite(or: 0)
        )
    }
}

extension Glow: Sanitizable {
    public func sanitized() -> Glow {
        // Ein defekter Effekt wird deaktiviert (Radius/Intensität auf 0),
        // um visuelle Artefakte oder extremes Rendering zu verhindern.
        Glow(
            radius: radius.finite(or: 0),
            colorHex: colorHex,
            intensity: intensity.finite(or: 0)
        )
    }
}

extension Shadow: Sanitizable {
    public func sanitized() -> Shadow {
        // Ein fehlerhafter Schatten wird unsichtbar geschaltet,
        // um das Layout nicht durch unendliche Offsets zu zerschießen.
        Shadow(
            offsetX: offsetX.finite(or: 0),
            offsetY: offsetY.finite(or: 0),
            radius: radius.finite(or: 0),
            colorHex: colorHex,
            opacity: opacity.finite(or: 0)
        )
    }
}

extension LayerEffects: Sanitizable {
    public func sanitized() -> LayerEffects {
        // Optionale Effekte werden nur bereinigt, wenn sie existieren.
        LayerEffects(
            glow: glow?.sanitized(),
            shadow: shadow?.sanitized()
        )
    }
}

extension LayerTexture: Sanitizable {
    public func sanitized() -> LayerTexture {
        // Deckkraft 0.5 stellt sicher, dass die Textur weder unsichtbar ist
        // noch den Hintergrund komplett verdeckt, falls der Wert korrupt war.
        LayerTexture(
            imageReference: imageReference,
            blendMode: blendMode,
            opacity: opacity.finite(or: 0.5),
            scale: scale.finite(or: 1)
        )
    }
}

extension QuadDistortion: Sanitizable {
    public func sanitized() -> QuadDistortion {
        // Alle vier Eckpunkte müssen valide Koordinaten aufweisen,
        // da sonst die mathematische Projektion der Ebene fehlschlägt.
        QuadDistortion(
            topLeft: topLeft.sanitized(),
            topRight: topRight.sanitized(),
            bottomRight: bottomRight.sanitized(),
            bottomLeft: bottomLeft.sanitized()
        )
    }
}

extension ImageLayerContent: Sanitizable {
    public func sanitized() -> ImageLayerContent {
        ImageLayerContent(
            originalFileReference: originalFileReference,
            cropRect: cropRect?.sanitized(),
            adjustments: adjustments.sanitized()
        )
    }
}

extension TextLayerContent: Sanitizable {
    public func sanitized() -> TextLayerContent {
        // Eine Schriftgröße von 0 oder kleiner macht den Text unlesbar.
        // 48pt ist eine gut sichtbare Standardgröße für die Wiederherstellung.
        TextLayerContent(
            string: string,
            fontName: fontName,
            fontSize: fontSize.finite(or: 48),
            colorHex: colorHex,
            alignment: alignment
        )
    }
}

extension ShapeLayerContent: Sanitizable {
    public func sanitized() -> ShapeLayerContent {
        // Ein Eckenradius von 0 ist der sicherste, mathematisch neutrale Zustand.
        ShapeLayerContent(
            kind: kind,
            size: size.sanitized(),
            cornerRadius: cornerRadius.finite(or: 0),
            fillColorHex: fillColorHex,
            pointCount: pointCount
        )
    }
}

extension LayerContent: Sanitizable {
    public func sanitized() -> LayerContent {
        switch self {
        case .image(let content):
            return .image(content.sanitized())
        case .text(let content):
            return .text(content.sanitized())
        case .shape(let content):
            return .shape(content.sanitized())
        }
    }
}

extension Layer: Sanitizable {
    public func sanitized() -> Layer {
        // Eine Ebene mit korrupter Deckkraft muss sichtbar bleiben (1.0),
        // damit der Nutzer sie im Editor wahrnimmt und nicht fälschlicherweise
        // von einem Datenverlust ausgeht.
        Layer(
            id: id,
            name: name,
            isVisible: isVisible,
            opacity: opacity.finite(or: 1.0),
            blendMode: blendMode,
            transform: transform.sanitized(),
            mask: mask, // Maske hat keine Double-Felder, bleibt unverändert
            distortion: distortion?.sanitized(),
            effects: effects?.sanitized(),
            texture: texture?.sanitized(),
            content: content.sanitized()
        )
    }
}

extension Document: Sanitizable {
    public func sanitized() -> Document {
        // Das Dokument delegiert die Bereinigung rekursiv nach unten.
        // Bereits valide Werte werden durch die Implementierung von `finite(or:)`
        // nicht verändert, wodurch die Integrität intakter Dokumente gewahrt bleibt.
        Document(
            canvas: canvas.sanitizedAsCanvas(),
            layers: layers.map { $0.sanitized() }
        )
    }
}
