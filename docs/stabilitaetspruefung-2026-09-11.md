# Stabilitätsprüfung vom 11. September 2026

Projektweite Suche nach Absturzmustern und riskanten Zahlenkonvertierungen;
vertiefte Prüfung von Dokumentpaketen, Ressourcenverwaltung, Datenbereinigung
und Maskenrendering. Die vorhandene Testsuite prüft zusätzlich Modell,
Bedienlogik, Rendering, Import, Export und Nebenläufigkeit.

## Behobene Fehler

- Beim Speichern wurden Freihandpfade, Konturfarbe und Konturbreite von
  Formebenen durch Vorgabewerte ersetzt. Diese Daten bleiben jetzt erhalten.
- Die vier mittleren Verziehpunkte gingen beim Speichern verloren. Alle acht
  Punkte werden nun erhalten und auf nicht endliche Koordinaten geprüft.
- Nicht endliche Koordinaten in Formzuschnittspfaden verhinderten das
  Speichern. Die Bereinigung erfasst nun auch Pfade und ihre Kurvengriffe.
- Speichern nach dem Löschen einer Ebene entfernte deren Original aus der
  Sitzung. Rückgängig stellte dann eine Ebene ohne Bild wieder her.
  Das gespeicherte Paket enthält weiterhin nur aktuelle Referenzen, die
  Sitzung behält Ressourcen für Undo/Redo und laufende Operationen.
- NaN-Farbkomponenten verursachten bei der Hex-Konvertierung einen
  Ganzzahlkonvertierungsabsturz. Nicht endliche Komponenten erhalten nun 0.
- Unendliche Darstellungsgrössen und nicht darstellbare Zuschnittgrössen
  konnten beim Erzeugen einer Formmaske abstürzen. Diese Werte werden vor
  der Ganzzahlkonvertierung abgewiesen.

## Nachweis

Vor den Korrekturen schlugen die Speicherregressionstests fehl. Die separaten
Farb- und Maskenregressionstests beendeten den Testprozess mit Signal 5.
Nach den Korrekturen: `swift test` erfolgreich, **762 Tests ohne Fehler**
(225 Modelltests und 537 App-/Renderingtests). `git diff --check` erfolgreich.
Die bereits vorhandenen lokalen Änderungen an `DocumentIOTests.swift` und
`SanitizingTests.swift` wurden erhalten und zur Verifikation verwendet.

## Grenzen und offene Beobachtungen

- AppKit meldet in einigen Renderingtests Layoutkonflikte bei
  `WidgetAutoHide.swift:560`, ohne die betreffenden Constraints offenzulegen
  (`<private>`). Die Tests bestehen. Die Ursache ist damit noch nicht
  bestimmt; ein gezielter interaktiver Layouttest bleibt offen.
- Kein manueller Langzeittest der gestarteten App und keine Garantie, dass
  sämtliche Kombinationen von Dokumenten, Hardware und Bedienabläufen
  fehlerfrei sind.
- Ressourcen früherer Zustände bleiben bis zum Ende der Dokumentsitzung
  verfügbar. Eine spätere Speicherbereinigung muss auch Undo/Redo und
  laufende Operationen berücksichtigen, statt nur aktuelle Ebenen zu prüfen.
