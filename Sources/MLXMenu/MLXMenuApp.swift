import AppKit
import Combine
import LocalLLMCore
import LocalInferenceBackends
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

final class MLXMenuAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) { WorkerProcessRegistry.shared.terminateAllSynchronously() }
}

@main
struct MLXMenuApp: App {
    @NSApplicationDelegateAdaptor(MLXMenuAppDelegate.self) private var appDelegate
    @StateObject private var server = ServerController()
    @StateObject private var autoRouter = AutoRouterController()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(server: server, autoRouter: autoRouter)
        } label: {
            Label("MLX Menu", systemImage: server.state.symbol)
        }
        .menuBarExtraStyle(.window)

        Window("MLX Chat", id: "chat") {
            ChatView(server: server, autoRouter: autoRouter)
        }
        .defaultSize(width: 680, height: 640)
        .windowResizability(.contentMinSize)
    }
}

enum ServerState: Equatable {
    case stopped
    case starting(String)
    case running(String)
    case stopping
    case failed(String)

    var symbol: String {
        switch self {
        case .running: "bolt.fill"
        case .starting, .stopping: "arrow.trianglehead.2.clockwise.rotate.90"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "bolt"
        }
    }
    var title: String {
        switch self {
        case .stopped: "Offline"
        case .starting: "Loading model…"
        case .running: "Ready"
        case .stopping: "Stopping…"
        case .failed: "Needs attention"
        }
    }
    var tint: Color {
        switch self { case .running: .green; case .failed: .orange; case .starting, .stopping: .blue; case .stopped: .secondary }
    }
    var isBusy: Bool { if case .starting = self { return true }; if case .stopping = self { return true }; return false }
    var isRunning: Bool { if case .running = self { return true }; return false }
}

enum CacheOperationState: Equatable {
    case idle
    case downloading(String)
    case removing(String)
    case completed(String)
    case failed(String)

    var isBusy: Bool {
        if case .downloading = self { return true }
        if case .removing = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .idle: nil
        case .downloading(let repository): "Downloading \(repository)…"
        case .removing(let repository): "Removing \(repository)…"
        case .completed(let message), .failed(let message): message
        }
    }
}

@MainActor
final class ServerController: ObservableObject {
    @Published var models: [LocalModel] = []
    @Published var cachedModels: [CachedModel] = []
    @Published var selectedID: String = ""
    @Published var state: ServerState = .stopped
    @Published var logURL: URL?
    @Published var showAdvanced = false
    @Published var port: Int = 8081
    @Published var maxTokens: Int = 4096
    @Published var thinking = false
    @Published var downloadRepository = ""
    @Published var cacheState: CacheOperationState = .idle

    private var process: Process?
    private var monitorTask: Task<Void, Never>?
    private var cacheProcess: Process?
    private var cacheTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let cacheManager = ModelCacheManager()
    private let provenModelIDs: Set<String> = [
        "mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit",
        "mlx-community/Qwen3.6-35B-A3B-4bit",
        "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
        "mlx-community/Huihui-Qwen3.6-27B-abliterated-4.5bit-msq"
    ]

    var selectedModel: LocalModel? { models.first { $0.id == selectedID } }
    var endpoint: String { "http://127.0.0.1:\(port)/v1" }
    var cachedSizeBytes: Int64 { cachedModels.reduce(0) { $0 + $1.sizeBytes } }
    func isProven(_ model: CachedModel) -> Bool { provenModelIDs.contains(model.repository) }
    func manualModel(for cached: CachedModel) -> LocalModel? { models.first { $0.repository == cached.repository } }

    init() {
        let portMigrationKey = "didMigrateDefaultPortTo8081"
        let savedPort = defaults.object(forKey: "port") as? Int
        if !defaults.bool(forKey: portMigrationKey), savedPort == nil || savedPort == 8080 {
            port = 8081
            defaults.set(port, forKey: "port")
            defaults.set(true, forKey: portMigrationKey)
        } else {
            port = savedPort ?? 8081
        }
        maxTokens = defaults.object(forKey: "maxTokens") as? Int ?? 4096
        selectedID = defaults.string(forKey: "selectedModel") ?? ""
        refreshModels()
        if CommandLine.arguments.contains("--start") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.start()
            }
        }
    }

    func refreshModels() {
        let catalog = ModelCatalog()
        cachedModels = catalog.discoverCached().sorted { left, right in
            let leftProven = provenModelIDs.contains(left.repository)
            let rightProven = provenModelIDs.contains(right.repository)
            if leftProven != rightProven { return leftProven }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        models = catalog.discover().sorted { left, right in
            let leftProven = provenModelIDs.contains(left.repository)
            let rightProven = provenModelIDs.contains(right.repository)
            if leftProven != rightProven { return leftProven }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        if !models.contains(where: { $0.id == selectedID }) {
            selectedID = models.first(where: { $0.repository.localizedCaseInsensitiveContains("Huihui-Qwen3.6") })?.id
                ?? models.first(where: \.isAbliterated)?.id ?? models.first?.id ?? ""
        }
        persist()
    }

    func downloadModel() {
        let repository = downloadRepository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cacheState.isBusy else { return }
        guard ModelCacheManager.isValidRepositoryIdentifier(repository) else {
            cacheState = .failed("Enter a model as owner/repository.")
            return
        }
        guard !cachedModels.contains(where: { $0.repository == repository }) else {
            cacheState = .completed("That model is already cached.")
            return
        }
        guard let executable = HuggingFaceExecutable.discover() else {
            cacheState = .failed("The Hugging Face downloader was not found. Reinstall the mlx-lm uv tool.")
            return
        }

        cacheState = .downloading(repository)
        cacheTask?.cancel()
        cacheTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let proc = Process()
            proc.executableURL = executable
            proc.arguments = ["download", repository, "--cache-dir", cacheManager.cacheRoot.path]
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "HF_HUB_OFFLINE")
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            environment["HOME"] = home
            environment["PATH"] = "\(home)/.local/share/uv/tools/mlx-lm/bin:\(home)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
            proc.environment = environment
            do {
                let logs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/MLXMenu")
                try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                let log = logs.appending(path: "download.log")
                if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
                proc.standardOutput = handle; proc.standardError = handle
                try proc.run(); WorkerProcessRegistry.shared.register(proc); cacheProcess = proc
                let status = await Task.detached { proc.waitUntilExit(); return proc.terminationStatus }.value
                WorkerProcessRegistry.shared.unregister(proc); cacheProcess = nil
                guard !Task.isCancelled else { cacheState = .idle; return }
                guard status == 0 else {
                    cacheState = .failed("Download failed. See ~/Library/Logs/MLXMenu/download.log.")
                    return
                }
                refreshModels()
                guard cachedModels.contains(where: { $0.repository == repository }) else {
                    cacheState = .failed("Download finished, but no complete model snapshot was found in the cache.")
                    return
                }
                downloadRepository = ""
                if models.contains(where: { $0.repository == repository }) {
                    selectedID = repository; persist()
                    cacheState = .completed("Downloaded and selected \(repository).")
                } else {
                    cacheState = .completed("Downloaded \(repository). Restart MLX Menu to add it to Auto routing.")
                }
            } catch {
                WorkerProcessRegistry.shared.unregister(proc); cacheProcess = nil
                cacheState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelCacheOperation() {
        cacheTask?.cancel()
        if let cacheProcess, cacheProcess.isRunning { cacheProcess.terminate() }
        cacheProcess = nil
        cacheState = .idle
    }

    func remove(_ model: CachedModel) {
        guard !cacheState.isBusy else { return }
        guard !(state.isRunning && selectedID == model.id) else {
            cacheState = .failed("Stop the server before removing its selected model.")
            return
        }
        let repository = model.repository
        let manager = cacheManager
        cacheState = .removing(repository)
        cacheTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached { try manager.remove(repository: repository) }.value
                refreshModels()
                cacheState = .completed("Removed \(repository). Auto routing will refresh after MLX Menu restarts.")
            } catch {
                cacheState = .failed(error.localizedDescription)
            }
        }
    }

    func select(_ model: LocalModel) {
        guard model.id != selectedID else { return }
        selectedID = model.id
        persist()
        if state.isRunning { switchToSelected() }
    }

    func toggle() {
        if state.isRunning { stop() } else { start() }
    }

    func start() {
        guard !state.isBusy, let model = selectedModel else { return }
        guard let executable = MLXExecutable.discover() else {
            state = .failed("MLX-LM was not found in ~/.local. Reinstall the mlx-lm uv tool.")
            return
        }
        let installedWrapper = Bundle.main.resourceURL?.appending(path: "mlx_server_no_mpi.py")
        let developmentWrapper = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Sources/MLXMenu/Resources/mlx_server_no_mpi.py")
        let wrapper = [installedWrapper, developmentWrapper].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        let installedWatchdog = Bundle.main.resourceURL?.appending(path: "worker_watchdog.py")
        let developmentWatchdog = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Sources/MLXMenu/Resources/worker_watchdog.py")
        let watchdog = [installedWatchdog, developmentWatchdog].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        let needsPythonWrapper = executable.lastPathComponent.localizedCaseInsensitiveContains("python")
        if needsPythonWrapper && wrapper == nil {
            state = .failed("The MLX launcher resource is missing.")
            return
        }
        guard isPortAvailable(port) else {
            state = .failed("Port \(port) is already in use. Choose another port in Advanced.")
            return
        }

        let concurrency = model.repository.localizedCaseInsensitiveContains("A3B") ? 4 : 2
        let config = ServerConfiguration(executable: executable, launcherScript: needsPythonWrapper ? wrapper : nil,
            modelPath: model.snapshotPath, port: port, maxTokens: maxTokens,
            decodeConcurrency: concurrency, promptConcurrency: 1)
        let proc = Process()
        let serverArguments = config.tunedArguments + (thinking ? [] : ["--chat-template-args", "{\"enable_thinking\":false}"])
        if let watchdog {
            guard let watchdogInterpreter = PythonExecutable.forToolExecutable(config.executable) else {
                state = .failed("The mlx-lm tool's Python interpreter is unavailable. Reinstall mlx-lm with uv.")
                return
            }
            proc.executableURL = watchdogInterpreter
            proc.arguments = [watchdog.path, String(ProcessInfo.processInfo.processIdentifier), config.executable.path] + serverArguments
        } else {
            proc.executableURL = config.executable
            proc.arguments = serverArguments
        }
        proc.environment = launchEnvironment()


        do {
            let logs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/MLXMenu")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let log = logs.appending(path: "server.log")
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            proc.standardOutput = handle
            proc.standardError = handle
            try proc.run(); WorkerProcessRegistry.shared.register(proc)
            process = proc
            logURL = log
            state = .starting(model.name)
            persist()
            monitorReadiness(config: config, model: model, process: proc)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        guard let proc = process else { state = .stopped; return }
        guard proc.isRunning else {
            WorkerProcessRegistry.shared.unregister(proc); process = nil; state = .stopped; return
        }
        monitorTask?.cancel()
        state = .stopping
        WorkerProcessRegistry.shared.unregister(proc); proc.terminate()
        Task { @MainActor in
            for _ in 0..<30 where proc.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            process = nil
            state = .stopped
        }
    }

    func stopAndWait() async {
        stop()
        for _ in 0..<80 {
            if process == nil || process?.isRunning == false { state = .stopped; process = nil; return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func switchToSelected() {
        guard let proc = process else { start(); return }
        monitorTask?.cancel()
        state = .stopping
        WorkerProcessRegistry.shared.unregister(proc)
        if proc.isRunning { proc.terminate() }
        Task { @MainActor in
            for _ in 0..<50 where proc.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            process = nil
            state = .stopped
            start()
        }
    }

    private func monitorReadiness(config: ServerConfiguration, model: LocalModel, process proc: Process) {
        monitorTask?.cancel()
        monitorTask = Task { @MainActor in
            for _ in 0..<900 {
                guard !Task.isCancelled else { return }
                if !proc.isRunning {
                    WorkerProcessRegistry.shared.unregister(proc); process = nil
                    state = .failed("The server exited while loading. Open the log for details.")
                    return
                }
                var request = URLRequest(url: config.healthEndpoint)
                request.timeoutInterval = 1
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    state = .running(model.name)
                    while proc.isRunning && !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                    }
                    if !Task.isCancelled {
                        WorkerProcessRegistry.shared.unregister(proc); process = nil
                        state = .failed("The server stopped unexpectedly. Open the log for details.")
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            if proc.isRunning { proc.terminate() }
            WorkerProcessRegistry.shared.unregister(proc)
            if process === proc { process = nil }
            state = .failed("Model loading timed out. Check memory pressure and the server log.")
        }
    }

    func copyEndpoint() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(endpoint, forType: .string) }
    func openLog() { if let logURL { NSWorkspace.shared.open(logURL) } }
    func quit(autoRouter: AutoRouterController) {
        cancelCacheOperation()
        if let process, process.isRunning { WorkerProcessRegistry.shared.unregister(process); process.terminate() }
        Task { await autoRouter.shutdown(); NSApplication.shared.terminate(nil) }
    }

    private func persist() {
        defaults.set(selectedID, forKey: "selectedModel")
        defaults.set(port, forKey: "port")
        defaults.set(maxTokens, forKey: "maxTokens")
    }

    private func launchEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["HOME"] = home
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_OFFLINE"] = "1"
        return env
    }

    private func isPortAvailable(_ port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

struct MenuPanel: View {
    @ObservedObject var server: ServerController
    @ObservedObject var autoRouter: AutoRouterController
    @Environment(\.openWindow) private var openWindow
    @State private var copied = false
    @State private var pendingRemoval: CachedModel?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            modelList
            Divider().opacity(0.55)
            controls
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Remove cached model?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { model in
            Button("Remove \(model.name)", role: .destructive) {
                Task { await autoRouter.shutdown(); server.remove(model) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { model in
            Text("This deletes \(model.formattedSize) from the Hugging Face disk cache. You can download it again later.")
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(server.state.tint.opacity(0.14)).frame(width: 34, height: 34)
                Image(systemName: server.state.symbol).foregroundStyle(server.state.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("MLX Local").font(.headline)
                Text(server.state.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(server.state.tint).frame(width: 7, height: 7)
        }
        .padding(14)
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("CACHED MODELS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(server.cachedModels.count) · \(ByteCountFormatter.string(fromByteCount: server.cachedSizeBytes, countStyle: .file))")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(action: server.refreshModels) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh models").disabled(server.cacheState.isBusy)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(server.cachedModels) { model in
                        let manualModel = server.manualModel(for: model)
                        HStack(spacing: 3) {
                            Button { if let manualModel { server.select(manualModel) } } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: server.selectedID == model.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(server.selectedID == model.id ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.name).lineLimit(1).font(.system(size: 12, weight: .medium))
                                        HStack(spacing: 5) {
                                            if server.isProven(model) {
                                                Text("PROVEN").font(.system(size: 8, weight: .bold)).foregroundStyle(.green)
                                            }
                                            if model.repository.localizedCaseInsensitiveContains("abliterat") {
                                                Text("ABLITERATED").font(.system(size: 8, weight: .bold)).foregroundStyle(.purple)
                                            }
                                            if manualModel == nil {
                                                Text("NOT MANUAL").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                                            }
                                            Text(model.formattedSize).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle()).padding(.vertical, 5).padding(.leading, 6)
                            }
                            .buttonStyle(.plain)
                            .disabled(manualModel == nil || server.state.isBusy || server.cacheState.isBusy)

                            Button { pendingRemoval = model } label: {
                                Image(systemName: "trash").font(.caption).foregroundStyle(.secondary)
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                            .help(server.state.isRunning && server.selectedID == model.id ? "Stop the server before removing this model" : "Remove cached model")
                            .disabled(server.cacheState.isBusy || autoRouter.isRunning || (server.state.isRunning && server.selectedID == model.id))
                        }
                        .background(server.selectedID == model.id ? Color.accentColor.opacity(0.08) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }.frame(maxHeight: 185)

            Divider().opacity(0.45)
            Text("DOWNLOAD MODEL").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 7) {
                TextField("owner/repository", text: $server.downloadRepository)
                    .textFieldStyle(.roundedBorder)
                    .disabled(server.cacheState.isBusy)
                    .onSubmit(server.downloadModel)
                if server.cacheState.isBusy {
                    Button(action: server.cancelCacheOperation) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("Cancel")
                } else {
                    Button(action: server.downloadModel) { Image(systemName: "arrow.down.circle.fill") }
                        .buttonStyle(.plain).help("Download from Hugging Face")
                        .disabled(server.downloadRepository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if server.cacheState.isBusy { ProgressView().controlSize(.small) }
            if let message = server.cacheState.message {
                Text(message).font(.caption2)
                    .foregroundStyle({ if case .failed = server.cacheState { return Color.orange }; return Color.secondary }())
                    .lineLimit(3)
            }
            Text("Cached files use disk. Only a running model uses unified memory.")
                .font(.caption2).foregroundStyle(.tertiary)
        }.padding(12)
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { server.selectedID },
            set: { id in
                guard let model = server.models.first(where: { $0.id == id }) else { return }
                server.select(model)
            }
        )
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if case .failed(let message) = server.state {
                Text(message).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Label("Model", systemImage: "cpu")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("Model", selection: modelSelection) {
                    ForEach(server.models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 245, alignment: .trailing)
                .disabled(server.models.isEmpty || server.state.isBusy || server.cacheState.isBusy || autoRouter.isRunning)
            }

            Button {
                openWindow(id: "chat")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Chat", systemImage: "terminal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(action: server.toggle) {
                HStack {
                    if server.state.isBusy { ProgressView().controlSize(.small) }
                    Image(systemName: server.state.isRunning ? "stop.fill" : "play.fill")
                    Text(server.state.isRunning ? "Stop Server" : "Start Server")
                }.frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(server.state.isBusy || server.cacheState.isBusy || server.selectedModel == nil)

            HStack {
                Text(server.endpoint).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button { server.copyEndpoint(); copied = true; Task { try? await Task.sleep(for: .seconds(1)); copied = false } } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(.plain).help("Copy OpenAI-compatible endpoint")
            }

            DisclosureGroup("Advanced", isExpanded: $server.showAdvanced) {
                VStack(spacing: 8) {
                    HStack { Text("Port"); Spacer(); TextField("8081", value: $server.port, format: .number).frame(width: 70).textFieldStyle(.roundedBorder) }
                    HStack { Text("Max output tokens"); Spacer(); TextField("4096", value: $server.maxTokens, format: .number).frame(width: 70).textFieldStyle(.roundedBorder) }
                    Toggle("Enable model thinking", isOn: $server.thinking)
                }.font(.caption).padding(.top, 6)
            }.font(.caption)

            HStack {
                if server.logURL != nil { Button("Open Log", action: server.openLog).buttonStyle(.plain) }
                Spacer()
                Button("Quit") { server.quit(autoRouter: autoRouter) }.buttonStyle(.plain)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(12)
    }
}


// MARK: - Local chat

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, notice }
    let id: UUID
    let role: Role
    var content: String

    init(role: Role, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
    }
}

private struct ChatRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    let model: String
    let messages: [Message]
    let temperature: Double
    let max_tokens: Int
    let stream: Bool
}

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }
    let choices: [Choice]
}

enum RoutingMode: String, CaseIterable, Identifiable { case auto = "Auto", manual = "Manual"; var id: String { rawValue } }

@MainActor
final class ChatController: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var attachments: [URL] = []
    @Published var mode: RoutingMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "routingMode") } }
    @Published var isGenerating = false
    @Published var statusText = "Local session"
    private var generationTask: Task<Void, Never>?

    init() {
        mode = UserDefaults.standard.string(forKey: "routingMode").flatMap(RoutingMode.init(rawValue:)) ?? .manual
    }

    func submit(server: ServerController, autoRouter: AutoRouterController) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        input = ""

        if attachments.isEmpty { switch text.lowercased() {
        case "clear", "/clear", "/reset":
            clear()
            return
        case "/help":
            messages.append(ChatMessage(role: .notice, content: "Commands: clear or /clear · /model · /stop · /help"))
            return
        case "/model":
            messages.append(ChatMessage(role: .notice, content: server.selectedModel?.repository ?? "No model selected"))
            return
        case "/stop":
            stop()
            return
        default:
            break
        } }

        if mode == .auto || !attachments.isEmpty {
            submitRouted(text: text, server: server, autoRouter: autoRouter)
            return
        }

        guard server.state.isRunning, let model = server.selectedModel else {
            messages.append(ChatMessage(role: .notice, content: "Server is offline. Start it from the menu-bar panel, then try again."))
            return
        }

        let context = messages.compactMap { message -> ChatRequest.Message? in
            guard message.role != .notice, !message.content.isEmpty else { return nil }
            return ChatRequest.Message(role: message.role.rawValue, content: message.content)
        } + [ChatRequest.Message(role: "user", content: text)]
        messages.append(ChatMessage(role: .user, content: text))
        let responseID = UUID()
        messages.append(ChatMessage(role: .assistant, content: ""))
        let responseIndex = messages.count - 1
        // Preserve the generated ID by replacing the placeholder once.
        messages[responseIndex] = ChatMessage(id: responseID, role: .assistant, content: "")

        guard let url = URL(string: server.endpoint + "/chat/completions") else { return }
        let requestBody = ChatRequest(model: model.snapshotPath.path, messages: context,
                                      temperature: 0.2, max_tokens: server.maxTokens, stream: true)
        isGenerating = true
        statusText = "Generating locally…"

        generationTask?.cancel()
        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 600
                request.httpBody = try JSONEncoder().encode(requestBody)
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }

                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard line.hasPrefix("data:") else { continue }
                    let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard value != "[DONE]", let data = value.data(using: .utf8),
                          let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                          let token = chunk.choices.first?.delta.content else { continue }
                    if let index = messages.firstIndex(where: { $0.id == responseID }) {
                        messages[index].content += token
                    }
                }
                statusText = "Local session"
            } catch is CancellationError {
                statusText = "Generation stopped"
            } catch {
                if let index = messages.firstIndex(where: { $0.id == responseID }), messages[index].content.isEmpty {
                    messages[index].content = "Request failed: \(error.localizedDescription)"
                }
                statusText = "Request failed"
            }
            isGenerating = false
        }
    }

    private func submitRouted(text: String, server: ServerController, autoRouter: AutoRouterController) {
        let files = attachments
        attachments = []
        let attachmentSummary = files.map(\.lastPathComponent).joined(separator: ", ")
        let display = text.isEmpty ? "Attached: \(attachmentSummary)" : text + (files.isEmpty ? "" : "\nAttached: \(attachmentSummary)")
        let history = messages.compactMap { message -> ConversationTurn? in
            guard message.role != .notice, !message.content.isEmpty else { return nil }
            return ConversationTurn(role: message.role.rawValue, content: message.content)
        }
        messages.append(ChatMessage(role: .user, content: display))
        let responseID = UUID()
        messages.append(ChatMessage(id: responseID, role: .assistant, content: ""))
        let requestAttachments = files.map { url -> RequestAttachment in
            var extractable: Bool? = nil; var pages: Int? = nil
            if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
                pages = pdf.pageCount
                extractable = !(pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return RequestAttachment(url: url, hasExtractableText: extractable, pageCount: pages)
        }
        let forced = mode == .manual ? server.selectedModel?.repository : nil
        let lower = text.lowercased()
        let structured = ["return json", "as json", "output json", "json object", "valid json"].contains(where: lower.contains)
        let estimatedTokens = max(text.count / 4, requestAttachments.reduce(0) { partial, attachment in
            partial + (attachment.modality == .code ? ((try? Data(contentsOf: attachment.url).count) ?? 0) / 4 :
                       attachment.modality == .document ? (attachment.pageCount ?? 1) * 1_500 : 0)
        })
        let request = InferenceRequest(text: text, attachments: requestAttachments, history: history,
                                       minimumContextTokens: min(estimatedTokens, 262_144), requiresStructuredOutput: structured,
                                       forcedModelID: forced)
        isGenerating = true; statusText = mode == .auto ? "Classifying and routing locally…" : "Running selected model locally…"
        generationTask?.cancel()
        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let wasRunning = server.state.isRunning
            do {
                if wasRunning { await server.stopAndWait() }
                let trace = try await autoRouter.run(request)
                let answer = trace.artifacts.last?.content ?? "The pipeline completed without a final text artifact."
                if let index = messages.firstIndex(where: { $0.id == responseID }) { messages[index].content = answer }
                let path = trace.actualModelIDs.map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: " → ")
                statusText = "\(mode == .auto ? "AUTO" : "MANUAL") · \(path)"
            } catch is CancellationError {
                statusText = "Generation stopped"
            } catch {
                if let index = messages.firstIndex(where: { $0.id == responseID }) { messages[index].content = "Request failed: \(error.localizedDescription)" }
                statusText = "Routing failed"
            }
            if wasRunning {
                await autoRouter.shutdown()
                server.start()
            }
            isGenerating = false
        }
    }

    func resumeRouted(server: ServerController, autoRouter: AutoRouterController) {
        guard autoRouter.resumableRequest != nil, !isGenerating else { return }
        let responseID = UUID(); messages.append(ChatMessage(id: responseID, role: .assistant, content: "Resuming saved local job…"))
        isGenerating = true; statusText = "Validating checkpoint and resuming locally…"
        generationTask?.cancel()
        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let wasRunning = server.state.isRunning
            do {
                if wasRunning { await server.stopAndWait() }
                let trace = try await autoRouter.resumeLatest()
                if let index = messages.firstIndex(where: { $0.id == responseID }) {
                    messages[index].content = trace.artifacts.last?.content ?? "The resumed pipeline completed without final text."
                }
                statusText = "RESUMED · \(trace.actualModelIDs.map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: " → "))"
            } catch {
                if let index = messages.firstIndex(where: { $0.id == responseID }) { messages[index].content = "Resume failed: \(error.localizedDescription)" }
                statusText = "Resume failed"
            }
            if wasRunning { await autoRouter.shutdown(); server.start() }
            isGenerating = false
        }
    }

    func addAttachments(_ urls: [URL]) {
        for url in urls where !attachments.contains(url) { attachments.append(url) }
    }

    func clear() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        messages.removeAll()
        attachments.removeAll()
        statusText = "Session cleared"
    }

    func stop() {
        guard isGenerating else {
            statusText = "Nothing is running"
            return
        }
        generationTask?.cancel()
    }
}

private extension ChatMessage {
    init(id: UUID, role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

struct ChatView: View {
    @ObservedObject var server: ServerController
    @ObservedObject var autoRouter: AutoRouterController
    @StateObject private var chat = ChatController()
    @FocusState private var inputFocused: Bool
    @State private var showingImporter = false
    @State private var showingRouteDetails = false

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider().opacity(0.5)
            transcript
            Divider().opacity(0.5)
            composer
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { inputFocused = true }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.image, .pdf, .audio, .plainText, .sourceCode], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { chat.addAttachments(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in chat.addAttachments(urls); return true }
        .background {
            Button("Clear session") { chat.clear() }
                .keyboardShortcut("l", modifiers: .control)
                .hidden()
        }
    }

    private var chatModelSelection: Binding<String> {
        Binding(
            get: { server.selectedID },
            set: { id in
                guard let model = server.models.first(where: { $0.id == id }) else { return }
                server.select(model)
            }
        )
    }

    private var chatHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.88))
                    .frame(width: 36, height: 36)
                Text(">_").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("LOCAL CONSOLE").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.1)
                if chat.mode == .auto {
                    Text(autoRouter.decision?.stages.map(\.kind.rawValue).joined(separator: " → ") ?? "Capability router")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Picker("Model", selection: chatModelSelection) {
                        ForEach(server.models) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: 245, alignment: .leading)
                    .disabled(server.models.isEmpty || server.state.isBusy || server.cacheState.isBusy || chat.isGenerating || autoRouter.isRunning)
                }
            }
            Picker("Mode", selection: $chat.mode) {
                ForEach(RoutingMode.allCases) { Text($0.rawValue.uppercased()).tag($0) }
            }.pickerStyle(.segmented).frame(width: 138)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(server.state.tint).frame(width: 7, height: 7)
                Text(server.state.title.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button { chat.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).help("Clear session (Control-L)")
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if chat.messages.isEmpty { emptyState }
                    ForEach(chat.messages) { message in
                        ChatMessageRow(message: message)
                            .id(message.id)
                    }
                    if chat.isGenerating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("inference").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
            }
            .onChange(of: chat.messages) { _, _ in
                withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("READY FOR INPUT").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.green)
            Text(chat.mode == .auto ? "Drop text, images, PDFs, scans, code, or audio. MLX Menu chooses the local route." : "A private conversation with the selected MLX model. Nothing leaves this Mac.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Text("Type /help for commands")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 36).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        VStack(spacing: 9) {
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chat.attachments, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                Text(url.lastPathComponent).lineLimit(1)
                                Button { chat.attachments.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                            }.font(.caption).padding(.horizontal, 8).padding(.vertical, 5).background(Color.secondary.opacity(0.1), in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button { showingImporter = true } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.plain).help("Attach images, documents, code, or audio")
                Text("❯").font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(.green)
                TextField("Message or command…", text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit { chat.submit(server: server, autoRouter: autoRouter) }
                    .disabled(chat.isGenerating)
                if chat.isGenerating {
                    Button { chat.stop() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.bordered).help("Stop generation")
                } else {
                    Button { chat.submit(server: server, autoRouter: autoRouter) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .disabled(chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.attachments.isEmpty)
                        .help("Send")
                }
            }
            HStack {
                Text(chat.statusText).foregroundStyle(.secondary)
                Spacer()
                if autoRouter.resumableRequest != nil && !chat.isGenerating {
                    Button("Resume saved job") { chat.resumeRouted(server: server, autoRouter: autoRouter) }.buttonStyle(.plain)
                    Button("Discard") { autoRouter.discardResumableJob() }.buttonStyle(.plain)
                }
                if autoRouter.decision != nil {
                    Button(showingRouteDetails ? "Hide route" : "Route details") { showingRouteDetails.toggle() }.buttonStyle(.plain)
                } else {
                    Text("clear · /model · /stop · /help").foregroundStyle(.tertiary)
                }
            }.font(.system(size: 9, design: .monospaced))
            if showingRouteDetails, let decision = autoRouter.decision {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TASK  \(decision.requirements.category.rawValue)")
                    Text("NEEDS \(decision.requirements.requiredCapabilities.map(\.rawValue).sorted().joined(separator: ", "))")
                    Text("ROUTE \(decision.stages.map { $0.modelID ?? $0.kind.rawValue }.joined(separator: " → "))")
                    let selected = autoRouter.registryModels.filter { decision.selectedModelIDs.contains($0.id) }
                    if let peak = selected.map(\.approximateMemoryBytes).max() {
                        Text("MEMORY estimated sequential peak \(ByteCountFormatter.string(fromByteCount: peak, countStyle: .memory))")
                    }
                    if let trace = autoRouter.trace {
                        Text("LATENCY \(String(format: "%.2f", (trace.telemetry?.wallMilliseconds ?? trace.completedAt.timeIntervalSince(trace.startedAt) * 1000) / 1000)) s active")
                        if !trace.fallbacks.isEmpty { Text("FALLBACKS \(trace.fallbacks.joined(separator: ", "))") }
                    }
                    Text("WHY   \(decision.reason)").foregroundStyle(.secondary)
                    ForEach(Array(autoRouter.events.enumerated()), id: \.offset) { _, event in Text("· \(event)").foregroundStyle(.secondary) }
                    if let trace = autoRouter.trace {
                        ForEach(trace.artifacts) { artifact in
                            DisclosureGroup(artifact.kind.rawValue.uppercased()) {
                                Text(artifact.content.isEmpty ? "(no text; \(artifact.sourceURLs.count) derived files)" : artifact.content)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
                            }
                        }
                    }
                }.font(.system(size: 9, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                 .padding(8).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }
}

struct ChatMessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 55)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                Text("YOU").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 10)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 11) {
                Text("MLX").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.green).padding(.top, 4)
                Text(message.content.isEmpty ? " " : message.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .notice:
            HStack(spacing: 8) {
                Image(systemName: "command").foregroundStyle(.secondary)
                Text(message.content).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
    }
}
