import CoreGraphics
import CoreImage
import ImageIO
import AppKit
import Vision
import Foundation

/// Automatisches Freistellen (Plan 5.4, 7.3): trennt das Hauptmotiv vom
/// Hintergrund über `VNGenerateForegroundInstanceMaskRequest` aus dem
/// Vision-Framework — on-device, ohne eigenes ML-Modell, funktioniert
/// offline.
///
/// Wichtig laut Plan 5.4: Das Ergebnis dieser Automatik ist **immer nur der
/// Startpunkt**, danach wird von Hand mit dem Pinsel nachgebessert. Diese
/// Datei liefert deshalb bewusst nur die Maskenpixel, keine UI und keine
/// Anbindung an `LayerMask`/`DocumentResources` — das Verdrahten mit Ebene
/// und Dokument geschieht an anderer Stelle.
enum ForegroundMasking {

    // MARK: - Fehler und Ergebnis

    /// Eigener Fehlertyp statt `try!`/erzwungenem Auspacken (Plan 2.1).
    enum MaskingError: Error, LocalizedError, Equatable {
        case invalidImage
        case visionRequestFailed(String)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "Die Bilddaten liessen sich nicht lesen."
            case .visionRequestFailed(let grund):
                return "Die Vision-Anfrage ist fehlgeschlagen: \(grund)"
            case .encodingFailed:
                return "Die berechnete Maske liess sich nicht als PNG kodieren."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .invalidImage:
                return "Bitte ein anderes Bildformat versuchen."
            case .visionRequestFailed, .encodingFailed:
                return "Das Hauptmotiv lässt sich stattdessen von Hand mit dem Pinsel freistellen."
            }
        }
    }

    /// Ergebnis eines Freistell-Versuchs. Bewusst kein optionaler Rückgabewert
    /// (`Data?`) für den Kein-Motiv-Fall: Ein Bild einer leeren Wand, auf dem
    /// Vision nichts findet, ist kein Fehler, sondern ein normales, erwartbares
    /// Ergebnis (Plan 2.1 verlangt, genau das von einem echten Fehler zu
    /// unterscheiden) — `.noSubjectFound` macht diesen Fall im Typsystem
    /// explizit, statt ihn mit „kaputtes Bild“ oder „Vision nicht verfügbar“
    /// zu vermischen, die beide über `throws` laufen.
    enum Result {
        /// PNG-Alphamaskendaten in denselben Pixelmassen wie das Quellbild.
        case mask(Data)
        /// Vision hat auf diesem Bild keine Vordergrund-Instanz gefunden.
        case noSubjectFound
    }

    // MARK: - Öffentliche, asynchrone Schnittstelle

    /// Erstellt eine Alphamaske für das Hauptmotiv aus Bilddaten.
    ///
    /// Rechenintensiv (Vision-Analyse plus Herunter-/Hochskalieren), deshalb
    /// `async` und frei von `@MainActor` (Plan 2.1 „Rechenintensive Vorgänge
    /// laufen asynchron“) — die Arbeit läuft explizit auf einem
    /// Hintergrund-Task, damit die Oberfläche währenddessen nicht einfriert.
    static func generateMask(from imageData: Data) async throws -> Result {
        guard let image = ImageDecoding.decode(imageData) else {
            throw MaskingError.invalidImage
        }
        return try await generateMask(from: image)
    }

    /// Dieselbe Freistell-Logik, ausgehend von einem bereits dekodierten Bild
    /// — vermeidet ein doppeltes Dekodieren, wenn der Aufrufer das `CGImage`
    /// (z. B. über `ImageStore`) schon in der Hand hat.
    static func generateMask(from image: CGImage) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            try synchronousGenerateMask(from: image)
        }.value
    }

    // MARK: - Synchroner Kern

    /// Bewusst nicht Teil der öffentlichen Schnittstelle: Vision-Aufrufe sind
    /// blockierend, dieser Weg läuft nur innerhalb von `Task.detached` oben.
    private static func synchronousGenerateMask(from originalImage: CGImage) throws -> Result {
        // Herunterskalieren vor der Analyse, danach die Maske wieder
        // hochziehen: `VNGenerateForegroundInstanceMaskRequest` braucht auf
        // einem 50-Megapixel-Foto spürbar länger, das Ergebnis wird davon
        // aber nicht sichtbar genauer — Vision arbeitet intern ohnehin mit
        // einer reduzierten Auflösung. Die Analyse an einer deutlich
        // kleineren Kopie zu machen und die binäre Maske (harte Kante, kein
        // Verlust an Kantenschärfe durch Interpolation) am Ende wieder auf
        // die Originalgrösse zu bringen, ist hier die richtige Wahl, weil
        // Plan 5.4 die Automatik ausdrücklich nur als groben Startpunkt
        // sieht, der danach mit dem Pinsel nachgebessert wird — für einen
        // Startpunkt genügt die Präzision einer verkleinerten Analyse, und
        // die App bleibt auch bei sehr grossen Fotos reaktionsschnell
        // (Plan 2.1). Kleine/mittlere Bilder bleiben unangetastet.
        let analysisLimit: CGFloat = 2048
        let longestSide = CGFloat(max(originalImage.width, originalImage.height))
        let analysisImage: CGImage
        if longestSide > analysisLimit {
            let scale = analysisLimit / longestSide
            guard let scaled = resized(originalImage, scale: scale) else {
                throw MaskingError.visionRequestFailed("Herunterskalieren für die Analyse fehlgeschlagen.")
            }
            analysisImage = scaled
        } else {
            analysisImage = originalImage
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: analysisImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw MaskingError.visionRequestFailed(error.localizedDescription)
        }

        guard let observation = request.results?.first else {
            // Keine Beobachtung überhaupt — z. B. ein Bild ohne jedes
            // erkennbare Objekt (leere Wand, reine Textur).
            return .noSubjectFound
        }

        // Mehrere Instanzen (z. B. zwei Personen im Bild): Vision liefert sie
        // als `IndexSet` in `allInstances`. Plan 5.4 spricht vom
        // *Hauptmotiv*, nicht von "allen Motiven" — deshalb werden hier
        // bewusst **alle** gefundenen Instanzen zusammen freigestellt statt
        // nur eine einzelne auszuwählen. Begründung: Vision liefert keine
        // Rangfolge nach "Wichtigkeit" zwischen mehreren Instanzen, jeder
        // Versuch, eine davon algorithmisch als "die Hauptperson" auszulegen
        // (z. B. die grösste Fläche), wäre eine geratene Heuristik, die bei
        // einem Doppelporträt regelmässig die falsche Hälfte wegschneiden
        // würde. Da das Ergebnis laut Plan ohnehin nur der Startpunkt ist,
        // der von Hand mit dem Pinsel nachgebessert wird, ist "alle
        // erkannten Vordergrund-Objekte auf einmal, Hintergrund weg" der
        // sicherere Startpunkt: Er verliert nie ungefragt ein Motiv, und zu
        // viel Maske lässt sich mit dem Pinsel leichter wegnehmen als zu
        // wenig Maske ergänzen (dafür bräuchte man sonst wieder eine exakte
        // Kante, die man von Hand kaum so sauber trifft wie Vision selbst).
        guard !observation.allInstances.isEmpty else {
            return .noSubjectFound
        }

        let maskPixelBuffer: CVPixelBuffer
        do {
            maskPixelBuffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances,
                from: handler,
                croppedToInstancesExtent: false
            )
        } catch {
            throw MaskingError.visionRequestFailed(error.localizedDescription)
        }

        let maskCIImage = CIImage(cvPixelBuffer: maskPixelBuffer)
        guard var maskCGImage = RenderContext.shared.createCGImage(maskCIImage, from: maskCIImage.extent) else {
            throw MaskingError.visionRequestFailed("Die Maske liess sich nicht zu einem Bild zusammensetzen.")
        }

        // Die Maske stammt von der (ggf. verkleinerten) Analysekopie —
        // zurück auf die Originalgrösse bringen, sonst passt sie beim
        // späteren Rendern nicht auf das Bild (siehe Kommentar oben).
        if maskCGImage.width != originalImage.width || maskCGImage.height != originalImage.height {
            guard let upscaled = resized(
                maskCGImage,
                targetWidth: originalImage.width,
                targetHeight: originalImage.height
            ) else {
                throw MaskingError.visionRequestFailed("Die Maske liess sich nicht auf die Originalgrösse bringen.")
            }
            maskCGImage = upscaled
        }

        guard let pngData = pngData(from: maskCGImage) else {
            throw MaskingError.encodingFailed
        }

        return .mask(pngData)
    }

    // MARK: - Hilfsmittel

    private static func resized(_ image: CGImage, scale: CGFloat) -> CGImage? {
        resized(
            image,
            targetWidth: max(1, Int((CGFloat(image.width) * scale).rounded())),
            targetHeight: max(1, Int((CGFloat(image.height) * scale).rounded()))
        )
    }

    private static func resized(_ image: CGImage, targetWidth: Int, targetHeight: Int) -> CGImage? {
        guard targetWidth > 0, targetHeight > 0 else { return nil }
        // Eigene Farbraum statt fest verdrahtetem Grau: Diese Funktion skaliert
        // sowohl das farbige Analysebild (vor Vision) als auch die spätere
        // Graustufen-Maske (danach) — ein fest eingebauter Graufarbraum würde
        // dem Analysebild vor der Vision-Anfrage seine Farbe nehmen.
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: image.alphaInfo == .none
                ? CGImageAlphaInfo.none.rawValue
                : CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    private static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
