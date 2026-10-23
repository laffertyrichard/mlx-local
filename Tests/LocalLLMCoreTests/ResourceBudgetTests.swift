import Foundation
import Testing
@testable import LocalLLMCore

/// The budget used to be a `let` captured at init, so freeing memory never widened it and
/// consuming memory never narrowed it. These check that a provider is consulted per admission.
@Suite("Resource admission budget")
struct ResourceBudgetTests {
    private final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64
        init(_ value: Int64) { self.value = value }
        var current: Int64 { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Int64) { lock.lock(); value = newValue; lock.unlock() }
    }

    private struct StubRuntime: ModelRuntime {
        let backend: InferenceBackend = .mlxLM
        func load(model: RegisteredModel) async throws {}
        func unload(model: RegisteredModel) async {}
        func execute(model: RegisteredModel?, stage: RouteStage, input: StageExecutionInput) async throws -> PipelineArtifact {
            throw ResourceError.runtimeUnavailable(.mlxLM)
        }
        func health(model: RegisteredModel) async -> ModelHealth { .healthy }
    }

    private func model(_ id: String, bytes: Int64) -> RegisteredModel {
        RegisteredModel(id: id, backend: .mlxLM, localPath: URL(filePath: "/tmp/\(id)"), family: "test",
                        capabilities: [.generalChat], inputModalities: [.text], outputModalities: [.text],
                        approximateMemoryBytes: bytes, contextWindow: 4096)
    }

    private func manager(_ models: [RegisteredModel], budget: Budget) -> ModelResourceManager {
        ModelResourceManager(registry: ModelRegistry(models: models), runtimes: [.mlxLM: StubRuntime()],
                             memoryBudgetBytes: budget.current, budgetProvider: { budget.current })
    }

    @Test("a provider is re-read instead of frozen at init")
    func budgetTracksProvider() async {
        let budget = Budget(10_000)
        let manager = manager([model("a", bytes: 8_000)], budget: budget)

        #expect(await manager.currentBudgetBytes() == 10_000)
        budget.set(40_000)
        #expect(await manager.currentBudgetBytes() == 40_000)
        budget.set(1_000)
        #expect(await manager.currentBudgetBytes() == 1_000)
    }

    @Test("freeing memory after launch admits a model the launch-time budget rejected")
    func wideningBudgetAdmitsLargeModel() async throws {
        let budget = Budget(10_000)
        let big = model("big", bytes: 30_000)
        let manager = manager([big], budget: budget)

        // Launch-time budget is too small: this is the pre-fix behaviour, and it must persist.
        await #expect(throws: ResourceError.self) {
            _ = try await manager.ensureLoaded(big, runtime: StubRuntime(), onEvent: nil)
        }

        // Quitting other apps frees memory. The frozen budget never saw this.
        budget.set(50_000)
        _ = try await manager.ensureLoaded(big, runtime: StubRuntime(), onEvent: nil)
        #expect(await manager.snapshot(totalMemoryBytes: 64_000).loadedModelIDs.contains("big"))
    }

    @Test("snapshot reports headroom against the live budget, not the launch-time one")
    func snapshotUsesLiveBudget() async {
        let budget = Budget(50_000)
        let manager = manager([model("a", bytes: 8_000)], budget: budget)

        #expect(await manager.snapshot(totalMemoryBytes: 64_000).availableMemoryBytes == 50_000)
        budget.set(20_000)
        #expect(await manager.snapshot(totalMemoryBytes: 64_000).availableMemoryBytes == 20_000)
    }
}
