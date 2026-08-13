import Foundation
import LocalLLMCore
import LocalInferenceBackends

@MainActor
final class AutoRouterController: ObservableObject {
    @Published private(set) var registryModels: [RegisteredModel] = []
    @Published private(set) var decision: RoutingDecision?
    @Published private(set) var trace: ExecutionTrace?
    @Published private(set) var events: [String] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false
    @Published private(set) var resumableRequest: InferenceRequest?

    private let classifier = TaskClassifier(semanticClassifier: NaturalLanguageTaskClassifier())
    private let router = CapabilityRouter()
    private var registry: ModelRegistry
    private var profileRegistry: ModelProfileRegistry
    private let manager: ModelResourceManager
    let storageRoot = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/MLXMenu")

    init() {
        let bundleBenchmark = Bundle.main.resourceURL?.appending(path: "local-results.json")
        let developmentBenchmark = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Benchmarks/local-results.json")
        let benchmark = [bundleBenchmark, developmentBenchmark].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        let bundleProfiles = Bundle.main.resourceURL?.appending(path: "capabilities.json")
        let developmentProfiles = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "ModelMetadata/capabilities.json")
        let profiles = [bundleProfiles, developmentProfiles].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        var discovered = ModelRegistryDiscovery(benchmarkURL: benchmark, profileURL: profiles).discover()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let wrapperCandidates = [Bundle.main.resourceURL?.appending(path: "mlx_server_no_mpi.py"),
                                 URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Sources/MLXMenu/Resources/mlx_server_no_mpi.py")].compactMap { $0 }
        let wrapper = wrapperCandidates.first { FileManager.default.fileExists(atPath: $0.path) }
        let watchdogCandidates = [Bundle.main.resourceURL?.appending(path: "worker_watchdog.py"),
                                  URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Sources/MLXMenu/Resources/worker_watchdog.py")].compactMap { $0 }
        let watchdog = watchdogCandidates.first { FileManager.default.fileExists(atPath: $0.path) }
        let vlmExecutable = home.appending(path: ".local/bin/mlx_vlm.server")
        var runtimes: [InferenceBackend: any ModelRuntime] = [.nativeDocument: NativeDocumentRuntime()]
        if let executable = MLXExecutable.discover(), !executable.lastPathComponent.localizedCaseInsensitiveContains("python") || wrapper != nil {
            let launcher = executable.lastPathComponent.localizedCaseInsensitiveContains("python") ? wrapper : nil
            runtimes[.mlxLM] = OpenAIWorkerRuntime(
                backend: .mlxLM, executable: executable, launcherScript: launcher,
                watchdogScript: watchdog,
                watchdogInterpreter: PythonExecutable.forToolExecutable(executable), basePort: 18081)
        } else {
            for var model in discovered.models where model.backend == .mlxLM { model.health = .unavailable; discovered.upsert(model) }
        }
        if FileManager.default.isExecutableFile(atPath: vlmExecutable.path) {
            runtimes[.mlxVLM] = OpenAIWorkerRuntime(
                backend: .mlxVLM, executable: vlmExecutable, watchdogScript: watchdog,
                watchdogInterpreter: PythonExecutable.forToolExecutable(vlmExecutable), basePort: 18181)
        } else {
            for var model in discovered.models where model.backend == .mlxVLM { model.health = .unavailable; discovered.upsert(model) }
        }
        let audioExecutable = home.appending(path: ".local/bin/mlx_audio.server")
        if FileManager.default.isExecutableFile(atPath: audioExecutable.path) {
            runtimes[.whisperMLX] = MLXAudioRuntime(
                executable: audioExecutable, watchdogScript: watchdog,
                watchdogInterpreter: PythonExecutable.forToolExecutable(audioExecutable), port: 18481)
        } else {
            for var model in discovered.models where model.backend == .whisperMLX { model.health = .unavailable; discovered.upsert(model) }
        }
        registry = discovered; registryModels = discovered.models.sorted { $0.id < $1.id }
        let installedProfileRegistry = storageRoot.appending(path: "model-profiles.json")
        let bundledProfileRegistry = Bundle.main.resourceURL?.appending(path: "model-profiles.json")
        let developmentProfileRegistry = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "V3/model-profiles.json")
        let profileDecoder = JSONDecoder(); profileDecoder.dateDecodingStrategy = .iso8601
        let shippedURL = [bundledProfileRegistry, developmentProfileRegistry].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let shipped = shippedURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? profileDecoder.decode(ModelProfileRegistry.self, from: $0) } ?? .init()
        if FileManager.default.fileExists(atPath: installedProfileRegistry.path) {
            do {
                let installed = try profileDecoder.decode(ModelProfileRegistry.self, from: Data(contentsOf: installedProfileRegistry))
                profileRegistry = ModelProfileRegistry.merged(shipped: shipped, installed: installed)
            } catch {
                let quarantine = installedProfileRegistry.deletingLastPathComponent().appending(path: "model-profiles.corrupt-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: installedProfileRegistry, to: quarantine)
                profileRegistry = shipped
            }
        } else { profileRegistry = shipped }
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        let pressureAware = Int64(Double(Self.availableMemoryEstimate() ?? physical) * 0.80)
        manager = ModelResourceManager(registry: discovered, runtimes: runtimes,
                                       memoryBudgetBytes: min(Int64(Double(physical) * 0.72), pressureAware))
        try? FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageRoot.path)
        let profileEncoder = JSONEncoder(); profileEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]; profileEncoder.dateEncodingStrategy = .iso8601
        if let data = try? profileEncoder.encode(profileRegistry) { secureWrite(data, to: installedProfileRegistry) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(registryModels) { secureWrite(data, to: storageRoot.appending(path: "registry.json")) }
        restoreLatestTrace(); restoreLatestResumable()
    }

    func run(_ request: InferenceRequest) async throws -> ExecutionTrace {
        try await run(request, decisionOverride: nil)
    }

    func resumeLatest() async throws -> ExecutionTrace {
        guard let request = resumableRequest, let checkpoint = try loadCheckpoint(requestID: request.id) else {
            throw ResourceError.staleCheckpoint(["no resumable job is available"])
        }
        return try await run(request, decisionOverride: checkpoint.decision)
    }

    func discardResumableJob() {
        guard let request = resumableRequest else { return }
        try? FileManager.default.removeItem(at: storageRoot.appending(path: "jobs/\(request.id.uuidString)"))
        cleanupTemporary(requestID: request.id); resumableRequest = nil
    }

    private func run(_ request: InferenceRequest, decisionOverride: RoutingDecision?) async throws -> ExecutionTrace {
        isRunning = true; errorMessage = nil; trace = nil; events = []
        defer { isRunning = false }
        persistRequest(request)
        let requirements = await classifier.classify(request)
        let resources = await manager.snapshot(totalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory))
        let selected: RoutingDecision
        do { selected = try decisionOverride ?? router.route(request: request, requirements: requirements, registry: registry, resources: resources, profileRegistry: profileRegistry) }
        catch { errorMessage = error.localizedDescription; removeResumableState(requestID: request.id); throw error }
        decision = selected
        do {
            let checkpoint = try loadCheckpoint(requestID: request.id)
            let result = try await manager.execute(decision: selected, request: request, resumeFrom: checkpoint, onEvent: { [weak self] event in
                await MainActor.run { self?.events.append(Self.describe(event)) }
            }, onCheckpoint: { [weak self] checkpoint in
                await MainActor.run { self?.persist(checkpoint) }
            })
            trace = result; persist(result); await refreshRegistrySnapshot(); cleanupTemporary(requestID: request.id)
            removeResumableState(requestID: request.id); resumableRequest = nil; pruneJobs()
            Task { [manager] in try? await Task.sleep(for: .seconds(300)); await manager.unloadIdle(olderThan: Date().addingTimeInterval(-300)) }
            return result
        } catch {
            errorMessage = error.localizedDescription; persistFailure(requestID: request.id, error: error, decision: selected)
            let isStale: Bool = { if case ResourceError.staleCheckpoint = error { return true }; return false }()
            let savedCheckpoint = try? loadCheckpoint(requestID: request.id)
            let hasCheckpoint = !isStale && (savedCheckpoint?.completedStageCount ?? 0) > 0
            if hasCheckpoint { resumableRequest = request }
            else { cleanupTemporary(requestID: request.id); removeResumableState(requestID: request.id) }
            await refreshRegistrySnapshot(); pruneJobs(); throw error
        }
    }

    func unloadIdle() async { await manager.unloadIdle(olderThan: Date().addingTimeInterval(-300)) }
    func shutdown() async { await manager.shutdown(); await refreshRegistrySnapshot() }

    private func refreshRegistrySnapshot() async {
        registryModels = await manager.registeredModels().sorted { $0.id < $1.id }
        registry = ModelRegistry(models: registryModels)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(registryModels) { secureWrite(data, to: storageRoot.appending(path: "registry.json")) }
    }

    private func persistRequest(_ request: InferenceRequest) {
        let directory = storageRoot.appending(path: "jobs/\(request.id.uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(request) { secureWrite(data, to: directory.appending(path: "request.json")) }
    }

    private func removeResumableState(requestID: UUID) {
        let directory = storageRoot.appending(path: "jobs/\(requestID.uuidString)")
        try? FileManager.default.removeItem(at: directory.appending(path: "checkpoint.json"))
        try? FileManager.default.removeItem(at: directory.appending(path: "request.json"))
    }

    private func loadCheckpoint(requestID: UUID) throws -> ExecutionCheckpoint? {
        let url = storageRoot.appending(path: "jobs/\(requestID.uuidString)/checkpoint.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ExecutionCheckpoint.self, from: data)
        } catch {
            throw ResourceError.staleCheckpoint(["checkpoint file is corrupted or incompatible: \(error.localizedDescription)"])
        }
    }

    private func persist(_ checkpoint: ExecutionCheckpoint) {
        let directory = storageRoot.appending(path: "jobs/\(checkpoint.decision.requestID.uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(checkpoint) { secureWrite(data, to: directory.appending(path: "checkpoint.json")) }
        for (index, artifact) in checkpoint.artifacts.enumerated() {
            secureWrite(Data(artifact.content.utf8), to: directory.appending(path: String(format: "%02d-%@.txt", index + 1, artifact.kind.rawValue)))
        }
    }

    private func persist(_ trace: ExecutionTrace) {
        let directory = storageRoot.appending(path: "jobs/\(trace.decision.requestID.uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(trace) { secureWrite(data, to: directory.appending(path: "trace.json")) }
        for (index, artifact) in trace.artifacts.enumerated() {
            secureWrite(Data(artifact.content.utf8), to: directory.appending(path: String(format: "%02d-%@.txt", index + 1, artifact.kind.rawValue)))
        }
        try? trace.decision.requestID.uuidString.write(to: storageRoot.appending(path: "latest-job"), atomically: true, encoding: .utf8)
    }

    private func persistFailure(requestID: UUID, error: Error, decision: RoutingDecision) {
        let directory = storageRoot.appending(path: "jobs/\(requestID.uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let payload: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()),
            "error": error.localizedDescription, "route": decision.reason,
            "cancellation_requested": error is CancellationError]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            secureWrite(data, to: directory.appending(path: "failure.json"))
        }
    }

    private func cleanupTemporary(requestID: UUID) {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: "MLXMenu/\(requestID.uuidString)"))
    }

    private func pruneJobs(limit: Int = 50, maximumBytes: Int64 = 1_073_741_824, maximumAge: TimeInterval = 7 * 86_400) {
        let jobs = storageRoot.appending(path: "jobs")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: jobs, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let now = Date()
        var survivors: [(url: URL, date: Date, bytes: Int64)] = []
        for entry in entries {
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(date) > maximumAge {
                try? FileManager.default.removeItem(at: entry)
                if let id = UUID(uuidString: entry.lastPathComponent) { cleanupTemporary(requestID: id) }
            } else { survivors.append((entry, date, directorySize(entry))) }
        }
        survivors.sort { $0.date > $1.date }
        var retained: Int64 = 0
        for (index, item) in survivors.enumerated() {
            retained += item.bytes
            if index >= limit || retained > maximumBytes {
                try? FileManager.default.removeItem(at: item.url)
                if let id = UUID(uuidString: item.url.lastPathComponent) { cleanupTemporary(requestID: id) }
            }
        }
    }

    private func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator { total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    private func restoreLatestTrace() {
        guard let id = try? String(contentsOf: storageRoot.appending(path: "latest-job"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let data = try? Data(contentsOf: storageRoot.appending(path: "jobs/\(id)/trace.json")) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let restored = try? decoder.decode(ExecutionTrace.self, from: data) { trace = restored; decision = restored.decision }
    }

    private func restoreLatestResumable() {
        let jobs = storageRoot.appending(path: "jobs")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: jobs, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let candidates = entries.filter { FileManager.default.fileExists(atPath: $0.appending(path: "checkpoint.json").path) && FileManager.default.fileExists(atPath: $0.appending(path: "request.json").path) }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for directory in candidates {
            guard let checkpointData = try? Data(contentsOf: directory.appending(path: "checkpoint.json")),
                  let checkpoint = try? decoder.decode(ExecutionCheckpoint.self, from: checkpointData), checkpoint.completedStageCount > 0,
                  let requestData = try? Data(contentsOf: directory.appending(path: "request.json")),
                  let request = try? decoder.decode(InferenceRequest.self, from: requestData) else { continue }
            resumableRequest = request; return
        }
    }

    private func secureWrite(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func availableMemoryEstimate() -> Int64? {
        let process = Process(); process.executableURL = URL(filePath: "/usr/bin/vm_stat")
        let pipe = Pipe(); process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }; process.waitUntilExit()
        guard let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        let pageSize: Int64 = text.split(separator: "\n").first.flatMap { line in
            line.split(whereSeparator: { !$0.isNumber }).compactMap { Int64($0) }.last
        } ?? 16_384
        let labels = ["Pages free", "Pages inactive", "Pages speculative", "Pages purgeable"]
        var pages: Int64 = 0
        for line in text.split(separator: "\n") where labels.contains(where: { line.hasPrefix($0) }) {
            if let value = line.split(whereSeparator: { !$0.isNumber }).compactMap({ Int64($0) }).last { pages += value }
        }
        return pages > 0 ? pages * pageSize : nil
    }

    private static func describe(_ event: PipelineEvent) -> String {
        switch event {
        case .stageStarted(let kind, let model): "Started \(kind.rawValue)\(model.map { " with \($0)" } ?? "")"
        case .fallback(let kind, let from, let to, let reason): "Fallback in \(kind.rawValue): \(from) → \(to) (\(reason))"
        case .stageCompleted(let kind, _, let milliseconds): "Completed \(kind.rawValue) in \(Int(milliseconds)) ms"
        case .stageReused(let kind, _): "Reused checkpoint artifact for \(kind.rawValue)"
        case .modelLoaded(let id, let milliseconds): "Loaded \(id) in \(Int(milliseconds)) ms"
        case .modelUnloaded(let id): "Unloaded \(id)"
        }
    }
}
