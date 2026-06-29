import Foundation

enum BQUploadError: LocalizedError {
    case invalidTableReference(String)
    case uploadCLINotFound
    case bqNotFound
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidTableReference(let ref):
            return "Invalid BigQuery reference '\(ref)'."
        case .uploadCLINotFound:
            #if DEBUG
            return "bqcsv not found. Set BQCSV_DEV_REPO to your local bqcsv repo, install bqcsv (pip install bqcsv), or set BQCSV_PATH / BQCSV_PYTHON."
            #else
            return "bqcsv CLI not found. Install it and ensure it is on your PATH."
            #endif
        case .bqNotFound:
            return "bq CLI not found. Install the Google Cloud SDK and ensure bq is on your PATH."
        case .uploadFailed(let message):
            return message
        }
    }
}

struct BQUploadService {
    struct UploadResult {
        let succeeded: Bool
        let log: String?
    }

    private struct UploadCommand {
        let cliName: String
        let pathEnvironmentKeys: [String]
        let prefixArguments: [String]
    }

    private static let shell = "/bin/zsh"
    private static let devUploadModule = "src.cli"
    private static let googleCloudSDKPattern = #"['"]([^'"]+/google-cloud-sdk)/path\.(?:zsh|bash)\.inc['"]"#
    private static var cachedToolEnvironment: [String: String]?

    private static func shellQuote(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func directoryContainingExecutable(at path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).deletingLastPathComponent
    }

    private static func parseToolVersions(at path: String) -> [String: String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }

        var versions: [String: String] = [:]
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            versions[String(parts[0])] = String(parts[1])
        }
        return versions
    }

    private static func asdfToolVersion(home: String, plugin: String) -> String? {
        parseToolVersions(at: "\(home)/.tool-versions")[plugin]
    }

    private static func asdfInstalledVersions(home: String, plugin: String) -> [String] {
        let installsDir = "\(home)/.asdf/installs/\(plugin)"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: installsDir) else {
            return []
        }
        return entries.filter { !$0.hasPrefix(".") }.sorted()
    }

    private static func asdfInstallBinary(home: String, plugin: String, command: String) -> String? {
        let version = asdfToolVersion(home: home, plugin: plugin)
            ?? asdfInstalledVersions(home: home, plugin: plugin).last
        guard let version else { return nil }

        let candidate = "\(home)/.asdf/installs/\(plugin)/\(version)/bin/\(command)"
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private static func ensureShellEnvironment(_ environment: inout [String: String]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if environment["HOME"]?.isEmpty != false {
            environment["HOME"] = home
        }
        if environment["USER"]?.isEmpty != false {
            environment["USER"] = NSUserName()
        }
        if environment["ASDF_DATA_DIR"]?.isEmpty != false {
            environment["ASDF_DATA_DIR"] = "\(home)/.asdf"
        }
    }

    private static func pyenvBQCSVExecutable(home: String) -> String? {
        let versionsDir = "\(home)/.pyenv/versions"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: versionsDir) else {
            return nil
        }

        for version in versions.sorted().reversed() {
            let candidate = "\(versionsDir)/\(version)/bin/bqcsv"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func pythonFromScriptShebang(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path),
              let data = try? handle.read(upToCount: 512),
              let firstLine = String(data: data, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .first
        else {
            return nil
        }

        guard firstLine.hasPrefix("#!") else { return nil }
        let interpreter = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard interpreter.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: interpreter)
        else {
            return nil
        }
        return interpreter
    }

    private static func resolvePythonExecutable() -> String {
        for key in ["BQCSV_PYTHON", "PYTHON_PATH"] {
            if let path = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        }

        #if DEBUG
        if let devUploadRepoPath = resolveDevUploadRepoPath() {
            for venvPython in ["\(devUploadRepoPath)/.venv/bin/python3", "\(devUploadRepoPath)/venv/bin/python3"] {
                if FileManager.default.isExecutableFile(atPath: venvPython) {
                    return venvPython
                }
            }
        }
        #endif

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var bqcsvCandidates: [String] = []
        if let bqcsvPath = ProcessInfo.processInfo.environment["BQCSV_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bqcsvPath.isEmpty {
            bqcsvCandidates.append(bqcsvPath)
        }
        if let pyenvBQCSV = pyenvBQCSVExecutable(home: home) {
            bqcsvCandidates.append(pyenvBQCSV)
        }
        if let asdfBQCSV = asdfInstallBinary(home: home, plugin: "python", command: "bqcsv") {
            bqcsvCandidates.append(asdfBQCSV)
        }
        for directory in ["/opt/homebrew/bin", "/usr/local/bin"] {
            bqcsvCandidates.append("\(directory)/bqcsv")
        }

        for candidate in bqcsvCandidates {
            if let python = pythonFromScriptShebang(at: candidate) {
                return python
            }
        }

        return "python3"
    }

    private static func resolveBQExecutable() -> String {
        if let path = ProcessInfo.processInfo.environment["BQ_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = ["\(home)/google-cloud-sdk/bin/bq"]
        candidates.append(contentsOf: shellConfigBinDirectories().map { "\($0)/bq" })

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        if let asdfBQ = asdfInstallBinary(home: home, plugin: "gcloud", command: "bq") {
            return asdfBQ
        }

        return "bq"
    }

    private static func resolveBQCSVExecutable() -> String {
        if let path = ProcessInfo.processInfo.environment["BQCSV_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for directory in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = "\(directory)/bqcsv"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        if let asdfBQCSV = asdfInstallBinary(home: home, plugin: "python", command: "bqcsv") {
            return asdfBQCSV
        }

        if let pyenvBQCSV = pyenvBQCSVExecutable(home: home) {
            return pyenvBQCSV
        }

        return "bqcsv"
    }

    private static func shellConfigBinDirectories() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configFiles = [".zprofile", ".zshrc", ".bash_profile", ".bashrc"]
        var directories: [String] = []

        guard let regex = try? NSRegularExpression(pattern: googleCloudSDKPattern) else {
            return directories
        }

        for file in configFiles {
            let configPath = "\(home)/\(file)"
            guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
                continue
            }

            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            regex.enumerateMatches(in: content, range: range) { match, _, _ in
                guard let match,
                      let sdkRange = Range(match.range(at: 1), in: content) else {
                    return
                }
                directories.append("\(content[sdkRange])/bin")
            }
        }

        return directories
    }

    private static func toolSearchPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories: [String] = []

        func append(_ path: String?) {
            guard let path,
                  !path.isEmpty,
                  !directories.contains(path) else {
                return
            }
            directories.append(path)
        }

        for key in ["BQ_PATH", "BQCSV_PATH", "PYTHON_PATH", "BQCSV_PYTHON"] {
            if let configuredPath = ProcessInfo.processInfo.environment[key] {
                append(directoryContainingExecutable(at: configuredPath))
            }
        }

        append("\(home)/google-cloud-sdk/bin")

        for directory in shellConfigBinDirectories() {
            append(directory)
        }

        append("/opt/homebrew/bin")
        append("/usr/local/bin")
        append("\(home)/.pyenv/shims")
        append("\(home)/.asdf/shims")
        append("\(home)/.asdf/bin")

        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in inheritedPath.split(separator: ":", omittingEmptySubsequences: true) {
            append(String(directory))
        }

        return directories.joined(separator: ":")
    }

    private static func toolEnvironment(extra: [String: String] = [:]) -> [String: String] {
        if extra.isEmpty, let cachedToolEnvironment {
            return cachedToolEnvironment
        }

        var environment = ProcessInfo.processInfo.environment
        ensureShellEnvironment(&environment)
        environment["PATH"] = toolSearchPath()
        for (key, value) in extra {
            environment[key] = value
        }

        if extra.isEmpty {
            cachedToolEnvironment = environment
        }

        return environment
    }

    private static func runShell(
        _ script: String,
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", script]
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = trimmedStdout.isEmpty
            ? trimmedStderr
            : [trimmedStdout, trimmedStderr].filter { !$0.isEmpty }.joined(separator: "\n")

        return (process.terminationStatus, combined)
    }

    private static func cliCommand(name: String, pathEnvironmentKeys: [String]) -> String {
        for key in pathEnvironmentKeys {
            if let path = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        }
        return name
    }

    private static func resolveUploadCommand(environment: inout [String: String]) -> UploadCommand {
        #if DEBUG
        if let devUploadRepoPath = resolveDevUploadRepoPath() {
            let existingPythonPath = environment["PYTHONPATH"] ?? ""
            environment["PYTHONPATH"] = existingPythonPath.isEmpty
                ? devUploadRepoPath
                : "\(devUploadRepoPath):\(existingPythonPath)"

            return UploadCommand(
                cliName: "python3",
                pathEnvironmentKeys: ["PYTHON_PATH", "BQCSV_PYTHON"],
                prefixArguments: ["-m", devUploadModule]
            )
        }
        #endif

        return UploadCommand(cliName: "bqcsv", pathEnvironmentKeys: ["BQCSV_PATH"], prefixArguments: [])
    }

    #if DEBUG
    private static func resolveDevUploadRepoPath() -> String? {
        guard let path = ProcessInfo.processInfo.environment["BQCSV_DEV_REPO"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }

        let cliPath = "\(path)/src/cli.py"
        guard FileManager.default.fileExists(atPath: cliPath) else {
            return nil
        }

        return path
    }
    #endif

    struct TableComponents {
        let project: String
        let dataset: String
        let table: String?

        var datasetReference: String { "\(project):\(dataset)" }
        var tableReference: String? {
            guard let table else { return nil }
            return "\(project):\(dataset).\(table)"
        }
    }

    private static func isValidIdentifier(_ value: String, allowsHyphen: Bool) -> Bool {
        guard !value.isEmpty else { return false }
        return value.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_" || (allowsHyphen && character == "-")
        }
    }

    static func makeTableComponents(
        project: String,
        dataset: String,
        table: String?
    ) throws -> TableComponents {
        let trimmedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDataset = dataset.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTable = table?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isValidIdentifier(trimmedProject, allowsHyphen: true) else {
            throw BQUploadError.invalidTableReference(trimmedProject.isEmpty ? "project" : trimmedProject)
        }
        guard isValidIdentifier(trimmedDataset, allowsHyphen: false) else {
            throw BQUploadError.invalidTableReference(trimmedDataset.isEmpty ? "dataset" : trimmedDataset)
        }
        if let trimmedTable, !trimmedTable.isEmpty {
            guard isValidIdentifier(trimmedTable, allowsHyphen: false) else {
                throw BQUploadError.invalidTableReference(trimmedTable)
            }
            return TableComponents(project: trimmedProject, dataset: trimmedDataset, table: trimmedTable)
        }
        return TableComponents(project: trimmedProject, dataset: trimmedDataset, table: nil)
    }

    private static func cliAvailabilityCheck(executable: String, notFoundMessage: String) -> String {
        if executable.contains("/") {
            return "[ -x \(shellQuote(executable)) ] || { echo \(shellQuote(notFoundMessage)); exit 127; }"
        }
        return "command -v \(shellQuote(executable)) >/dev/null 2>&1 || { echo \(shellQuote(notFoundMessage)); exit 127; }"
    }

    private static func resolvedUploadCLIExecutable(_ uploadCommand: UploadCommand) -> String {
        if uploadCommand.cliName == "bqcsv" {
            return resolveBQCSVExecutable()
        }
        if uploadCommand.cliName == "python3" {
            return resolvePythonExecutable()
        }
        return cliCommand(
            name: uploadCommand.cliName,
            pathEnvironmentKeys: uploadCommand.pathEnvironmentKeys
        )
    }

    private static func uploadCommandInvocation(_ uploadCommand: UploadCommand) -> String {
        let command = resolvedUploadCLIExecutable(uploadCommand)
        return ([command] + uploadCommand.prefixArguments).map(shellQuote).joined(separator: " ")
    }

    private static func buildUploadScript(
        csvURL: URL,
        components: TableComponents,
        uploadCommand: UploadCommand
    ) -> String {
        let uploadCLI = uploadCommandInvocation(uploadCommand)
        let bqExecutable = resolveBQExecutable()
        let uploadCLIExecutable = resolvedUploadCLIExecutable(uploadCommand)
        let bqCLI = shellQuote(bqExecutable)
        let csvPath = shellQuote(csvURL.path)
        let datasetReference = shellQuote(components.datasetReference)
        let project = shellQuote(components.project)
        let dataset = shellQuote(components.dataset)

        let uploadInvocation: String
        if let table = components.table {
            let tableReference = shellQuote(components.tableReference!)
            let tableArg = shellQuote(table)
            uploadInvocation = """
            replace_flag=""
            if \(bqCLI) show \(tableReference) >/dev/null 2>&1; then
              replace_flag="--replace"
            fi
            \(uploadCLI) \(csvPath) --project \(project) --dataset \(dataset) --table \(tableArg) --output json "$replace_flag"
            """
        } else {
            uploadInvocation = """
            \(uploadCLI) \(csvPath) --project \(project) --dataset \(dataset) --output json
            """
        }

        return """
        set -e
        \(cliAvailabilityCheck(executable: bqExecutable, notFoundMessage: "BQ_NOT_FOUND"))
        \(cliAvailabilityCheck(executable: uploadCLIExecutable, notFoundMessage: "UPLOAD_CLI_NOT_FOUND"))
        if ! \(bqCLI) show \(datasetReference) >/dev/null 2>&1; then
          \(bqCLI) mk -d \(datasetReference)
        fi
        \(uploadInvocation)
        """
    }

    private static func parseUploadResponse(_ output: String) -> UploadResult? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String
        else {
            return nil
        }

        let log = (json["log"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return UploadResult(
            succeeded: status == "success",
            log: log?.isEmpty == false ? log : nil
        )
    }

    static func upload(
        csvURL: URL,
        project: String,
        dataset: String,
        table: String?
    ) async throws -> UploadResult {
        let components = try makeTableComponents(project: project, dataset: dataset, table: table)
        var environment = toolEnvironment()
        let uploadCommand = resolveUploadCommand(environment: &environment)

        let script = buildUploadScript(
            csvURL: csvURL,
            components: components,
            uploadCommand: uploadCommand
        )

        let uploadResult = try runShell(script, environment: environment)

        switch uploadResult.output {
        case "BQ_NOT_FOUND":
            throw BQUploadError.bqNotFound
        case "UPLOAD_CLI_NOT_FOUND":
            throw BQUploadError.uploadCLINotFound
        default:
            break
        }

        if let parsed = parseUploadResponse(uploadResult.output) {
            return parsed
        }

        guard uploadResult.status == 0 else {
            let message = uploadResult.output.isEmpty
                ? "bqcsv failed with exit code \(uploadResult.status)"
                : uploadResult.output
            throw BQUploadError.uploadFailed(message)
        }

        return UploadResult(succeeded: true, log: nil)
    }
}
