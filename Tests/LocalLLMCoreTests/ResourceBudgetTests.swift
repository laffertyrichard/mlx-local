import Foundation
import Testing
@testable import LocalLLMCore

@Suite("Resource admission budget")
struct ResourceBudgetTests {
    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var available: Int64?
        let physical: Int64
        private var evictions: [String] = []
        init(_ available: Int64?, physical: Int64 = 100_000) {
            self.available = available; self.physical = physical
        }
        var observation: (available: Int64?, physical: Int64) {
            lock.lock(); defer { lock.unlock() }; return (available, physical)
        }
        var unloaded: [String] { lock.lock(); defer { lock.unlock() }; return evictions }
        func set(_ bytes: Int64?) { lock.lock(); defer { lock.unlock() }; available = bytes }
        func allocate(_ bytes: Int64) {
            lock.lock(); defer { lock.unlock() }; available = available.map { $0 - bytes }
        }
        func release(_ bytes: Int64, id: String) {
            lock.lock(); defer { lock.unlock() }
            available = available.map { $0 + bytes }; evictions.append(id)
        }
    }

    private enum LoadFailure: Error { case expected }
    private struct StubRuntime: ModelRuntime {
        let backend: InferenceBackend = .mlxLM
        let memory: Memory
        var footprints: [String: Int64] = [:]
        var failures: Set<String> = []
        func load(model: RegisteredModel) async throws {
            if failures.contains(model.id) { throw LoadFailure.expected }
            memory.allocate(footprints[model.id] ?? model.approximateMemoryBytes)
        }
        func unload(model: RegisteredModel) async {
            memory.release(footprints[model.id] ?? model.approximateMemoryBytes, id: model.id)
        }
        func execute(model: RegisteredModel?, stage: RouteStage, input: StageExecutionInput) async throws -> PipelineArtifact {
            PipelineArtifact(kind: .text, content: "stub")
        }
        func health(model: RegisteredModel) async -> ModelHealth { .healthy }
    }

    private func model(_ id: String, _ bytes: Int64) -> RegisteredModel {
        RegisteredModel(id: id, backend: .mlxLM, localPath: URL(filePath: "/tmp/\(id)"), family: "test",
                        capabilities: [.generalChat], inputModalities: [.text], outputModalities: [.text],
                        approximateMemoryBytes: bytes, contextWindow: 4096)
    }

    private func manager(_ models: [RegisteredModel], runtime: StubRuntime) -> ModelResourceManager {
        // Baseline adapter: expose the fake observation through the original budget API.
        ModelResourceManager(registry: ModelRegistry(models: models), runtimes: [.mlxLM: runtime],
                             memoryBudgetBytes: 72_000, budgetProvider: {
            let observation = runtime.memory.observation
            let cap = Int64(Double(observation.physical) * 0.72)
            return observation.available.map { min(cap, Int64(Double($0) * 0.8)) } ?? cap
        })
    }

    @Test("sequential loads retain residents without subtracting their footprints twice")
    func sequentialLoads() async throws {
        let memory = Memory(40_000)
        let runtime = StubRuntime(memory: memory)
        let a = model("a", 20_000), b = model("b", 8_000), c = model("c", 4_000)
        let manager = manager([a, b, c], runtime: runtime)
        for model in [a, b, c] { _ = try await manager.ensureLoaded(model, runtime: runtime, onEvent: nil) }
        let snapshot = await manager.snapshot(totalMemoryBytes: memory.physical)
        #expect(snapshot.loadedModelIDs == ["a", "b", "c"])
        #expect(snapshot.availableMemoryBytes == 6_400)
        #expect(memory.unloaded.isEmpty)
    }

    @Test("a retained model's peak estimate is not charged against live free memory")
    func retainedPeakEstimate() async throws {
        let memory = Memory(50_000)
        let runtime = StubRuntime(memory: memory, footprints: ["a": 10_000, "b": 5_000])
        let a = model("a", 30_000), b = model("b", 20_000)
        let manager = manager([a, b], runtime: runtime)
        _ = try await manager.ensureLoaded(a, runtime: runtime, onEvent: nil)
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).availableMemoryBytes == 32_000)
        _ = try await manager.ensureLoaded(b, runtime: runtime, onEvent: nil)
        let snapshot = await manager.snapshot(totalMemoryBytes: memory.physical)
        #expect(snapshot.loadedModelIDs == ["a", "b"])
        #expect(snapshot.availableMemoryBytes == 22_000) // Separate estimate cap: 72 - 30 - 20.
        #expect(memory.unloaded.isEmpty)
    }

    @Test("eviction re-observes actual released memory before admitting the next model")
    func evictionReobserves() async throws {
        let memory = Memory(50_000)
        let runtime = StubRuntime(memory: memory)
        let a = model("a", 20_000), b = model("b", 30_000)
        let manager = manager([a, b], runtime: runtime)
        _ = try await manager.ensureLoaded(a, runtime: runtime, onEvent: nil)
        _ = try await manager.ensureLoaded(b, runtime: runtime, onEvent: nil)
        #expect(memory.unloaded == ["a"])
        let snapshot = await manager.snapshot(totalMemoryBytes: memory.physical)
        #expect(snapshot.loadedModelIDs == ["b"])
        #expect(snapshot.availableMemoryBytes == 16_000)
    }

    @Test("a routing reclaim hint cannot override admission after actual eviction")
    func optimisticHintCannotOveradmit() async throws {
        let memory = Memory(50_000)
        let runtime = StubRuntime(memory: memory, footprints: ["a": 1_000])
        let a = model("a", 30_000), b = model("b", 20_000)
        let manager = manager([a, b], runtime: runtime)
        _ = try await manager.ensureLoaded(a, runtime: runtime, onEvent: nil)
        memory.set(10_000) // Unrelated workload consumes memory; only 1 KB will be reclaimed.
        let snapshot = await manager.snapshot(totalMemoryBytes: memory.physical)
        #expect(snapshot.availableMemoryBytes == 8_000)
        #expect(snapshot.reclaimableMemoryBytes == 30_000)
        let request = InferenceRequest(text: "hello", forcedModelID: "b")
        let decision = try CapabilityRouter().route(request: request,
            requirements: TaskRequirements(category: .chat, requiredCapabilities: [.generalChat], inputModalities: [.text]),
            registry: ModelRegistry(models: [a, b]), resources: snapshot)
        #expect(decision.stages.first?.modelID == "b")
        await #expect(throws: ResourceError.self) {
            _ = try await manager.ensureLoaded(b, runtime: runtime, onEvent: nil)
        }
        #expect(memory.unloaded == ["a"])
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).loadedModelIDs.isEmpty)
    }

    @Test("failed loads release reservations so subsequent loads can fit")
    func failedLoadReleasesReservation() async throws {
        let memory = Memory(40_000)
        let runtime = StubRuntime(memory: memory, failures: ["bad"])
        let bad = model("bad", 30_000), good = model("good", 30_000)
        let manager = manager([bad, good], runtime: runtime)
        await #expect(throws: LoadFailure.self) {
            _ = try await manager.ensureLoaded(bad, runtime: runtime, onEvent: nil)
        }
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).availableMemoryBytes == 32_000)
        #expect(await manager.registeredModels().first { $0.id == "bad" }?.loadedState == .failed)
        _ = try await manager.ensureLoaded(good, runtime: runtime, onEvent: nil)
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).loadedModelIDs == ["good"])
    }

    @Test("unloading restores observed headroom, not the larger peak estimate")
    func unloadRestoresHeadroom() async throws {
        let memory = Memory(50_000)
        let runtime = StubRuntime(memory: memory, footprints: ["a": 10_000])
        let a = model("a", 30_000)
        let manager = manager([a], runtime: runtime)
        _ = try await manager.ensureLoaded(a, runtime: runtime, onEvent: nil)
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).availableMemoryBytes == 32_000)
        await manager.unloadIdle(olderThan: .distantFuture)
        let snapshot = await manager.snapshot(totalMemoryBytes: memory.physical)
        #expect(snapshot.availableMemoryBytes == 40_000)
        #expect(snapshot.loadedModelIDs.isEmpty && snapshot.reclaimableMemoryBytes == 0)
    }

    @Test("missing observation falls back to the estimate cap, not physical availability")
    func missingObservation() async throws {
        let memory = Memory(nil)
        let runtime = StubRuntime(memory: memory)
        let a = model("a", 50_000), b = model("b", 25_000), tooBig = model("large", 73_000)
        let manager = manager([a, b, tooBig], runtime: runtime)
        _ = try await manager.ensureLoaded(a, runtime: runtime, onEvent: nil)
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).availableMemoryBytes == 22_000)
        _ = try await manager.ensureLoaded(b, runtime: runtime, onEvent: nil)
        #expect(memory.unloaded == ["a"])
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).availableMemoryBytes == 47_000)
        await #expect(throws: ResourceError.self) {
            _ = try await manager.ensureLoaded(tooBig, runtime: runtime, onEvent: nil)
        }
    }

    @Test("live availability never bypasses the separate resident estimate cap")
    func estimateCap() async throws {
        let memory = Memory(100_000)
        let runtime = StubRuntime(memory: memory, footprints: ["a": 1_000, "b": 1_000])
        let a = model("a", 50_000), b = model("b", 30_000)
        let manager = manager([a, b], runtime: runtime)
        _ = try await manager.ensureLoaded(a, runtime: runtime, onEvent: nil)
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).availableMemoryBytes == 22_000)
        _ = try await manager.ensureLoaded(b, runtime: runtime, onEvent: nil)
        #expect(memory.unloaded == ["a"])
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).loadedModelIDs == ["b"])
    }

    @Test("fixed budgets retain estimate-based headroom and eviction without observations")
    func fixedBudgetUnchanged() async throws {
        let memory = Memory(1_000)
        let runtime = StubRuntime(memory: memory, footprints: ["a": 100, "b": 100])
        let a = model("a", 20_000), b = model("b", 15_000)
        let manager = ModelResourceManager(registry: ModelRegistry(models: [a, b]), runtimes: [.mlxLM: runtime],
                                           memoryBudgetBytes: 30_000)
        _ = try await manager.ensureLoaded(a, runtime: runtime, onEvent: nil)
        let snapshot = await manager.snapshot(totalMemoryBytes: memory.physical)
        #expect(snapshot.availableMemoryBytes == 10_000 && snapshot.reclaimableMemoryBytes == 20_000)
        #expect(await manager.currentBudgetBytes() == 30_000)
        _ = try await manager.ensureLoaded(b, runtime: runtime, onEvent: nil)
        #expect(memory.unloaded == ["a"])
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).availableMemoryBytes == 15_000)
    }

    @Test("live observations reflect external memory changes between admissions")
    func externalMemoryChanges() async throws {
        let memory = Memory(10_000)
        let runtime = StubRuntime(memory: memory)
        let a = model("a", 30_000)
        let manager = manager([a], runtime: runtime)
        await #expect(throws: ResourceError.self) {
            _ = try await manager.ensureLoaded(a, runtime: runtime, onEvent: nil)
        }
        memory.set(50_000)
        _ = try await manager.ensureLoaded(a, runtime: runtime, onEvent: nil)
        memory.set(5_000)
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).availableMemoryBytes == 4_000)
    }
}
