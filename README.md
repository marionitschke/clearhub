# ClearHub

Native macOS-App (SwiftUI + AppKit), die deine Projektordner nach `node_modules/` und `vendor/` durchsucht und die ausgewählten Ordner löscht. So holst du dir Speicherplatz zurück, den alte Arbeitsprojekte belegen.

![ClearHub – Beispielansicht (Mockup)](docs/screenshot.svg)

<sub>Mockup zur Veranschaulichung, kein echter Screenshot.</sub>

## Funktionen

- **Suchorte frei wählbar:** beliebig viele Ordner (Standard: `~`), werden gespeichert.
- **`node_modules/`** – erkennt npm, Yarn, pnpm und Bun am Lockfile.
- **`vendor/`** – nur echte Projekt-Abhängigkeiten: neben `composer.json`, `go.mod` oder `Gemfile`.
- **Größe und Alter** – sortierbar nach Größe oder „Projekt geändert“, filterbar nach Typ und Pfad.
- **Löschen** – in den Papierkorb (Standard) oder endgültig, immer mit Bestätigung.
- **Erneut scannen** – der Button wird hervorgehoben, sobald Suchorte oder Typen geändert wurden.

### Sicherheit

- Versteckte Ordner (`.git`, `.nvm`, `.cache` …), `~/Library` und Systemordner werden nie durchsucht.
- Verschachtelte `node_modules` werden nicht einzeln gelistet – nur der oberste Ordner pro Projekt.
- Gelöscht wird nur, was tatsächlich `node_modules` bzw. `vendor` heißt.

## Bedienung

| Aktion | Kürzel |
| --- | --- |
| Scannen / erneut scannen | ⌘R |
| Ordner hinzufügen | ⌘O |
| Ausgewählte Zeilen markieren | Leertaste |
| Im Finder zeigen | Doppelklick |
| Markierte löschen | ⌘⌫ |

Beim ersten Scan von `~` fragt macOS nach Zugriff auf Schreibtisch, Dokumente und Downloads – erlauben, sonst fehlen Treffer.

## Bauen

Voraussetzung: macOS 14+, Xcode bzw. Swift 5.10+.

```bash
./build.sh
open build/ClearHub.app
```

`build.sh` baut im Release-Modus, erzeugt `build/ClearHub.app` und signiert ad hoc.

Tests:

```bash
swift test
```

## Aufbau

| Pfad | Inhalt |
| --- | --- |
| `Sources/ClearHubCore/Scanner.swift` | Verzeichnis-Scan, Erkennung, Größenberechnung |
| `Sources/ClearHubCore/Deleter.swift` | Papierkorb / endgültig löschen |
| `Sources/ClearHub/AppModel.swift` | Zustand, Hintergrund-Scan, Einstellungen |
| `Sources/ClearHub/ContentView.swift` | Oberfläche |
| `Tests/ClearHubCoreTests` | Unit-Tests für Scan und Löschen |
