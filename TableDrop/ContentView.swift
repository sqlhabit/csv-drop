import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum AppSettings {
    static let tableReferenceKey = "tableReference"

    static var tableReference: String {
        get { UserDefaults.standard.string(forKey: tableReferenceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: tableReferenceKey) }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var tableReference = AppSettings.tableReference
    @State private var selectedFileURL: URL?
    @State private var isTargeted = false
    @State private var isUploading = false
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var uploadResult: BQUploadService.UploadResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Table reference")
                    .font(.headline)
                TextField("project_id.dataset_id.table_id", text: $tableReference)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isUploading)
            }

            dropZone

            statusView

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 300)
        .onChange(of: tableReference) { newValue in
            AppSettings.tableReference = newValue
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase != .active {
                AppSettings.tableReference = tableReference
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            AppSettings.tableReference = tableReference
        }
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
                    Text("🟢 Table was uploaded successfully.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("🔴 There was an error during the upload")
                        .font(.caption)
                        .foregroundStyle(.red)
                    if let log = uploadResult.log {
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
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

        guard !tableReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            uploadResult = nil
            statusMessage = "Enter a table reference before uploading."
            statusIsError = true
            return
        }

        selectedFileURL = url
        startUpload()
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
                    tableReference: tableReference
                )
                await MainActor.run {
                    uploadResult = result
                    statusMessage = ""
                    isUploading = false
                    selectedFileURL = nil
                }
            } catch {
                await MainActor.run {
                    uploadResult = nil
                    statusMessage = error.localizedDescription
                    statusIsError = true
                    isUploading = false
                    selectedFileURL = nil
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
