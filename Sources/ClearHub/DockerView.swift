import SwiftUI

struct DockerResultsArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.dockerImages.isEmpty {
            DockerTable()
        } else {
            DockerPlaceholder(
                emptyTitle: "Keine Images",
                emptyText: "Docker hat keine lokalen Images.",
                introTitle: "Docker-Images prüfen",
                introText: "ClearHub zeigt, welche Images ein Container nutzt, welche zu einem Projekt gehören und welche verwaist sind."
            )
        }
    }
}

struct DockerVolumesArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.dockerVolumes.isEmpty {
            VolumeTable()
        } else {
            DockerPlaceholder(
                emptyTitle: "Keine Volumes",
                emptyText: "Docker hat keine Volumes.",
                introTitle: "Docker-Volumes prüfen",
                introText: "ClearHub zeigt, welche Volumes ein Container nutzt, welche zu einem Projekt gehören und welche verwaist sind."
            )
        }
    }
}

private struct DockerPlaceholder: View {
    @Environment(AppModel.self) private var model
    let emptyTitle: String
    let emptyText: String
    let introTitle: String
    let introText: String

    var body: some View {
        Group {
            if model.isScanning || model.isLoadingDocker {
                ContentUnavailableView {
                    EmptyStateLabel(title: "Docker wird abgefragt …", systemImage: "shippingbox")
                } description: {
                    Text("Zuerst werden die Suchorte nach Compose- und DDEV-Projekten durchsucht.")
                }
            } else if let error = model.dockerError {
                ContentUnavailableView {
                    EmptyStateLabel(title: "Docker nicht erreichbar", systemImage: "exclamationmark.triangle", color: Darcula.warn)
                } description: {
                    Text(error)
                } actions: {
                    Button("Erneut versuchen") { model.loadDocker() }
                }
            } else if !model.includeDocker {
                ContentUnavailableView {
                    EmptyStateLabel(title: "Docker-Scan ist aus", systemImage: "shippingbox", color: Darcula.muted)
                } description: {
                    Text("Aktiviere „Docker“ und scanne erneut.")
                }
            } else if model.hasScanned {
                ContentUnavailableView {
                    EmptyStateLabel(title: emptyTitle, systemImage: "checkmark.circle", color: Darcula.success)
                } description: {
                    Text(emptyText)
                }
            } else {
                ContentUnavailableView {
                    EmptyStateLabel(title: introTitle, systemImage: "shippingbox")
                } description: {
                    Text(introText)
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
                            .darculaSecondary()
                    }
                }
                .help(image.reference)
                .darculaRowText()
            }

            TableColumn("Status", value: \.statusSort) { image in
                StatusBadge(image: image)
            }
            .width(min: 200, ideal: 260)

            TableColumn("Erstellt", value: \.createdSort) { image in
                if let created = image.created {
                    Text(created, format: .relative(presentation: .named))
                        .darculaSecondary()
                        .help(created.formatted(date: .long, time: .shortened))
                }
            }
            .width(min: 100, ideal: 120)

            TableColumn("Wird frei", value: \.sizeSort) { image in
                HStack {
                    Spacer()
                    Text(image.uniqueSize.formattedBytes).monospacedDigit()
                }
                .darculaRowText()
                .help(image.sharedSize > 0
                    ? "Nur dieses Image: \(image.uniqueSize.formattedBytes). Mit anderen Images geteilt: \(image.sharedSize.formattedBytes)."
                    : "")
            }
            .width(min: 80, ideal: 90)
        }
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
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

private struct VolumeTable: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<String>()

    var body: some View {
        @Bindable var model = model

        Table(model.visibleVolumes, selection: $selection, sortOrder: $model.volumeSortOrder) {
            TableColumn("") { volume in
                Toggle("", isOn: model.isChecked(volume: volume.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!volume.status.isDeletable)
                    .help(lockHelp(volume))
            }
            .width(22)

            TableColumn("Volume", value: \.name) { volume in
                VStack(alignment: .leading, spacing: 1) {
                    Text(volume.displayName)
                        .fontWeight(.medium)
                        .font(volume.isAnonymous ? .body.monospaced() : .body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !volume.driver.isEmpty, volume.driver != "local" {
                        Text(volume.driver)
                            .font(.caption)
                            .darculaSecondary()
                    }
                }
                .help(volume.name)
                .darculaRowText()
            }

            TableColumn("Status", value: \.statusSort) { volume in
                StatusBadge(volume: volume)
            }
            .width(min: 220, ideal: 300)

            TableColumn("Größe", value: \.sizeSort) { volume in
                HStack {
                    Spacer()
                    Text(volume.size.formattedBytes).monospacedDigit()
                }
                .darculaRowText()
            }
            .width(min: 80, ideal: 90)
        }
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Markieren") {
                let deletable = model.dockerVolumes.filter { ids.contains($0.id) && $0.status.isDeletable }
                model.checkedVolumes.formUnion(deletable.map(\.id))
            }
            Button("Markierung entfernen") { model.checkedVolumes.subtract(ids) }
            if let path = projectPath(for: ids) {
                Divider()
                Button("Projekt im Finder zeigen") { model.reveal([URL(fileURLWithPath: path)]) }
            }
        }
        .onKeyPress(.space) {
            let deletable = Set(model.dockerVolumes.filter { selection.contains($0.id) && $0.status.isDeletable }.map(\.id))
            guard !deletable.isEmpty else { return .ignored }
            if deletable.isSubset(of: model.checkedVolumes) {
                model.checkedVolumes.subtract(deletable)
            } else {
                model.checkedVolumes.formUnion(deletable)
            }
            return .handled
        }
    }

    private func lockHelp(_ volume: DockerVolume) -> String {
        switch volume.status {
        case .inUse: "Wird von einem Container genutzt – nicht löschbar."
        case .project: "Enthält Daten eines Projekts auf deiner Platte – nicht löschbar."
        default: ""
        }
    }

    private func projectPath(for ids: Set<String>) -> String? {
        guard ids.count == 1, let volume = model.dockerVolumes.first(where: { ids.contains($0.id) }),
              case .project(_, let path) = volume.status
        else { return nil }
        return path
    }
}

private struct StatusBadge: View {
    let label: String
    let detail: String
    let help: String
    let color: Color
    let locked: Bool

    init(image: DockerImage) {
        label = image.statusLabel
        detail = image.statusDetail
        help = image.statusHelp
        color = image.statusColor
        locked = !image.status.isDeletable
    }

    init(volume: DockerVolume) {
        label = volume.statusLabel
        detail = volume.statusDetail
        help = volume.statusHelp
        color = volume.statusColor
        locked = !volume.status.isDeletable
    }

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 3) {
                if locked {
                    Image(systemName: "lock.fill").imageScale(.small)
                }
                Text(label)
            }
            .font(.caption)
            .darculaBadge(color)

            Text(detail)
                .font(.caption)
                .darculaSecondary()
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .darculaRowText()
        .help(help)
    }
}
