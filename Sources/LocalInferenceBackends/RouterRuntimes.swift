import AppKit
import Foundation
import LocalLLMCore
import PDFKit

public final class WorkerProcessRegistry: @unchecked Sendable {
    public static let shared = WorkerProcessRegistry()
    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]
    private init() {}
    public func register(_ process: Process) { lock.lock(); processes[process.processIdentifier] = process; lock.unlock() }
    public func unregister(_ process: Process) { lock.lock(); processes.removeValue(forKey: process.processIdentifier); lock.unlock() }
    public func terminateAllSynchronously() {
        lock.lock(); let values = Array(processes.values); processes.removeAll(); lock.unlock()
        for process in values where process.isRunning { process.terminate() }
    }
}

public actor OpenAIWorkerRuntime: ModelRuntime {
    public nonisolated let backend: InferenceBackend
    private let executable: URL
    private let launcherScript: URL?
    private let watchdogScript: URL?
    private let watchdogInterpreter: URL?
    private let basePort: Int
    private var workers: [String: (process: Process, endpoint: URL)] = [:]

    public init(backend: InferenceBackend, executable: URL, launcherScript: URL? = nil,
                watchdogScript: URL? = nil, watchdogInterpreter: URL? = nil, basePort: Int) {
        self.backend = backend; self.executable = executable; self.launcherScript = launcherScript
        self.watchdogScript = watchdogScript; self.watchdogInterpreter = watchdogInterpreter
        self.basePort = basePort
    }

    public func load(model: RegisteredModel) async throws {
        if let worker = workers[model.id], worker.process.isRunning { return }
        if let existing = workers[model.id] {
            WorkerProcessRegistry.shared.unregister(existing.process)
            if existing.process.isRunning { existing.process.terminate() }
            workers.removeValue(forKey: model.id)
        }
        let used = Set(workers.values.map { $0.endpoint.port ?? basePort })
        guard let port = (basePort..<(basePort + 100)).first(where: { !used.contains($0) && loopbackPortAvailable($0) }) else {
            throw RuntimeFailure.configuration("No free loopback worker port is available.")
        }
        let process = Process(); process.executableURL = executable
        switch backend {
        case .mlxLM:
            let serverArguments = ["--model", model.localPath.path, "--host", "127.0.0.1", "--port", String(port),
                                   "--max-tokens", "8192", "--temp", "0", "--log-level", "INFO", "--decode-concurrency", "1",
                                   "--prompt-concurrency", "1", "--prefill-step-size", "2048", "--prompt-cache-size", "1"]
            process.arguments = (launcherScript.map { [$0.path] } ?? []) + serverArguments
        case .mlxVLM:
            process.arguments = ["--host", "127.0.0.1", "--port", String(port), "--model", model.localPath.path,
                                 "--max-tokens", "8192", "--prefill-step-size", "1024", "--vision-cache-size", "4", "--log-level", "INFO"]
        default: throw RuntimeFailure.configuration("Unsupported HTTP worker backend: \(backend.rawValue)")
        }
        if let watchdogScript {
            guard let watchdogInterpreter else {
                throw RuntimeFailure.configuration("The MLX tool's Python interpreter is unavailable.")
            }
            let workerArguments = process.arguments ?? []
            process.executableURL = watchdogInterpreter
            process.arguments = [watchdogScript.path, String(ProcessInfo.processInfo.processIdentifier), executable.path] + workerArguments
        }
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["HOME"] = home; environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        environment["HF_HUB_OFFLINE"] = "1"; environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/MLXMenu/workers")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logURL = logDirectory.appending(path: model.id.replacingOccurrences(of: "/", with: "--") + ".log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: logURL); try handle.seekToEnd()
        process.standardOutput = handle; process.standardError = handle
        try process.run(); WorkerProcessRegistry.shared.register(process)
        let endpoint = URL(string: "http://127.0.0.1:\(port)/v1")!
        workers[model.id] = (process, endpoint)
        do { try await waitUntilReady(process: process, endpoint: endpoint, modelID: model.id, modelPath: model.localPath.path) }
        catch {
            WorkerProcessRegistry.shared.unregister(process)
            if process.isRunning { process.terminate() }
            workers.removeValue(forKey: model.id)
            throw error
        }
    }

    public func unload(model: RegisteredModel) async {
        guard let worker = workers.removeValue(forKey: model.id) else { return }
        WorkerProcessRegistry.shared.unregister(worker.process)
        if worker.process.isRunning {
            worker.process.terminate()
            for _ in 0..<30 where worker.process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if worker.process.isRunning { kill(worker.process.processIdentifier, SIGKILL) }
        }
    }

    public func execute(model: RegisteredModel?, stage: RouteStage, input: StageExecutionInput) async throws -> PipelineArtifact {
        guard let model, let endpoint = workers[model.id]?.endpoint else { throw RuntimeFailure.notLoaded(model?.id ?? "unknown") }
        let prompt = try stagePrompt(stage: stage, input: input)
        let artifactImages = input.artifacts.flatMap(\.sourceURLs).filter { $0.isFileURL }
        let requestImages = input.request.attachments.filter { $0.modality == .image }.map(\.url)
        let candidates = stage.kind == .ocr ? (artifactImages.isEmpty ? requestImages : artifactImages) : (requestImages.isEmpty ? artifactImages : requestImages)
        var seen = Set<URL>()
        let images = backend == .mlxVLM ? candidates.filter { seen.insert($0).inserted } : []
        let answer: String
        var confidence: Double? = nil
        if stage.kind == .ocr {
            guard !images.isEmpty else { throw RuntimeFailure.configuration("OCR received no rendered pages or images.") }
            var pages: [String] = []
            var scores: [Double] = []
            for (index, image) in images.enumerated() {
                let page = try await completion(endpoint: endpoint, model: model, prompt: prompt, images: [image], profile: stage.modelProfile)
                let score = ocrConfidence(page)
                guard score >= 0.35 else { throw RuntimeFailure.lowConfidenceOCR(index + 1, score) }
                pages.append("## Page \(index + 1)\n\n\(page)"); scores.append(score)
            }
            answer = pages.joined(separator: "\n\n")
            confidence = scores.reduce(0, +) / Double(scores.count)
        } else if backend == .mlxLM && prompt.count > max(8_000, model.contextWindow * 3) {
            answer = try await chunkedLanguageCompletion(endpoint: endpoint, model: model, request: input.request, artifacts: input.artifacts)
        } else {
            answer = try await completion(endpoint: endpoint, model: model, prompt: prompt, images: images, profile: stage.modelProfile)
        }
        let kind: ArtifactKind = stage.kind == .ocr ? .markdown : stage.kind == .visionExtraction ? .visionObservations : .finalResponse
        return PipelineArtifact(kind: kind, content: answer, sourceURLs: images, confidence: confidence,
                                metadata: ["model": model.id, "backend": backend.rawValue, "items": String(max(images.count, 1))])
    }

    private func completion(endpoint: URL, model: RegisteredModel, prompt: String, images: [URL],
                            profile: ModelProfile? = nil) async throws -> String {
        var content: Any = prompt
        if backend == .mlxVLM {
            var parts: [[String: Any]] = [["type": "text", "text": prompt]]
            for image in images {
                let encoded = try encodedImage(image, maximumDimension: profile?.preprocessing.maximumImageDimension ?? 4096)
                parts.append(["type": "image_url", "image_url": ["url": "data:\(encoded.mime);base64,\(encoded.data.base64EncodedString())"]])
            }
            content = parts
        }
        let generation = profile?.generation ?? GenerationConfiguration()
        var body: [String: Any] = ["model": model.localPath.path, "messages": [["role": "user", "content": content]],
                                   "temperature": generation.temperature, "max_tokens": generation.maxOutputTokens, "stream": false]
        if let value = generation.topP { body["top_p"] = value }
        if let value = generation.topK { body["top_k"] = value }
        if let value = generation.repetitionPenalty { body["repetition_penalty"] = value }
        if !generation.stopSequences.isEmpty { body["stop"] = generation.stopSequences }
        var request = URLRequest(url: endpoint.appending(path: "chat/completions")); request.httpMethod = "POST"; request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RuntimeFailure.http((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any] else {
            throw RuntimeFailure.malformedResponse
        }
        let answer = (message["content"] as? String) ?? (message["reasoning"] as? String) ?? ""
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RuntimeFailure.malformedResponse }
        return answer
    }

    private func encodedImage(_ url: URL, maximumDimension: Int) throws -> (data: Data, mime: String) {
        guard let image = NSImage(contentsOf: url) else { throw RuntimeFailure.configuration("Could not decode image \(url.lastPathComponent).") }
        let original = image.size
        let scale = min(1, CGFloat(maximumDimension) / max(original.width, original.height))
        let target = NSSize(width: max(1, original.width * scale), height: max(1, original.height * scale))
        let rendered = NSImage(size: target); rendered.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target)); rendered.unlockFocus()
        guard let tiff = rendered.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw RuntimeFailure.configuration("Could not normalize image \(url.lastPathComponent).")
        }
        return (data, "image/png")
    }

    private func ocrConfidence(_ text: String) -> Double {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return 0 }
        let uniqueRatio = Double(Set(lines).count) / Double(lines.count)
        let lengthScore = min(Double(text.count) / 80, 1)
        return 0.65 * uniqueRatio + 0.35 * lengthScore
    }

    public func health(model: RegisteredModel) async -> ModelHealth {
        guard let worker = workers[model.id], worker.process.isRunning else { return .unavailable }
        return .healthy
    }

    private func waitUntilReady(process: Process, endpoint: URL, modelID: String, modelPath: String) async throws {
        let health = endpoint.appending(path: "models")
        for _ in 0..<900 {
            guard process.isRunning else { throw RuntimeFailure.exitedWhileLoading(modelID) }
            var request = URLRequest(url: health); request.timeoutInterval = 1
            if let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                if body.contains(modelID) || body.contains(modelPath) || body.contains(URL(filePath: modelPath).lastPathComponent) { return }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw RuntimeFailure.loadTimeout(modelID)
    }

    private func stagePrompt(stage: RouteStage, input: StageExecutionInput) throws -> String {
        let profile = stage.modelProfile
        if stage.kind == .ocr && profile == nil { return "Extract the text content from this image." }
        var prompt = ""
        if let system = profile?.systemPrompt, !system.isEmpty { prompt += system + "\n\n" }
        if let instruction = profile?.taskInstruction, !instruction.isEmpty { prompt += instruction + "\n\n" }
        if let examples = profile?.fewShotExamples, !examples.isEmpty { prompt += "Examples:\n" + examples.joined(separator: "\n---\n") + "\n\n" }
        if stage.kind == .ocr { prompt += "Extract the text content from this image.\n\n" }
        if stage.kind == .validation { prompt += "Validate the prior pipeline result against all extracted observations. Correct arithmetic, omissions, unsupported claims, and formatting before answering.\n\n" }
        if !input.request.history.isEmpty {
            prompt += "Recent local conversation context:\n"
            for turn in input.request.history.suffix(12) { prompt += "\(turn.role): \(turn.content)\n" }
            prompt += "\n"
        }
        prompt += input.request.text
        for file in input.request.attachments.filter({ $0.modality == .code }) {
            guard let data = try? Data(contentsOf: file.url), data.count <= 8 * 1024 * 1024,
                  let content = String(data: data, encoding: .utf8) else {
                throw RuntimeFailure.configuration("Could not read code attachment \(file.url.lastPathComponent) as bounded UTF-8 text.")
            }
            prompt += "\n\n--- code: \(file.url.lastPathComponent) ---\n\(content)"
        }
        if !input.artifacts.isEmpty {
            prompt += "\n\nUse these normalized local pipeline artifacts:\n"
            for artifact in input.artifacts { prompt += "\n--- \(artifact.kind.rawValue) ---\n\(artifact.content)\n" }
        }
        if input.requiresStructuredOutput {
            prompt += "\nReturn only valid JSON"
            if let schema = input.request.structuredOutputSchema, !schema.isEmpty { prompt += " matching this schema: \(schema)" }
            prompt += "."
        }
        return prompt
    }

    private func chunkedLanguageCompletion(endpoint: URL, model: RegisteredModel, request: InferenceRequest,
                                             artifacts: [PipelineArtifact]) async throws -> String {
        var sourceParts = request.history.map { "\($0.role): \($0.content)" }
        for file in request.attachments.filter({ $0.modality == .code }) {
            if let content = try? String(contentsOf: file.url, encoding: .utf8) { sourceParts.append(content) }
        }
        sourceParts.append(contentsOf: artifacts.map(\.content))
        if sourceParts.isEmpty { sourceParts.append(request.text) }
        let source = sourceParts.joined(separator: "\n\n")
        let chunkSize = max(8_000, model.contextWindow * 2)
        var chunks: [String] = []
        var index = source.startIndex
        while index < source.endIndex {
            let end = source.index(index, offsetBy: chunkSize, limitedBy: source.endIndex) ?? source.endIndex
            chunks.append(String(source[index..<end])); index = end
        }
        var summaries: [String] = []
        for (offset, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let prompt = "Task: \(request.text)\nAnalyze source chunk \(offset + 1) of \(chunks.count). Preserve facts needed for final synthesis.\n\n\(chunk)"
            summaries.append(try await completion(endpoint: endpoint, model: model, prompt: prompt, images: []))
        }
        while summaries.joined(separator: "\n\n").count > chunkSize {
            var reduced: [String] = []
            for groupStart in stride(from: 0, to: summaries.count, by: 4) {
                let group = summaries[groupStart..<min(groupStart + 4, summaries.count)].joined(separator: "\n\n")
                reduced.append(try await completion(endpoint: endpoint, model: model,
                    prompt: "Compress these partial analyses without dropping facts needed for: \(request.text)\n\n\(group)", images: []))
            }
            summaries = reduced
        }
        var final = "Complete the user task from these local chunk analyses:\n\n" + summaries.joined(separator: "\n\n") + "\n\nUser task: \(request.text)"
        if request.requiresStructuredOutput {
            final += "\nReturn only valid JSON"
            if let schema = request.structuredOutputSchema { final += " matching: \(schema)" }
            final += "."
        }
        return try await completion(endpoint: endpoint, model: model, prompt: final, images: [])
    }

}

public actor NativeDocumentRuntime: ModelRuntime {
    public nonisolated let backend: InferenceBackend = .nativeDocument
    public init() {}
    public func load(model: RegisteredModel) async throws {}
    public func unload(model: RegisteredModel) async {}
    public func health(model: RegisteredModel) async -> ModelHealth { .healthy }
    public func execute(model: RegisteredModel?, stage: RouteStage, input: StageExecutionInput) async throws -> PipelineArtifact {
        let documents = input.request.attachments.filter { $0.modality == .document }
        var textParts: [String] = []; var images: [URL] = []
        let output = FileManager.default.temporaryDirectory.appending(path: "MLXMenu/\(input.request.id.uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for attachment in documents {
            guard attachment.url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: attachment.url) else {
                if let text = try? String(contentsOf: attachment.url, encoding: .utf8), !text.isEmpty {
                    textParts.append(text)
                } else if let attributed = try? NSAttributedString(url: attachment.url, options: [:], documentAttributes: nil), !attributed.string.isEmpty {
                    textParts.append(attributed.string)
                } else {
                    throw RuntimeFailure.configuration("Could not extract document \(attachment.url.lastPathComponent).")
                }
                continue
            }
            let extracted = (pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !extracted.isEmpty { textParts.append(extracted); continue }
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                guard let page = pdf.page(at: index) else { throw RuntimeFailure.configuration("Could not render PDF page \(index + 1).") }
                let bounds = page.bounds(for: .mediaBox); let scale: CGFloat = min(2.0, 2200 / max(bounds.width, bounds.height))
                let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
                let image = NSImage(size: size); image.lockFocus()
                NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
                guard let context = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); continue }
                context.saveGState(); context.scaleBy(x: scale, y: scale); page.draw(with: .mediaBox, to: context); context.restoreGState(); image.unlockFocus()
                guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { continue }
                let url = output.appending(path: String(format: "page-%03d.png", index + 1)); try png.write(to: url); images.append(url)
            }
        }
        guard !textParts.isEmpty || !images.isEmpty else { throw RuntimeFailure.configuration("No local extractor could read the attached document.") }
        return PipelineArtifact(kind: .text, content: textParts.joined(separator: "\n\n"), sourceURLs: images,
                                metadata: ["pageImages": String(images.count), "documents": String(documents.count), "coverage": "complete"])
    }
}

private func loopbackPortAvailable(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
}

enum RuntimeFailure: LocalizedError {
    case configuration(String), notLoaded(String), exitedWhileLoading(String), loadTimeout(String), http(Int, String), malformedResponse, lowConfidenceOCR(Int, Double)
    var errorDescription: String? {
        switch self {
        case .configuration(let value): value
        case .notLoaded(let id): "Model worker is not loaded: \(id)"
        case .exitedWhileLoading(let id): "Model worker exited while loading \(id)."
        case .loadTimeout(let id): "Timed out loading \(id)."
        case .http(let code, let body): "Worker returned HTTP \(code): \(body.prefix(500))"
        case .malformedResponse: "Worker returned a malformed OpenAI-compatible response."
        case .lowConfidenceOCR(let page, let confidence): "OCR confidence was too low on page \(page) (\(String(format: "%.2f", confidence)))."
        }
    }
}


public actor MLXAudioRuntime: ModelRuntime {
    public nonisolated let backend: InferenceBackend = .whisperMLX
    private let executable: URL
    private let watchdogScript: URL?
    private let watchdogInterpreter: URL?
    private let port: Int
    private var process: Process?
    private var loaded: Set<String> = []

    public init(executable: URL, watchdogScript: URL? = nil,
                watchdogInterpreter: URL? = nil, port: Int = 18481) {
        self.executable = executable; self.watchdogScript = watchdogScript
        self.watchdogInterpreter = watchdogInterpreter; self.port = port
    }

    public func load(model: RegisteredModel) async throws {
        try await ensureServer()
        guard let endpoint = URL(string: "http://127.0.0.1:\(port)/v1/models") else { throw RuntimeFailure.configuration("Invalid audio endpoint") }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "model_name", value: model.localPath.path)]
        var request = URLRequest(url: components.url!); request.httpMethod = "POST"; request.timeoutInterval = 180
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RuntimeFailure.http((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        loaded.insert(model.id)
    }

    public func unload(model: RegisteredModel) async {
        if process?.isRunning == true {
            var components = URLComponents(string: "http://127.0.0.1:\(port)/v1/models")!
            components.queryItems = [URLQueryItem(name: "model_name", value: model.localPath.path)]
            var request = URLRequest(url: components.url!); request.httpMethod = "DELETE"; request.timeoutInterval = 30
            _ = try? await URLSession.shared.data(for: request)
        }
        loaded.remove(model.id)
        if loaded.isEmpty { await stopServer() }
    }

    public func execute(model: RegisteredModel?, stage: RouteStage, input: StageExecutionInput) async throws -> PipelineArtifact {
        guard let model, loaded.contains(model.id) else { throw RuntimeFailure.notLoaded(model?.id ?? "audio") }
        let audioFiles = input.request.attachments.filter { $0.modality == .audio }
        guard !audioFiles.isEmpty else { throw RuntimeFailure.configuration("Transcription received no audio files.") }
        var transcripts: [String] = []
        for (index, audio) in audioFiles.enumerated() {
            try Task.checkCancellation()
            transcripts.append("## Recording \(index + 1)\n\n" + (try await transcribe(audio, model: model)))
        }
        return PipelineArtifact(kind: .transcript, content: transcripts.joined(separator: "\n\n"), sourceURLs: audioFiles.map(\.url),
                                metadata: ["model": model.id, "backend": backend.rawValue, "recordings": String(audioFiles.count)])
    }

    private func transcribe(_ audio: RequestAttachment, model: RegisteredModel) async throws -> String {
        let boundary = "MLXMenu-\(UUID().uuidString)"
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", model.localPath.path); field("response_format", "json"); field("max_tokens", "4096")
        guard let fileData = try? Data(contentsOf: audio.url) else { throw RuntimeFailure.configuration("Could not read audio file \(audio.url.lastPathComponent).") }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.url.lastPathComponent)\"\r\nContent-Type: \(audio.mimeType ?? "audio/wav")\r\n\r\n")
        body.append(fileData); append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/audio/transcriptions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 600; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RuntimeFailure.http((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = json?["text"] as? String, !text.isEmpty else { throw RuntimeFailure.malformedResponse }
        return text
    }

    public func health(model: RegisteredModel) async -> ModelHealth { loaded.contains(model.id) && process?.isRunning == true ? .healthy : .unavailable }

    private func ensureServer() async throws {
        if process?.isRunning == true { return }
        guard loopbackPortAvailable(port) else { throw RuntimeFailure.configuration("Audio worker port \(port) is already in use.") }
        let process = Process(); process.executableURL = executable
        process.arguments = ["--host", "127.0.0.1", "--port", String(port), "--log-dir",
                             FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/MLXMenu/audio").path]
        if let watchdogScript {
            guard let watchdogInterpreter else {
                throw RuntimeFailure.configuration("The MLX audio tool's Python interpreter is unavailable.")
            }
            let workerArguments = process.arguments ?? []
            process.executableURL = watchdogInterpreter
            process.arguments = [watchdogScript.path, String(ProcessInfo.processInfo.processIdentifier), executable.path] + workerArguments
        }
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"; environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/MLXMenu")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let log = logDirectory.appending(path: "audio-server.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd(); process.standardOutput = handle; process.standardError = handle
        try process.run(); WorkerProcessRegistry.shared.register(process); self.process = process
        for _ in 0..<300 {
            guard process.isRunning else { throw RuntimeFailure.exitedWhileLoading("mlx-audio") }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!); request.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        await stopServer(); throw RuntimeFailure.loadTimeout("mlx-audio")
    }

    private func stopServer() async {
        guard let process else { return }; self.process = nil; WorkerProcessRegistry.shared.unregister(process)
        if process.isRunning { process.terminate(); for _ in 0..<30 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }; if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }
}
