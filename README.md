# Assemblage

Eine native macOS-App für Fotobearbeitung und Collagen, die sich bewusst auf das beschränkt, was im Alltag wirklich gebraucht wird: Bilder kombinieren, freistellen/maskieren, grundlegend anpassen, sauber exportieren.

Jedes Feature muss sich rechtfertigen. Lieber fünf Werkzeuge, die exzellent funktionieren, als zwanzig, die halbherzig sind.

## Status

**Alle vier Phasen der Roadmap stehen.** Die App importiert Fotos per Drag & Drop, ordnet sie frei an, maskiert sie von Hand oder automatisch, passt sie an und exportiert nach PNG, JPEG und PDF.

Offen sind nur noch die im Plan als „ggf." markierten Punkte (iPad-Version, iCloud) sowie die Entscheidungen aus Plan §10 — Vertrieb, Preismodell und wie viele Collage-Vorlagen mitgeliefert werden sollen.

| Phase | Inhalt | Stand |
| --- | --- | --- |
| 0 | Dokumentarchitektur, Canvas, Ebenenliste | ✅ |
| 1 | Import, Anordnen, Zuschneiden, Ausrichtungshilfen, PNG/JPEG-Export | ✅ |
| 2 | Bildanpassungen, Pinsel-Maske, automatisches Freistellen, Blend-Modi | ✅ |
| 3 | Text, Formen, Collage-Vorlagen, PDF-Export | ✅ |
| 4 | Tastenkürzel für Power-User | ✅ |

Die nicht verhandelbaren Grundanforderungen aus Plan §2.1 sind ebenfalls abgedeckt: Autosave und Versionsverwaltung über `NSDocument`, asynchroner Export und asynchrones Freistellen, Fehlerbehandlung statt `try!`, automatisierte Tests der Kernpipeline samt Stresstest, und lokale Diagnoseberichte (siehe unten).

### Über die Roadmap hinaus

| Werkzeug | Wo |
| --- | --- |
| Freies Verziehen an den vier Ecken, mit Option-Taste proportional | Werkzeugleiste, „Ebene › Verziehen" |
| Texturen auf einer Ebene, gekachelt und auf ihre Form beschnitten | „Ebene › Textur hinzufügen…" |
| Formvorlagen: Dreieck, Fünfeck, Sechseck, Stern, Herz, Pfeil, Sprechblase | „Einfügen › Formvorlage" |
| Leuchten und Schlagschatten, der Silhouette folgend | Inspector |
| Text direkt auf der Leinwand ändern | Doppelklick auf die Textebene |
| Text und Formen in ein Objekt umwandeln (dann verziehbar) | „Ebene › In Objekt umwandeln" |
| Vorher/Nachher je Ebene | ⌘\ oder „Ebene › Vorher/Nachher vergleichen" |
| Wiederholen auch mit ⌘Y | zusätzlich zu ⇧⌘Z |
| Werkzeugleiste, die beim Überfahren aufklappt | links neben der Leinwand |

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

## Diagnoseberichte

Assemblage legt von macOS über MetricKit gelieferte Absturz-, Hänger- und
Schreibdiagnosen ausschliesslich lokal unter `~/Library/Logs/Assemblage/` ab.
Der Ordner lässt sich über „Hilfe › Diagnoseberichte anzeigen“ öffnen. Es wird
nichts übertragen. Berichte werden nach 90 Tagen gelöscht; zusätzlich bleiben
höchstens die 50 neuesten erhalten.

MetricKit liefert diese Diagnosen auf macOS nachträglich und nicht garantiert,
typischerweise ungefähr einmal täglich bei laufender App. Die lokalen Dateien
sind deshalb eine Hilfe für die Fehlersuche, aber kein lückenloses oder
unmittelbares Absturzprotokoll.

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
