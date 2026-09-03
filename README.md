# Assemblage

Eine native macOS-App für Fotobearbeitung und Collagen, die sich bewusst auf das beschränkt, was im Alltag wirklich gebraucht wird: Bilder kombinieren, freistellen/maskieren, grundlegend anpassen, sauber exportieren.

Jedes Feature muss sich rechtfertigen. Lieber fünf Werkzeuge, die exzellent funktionieren, als zwanzig, die halbherzig sind.

## Status

**Phasen 0 bis 3 der Roadmap stehen.** Die App importiert Fotos per Drag & Drop, ordnet sie frei an, maskiert sie von Hand oder automatisch, passt sie an und exportiert nach PNG, JPEG und PDF.

| Phase | Inhalt | Stand |
| --- | --- | --- |
| 0 | Dokumentarchitektur, Canvas, Ebenenliste | ✅ |
| 1 | Import, Anordnen, Zuschneiden, Ausrichtungshilfen, PNG/JPEG-Export | ✅ |
| 2 | Bildanpassungen, Pinsel-Maske, automatisches Freistellen, Blend-Modi | ✅ |
| 3 | Text, Formen, Collage-Vorlagen, PDF-Export | ✅ |
| 4 | Politur: Tastenkürzel, Vorlagen-Bibliothek, optional iPad/iCloud | offen |

Der vollständige Entwicklungsplan (Vision, Feature-Set, technische Architektur, Roadmap) liegt in [`docs/entwicklungsplan.md`](docs/entwicklungsplan.md), die Regeln für die Mitarbeit in [`agent-rules.md`](agent-rules.md).

## Bauen & starten

```bash
Scripts/make-app.sh          # baut .build/Assemblage.app
open .build/Assemblage.app
```

`swift build` allein erzeugt nur die nackte ausführbare Datei. Erst das Bundle bringt App-Symbol, Dokumenttyp `.assemblage` und die `NSDocument`-Anbindung mit — Details im Kopf von [`Scripts/make-app.sh`](Scripts/make-app.sh).

```bash
swift test                   # Modell + Rendering-Pipeline
```

## Aufbau

| Ziel | Inhalt |
| --- | --- |
| `Sources/AssemblageModel` | Reines Datenmodell — Codable-Strukturen, kein AppKit/Core Image/Vision. Läuft und testet auch unter Linux; die CI hält diese Trennung ehrlich. |
| `Sources/AssemblageKit` | Die Mac-App: AppKit-Canvas (Core Animation), Dokumentpakete, SwiftUI-Paletten. |
| `Sources/Assemblage` | Nur der Einstiegspunkt — damit der App-Code selbst testbar bleibt. |

### Festlegungen, die überall gelten

- **Koordinatensystem:** Ursprung oben links, y wächst nach unten. `Transform2D.x/y` ist der **Mittelpunkt** einer Ebene, nicht ihre obere linke Ecke.
- **Ebenenreihenfolge:** `Document.layers[0]` liegt zuunterst; die Ebenenliste zeigt sie umgekehrt.
- **Änderungen** laufen ausschliesslich über `AssemblageDocument.modify(_:_:)` — nur so landen sie im Undo-Stack.
- **Dokumentformat:** Paket aus `document.json` plus `originals/` und `masks/`. Fehlende Felder mit neutralem Vorgabewert sind erlaubt, damit das Format erweiterbar bleibt.

## Lizenz

Copyright © 2026 Arun Meyer. Alle Rechte vorbehalten. Siehe [LICENSE](LICENSE) — dies ist **kein** Open-Source-Projekt; der Code ist einsehbar, aber nicht zur Nutzung, Kopie oder Weiterverbreitung freigegeben.
