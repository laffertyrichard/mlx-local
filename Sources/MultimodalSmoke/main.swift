import Foundation
import LocalInferenceBackends
import LocalLLMCore
import PDFKit

@main struct MultimodalSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count >= 3 else {
            print("usage: swift run MultimodalSmoke <file> <prompt> [forced-model-id]"); return
        }
        let urls = CommandLine.arguments[1].split(separator: ",").map { URL(filePath: String($0)) }
        let prompt = CommandLine.arguments[2]
        let forced = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
        let attachments = urls.map { url -> RequestAttachment in
            var extractable: Bool? = nil; var pages: Int? = nil
            if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
                pages = pdf.pageCount; extractable = !(pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return RequestAttachment(url: url, hasExtractableText: extractable, pageCount: pages)
        }
        let lower = prompt.lowercased()
        let structured = ["return json", "as json", "output json", "json object", "valid json"].contains(where: lower.contains)
        let request = InferenceRequest(text: prompt, attachments: attachments, quality: .balanced,
                                       requiresStructuredOutput: structured, forcedModelID: forced)
        let benchmark = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Benchmarks/local-results.json")
        let profiles = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "ModelMetadata/capabilities.json")
        let registry = ModelRegistryDiscovery(benchmarkURL: benchmark, profileURL: profiles).discover()
        let requirements = await TaskClassifier().classify(request)
        let total = Int64(ProcessInfo.processInfo.physicalMemory), budget = Int64(Double(total) * 0.72)
        let decision = try CapabilityRouter().route(request: request, requirements: requirements, registry: registry,
                                                    resources: MachineResources(totalMemoryBytes: total, availableMemoryBytes: budget))
        print("TASK: \(requirements.category.rawValue)")
        print("CAPABILITIES: \(requirements.requiredCapabilities.map(\.rawValue).sorted().joined(separator: ", "))")
        print("ROUTE: \(decision.stages.map { $0.modelID ?? $0.kind.rawValue }.joined(separator: " -> "))")
        print("WHY: \(decision.reason)")
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let python = MLXExecutable.discover() else { throw SmokeError.missing("mlx-lm") }
        let wrapper = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Sources/MLXMenu/Resources/mlx_server_no_mpi.py")
        let vlm = home.appending(path: ".local/bin/mlx_vlm.server")
        let watchdog = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Sources/MLXMenu/Resources/worker_watchdog.py")
        let runtimes: [InferenceBackend: any ModelRuntime] = [
            .nativeDocument: NativeDocumentRuntime(),
            .mlxLM: OpenAIWorkerRuntime(backend: .mlxLM, executable: python, launcherScript: wrapper, watchdogScript: watchdog, basePort: 18281),
            .mlxVLM: OpenAIWorkerRuntime(backend: .mlxVLM, executable: vlm, watchdogScript: watchdog, basePort: 18381),
            .whisperMLX: MLXAudioRuntime(executable: home.appending(path: ".local/bin/mlx_audio.server"), watchdogScript: watchdog, port: 18482),
        ]
        let manager = ModelResourceManager(registry: registry, runtimes: runtimes, memoryBudgetBytes: budget)
        do {
            let trace = try await manager.execute(decision: decision, request: request) { event in print("EVENT: \(event)") }
            print("ACTUAL: \(trace.actualModelIDs.joined(separator: " -> "))")
            print("OUTPUT:\n\(trace.artifacts.last?.content ?? "<none>")")
        } catch { await manager.shutdown(); throw error }
        await manager.shutdown()
    }
}
enum SmokeError: LocalizedError { case missing(String); var errorDescription: String? { if case .missing(let value) = self { return "Missing \(value)" }; return nil } }
