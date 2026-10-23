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
        private var loads: [String] = []
        init(_ available: Int64?, physical: Int64 = 100_000) {
            self.available = available; self.physical = physical
        }
        var observation: (available: Int64?, physical: Int64) {
            lock.lock(); defer { lock.unlock() }; return (available, physical)
        }
        var unloaded: [String] { lock.lock(); defer { lock.unlock() }; return evictions }
        func set(_ bytes: Int64?) { lock.lock(); defer { lock.unlock() }; available = bytes }
        var loaded: [String] { lock.lock(); defer { lock.unlock() }; return loads }
        func allocate(_ bytes: Int64, id: String) {
            lock.lock(); defer { lock.unlock() }
            available = available.map { $0 - bytes }; loads.append(id)
        }
        func release(_ bytes: Int64, id: String) {
            lock.lock(); defer { lock.unlock() }
            available = available.map { $0 + bytes }; evictions.append(id)
        }
    }

    private actor LoadPause {
        private var started = false
        private var finished = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var finishWaiters: [CheckedContinuation<Void, Never>] = []
        func pause() async {
            if finished { return }
            await withCheckedContinuation { continuation in
                finishWaiters.append(continuation); started = true
                startWaiter?.resume(); startWaiter = nil
            }
        }
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiter = $0 }
        }
        func finish() {
            finished = true
            for waiter in finishWaiters { waiter.resume() }
            finishWaiters = []
        }
    }

    private enum LoadFailure: Error { case expected }
    private struct StubRuntime: ModelRuntime {
        let backend: InferenceBackend = .mlxLM
        let memory: Memory
        var footprints: [String: Int64] = [:]
        var failures: Set<String> = []
        var pause: LoadPause?
        var unloadPause: LoadPause?
        func load(model: RegisteredModel) async throws {
            if failures.contains(model.id) { throw LoadFailure.expected }
            memory.allocate(footprints[model.id] ?? model.approximateMemoryBytes, id: model.id)
            await pause?.pause()
        }
        func unload(model: RegisteredModel) async {
            await unloadPause?.pause()
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
        ModelResourceManager(registry: ModelRegistry(models: models), runtimes: [.mlxLM: runtime],
                             memoryBudgetBytes: 72_000, budgetProvider: {
            let observation = runtime.memory.observation
            return MemoryObservation(availableBytes: observation.available, physicalBytes: observation.physical)
        })
    }

    @Test("R2-M01: purgeable pages overlapping inactive pages never inflate admission")
    func overlappingVMStatCategories() async throws {
        let text = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                               65536.
        Pages inactive:                          262144.
        Pages speculative:                            0.
        Pages purgeable:                         262144.
        """
        let gib: Int64 = 1_073_741_824
        let available = try #require(MemoryObservation.availableBytes(fromVMStat: text))
        #expect(available == 5 * gib)
        let memory = Memory(available, physical: 64 * gib)
        let runtime = StubRuntime(memory: memory)
        let incoming = model("six-gib", 6 * gib)
        let manager = manager([incoming], runtime: runtime)
        await #expect(throws: ResourceError.self) {
            _ = try await manager.ensureLoaded(incoming, runtime: runtime, onEvent: nil)
        }
        #expect(memory.loaded.isEmpty)
    }

    @Test("R2-M02: same-model callers coalesce after a suspended eviction")
    func sameModelAfterEviction() async throws {
        let memory = Memory(100_000)
        let eviction = LoadPause(), loading = LoadPause()
        let runtime = StubRuntime(memory: memory, footprints: ["a": 1_000, "b": 1_000], unloadPause: eviction)
        let paused = StubRuntime(memory: memory, footprints: ["b": 1_000], pause: loading)
        let a = model("a", 50_000), b = model("b", 30_000), c = model("c", 43_000)
        let manager = manager([a, b, c], runtime: runtime)
        _ = try await manager.ensureLoaded(a, runtime: runtime, onEvent: nil)
        let first = Task { try await manager.ensureLoaded(b, runtime: paused, onEvent: nil) }
        await eviction.waitUntilStarted()
        let second = Task { try await manager.ensureLoaded(b, runtime: paused, onEvent: nil) }
        await loading.waitUntilStarted()
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).availableMemoryBytes == 42_000)
        await eviction.finish()
        // C exceeds the remaining commitment cap while B is loading; no estimates are overwritten.
        await #expect(throws: ResourceError.self) {
            _ = try await manager.ensureLoaded(c, runtime: runtime, onEvent: nil)
        }
        await loading.finish()
        _ = try await first.value
        _ = try await second.value
        #expect(memory.loaded.filter { $0 == "b" }.count == 1)
        #expect(!memory.loaded.contains("c"))
        #expect(memory.unloaded == ["a"])
        let snapshot = await manager.snapshot(totalMemoryBytes: memory.physical)
        #expect(snapshot.loadedModelIDs == ["b"])
        #expect(snapshot.availableMemoryBytes == 42_000)
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

    @Test("admission re-observes after each LRU eviction, not only the first")
    func multipleEvictions() async throws {
        let memory = Memory(80_000, physical: 200_000)
        let runtime = StubRuntime(memory: memory)
        let a = model("a", 20_000), b = model("b", 20_000), c = model("c", 35_000)
        let manager = manager([a, b, c], runtime: runtime)
        _ = try await manager.ensureLoaded(a, runtime: runtime, onEvent: nil)
        _ = try await manager.ensureLoaded(b, runtime: runtime, onEvent: nil)
        memory.set(10_000)
        _ = try await manager.ensureLoaded(c, runtime: runtime, onEvent: nil)
        #expect(memory.unloaded == ["a", "b"])
        let snapshot = await manager.snapshot(totalMemoryBytes: memory.physical)
        #expect(snapshot.loadedModelIDs == ["c"])
        #expect(snapshot.availableMemoryBytes == 12_000)
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

    @Test("missing observation falls back to the estimate cap, not physical availability", arguments: [100_000, 200_000])
    func missingObservation(physical: Int64) async throws {
        let memory = Memory(nil, physical: physical)
        let runtime = StubRuntime(memory: memory)
        let factor = physical / 100_000
        let a = model("a", 50_000 * factor), b = model("b", 25_000 * factor), tooBig = model("large", 73_000 * factor)
        let manager = manager([a, b, tooBig], runtime: runtime)
        _ = try await manager.ensureLoaded(a, runtime: runtime, onEvent: nil)
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).availableMemoryBytes == 22_000 * factor)
        _ = try await manager.ensureLoaded(b, runtime: runtime, onEvent: nil)
        #expect(memory.unloaded == ["a"])
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).availableMemoryBytes == 47_000 * factor)
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

    @Test("partially allocated in-flight loads retain conservative full reservations")
    func concurrentReservation() async throws {
        let memory = Memory(40_000)
        let pause = LoadPause()
        let paused = StubRuntime(memory: memory, footprints: ["a": 10_000], pause: pause)
        let runtime = StubRuntime(memory: memory)
        let a = model("a", 20_000), b = model("b", 10_000)
        let manager = manager([a, b], runtime: runtime)
        let loading = Task { try await manager.ensureLoaded(a, runtime: paused, onEvent: nil) }
        await pause.waitUntilStarted()
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).availableMemoryBytes == 4_000)
        await #expect(throws: ResourceError.self) {
            _ = try await manager.ensureLoaded(b, runtime: runtime, onEvent: nil)
        }
        await pause.finish()
        _ = try await loading.value
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).availableMemoryBytes == 24_000)
        _ = try await manager.ensureLoaded(b, runtime: runtime, onEvent: nil)
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).loadedModelIDs == ["a", "b"])
        #expect(memory.unloaded.isEmpty)
    }

    @Test("load completion transfers reservations before reentrant event callbacks")
    func completionCallbackHeadroom() async throws {
        let memory = Memory(50_000)
        let runtime = StubRuntime(memory: memory, footprints: ["a": 10_000])
        let a = model("a", 30_000)
        let manager = manager([a], runtime: runtime)
        _ = try await manager.ensureLoaded(a, runtime: runtime, onEvent: { event in
            if case .modelLoaded = event {
                let snapshot = await manager.snapshot(totalMemoryBytes: memory.physical)
                #expect(snapshot.loadedModelIDs == ["a"])
                #expect(snapshot.availableMemoryBytes == 32_000)
            }
        })
    }

    @Test("observed zero availability denies admission rather than using the failure fallback")
    func zeroAvailability() async {
        let memory = Memory(0)
        let runtime = StubRuntime(memory: memory)
        let a = model("a", 1_000)
        let manager = manager([a], runtime: runtime)
        #expect(await manager.snapshot(totalMemoryBytes: memory.physical).availableMemoryBytes == 0)
        await #expect(throws: ResourceError.self) {
            _ = try await manager.ensureLoaded(a, runtime: runtime, onEvent: nil)
        }
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
