import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum AppSettings {
    static let projectKey = "bqProject"
    static let datasetKey = "bqDataset"
    static let tableKey = "bqTable"
    private static let legacyTableReferenceKey = "tableReference"

    static var project: String {
        get { UserDefaults.standard.string(forKey: projectKey) ?? migratedLegacy()?.project ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: projectKey) }
    }

    static var dataset: String {
        get { UserDefaults.standard.string(forKey: datasetKey) ?? migratedLegacy()?.dataset ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: datasetKey) }
    }

    static var table: String {
        get { UserDefaults.standard.string(forKey: tableKey) ?? migratedLegacy()?.table ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: tableKey) }
    }

    private static func migratedLegacy() -> (project: String, dataset: String, table: String)? {
        guard UserDefaults.standard.string(forKey: projectKey) == nil,
              UserDefaults.standard.string(forKey: datasetKey) == nil,
              UserDefaults.standard.string(forKey: tableKey) == nil,
              let legacy = UserDefaults.standard.string(forKey: legacyTableReferenceKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !legacy.isEmpty
        else {
            return nil
        }

        let parts = legacy.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        let project = String(parts[0])
        let dataset = String(parts[1])
        let table = parts.count >= 3 ? String(parts[2]) : ""
        UserDefaults.standard.set(project, forKey: projectKey)
        UserDefaults.standard.set(dataset, forKey: datasetKey)
        UserDefaults.standard.set(table, forKey: tableKey)
        return (project, dataset, table)
    }

    static func persist(project: String, dataset: String, table: String) {
        self.project = project
        self.dataset = dataset
        self.table = table
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var project = AppSettings.project
    @State private var dataset = AppSettings.dataset
    @State private var table = AppSettings.table
    @State private var selectedFileURL: URL?
    @State private var securityScopedFileURL: URL?
    @State private var isTargeted = false
    @State private var isUploading = false
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var uploadResult: BQUploadService.UploadResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("BigQuery destination")
                    .font(.headline)
                TextField("Project", text: $project)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isUploading)
                TextField("Dataset", text: $dataset)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isUploading)
                TextField("Table (optional)", text: $table)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isUploading)
            }

            dropZone

            statusView

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 300)
        .onChange(of: project) { _ in persistSettings() }
        .onChange(of: dataset) { _ in persistSettings() }
        .onChange(of: table) { _ in persistSettings() }
        .onChange(of: scenePhase) { newPhase in
            if newPhase != .active {
                persistSettings()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            persistSettings()
        }
    }

    private func persistSettings() {
        AppSettings.persist(project: project, dataset: dataset, table: table)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                )

            VStack(spacing: 8) {
                if isUploading {
                    ProgressView()
                        .controlSize(.regular)
                } else {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
                if !isUploading {
                    Text("Drop CSV here")
                        .font(.headline)
                }
                if let selectedFileURL, isUploading {
                    Text(selectedFileURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("or click to choose a file")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { if !isUploading { openFilePicker() } }
        .onDrop(of: [.fileURL, .url], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let uploadResult {
                if uploadResult.succeeded {
                    Text("🟢 Your upload was successful.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    uploadErrorView(
                        message: "🔴 There was an error during the upload.",
                        log: uploadResult.log
                    )
                }
            } else if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func uploadErrorView(message: String, log: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if let log, !log.isEmpty {
                ScrollView {
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: 100)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose CSV file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, UTType(filenameExtension: "csv")!]

        if panel.runModal() == .OK, let url = panel.url {
            selectFile(url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !isUploading else { return false }
        guard let provider = providers.first else { return false }

        if provider.canLoadObject(ofClass: URL.self) {
            provider.loadObject(ofClass: URL.self) { item, _ in
                guard let url = item as? URL else { return }
                DispatchQueue.main.async { selectFile(url) }
            }
            return true
        }

        let typeIdentifiers = [UTType.fileURL.identifier, UTType.url.identifier]
        guard let typeId = typeIdentifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, _ in
            guard let url = urlFromDropItem(item) else { return }
            DispatchQueue.main.async { selectFile(url) }
        }
        return true
    }

    private func urlFromDropItem(_ item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let nsurl = item as? NSURL { return nsurl as URL }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String {
            if string.hasPrefix("file://") {
                return URL(string: string)
            }
            return URL(fileURLWithPath: string)
        }
        return nil
    }

    private func selectFile(_ url: URL) {
        guard !isUploading else { return }

        guard url.pathExtension.lowercased() == "csv" else {
            uploadResult = nil
            statusMessage = "Please choose a .csv file."
            statusIsError = true
            return
        }

        guard !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !dataset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            uploadResult = nil
            statusMessage = "Enter project and dataset before uploading."
            statusIsError = true
            return
        }

        beginSecurityScopedAccess(for: url)
        selectedFileURL = url
        startUpload()
    }

    private func beginSecurityScopedAccess(for url: URL) {
        if let securityScopedFileURL {
            securityScopedFileURL.stopAccessingSecurityScopedResource()
            self.securityScopedFileURL = nil
        }
        if url.startAccessingSecurityScopedResource() {
            securityScopedFileURL = url
        }
    }

    private func endSecurityScopedAccess() {
        if let securityScopedFileURL {
            securityScopedFileURL.stopAccessingSecurityScopedResource()
            self.securityScopedFileURL = nil
        }
    }

    private func startUpload() {
        guard let fileURL = selectedFileURL else { return }

        isUploading = true
        statusMessage = ""
        statusIsError = false
        uploadResult = nil

        Task {
            do {
                let result = try await BQUploadService.upload(
                    csvURL: fileURL,
                    project: project,
                    dataset: dataset,
                    table: table.isEmpty ? nil : table
                )
                await MainActor.run {
                    uploadResult = result
                    statusMessage = ""
                    isUploading = false
                    selectedFileURL = nil
                    endSecurityScopedAccess()
                }
            } catch {
                await MainActor.run {
                    uploadResult = BQUploadService.UploadResult(
                        succeeded: false,
                        log: error.localizedDescription
                    )
                    statusMessage = ""
                    statusIsError = false
                    isUploading = false
                    selectedFileURL = nil
                    endSecurityScopedAccess()
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
