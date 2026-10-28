# ClearHub

macOS-App (SwiftUI + AppKit, macOS 14+), die `node_modules/`, Projekt-`vendor/` und veraltete Docker-Images findet und löscht. Swift Package, kein Xcode-Projekt.

## Befehle

- Tests: `swift test`
- App bauen: `./build.sh` → `build/ClearHub.app` (Info.plist wird im Skript erzeugt, ad-hoc signiert)
- Nach UI-Änderungen: `pkill -x ClearHub; ./build.sh && open build/ClearHub.app`
- Icon: `swift Scripts/make-icon.swift` → `Resources/AppIcon.icns` (wird eingecheckt, `build.sh` kopiert es ins Bundle)

## Aufbau

- `Sources/ClearHubCore` – UI-freie Logik (Scan, Größe, Löschen). Alles hier ist `public` und synchron/blockierend; Tests nur gegen dieses Target.
- `Sources/ClearHub` – SwiftUI-Oberfläche. `AppModel` (`@MainActor @Observable`) hält den gesamten Zustand und startet Hintergrundarbeit auf `DispatchQueue.global`, Ergebnisse gehen per `Task { @MainActor in … }` zurück.

## Regeln

- UI-Texte, Kommentare und Commit-Messages auf Deutsch.
- Sprachmodus Swift 5 (`swift-tools-version: 5.10`); trotzdem warnungsfrei halten, auch für Swift-6-Concurrency-Warnungen.
- Neue Scan-/Lösch-Logik gehört nach `ClearHubCore` und bekommt einen Test in `Tests/ClearHubCoreTests` (arbeitet in einem Temp-Ordner, nie im echten Home).
- Einstellungen werden in `AppModel` per `didSet` in `UserDefaults` gespeichert; neue Scan-Einstellungen müssen auch `markSettingsChanged()` aufrufen, sonst wird „Erneut scannen“ nicht hervorgehoben.

## Fallen

- **Löschsicherheit nicht aufweichen:** `Deleter` löscht nur Ordner, deren Name exakt `node_modules`/`vendor` ist. `Scanner` überspringt versteckte Ordner (`.nvm` enthält globale npm-Pakete!), `~/Library` und Systempfade. `vendor/` zählt nur neben `composer.json`, `go.mod` oder `Gemfile`.
- Standard-Löschmodus ist Papierkorb – so lassen.
- **Docker:** nie `--force` beim Löschen. `.inUse`-Images sind nicht markierbar; „Verwaiste markieren“ erfasst nur `isOrphaned` (dangling, verwaist, Build-Cache), nie `.project`.
- Docker-Daten kommen aus `docker system df -v --format '{{json .}}'`; Größen sind dezimal (`MB` = 10⁶). „Wird frei“ = `UniqueSize`, nicht `Size`.
- Die App erbt keinen Shell-PATH: `Docker.searchPaths` enthält die Installationsorte (Docker Desktop, OrbStack, Colima, Rancher).
- Projekt-Zuordnung (`DockerProjectIndex`): `image:` aus Compose-Dateien, gebaute Images `<projekt>-<service>`, DDEV-Tags `…-<site>-built`. DDEV liegt in versteckten `.ddev/` – der Scanner prüft `.ddev/config.yaml` nur neben Projektdateien (composer.json, package.json …).
- `NSDirectoryEnumerator` nicht mit `for … in` in async-Kontexten iterieren (Swift 6 Fehler); `while let … = enumerator.nextObject()` verwenden.
- Ein neuer Scan muss den alten über `CancelToken` abbrechen; Callbacks prüfen `token.isCancelled`, sonst landen veraltete Ergebnisse in der Liste.
- `docs/screenshot.svg` ist ein Mockup, kein echter Screenshot. Bei sichtbaren UI-Änderungen anpassen und in der README als Mockup gekennzeichnet lassen.

## Git

- Remote: `git@github.com:marionitschke/clearhub.git`, Branch `main`.
- Das Repo nutzt `core.sshCommand` mit `~/.ssh/github_ed25519` (andere Keys sind bei GitHub nicht hinterlegt).
