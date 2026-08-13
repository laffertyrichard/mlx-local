import Foundation
import Testing
@testable import LocalLLMCore

@Suite("Model cache management")
struct ModelCacheManagerTests {
    @Test("accepts a Hugging Face owner/repository identifier")
    func acceptsRepositoryIdentifier() throws {
        #expect(ModelCacheManager.isValidRepositoryIdentifier("mlx-community/Qwen3.6-35B-A3B-4bit"))
    }

    @Test("rejects identifiers that could escape the cache root")
    func rejectsUnsafeRepositoryIdentifiers() throws {
        #expect(!ModelCacheManager.isValidRepositoryIdentifier("../private/model"))
        #expect(!ModelCacheManager.isValidRepositoryIdentifier("owner/repo/extra"))
        #expect(!ModelCacheManager.isValidRepositoryIdentifier("owner repo/model"))
    }

    @Test("removes only the requested model cache folder")
    func removesRequestedModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ModelCacheManagerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelCacheManager(cacheRoot: root)
        let target = root.appending(path: "models--owner--target")
        let neighbor = root.appending(path: "models--owner--neighbor")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: target.appending(path: "blob"))

        try manager.remove(repository: "owner/target")

        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(FileManager.default.fileExists(atPath: neighbor.path))
    }
    @Test("ignores snapshots until model weights are present")
    func ignoresIncompleteSnapshots() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ModelCatalogTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appending(path: "models--owner--model/snapshots/revision")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{\"model_type\":\"qwen\"}".utf8).write(to: snapshot.appending(path: "config.json"))

        #expect(ModelCatalog(cacheRoot: root).discover().isEmpty)

        try Data("weights".utf8).write(to: snapshot.appending(path: "model.safetensors"))
        #expect(ModelCatalog(cacheRoot: root).discover().map(\.repository) == ["owner/model"])
    }

    @Test("Nemotron 3.5 is offered to the manual MLX-LM server")
    func discoversNemotronForManualChat() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "NemotronCatalogTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = "mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit"
        let snapshot = root.appending(
            path: "models--mlx-community--NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit/snapshots/revision"
        )
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data(#"{"model_type":"nemotron_h"}"#.utf8).write(to: snapshot.appending(path: "config.json"))
        try Data("weights".utf8).write(to: snapshot.appending(path: "model.safetensors"))

        let catalog = ModelCatalog(cacheRoot: root)

        #expect(catalog.discoverCached().map(\.id) == [repository])
        #expect(catalog.discover().map(\.id) == [repository])
    }

    @Test("inventory includes complete non-chat models without offering them to the manual server")
    func inventoriesNonChatModels() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ModelInventoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appending(path: "models--owner--vision/snapshots/revision")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{\"model_type\":\"qwen_vl\"}".utf8).write(to: snapshot.appending(path: "config.json"))
        try Data("weights".utf8).write(to: snapshot.appending(path: "model.safetensors"))
        let catalog = ModelCatalog(cacheRoot: root)

        #expect(catalog.discoverCached().map(\.repository) == ["owner/vision"])
        #expect(catalog.discover().isEmpty)
    }

    @Test("manual server defaults to the dedicated MLX port")
    func manualServerUsesDedicatedPort() {
        let configuration = ServerConfiguration(
            executable: URL(filePath: "/usr/bin/python3"),
            modelPath: URL(filePath: "/tmp/model")
        )
        #expect(configuration.port == 8081)
        #expect(configuration.endpoint.absoluteString == "http://127.0.0.1:8081/v1")
    }

    @Test("resolves a uv tool's Python without relying on the macOS system path")
    func resolvesToolPythonInterpreter() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PythonExecutableTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let python = root.appending(path: "python")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let tool = root.appending(path: "mlx_tool.server")
        try Data("#!\(python.path)\nprint('ok')\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        #expect(PythonExecutable.forToolExecutable(python) == python)
        #expect(PythonExecutable.forToolExecutable(tool) == python)
    }

    @Test("rejects a tool script whose interpreter is unavailable")
    func rejectsMissingToolInterpreter() throws {
        let tool = FileManager.default.temporaryDirectory
            .appending(path: "MissingPythonTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tool) }
        try Data("#!/missing/python\n".utf8).write(to: tool)

        #expect(PythonExecutable.forToolExecutable(tool) == nil)
        try Data("#!/usr/bin/env ruby\n".utf8).write(to: tool)
        #expect(PythonExecutable.forToolExecutable(tool) == nil)
    }

}
