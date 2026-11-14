import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ScanSettingsBar()
            Divider()
            ResultsArea()
            Divider()
            FooterBar(confirmDelete: $confirmDelete)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: searchPrompt)
        .toolbar {
            ToolbarItem(placement: .principal) {
                DarculaTabs(tabs: [
                    (Section.folders, "Ordner (\(model.results.count))"),
                    (Section.docker, "Images (\(model.dockerImages.count))"),
                    (Section.volumes, "Volumes (\(model.dockerVolumes.count))"),
                ], selection: $model.section)
                .fixedSize()
                .accessibilityLabel("Ansicht")
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button(model.deleteMode == .trash ? "In den Papierkorb legen" : "Endgültig löschen", role: .destructive) {
                model.deleteChecked()
            }
        } message: {
            Text(deleteMessage)
        }
        .alert(
            "Einige Einträge konnten nicht gelöscht werden",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var searchPrompt: String {
        switch model.section {
        case .folders: "Pfad filtern"
        case .docker: "Image filtern"
        case .volumes: "Volume filtern"
        }
    }

    private var deleteTitle: String {
        var parts: [String] = []
        if !model.checked.isEmpty { parts.append("\(model.checked.count) Ordner") }
        if !model.checkedImages.isEmpty { parts.append("\(model.checkedImages.count) Docker-Einträge") }
        if !model.checkedVolumes.isEmpty {
            parts.append(model.checkedVolumes.count == 1 ? "1 Volume" : "\(model.checkedVolumes.count) Volumes")
        }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " und " + parts[parts.count - 1] : parts.joined()
        return list + " löschen?"
    }

    private var deleteMessage: String {
        var lines = ["Insgesamt \(model.checkedBytes.formattedBytes)."]
        if !model.checked.isEmpty {
            lines.append(model.deleteMode == .trash
                ? "Ordner kommen in den Papierkorb. Wiederherstellen mit npm install / composer install."
                : "Ordner werden sofort und unwiderruflich gelöscht. Wiederherstellen mit npm install / composer install.")
        }
        if !model.checkedImages.isEmpty {
            lines.append("Docker-Images werden endgültig entfernt (kein Papierkorb) und beim nächsten Start neu gebaut bzw. gepullt.")
            let projectImages = model.checkedDockerImages.filter { if case .project = $0.status { true } else { false } }
            if !projectImages.isEmpty {
                lines.append("⚠️ \(projectImages.count) davon gehören zu Projekten auf deiner Platte.")
            }
        }
        if !model.checkedVolumes.isEmpty {
            lines.append("⚠️ Volumes enthalten Daten (z. B. Datenbanken). Sie werden endgültig gelöscht und lassen sich nicht wiederherstellen.")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Settings

private struct ScanSettingsBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Durchsuchen:")
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.roots, id: \.self) { root in
                            RootChip(url: root) { model.removeRoot(root) }
                        }
                        Button("Ordner hinzufügen", systemImage: "plus") { model.addRoots() }
                            .buttonStyle(.borderless)
                    }
                }
            }

            HStack(spacing: 18) {
                Text("Suchen nach:")
                    .foregroundStyle(.secondary)
                Group {
                    Toggle("node_modules/", isOn: $model.includeNodeModules)
                    Toggle("vendor/ (Composer, Go, Bundler)", isOn: $model.includeVendor)
                        .help("Nur vendor/-Ordner neben composer.json, go.mod oder Gemfile.")
                    Toggle("Docker", isOn: $model.includeDocker)
                        .help("Images, Volumes und Build-Cache prüfen. Compose- und DDEV-Projekte in den Suchorten werden zugeordnet.")
                }
                .toggleStyle(.checkbox)
                .disabled(model.isScanning)
                Spacer()
                ScanStatus()
                ScanButton()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct RootChip: View {
    let url: URL
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text((url.path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Entfernen")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(nsColor: Darcula.raised), in: Capsule())
    }
}

private struct ScanButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isScanning {
            Button("Abbrechen", systemImage: "stop.fill") { model.cancelScan() }
        } else if model.settingsChanged {
            // Search locations/types changed: highlight the button so the rescan is not forgotten.
            Button("Erneut scannen", systemImage: "arrow.clockwise") { model.startScan() }
                .primaryAction()
                .disabled(!model.canScan)
                .help("Suchorte oder Typen wurden geändert – Ergebnisse sind veraltet.")
        } else {
            Button(model.hasScanned ? "Erneut scannen" : "Scannen",
                   systemImage: model.hasScanned ? "arrow.clockwise" : "magnifyingglass") {
                model.startScan()
            }
            .disabled(!model.canScan)
        }
    }
}

private struct ScanStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isScanning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(model.scannedCount.formatted()) Ordner geprüft")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .help(model.currentPath)
        } else if model.isLoadingDocker {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Docker wird abgefragt …")
                    .foregroundStyle(.secondary)
            }
        } else if model.pendingSizes > 0 {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Größen werden berechnet …")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Results

private struct ResultsArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.section {
        case .folders: FolderResultsArea()
        case .docker: DockerResultsArea()
        case .volumes: DockerVolumesArea()
        }
    }
}

private struct FolderResultsArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.results.isEmpty {
            Group {
                if model.isScanning {
                    ContentUnavailableView {
                        EmptyStateLabel(title: "Suche läuft …", systemImage: "magnifyingglass")
                    } description: {
                        Text((model.currentPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else if model.hasScanned {
                    ContentUnavailableView {
                        EmptyStateLabel(title: "Nichts gefunden", systemImage: "checkmark.circle", color: Darcula.success)
                    } description: {
                        Text("In den gewählten Ordnern liegen keine passenden Abhängigkeits-Ordner.")
                    }
                } else {
                    ContentUnavailableView {
                        EmptyStateLabel(title: "Speicherplatz freiräumen", systemImage: "externaldrive.badge.minus")
                    } description: {
                        Text("ClearHub findet node_modules/- und vendor/-Ordner in deinen Projekten.")
                    } actions: {
                        Button("Jetzt scannen") { model.startScan() }
                            .primaryAction()
                            .disabled(!model.canScan)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ResultsTable()
        }
    }
}

private struct ResultsTable: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<URL>()

    var body: some View {
        @Bindable var model = model

        Table(model.visibleResults, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("") { folder in
                Toggle("", isOn: model.isChecked(folder.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
            }
            .width(22)

            TableColumn("Projekt", value: \.projectName) { folder in
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.projectName)
                        .fontWeight(.medium)
                    Text(folder.projectPath)
                        .font(.caption)
                        .darculaSecondary()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(folder.url.path)
                .darculaRowText()
            }

            TableColumn("Typ", value: \.kindLabel) { folder in
                KindBadge(folder: folder)
            }
            .width(min: 150, ideal: 170)

            TableColumn("Projekt geändert", value: \.modifiedSort) { folder in
                if let modified = folder.modified {
                    Text(modified, format: .relative(presentation: .named))
                        .darculaSecondary()
                        .help(modified.formatted(date: .long, time: .shortened))
                }
            }
            .width(min: 110, ideal: 130)

            TableColumn("Größe", value: \.sizeSort) { folder in
                HStack {
                    Spacer()
                    if let size = folder.size {
                        Text(size.formattedBytes).monospacedDigit()
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .darculaRowText()
            }
            .width(min: 80, ideal: 90)
        }
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: URL.self) { ids in
            Button("Im Finder zeigen") { model.reveal(Array(ids)) }
            Divider()
            Button("Markieren") { model.checked.formUnion(ids) }
            Button("Markierung entfernen") { model.checked.subtract(ids) }
        } primaryAction: { ids in
            model.reveal(Array(ids))
        }
        .onKeyPress(.space) {
            guard !selection.isEmpty else { return .ignored }
            // Space toggles the mark of the selected rows.
            if selection.isSubset(of: model.checked) {
                model.checked.subtract(selection)
            } else {
                model.checked.formUnion(selection)
            }
            return .handled
        }
    }
}

private struct KindBadge: View {
    let folder: FoundFolder

    var body: some View {
        HStack(spacing: 5) {
            Text(folder.kind.rawValue)
                .font(.caption.monospaced())
                .darculaBadge(color)
            Text(folder.ecosystem)
                .font(.caption)
                .darculaSecondary()
        }
        .darculaRowText()
    }

    private var color: Color { Color(nsColor: folder.kind == .nodeModules ? Darcula.success : Darcula.color(0xB08ED8)) }
}

// MARK: - Footer

private struct FooterBar: View {
    @Environment(AppModel.self) private var model
    @Binding var confirmDelete: Bool

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if model.checkedCount == 0 {
                    switch model.section {
                    case .folders:
                        Text("\(model.results.count) Ordner gefunden · \(model.totalBytes.formattedBytes)")
                    case .docker:
                        Text("\(model.dockerImages.count) Docker-Einträge · \(model.orphanedBytes.formattedBytes) verwaist")
                    case .volumes:
                        Text("\(model.dockerVolumes.count) Volumes · \(model.orphanedVolumeBytes.formattedBytes) verwaist")
                    }
                } else {
                    Text("\(model.checkedCount) ausgewählt · \(model.checkedBytes.formattedBytes)")
                        .fontWeight(.semibold)
                }
                if let status = model.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()

            Spacer()

            switch model.section {
            case .folders:
                Button("Alle markieren") { model.checkAllVisible() }
                    .disabled(model.visibleResults.isEmpty)
            case .docker:
                Button("Verwaiste markieren") { model.checkAllVisible() }
                    .disabled(!model.visibleImages.contains { $0.status.isOrphaned })
                    .help("Markiert dangling, verwaiste Images und den ungenutzten Build-Cache – keine Projekt-Images.")
            case .volumes:
                Button("Verwaiste markieren") { model.checkAllVisible() }
                    .disabled(!model.visibleVolumes.contains { $0.status.isOrphaned })
                    .help("Markiert anonyme und verwaiste Volumes ohne Container – keine Projekt- oder Werkzeug-Volumes.")
            }

            Button("Keine") {
                model.checked.removeAll()
                model.checkedImages.removeAll()
                model.checkedVolumes.removeAll()
            }
            .disabled(model.checkedCount == 0)

            Picker("", selection: $model.deleteMode) {
                Text("In den Papierkorb").tag(DeleteMode.trash)
                Text("Endgültig löschen").tag(DeleteMode.permanent)
            }
            .labelsHidden()
            .fixedSize()
            .help("Gilt für Ordner. Docker-Images und -Volumes werden immer endgültig entfernt.")

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                if model.isDeleting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Löschen …", systemImage: "trash")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(nsColor: Darcula.dangerFill))
            .foregroundStyle(.white)
            .disabled(model.checkedCount == 0 || model.isScanning || model.isDeleting)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// The label of an empty state, its symbol in a palette color (ClearHub's orange unless it reports
/// a result or a problem).
struct EmptyStateLabel: View {
    let title: String
    let systemImage: String
    var color: NSColor = Darcula.ink

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color(nsColor: color))
        }
    }
}
