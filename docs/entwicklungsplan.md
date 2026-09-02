# Entwicklungsplan: Assemblage — Foto- & Collage-App für macOS

*App-Name: Assemblage*

## 1. Vision

Eine native macOS-App für Fotobearbeitung und Collagen, die sich bewusst auf das beschränkt, was im Alltag wirklich gebraucht wird: Bilder kombinieren, freistellen/maskieren, grundlegend anpassen, sauber exportieren. Kein Photoshop-Klon mit 200 Menüpunkten, sondern ein Werkzeug, das man ohne Tutorial versteht.

**Leitsatz:** Jedes Feature muss sich rechtfertigen. Lieber fünf Werkzeuge, die exzellent funktionieren, als zwanzig, die halbherzig sind.

## 2. Nicht verhandelbare Grundanforderungen

Wichtiger als jedes einzelne Feature: Die App muss stabil, effizient und ohne Abstürze laufen. Eine App, die abstürzt oder ruckelt, ist wertlos — egal wie clean die Oberfläche ist. Das steht über allem anderen in diesem Dokument.

### 2.1 Stabilität & Performance
- **Kein Datenverlust bei Absturz:** Autosave in kurzen Intervallen sowie bei Werkzeug-/Ebenenwechseln; automatische Wiederherstellung offener Dokumente nach einem Crash
- **Mehrere Backups, automatisch und manuell:** Nicht nur ein einzelner Autosave-Stand — mehrere Versionen im Hintergrund behalten. Dafür bietet sich Apples eingebaute Dokumentenversionierung an (`NSDocument` mit aktiviertem Auto-Save liefert automatisch den bekannten "Alle Versionen durchsuchen..."-Zeitmaschine-Browser über `NSFileVersion`, kein Eigenbau nötig). Zusätzlich ein manueller Befehl ("Version jetzt sichern"), mit dem man bewusst einen benannten Stand festhält, bevor man z. B. eine riskante Änderung ausprobiert. Alte automatische Versionen nach sinnvoller Anzahl/Zeitspanne aufräumen, um Speicherplatz zu sparen
- **Speicher-Management bei grossen Bildern:** Kacheln (Tiling) grosser Fotos statt alles im RAM zu halten; keine Retain-Cycles, besonders im Undo-Stack, der sonst grosse `CIImage`-Puffer unnötig lange festhält
- **Rechenintensive Vorgänge laufen asynchron:** Filter, automatisches Freistellen und Export im Hintergrund (`DispatchQueue`/`async-await`), damit die Oberfläche nie einfriert
- **Fehler abfangen statt abstürzen:** Datei-Import/-Export, Vision-Framework-Aufrufe und Core-Image-Filterketten grundsätzlich mit Fehlerbehandlung, kein `try!`/erzwungenes Auspacken in produktivem Code
- **Automatisierte Tests** für die Kernpipeline (Kompositing, Maskierung, Export) sowie gezielte Stresstests mit sehr grossen Leinwänden und vielen Ebenen vor jedem Release
- **Crash-Reporting von Anfang an** (z. B. via `MetricKit`), um Probleme früh zu erkennen statt erst durch Nutzer-Beschwerden

### 2.2 Touch- und Apple-Pencil-Bedienung (iPad als erweiterter Bildschirm)
Seit macOS 27 „Golden Gate" unterstützt Sidecar per „Direct Touch" die direkte Fingerbedienung von Mac-Apps auf dem iPad — zusätzlich zum länger etablierten Apple Pencil. Konsequenzen für die App:

- **Apple Pencil (Druck, Neigung):** Funktioniert über Sidecar bereits als Standard-Tablet-Eingabe. Die Pinsel-Maske sollte `NSEvent`-Druckwerte (`pressure`) auswerten, damit sich die Maskenkante mit dem Pencil natürlich abstuft — genau der Anwendungsfall, für den Sidecar mit Apple Pencil ausgelegt ist
- **Direkte Fingerbedienung (macOS 27 + iPadOS 27, Apple-Silicon-Mac vorausgesetzt):** Ein Finger funktioniert automatisch wie ein Mauszeiger — Standard-AppKit-Controls (Buttons, Regler, Ebenenliste) funktionieren dadurch bereits "gratis" ohne Zusatzaufwand
- **Wichtig für die eigene Canvas-Implementierung:** Erste Testberichte zeigen, dass kleine Elemente per Finger zu Fehltippern führen — Griffpunkte, Werkzeug-Icons und Regler daher grosszügig dimensionieren, was ohnehin zur cleanen, reduzierten Optik der App passt
- **Multitouch-Gesten** (Pinch-to-Zoom auf dem Canvas) über `NSMagnificationGestureRecognizer` einbinden — wird von Sidecar Direct Touch ebenfalls unterstützt
- Voraussetzung: Mac mit Apple Silicon (aktuell ohnehin Standard) sowie ein iPad mit iPadOS 27, verbunden über Sidecar

## 3. Zielgruppe & Anwendungsfälle

- Leute, die schnell eine Collage aus mehreren Fotos bauen wollen (Social Media, Poster, Einladungen, Moodboards)
- Nutzer, die ein Objekt/eine Person freistellen und neu zusammensetzen wollen
- Kein Zielpublikum: professionelle Fotograf:innen mit RAW-Workflow oder Compositing-Profis — dafür bleibt Photoshop die richtige Wahl

## 4. Design-Prinzipien

1. **Ein Fenster, ein Fokus:** Canvas in der Mitte, Ebenen links oder rechts, Eigenschaften-Inspektor kontextabhängig — keine verschachtelten Paletten-Wolken.
2. **Progressive Disclosure:** Die Werkzeugleiste zeigt nur, was gerade relevant ist. Ist eine Textebene ausgewählt, erscheinen Text-Optionen; sonst nicht.
3. **Direkte Manipulation:** Ziehen, Skalieren, Rotieren passiert direkt auf dem Canvas mit sichtbaren Griffpunkten — keine Zahlenfelder als einziger Weg.
4. **Sofortiges visuelles Feedback:** Alle Anpassungen live sichtbar, keine "Vorschau berechnen"-Wartezeiten.
5. **Optik:** Liquid-Glass-Ästhetik, konsistent mit deinen bisherigen Tools — helle, klare Flächen, dezente Transluzenz für Paletten, keine überladenen Icons.

## 5. Feature-Set (MVP) — was wirklich rein muss

### 5.1 Import & Canvas
- Drag & Drop von Fotos direkt auf die Arbeitsfläche (aus Finder oder Fotos-App)
- Unterstützte Formate: JPEG, PNG, HEIC, TIFF
- Freie Leinwandgrösse + Vorlagen-Presets (Instagram-Post 1:1, Story 9:16, A4-Poster, etc.)

### 5.2 Ebenen (Layers)
- Einfache Ebenenliste mit Vorschaubild, Sichtbarkeits-Toggle, Umbenennen
- Reihenfolge per Drag & Drop ändern
- Deckkraft-Regler pro Ebene
- **Blend-Modi — bewusst nur eine kuratierte Auswahl:** Normal, Multiplizieren, Negativ multiplizieren (Screen), Ineinanderkopieren (Overlay), Aufhellen, Abdunkeln. Nicht die 20+ Modi aus Photoshop.

### 5.3 Anordnen & Collagieren
- Frei positionieren, skalieren, rotieren per Maus/Trackpad-Geste direkt auf dem Canvas
- Ausrichtungshilfen (Smart Guides): Zentrieren, gleicher Abstand, Kantenausrichtung zu anderen Ebenen
- Einfache Raster-/Rahmenvorlagen für klassische Collagen (z. B. 2×2-Raster, Polaroid-Stapel) als Startpunkt, danach frei editierbar
- Zuschneiden (Crop) pro Ebene, auch nachträglich änderbar (nicht-destruktiv)

### 5.4 Maskierung
- **Pinsel-Maske:** weiche Kante, Grösse und Härte einstellbar, auf jede Ebene anwendbar
- **Automatisches Freistellen:** ein Klick, um das Hauptmotiv (Person/Objekt) automatisch vom Hintergrund zu trennen (technisch via Vision-Framework, siehe Abschnitt 6)
- Maske umkehren, Maske vorübergehend deaktivieren, Maske löschen
- Ergebnis der Automatik ist immer nur der **Startpunkt** — von Hand mit dem Pinsel nachbesserbar

### 5.5 Grundlegende Bildanpassungen
Nur das, was wirklich ständig gebraucht wird:
- Helligkeit, Kontrast, Sättigung, Wärme/Farbton
- Weichzeichnen (z. B. für Hintergrund-Bokeh-Effekt in Collagen)
- Schärfen
- Spiegeln (horizontal/vertikal), Drehen in 90°-Schritten sowie frei

### 5.6 Text
- Einfache Textebene: Schrift, Grösse, Farbe, Ausrichtung, Deckkraft
- Kein volles Typografie-Werkzeug wie in Illustrator (Laufweite, Ligaturen etc. bewusst weggelassen)

### 5.7 Einfache Formen
- Rechteck, Ellipse, abgerundetes Rechteck als Rahmen/Hintergrundflächen für Collagen — reine Nutzflächen, kein Vektor-Zeichenwerkzeug

### 5.8 Export
- PNG (mit Transparenz), JPEG, PDF
- Export-Grössen-Presets passend zu den Canvas-Vorlagen aus 4.1

## 6. Bewusst NICHT im Funktionsumfang (v1)

Explizit weggelassen, um Fokus zu halten — kann später als separates Modul oder gar nicht kommen:

- RAW-Entwicklung / Camera-Raw-artige Werkzeuge
- Ebenenstile mit vielen Reglern (Schlagschatten-Winkel, Weichzeichnungskurven etc.) — falls überhaupt, nur ein simpler Schlagschatten mit 2–3 Reglern
- Dutzende Filter/Effekte-Presets — lieber 5–8 gute statt 70 mittelmässige
- Vektor-Pfadwerkzeug (Zeichenstift) — gehört in die zweite App (Logo-Tool)
- Video-Bearbeitung
- Plugin-/Erweiterungssystem
- Volles Farbmanagement (CMYK, Soft-Proofing) — App zielt auf Bildschirm-/Social-Media-Ausgabe, nicht auf Druckvorstufe

## 7. Technische Architektur

### 7.1 Framework-Wahl
- **Swift**, wie bei Sackmesser
- Canvas/Editor-Kern als **AppKit** (`NSView`-basiert) für volle Kontrolle über Drag-Gesten, Griffpunkte, Performance bei grossen Bildern
- Paletten/Inspector (Ebenenliste, Regler, Eigenschaften) können in **SwiftUI** gebaut und per `NSHostingView` eingebettet werden — spart Zeit bei Standard-UI, ohne den Canvas-Renderer einzuschränken

### 7.2 Rendering-Pipeline
- **Core Image** (`CIFilter`, `CIImage`) für alle Anpassungen (Helligkeit, Kontrast, Weichzeichnen, Schärfen) — GPU-beschleunigt, nicht-destruktiv durch neu berechnete Filterketten statt fest gebrannter Pixel
- **Core Animation / `CALayer`** für die Live-Komposition der Ebenen auf dem Canvas (Position, Rotation, Deckkraft, Blend-Modus in Echtzeit)
- Finaler Export rendert die komplette Ebenenkette einmalig in hoher Auflösung über einen `CIContext`

### 7.3 Maskierung — konkrete Umsetzung
- **Pinsel-Maske:** Off-Screen-Bitmap-Kontext (`CGContext`), in den mit dem Pinsel gemalt wird; das Ergebnis wird als Alphamaske über `CIBlendWithMask` auf die Bildebene angewendet
- **Automatisches Freistellen:** `VNGenerateForegroundInstanceMaskRequest` aus dem **Vision-Framework** (on-device, kein eigenes ML-Modell nötig, funktioniert offline). Liefert eine Instanzmaske des Hauptmotivs, die direkt als Startmaske übernommen und danach mit dem Pinsel verfeinert werden kann.

### 7.4 Datenmodell & Speicherung
- Dokumentbasierte App (`NSDocument`), ein Ebenenbaum als Kern-Datenstruktur
- Eigenes Projektformat (z. B. Paket/Bundle aus JSON-Struktur + referenzierten Original-Bilddateien), damit nicht-destruktiv bearbeitet werden kann und Originale erhalten bleiben
- `NSUndoManager` für Undo/Redo — Standard-Mechanismus, kein Custom-Stack nötig

## 8. UI-Konzept (grob)

```
┌─────────────────────────────────────────────────┐
│  Werkzeugleiste (kontextabhängig)                │
├───────────┬───────────────────────┬─────────────┤
│  Ebenen   │                       │  Eigenschaften│
│  (Liste)  │        Canvas         │  (Inspector) │
│           │                       │  je nach      │
│           │                       │  Auswahl      │
└───────────┴───────────────────────┴─────────────┘
```
- Werkzeugleiste oben: Auswählen, Verschieben, Pinsel-Maske, Freistellen, Text, Formen, Zuschneiden — max. 7–8 Icons sichtbar
- Ebenenliste links, klassisch von oben nach unten sortiert
- Eigenschaften-Panel rechts wechselt automatisch je nach ausgewähltem Werkzeug/Ebene (z. B. Regler für Helligkeit bei Bildebene, Schriftoptionen bei Textebene)

## 9. Entwicklungs-Roadmap

**Phase 0 — Grundgerüst**
Dokumentarchitektur, Canvas-Rendering mit Core Animation, einfache Ebenenliste (nur anzeigen, noch keine Bearbeitung)

**Phase 1 — MVP: Collage-Grundfunktion**
Bild-Import per Drag & Drop, frei positionieren/skalieren/rotieren, Zuschneiden, Ausrichtungshilfen, PNG/JPEG-Export

**Phase 2 — Anpassungen & Maskierung**
Core-Image-Anpassungsregler (Helligkeit/Kontrast/Sättigung/Wärme), Pinsel-Maske, automatisches Freistellen via Vision-Framework, Blend-Modi

**Phase 3 — Text, Formen & Vorlagen**
Textebenen, einfache Formen/Rahmen, Collage-Rastervorlagen, PDF-Export

**Phase 4 — Politur & optional**
Tastenkürzel für Power-User, Vorlagen-Bibliothek erweitern, ggf. iPad-Version, ggf. iCloud-Synchronisierung

## 10. Offene Entscheidungen

- ~~Name der App~~ → entschieden: **Assemblage**
- Vertrieb: Mac App Store (Sandboxing-Vorgaben beachten, analog zu Sackmesser) vs. eigenständiger Vertrieb
- Preismodell: Einmalkauf vs. kostenlos mit optionalen Vorlagen-Käufen
- Wie viele Collage-Rastervorlagen für den Start wirklich nötig sind (lieber wenige, gute, als eine überladene Bibliothek)
