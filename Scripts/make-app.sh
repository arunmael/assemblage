#!/bin/bash
# Baut Assemblage.app — ein echtes Programmpaket, nicht nur die nackte
# ausführbare Datei, die `swift build` erzeugt.
#
# Nötig, weil mehreres nur aus einem Bundle heraus funktioniert: Das App-Symbol
# hat sonst keinen Ort, die Registrierung des Dokumenttyps `.assemblage`
# (damit ein Doppelklick im Finder die App öffnet) steht in der Info.plist, und
# `NSDocument` findet seine Dokumentklasse ebenfalls nur darüber.
#
# Aufruf: Scripts/make-app.sh [release|debug]    (Vorgabe: release)

set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIGURATION"
APP="$ROOT/.build/Assemblage.app"
VERSION="0.1.0"

cd "$ROOT"

echo "▸ Baue ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product Assemblage

echo "▸ Erzeuge App-Symbol…"
ICONSET="$ROOT/.build/Assemblage.iconset"
swift "$ROOT/Scripts/make-icon.swift" "$ICONSET"
iconutil --convert icns "$ICONSET" --output "$ROOT/.build/Assemblage.icns"

echo "▸ Baue Bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/Assemblage" "$APP/Contents/MacOS/Assemblage"
cp "$ROOT/.build/Assemblage.icns" "$APP/Contents/Resources/Assemblage.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Assemblage</string>
    <key>CFBundleDisplayName</key>
    <string>Assemblage</string>
    <key>CFBundleIdentifier</key>
    <string>de.arun.Assemblage</string>
    <key>CFBundleExecutable</key>
    <string>Assemblage</string>
    <key>CFBundleIconFile</key>
    <string>Assemblage</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Arun Meyer</string>

    <!-- Das eigene Projektformat (Plan 7.4). Ein Paket (Ordner, den der
         Finder als eine Datei zeigt), weil neben document.json auch die
         Original-Fotos und Masken darin liegen. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Assemblage-Dokument</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSTypeIsPackage</key>
            <true/>
            <key>LSItemContentTypes</key>
            <array>
                <string>de.arun.assemblage.document</string>
            </array>
            <!-- Modulname mit Punkt: sonst findet AppKit die Klasse nicht. -->
            <key>NSDocumentClass</key>
            <string>AssemblageKit.AssemblageDocument</string>
        </dict>
    </array>

    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>de.arun.assemblage.document</string>
            <key>UTTypeDescription</key>
            <string>Assemblage-Dokument</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>com.apple.package</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>assemblage</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc-Signatur: nicht vertriebsfertig, aber ohne jede Signatur verweigert
# macOS der App den Zugriff auf Dateien ausserhalb des eigenen Ordners.
echo "▸ Signiere (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Fertig: $APP"
echo "  Starten mit:  open '$APP'"
