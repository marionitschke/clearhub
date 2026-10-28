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
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Pfad filtern")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Typ", selection: $model.filter) {
                    ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isScanning {
                    Button("Abbrechen", systemImage: "stop.fill") { model.cancelScan() }
                } else {
                    Button("Scannen", systemImage: "magnifyingglass") { model.startScan() }
                        .disabled(!model.canScan)
                }
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
            "Einige Ordner konnten nicht gelöscht werden",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var deleteTitle: String {
        "\(model.checked.count) Ordner \(model.deleteMode == .trash ? "in den Papierkorb legen" : "endgültig löschen")?"
    }

    private var deleteMessage: String {
        let size = model.checkedBytes.formattedBytes
        return model.deleteMode == .trash
            ? "\(size) werden in den Papierkorb verschoben. Abhängigkeiten lassen sich mit npm install / composer install wiederherstellen."
            : "\(size) werden sofort und unwiderruflich gelöscht. Abhängigkeiten lassen sich mit npm install / composer install wiederherstellen."
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
                Toggle("node_modules/", isOn: $model.includeNodeModules)
                Toggle("vendor/ (Composer, Go, Bundler)", isOn: $model.includeVendor)
                    .help("Nur vendor/-Ordner neben composer.json, go.mod oder Gemfile.")
                Spacer()
                ScanStatus()
            }
            .toggleStyle(.checkbox)
            .disabled(model.isScanning)
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
                if model.checked.isEmpty {
                    Text("\(model.results.count) Ordner gefunden · \(model.totalBytes.formattedBytes)")
                } else {
                    Text("\(model.checked.count) ausgewählt · \(model.checkedBytes.formattedBytes)")
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

            Button("Alle markieren") {
                model.checked.formUnion(model.visibleResults.map(\.id))
            }
            .disabled(model.visibleResults.isEmpty)

            Button("Keine") { model.checked.removeAll() }
                .disabled(model.checked.isEmpty)

            Picker("", selection: $model.deleteMode) {
                Text("In den Papierkorb").tag(DeleteMode.trash)
                Text("Endgültig löschen").tag(DeleteMode.permanent)
            }
            .labelsHidden()
            .fixedSize()

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
            .disabled(model.checked.isEmpty || model.isScanning || model.isDeleting)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
