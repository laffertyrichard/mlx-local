import Foundation
import PDFKit
import LocalLLMCore
import LocalInferenceBackends

@main struct PreconEvaluation {
    static func main() async {
        do {
            let options = try PreconEvaluationOptions.parse(Array(CommandLine.arguments.dropFirst()))
            try await run(options)
        } catch {
            fputs("\(PreconEvaluationOptions.usage)\n\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run(_ options: PreconEvaluationOptions) async throws {
        let root = URL(filePath: FileManager.default.currentDirectoryPath)
        let dataset = try PreconEvaluationSet.load(URL(filePath: options.dataset))
        let output = URL(filePath: options.output)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw PreconProjectError.alreadyExists(output.path) }
        let registry = ModelRegistryDiscovery().discover()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let resources = root.appending(path: "Sources/MLXMenu/Resources")
        let runtimes = try options.runtimes(models: registry.models, fileExists: FileManager.default.fileExists(atPath:)) { model in
            let executable: URL
            var launcher: URL?
            switch model.backend {
            case .mlxLM:
                guard let discovered = MLXExecutable.discover() else { throw PreconRuntimeError.unavailable("MLX text executable missing") }
                executable = discovered
                if executable.lastPathComponent.localizedCaseInsensitiveContains("python") {
                    launcher = resources.appending(path: "mlx_server_no_mpi.py")
                    guard FileManager.default.fileExists(atPath: launcher!.path) else { throw PreconRuntimeError.unavailable("Text launcher missing") }
                }
            case .mlxVLM: executable = home.appending(path: ".local/bin/mlx_vlm.server")
            default: throw PreconRuntimeError.unsupported("Backend is not a text/image runtime")
            }
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw PreconRuntimeError.unavailable(executable.path) }
            return OpenAIWorkerRuntime(backend: model.backend, executable: executable, launcherScript: launcher,
                watchdogScript: resources.appending(path: "worker_watchdog.py"),
                watchdogInterpreter: PythonExecutable.forToolExecutable(executable), basePort: model.backend == .mlxLM ? 18781 : 18881)
        }
        let manager = ModelResourceManager(registry: registry, runtimes: runtimes,
            memoryBudgetBytes: LiveMemoryObservation.read().commitmentCapBytes,
            budgetProvider: { LiveMemoryObservation.read() })
        do {
            let adapter = PreconRuntimeInterpreter(manager: manager, textModelID: options.textModelID, imageModelID: options.imageModelID)
            let digest = try await adapter.profileDigest()
            let workspace = FileManager.default.temporaryDirectory.appending(path: "PreconRealEval-\(UUID())")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workspace) }
            let pages = try await dataset.evaluate(adapter: adapter, in: workspace)
            var report = try JSONSerialization.jsonObject(with: dataset.report(pages, label: "REAL — not construction accuracy certification")) as! [String: Any]
            report["dataset"] = dataset.label
            report["dataset_sha256"] = try StableDigest.file(URL(filePath: options.dataset))
            report["text_model"] = options.textModelID
            report["image_model"] = options.imageModelID as Any? ?? NSNull()
            report["profile_digest"] = digest
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
            try bytes.write(to: output, options: .withoutOverwriting)
            print("Evaluation written to \(output.path)")
            await manager.shutdown()
        } catch { await manager.shutdown(); throw error }
    }
}
