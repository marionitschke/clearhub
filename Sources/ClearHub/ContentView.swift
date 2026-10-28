import ClearHubCore
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
        .searchable(text: $model.searchText, placement: .toolbar, prompt: model.section == .folders ? "Pfad filtern" : "Image filtern")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Ansicht", selection: $model.section) {
                    Text("Ordner (\(model.results.count))").tag(Section.folders)
                    Text("Docker (\(model.dockerImages.count))").tag(Section.docker)
                }
                .pickerStyle(.segmented)
                .fixedSize()
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

    private var deleteTitle: String {
        var parts: [String] = []
        if !model.checked.isEmpty { parts.append("\(model.checked.count) Ordner") }
        if !model.checkedImages.isEmpty { parts.append("\(model.checkedImages.count) Docker-Einträge") }
        return parts.joined(separator: " und ") + " löschen?"
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
        return lines.joined(separator: "\n")
    }
}

// MARK: - Einstellungen

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
                    Toggle("Docker-Images", isOn: $model.includeDocker)
                        .help("Images und Build-Cache prüfen. Compose- und DDEV-Projekte in den Suchorten werden zugeordnet.")
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
                .foregroundStyle(.tint)
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
        .background(.quaternary, in: Capsule())
    }
}

private struct ScanButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isScanning {
            Button("Abbrechen", systemImage: "stop.fill") { model.cancelScan() }
        } else if model.settingsChanged {
            // Suchorte/Typen geändert: Button hervorheben, damit der neue Scan nicht vergessen wird.
            Button("Erneut scannen", systemImage: "arrow.clockwise") { model.startScan() }
                .buttonStyle(.borderedProminent)
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

// MARK: - Ergebnisse

private struct ResultsArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.section {
        case .folders: FolderResultsArea()
        case .docker: DockerResultsArea()
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
                        Label("Suche läuft …", systemImage: "magnifyingglass")
                    } description: {
                        Text((model.currentPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else if model.hasScanned {
                    ContentUnavailableView(
                        "Nichts gefunden",
                        systemImage: "checkmark.circle",
                        description: Text("In den gewählten Ordnern liegen keine passenden Abhängigkeits-Ordner.")
                    )
                } else {
                    ContentUnavailableView {
                        Label("Speicherplatz freiräumen", systemImage: "externaldrive.badge.minus")
                    } description: {
                        Text("ClearHub findet node_modules/- und vendor/-Ordner in deinen Projekten.")
                    } actions: {
                        Button("Jetzt scannen") { model.startScan() }
                            .buttonStyle(.borderedProminent)
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
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(folder.url.path)
            }

            TableColumn("Typ", value: \.kindLabel) { folder in
                KindBadge(folder: folder)
            }
            .width(min: 150, ideal: 170)

            TableColumn("Projekt geändert", value: \.modifiedSort) { folder in
                if let modified = folder.modified {
                    Text(modified, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
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
            }
            .width(min: 80, ideal: 90)
        }
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
            // Leertaste schaltet die Markierung der ausgewählten Zeilen um.
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
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(color)
            Text(folder.ecosystem)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color { folder.kind == .nodeModules ? .green : .purple }
}

// MARK: - Fußzeile

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
            }

            Button("Keine") {
                model.checked.removeAll()
                model.checkedImages.removeAll()
            }
            .disabled(model.checkedCount == 0)

            Picker("", selection: $model.deleteMode) {
                Text("In den Papierkorb").tag(DeleteMode.trash)
                Text("Endgültig löschen").tag(DeleteMode.permanent)
            }
            .labelsHidden()
            .fixedSize()
            .help("Gilt für Ordner. Docker-Images werden immer endgültig entfernt.")

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
            .tint(.red)
            .disabled(model.checkedCount == 0 || model.isScanning || model.isDeleting)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
