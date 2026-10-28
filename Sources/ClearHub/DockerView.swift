import ClearHubCore
import SwiftUI

struct DockerResultsArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.dockerImages.isEmpty {
            DockerTable()
        } else {
            Group {
                if model.isScanning || model.isLoadingDocker {
                    ContentUnavailableView {
                        Label("Docker wird abgefragt …", systemImage: "shippingbox")
                    } description: {
                        Text("Zuerst werden die Suchorte nach Compose- und DDEV-Projekten durchsucht.")
                    }
                } else if let error = model.dockerError {
                    ContentUnavailableView {
                        Label("Docker nicht erreichbar", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Erneut versuchen") { model.loadDocker() }
                    }
                } else if !model.includeDocker {
                    ContentUnavailableView {
                        Label("Docker-Scan ist aus", systemImage: "shippingbox")
                    } description: {
                        Text("Aktiviere „Docker-Images“ und scanne erneut.")
                    }
                } else if model.hasScanned {
                    ContentUnavailableView("Keine Images", systemImage: "checkmark.circle", description: Text("Docker hat keine lokalen Images."))
                } else {
                    ContentUnavailableView {
                        Label("Docker-Images prüfen", systemImage: "shippingbox")
                    } description: {
                        Text("ClearHub zeigt, welche Images ein Container nutzt, welche zu einem Projekt gehören und welche verwaist sind.")
                    } actions: {
                        Button("Jetzt scannen") { model.startScan() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canScan)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DockerTable: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<String>()

    var body: some View {
        @Bindable var model = model

        Table(model.visibleImages, selection: $selection, sortOrder: $model.dockerSortOrder) {
            TableColumn("") { image in
                Toggle("", isOn: model.isChecked(image: image.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!image.status.isDeletable)
                    .help(image.status.isDeletable ? "" : "Wird von einem Container genutzt – nicht löschbar.")
            }
            .width(22)

            TableColumn("Image", value: \.displayName) { image in
                VStack(alignment: .leading, spacing: 1) {
                    Text(image.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if image.status != .buildCache {
                        Text(image.shortID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .help(image.reference)
            }

            TableColumn("Status", value: \.statusSort) { image in
                StatusBadge(image: image)
            }
            .width(min: 200, ideal: 260)

            TableColumn("Erstellt", value: \.createdSort) { image in
                if let created = image.created {
                    Text(created, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                        .help(created.formatted(date: .long, time: .shortened))
                }
            }
            .width(min: 100, ideal: 120)

            TableColumn("Wird frei", value: \.sizeSort) { image in
                HStack {
                    Spacer()
                    Text(image.uniqueSize.formattedBytes).monospacedDigit()
                }
                .help(image.sharedSize > 0
                    ? "Nur dieses Image: \(image.uniqueSize.formattedBytes). Mit anderen Images geteilt: \(image.sharedSize.formattedBytes)."
                    : "")
            }
            .width(min: 80, ideal: 90)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Markieren") {
                let deletable = model.dockerImages.filter { ids.contains($0.id) && $0.status.isDeletable }
                model.checkedImages.formUnion(deletable.map(\.id))
            }
            Button("Markierung entfernen") { model.checkedImages.subtract(ids) }
            if let path = projectPath(for: ids) {
                Divider()
                Button("Projekt im Finder zeigen") { model.reveal([URL(fileURLWithPath: path)]) }
            }
        }
        .onKeyPress(.space) {
            let deletable = Set(model.dockerImages.filter { selection.contains($0.id) && $0.status.isDeletable }.map(\.id))
            guard !deletable.isEmpty else { return .ignored }
            if deletable.isSubset(of: model.checkedImages) {
                model.checkedImages.subtract(deletable)
            } else {
                model.checkedImages.formUnion(deletable)
            }
            return .handled
        }
    }

    private func projectPath(for ids: Set<String>) -> String? {
        guard ids.count == 1, let image = model.dockerImages.first(where: { ids.contains($0.id) }),
              case .project(_, let path) = image.status
        else { return nil }
        return path
    }
}

private struct StatusBadge: View {
    let image: DockerImage

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 3) {
                if !image.status.isDeletable {
                    Image(systemName: "lock.fill").imageScale(.small)
                }
                Text(image.statusLabel)
            }
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(image.statusColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(image.statusColor)

            Text(image.statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(image.statusHelp)
    }
}
