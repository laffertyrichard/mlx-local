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
        let ids = [options.textModelID] + (options.imageModelID.map { [$0] } ?? [])
        for id in ids {
            guard let model = registry.model(id: id), FileManager.default.fileExists(atPath: model.localPath.path),
                  model.health != .failed, model.health != .unavailable else { throw PreconRuntimeError.unavailable("Model is not installed: \(id)") }
        }
        guard PreconReadPage.textModels(registry.models).contains(where: { $0.id == options.textModelID }) else {
            throw PreconRuntimeError.unsupported("Text selection lacks structured reasoning")
        }
        if let image = options.imageModelID, !PreconReadPage.imageModels(registry.models).contains(where: { $0.id == image }) {
            throw PreconRuntimeError.unsupported("Image selection lacks OCR/vision")
        }
        var runtimes: [InferenceBackend: any ModelRuntime] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser
        let resources = root.appending(path: "Sources/MLXMenu/Resources")
        for id in ids {
            let model = registry.model(id: id)!
            if runtimes[model.backend] != nil { continue }
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
            runtimes[model.backend] = OpenAIWorkerRuntime(backend: model.backend, executable: executable, launcherScript: launcher,
                watchdogScript: resources.appending(path: "worker_watchdog.py"),
                watchdogInterpreter: PythonExecutable.forToolExecutable(executable), basePort: model.backend == .mlxLM ? 18781 : 18881)
        }
        let manager = ModelResourceManager(registry: registry, runtimes: runtimes,
            memoryBudgetBytes: MemoryObservation(availableBytes: nil, physicalBytes: Int64(ProcessInfo.processInfo.physicalMemory)).commitmentCapBytes)
        do {
            let adapter = PreconRuntimeInterpreter(manager: manager, textModelID: options.textModelID, imageModelID: options.imageModelID)
            let digest = try await adapter.profileDigest()
            let workspace = FileManager.default.temporaryDirectory.appending(path: "PreconRealEval-\(UUID())")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workspace) }
            let store = try PreconProjectStore(root: workspace), project = workspace.appending(path: "project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            var pages: [PreconEvaluationPage] = []
            for item in dataset.cases {
                try Task.checkCancellation()
                let pdf = try dataset.generate(item, in: workspace)
                let sources = try store.importSource(pdf, into: project, role: .proposed, revision: "EVAL")
                let pipeline = try await adapter.pipeline(store: store, project: project)
                let units = try await pipeline.run(sources)
                let native = PDFDocument(url: pdf)?.page(at: 0)?.string ?? ""
                pages.append(.init(caseID: item.id, units: units, nativeText: native))
                if units.contains(where: { $0.status == .deferred }) { break }
            }
            let score = try dataset.score(pages, label: "REAL — not construction accuracy certification")
            let report: [String: Any] = ["dataset": dataset.label, "dataset_sha256": try StableDigest.file(URL(filePath: options.dataset)),
                "text_model":options.textModelID, "image_model":options.imageModelID as Any? ?? NSNull(), "profile_digest":digest,
                "metrics":try JSONSerialization.jsonObject(with: Data(score.json().utf8)),
                "units":try JSONSerialization.jsonObject(with: PreconJSON.encoder.encode(pages.flatMap(\.units)))]
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
            try bytes.write(to: output, options: .withoutOverwriting)
            print("Evaluation written to \(output.path)")
            await manager.shutdown()
        } catch { await manager.shutdown(); throw error }
    }
}
