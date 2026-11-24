import SwiftUI

struct ClaudeArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.claudeItems.isEmpty {
            ClaudeTable()
        } else {
            Group {
                if model.isLoadingClaude {
                    ContentUnavailableView {
                        EmptyStateLabel(title: "Claude-Daten werden geprüft …", systemImage: "sparkles")
                    } description: {
                        Text("Caches, Programmversionen, Logs und Chat-Verläufe von Claude Desktop und Claude Code.")
                    }
                } else if !model.includeClaude {
                    ContentUnavailableView {
                        EmptyStateLabel(title: "Claude-Scan ist aus", systemImage: "sparkles", color: Darcula.muted)
                    } description: {
                        Text("Aktiviere „Claude“ und scanne erneut.")
                    }
                } else if model.hasScanned {
                    ContentUnavailableView {
                        EmptyStateLabel(title: "Keine Claude-Daten", systemImage: "checkmark.circle", color: Darcula.success)
                    } description: {
                        Text("Claude Desktop und Claude Code haben hier nichts abgelegt.")
                    }
                } else {
                    ContentUnavailableView {
                        EmptyStateLabel(title: "Claude-Daten prüfen", systemImage: "sparkles")
                    } description: {
                        Text("ClearHub zeigt Caches, alte Versionen, Logs und Chat-Verläufe von Claude Desktop und Claude Code – und was davon gefahrlos weg kann.")
                    } actions: {
                        Button("Jetzt scannen") { model.startScan() }
                            .primaryAction()
                            .disabled(!model.canScan)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ClaudeTable: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<String>()

    var body: some View {
        @Bindable var model = model

        Table(model.visibleClaude, selection: $selection, sortOrder: $model.claudeSortOrder) {
            TableColumn("") { item in
                Toggle("", isOn: model.isChecked(claude: item.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!item.status.isDeletable)
                    .help(item.status.isDeletable ? "" : item.statusHelp)
            }
            .width(22)

            TableColumn("Eintrag", value: \.name) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(item.app.rawValue) · \(item.displayLocation)")
                        .font(.caption)
                        .darculaSecondary()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(pathsHelp(item))
                .darculaRowText()
            }

            TableColumn("Status", value: \.statusSort) { item in
                StatusBadge(claude: item)
            }
            .width(min: 220, ideal: 280)

            TableColumn("Geändert", value: \.modifiedSort) { item in
                if let modified = item.modified {
                    Text(modified, format: .relative(presentation: .named))
                        .darculaSecondary()
                        .help(modified.formatted(date: .long, time: .shortened))
                }
            }
            .width(min: 100, ideal: 120)

            TableColumn("Größe", value: \.sizeSort) { item in
                HStack {
                    Spacer()
                    Text(item.size.formattedBytes).monospacedDigit()
                }
                .darculaRowText()
            }
            .width(min: 80, ideal: 90)
        }
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Im Finder zeigen") { model.reveal(firstURLs(ids)) }
            Divider()
            Button("Markieren") { model.checkedClaude.formUnion(deletable(ids)) }
            Button("Markierung entfernen") { model.checkedClaude.subtract(ids) }
        } primaryAction: { ids in
            model.reveal(firstURLs(ids))
        }
        .onKeyPress(.space) {
            let deletable = deletable(selection)
            guard !deletable.isEmpty else { return .ignored }
            if deletable.isSubset(of: model.checkedClaude) {
                model.checkedClaude.subtract(deletable)
            } else {
                model.checkedClaude.formUnion(deletable)
            }
            return .handled
        }
    }

    private func deletable(_ ids: Set<String>) -> Set<String> {
        Set(model.claudeItems.filter { ids.contains($0.id) && $0.status.isDeletable }.map(\.id))
    }

    private func firstURLs(_ ids: Set<String>) -> [URL] {
        model.claudeItems.filter { ids.contains($0.id) }.compactMap(\.urls.first)
    }

    /// What gets deleted; long lists (old conversations) are cut short.
    private func pathsHelp(_ item: ClaudeItem) -> String {
        let paths = item.urls.prefix(8).map { ($0.path as NSString).abbreviatingWithTildeInPath }
        let more = item.urls.count > 8 ? ["… und \(item.urls.count - 8) weitere"] : []
        return (paths + more).joined(separator: "\n")
    }
}

extension StatusBadge {
    init(claude item: ClaudeItem) {
        label = item.statusLabel
        detail = item.statusDetail
        help = item.statusHelp
        color = item.statusColor
        locked = !item.status.isDeletable
    }
}
