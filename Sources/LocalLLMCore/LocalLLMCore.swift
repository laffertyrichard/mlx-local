import Foundation

public struct CachedModel: Identifiable, Hashable, Sendable {
    public let repository: String
    public let snapshotPath: URL
    public let sizeBytes: Int64

    public var id: String { repository }
    public var name: String { repository.split(separator: "/").last.map(String.init) ?? repository }
    public var organization: String { repository.split(separator: "/").first.map(String.init) ?? "Local" }
    public var formattedSize: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }

    public init(repository: String, snapshotPath: URL, sizeBytes: Int64) {
        self.repository = repository
        self.snapshotPath = snapshotPath
        self.sizeBytes = sizeBytes
    }
}

public struct LocalModel: Identifiable, Hashable, Sendable {
    public let repository: String
    public let snapshotPath: URL
    public let sizeBytes: Int64

    public var id: String { repository }
    public var name: String { repository.split(separator: "/").last.map(String.init) ?? repository }
    public var organization: String { repository.split(separator: "/").first.map(String.init) ?? "Local" }
    public var isAbliterated: Bool { repository.localizedCaseInsensitiveContains("abliterat") }
    public var formattedSize: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }

    public init(repository: String, snapshotPath: URL, sizeBytes: Int64) {
        self.repository = repository
        self.snapshotPath = snapshotPath
        self.sizeBytes = sizeBytes
    }

    public init(cached: CachedModel) {
        self.init(repository: cached.repository, snapshotPath: cached.snapshotPath, sizeBytes: cached.sizeBytes)
    }
}

public struct ModelCatalog: Sendable {
    public let cacheRoot: URL

    public init(cacheRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".cache/huggingface/hub")) {
        self.cacheRoot = cacheRoot
    }

    public func discoverCached() -> [CachedModel] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let folders = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: keys) else { return [] }

        return folders.compactMap { folder -> CachedModel? in
            let prefix = "models--"
            guard folder.lastPathComponent.hasPrefix(prefix) else { return nil }
            let encoded = String(folder.lastPathComponent.dropFirst(prefix.count))
            guard let separator = encoded.range(of: "--") else { return nil }
            let repository = encoded.replacingCharacters(in: separator, with: "/")
            let snapshots = folder.appending(path: "snapshots")
            guard let choices = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: keys) else { return nil }
            let valid = choices.filter {
                fm.fileExists(atPath: $0.appending(path: "config.json").path) && containsModelWeights($0)
            }
            guard let snapshot = valid.max(by: { modificationDate($0) < modificationDate($1) }) else { return nil }
            return CachedModel(repository: repository, snapshotPath: snapshot,
                               sizeBytes: directorySize(folder.appending(path: "blobs")))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func discover() -> [LocalModel] {
        discoverCached().filter { isChatModel($0.snapshotPath) }.map(LocalModel.init(cached:)).sorted {
            if $0.isAbliterated != $1.isAbliterated { return $0.isAbliterated }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func isChatModel(_ snapshot: URL) -> Bool {
        guard let data = try? Data(contentsOf: snapshot.appending(path: "config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let type = (object["model_type"] as? String ?? "").lowercased()
        let unsupported = ["bert", "vl", "ocr", "embedding", "asr"]
        return !unsupported.contains(where: type.contains)
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func containsModelWeights(_ snapshot: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil) else { return false }
        return files.contains { ["safetensors", "gguf", "npz"].contains($0.pathExtension.lowercased()) }
    }

    private func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}

public struct ServerConfiguration: Sendable, Equatable {
    public let executable: URL
    public let launcherScript: URL?
    public let model: String
    public let port: Int
    public let maxTokens: Int
    public let temperature: Double
    public let decodeConcurrency: Int
    public let promptConcurrency: Int
    public let promptCacheBytes: Int64

    public init(executable: URL, launcherScript: URL? = nil, modelPath: URL, port: Int = 8081, maxTokens: Int = 4096,
                temperature: Double = 0, decodeConcurrency: Int = 2, promptConcurrency: Int = 1,
                promptCacheBytes: Int64 = 4_294_967_296) {
        self.executable = executable
        self.launcherScript = launcherScript
        self.model = modelPath.path
        self.port = port
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.decodeConcurrency = decodeConcurrency
        self.promptConcurrency = promptConcurrency
        self.promptCacheBytes = promptCacheBytes
    }

    public init(executable: URL, launcherScript: URL? = nil, modelIdentifier: String, port: Int = 8081, maxTokens: Int = 4096,
                temperature: Double = 0, decodeConcurrency: Int = 2, promptConcurrency: Int = 1,
                promptCacheBytes: Int64 = 4_294_967_296) {
        self.executable = executable
        self.launcherScript = launcherScript
        self.model = modelIdentifier
        self.port = port
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.decodeConcurrency = decodeConcurrency
        self.promptConcurrency = promptConcurrency
        self.promptCacheBytes = promptCacheBytes
    }

    public var endpoint: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }
    public var healthEndpoint: URL { endpoint.appending(path: "models") }
    public var arguments: [String] {
        (launcherScript.map { [$0.path] } ?? []) + ["--model", model, "--host", "127.0.0.1", "--port", String(port),
         "--max-tokens", String(maxTokens), "--temp", String(temperature), "--log-level", "INFO"]
    }

    public var tunedArguments: [String] {
        arguments + ["--decode-concurrency", String(decodeConcurrency),
                     "--prompt-concurrency", String(promptConcurrency),
                     "--prefill-step-size", "2048", "--prompt-cache-size", "2",
                     "--prompt-cache-bytes", String(promptCacheBytes)]
    }
}

public enum MLXExecutable {
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = [home.appending(path: ".local/share/uv/tools/mlx-lm/bin/python"), home.appending(path: ".local/bin/mlx_lm.server"), URL(filePath: "/opt/homebrew/bin/mlx_lm.server")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

public enum PythonExecutable {
    /// Resolve the interpreter belonging to an installed uv tool instead of relying on
    /// `/usr/bin/python3`, which is not present on a clean macOS installation.
    public static func forToolExecutable(_ executable: URL) -> URL? {
        let files = FileManager.default
        if executable.lastPathComponent.hasPrefix("python"),
           files.isExecutableFile(atPath: executable.path) {
            return executable
        }
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096),
              let firstLine = String(data: data, encoding: .utf8)?.split(separator: "\n", maxSplits: 1).first,
              firstLine.hasPrefix("#!") else { return nil }
        let declaration = firstLine.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
        if declaration.hasPrefix("/usr/bin/env ") {
            let name = declaration.dropFirst("/usr/bin/env ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.hasPrefix("python"), !name.contains(" ") else { return nil }
            let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
                .map { URL(filePath: $0).appending(path: name) }
            return candidates.first { files.isExecutableFile(atPath: $0.path) }
        }
        guard declaration.hasPrefix("/") else { return nil }
        let interpreter = URL(filePath: declaration)
        guard interpreter.lastPathComponent.hasPrefix("python") else { return nil }
        return files.isExecutableFile(atPath: interpreter.path) ? interpreter : nil
    }
}


public enum ModelCacheError: LocalizedError, Equatable {
    case invalidRepositoryIdentifier(String)
    case modelNotCached(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepositoryIdentifier:
            "Enter a Hugging Face model as owner/repository."
        case .modelNotCached(let repository):
            "The model is not cached: \(repository)."
        }
    }
}

public struct ModelCacheManager: Sendable {
    public let cacheRoot: URL

    public init(cacheRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".cache/huggingface/hub")) {
        self.cacheRoot = cacheRoot.standardizedFileURL
    }

    public static func isValidRepositoryIdentifier(_ repository: String) -> Bool {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." &&
            part.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    public func cacheFolder(for repository: String) throws -> URL {
        guard Self.isValidRepositoryIdentifier(repository) else {
            throw ModelCacheError.invalidRepositoryIdentifier(repository)
        }
        let encoded = "models--" + repository.replacingOccurrences(of: "/", with: "--")
        return cacheRoot.appending(path: encoded, directoryHint: .isDirectory)
    }

    public func remove(repository: String) throws {
        let folder = try cacheFolder(for: repository)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw ModelCacheError.modelNotCached(repository)
        }
        try FileManager.default.removeItem(at: folder)
    }
}

public enum HuggingFaceExecutable {
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = [
            home.appending(path: ".local/share/uv/tools/mlx-lm/bin/hf"),
            home.appending(path: ".local/bin/hf"),
            URL(filePath: "/opt/homebrew/bin/hf")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
