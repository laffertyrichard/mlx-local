import Darwin
import Foundation

public enum NetworkPermission: Codable, Equatable, Sendable {
    case none
    case loopback(ports: [Int])
    case hosts([String])
}
public enum RetrySemantics: String, Codable, Sendable { case never, safe, idempotentOnly = "idempotent_only" }

public struct WorkflowPermissionContract: Codable, Equatable, Sendable {
    public var readableRoots: [URL]
    public var writableRoots: [URL]
    public var network: NetworkPermission
    public var executablePaths: [URL]
    public var requiresUserConfirmation: Bool
    public init(readableRoots: [URL], writableRoots: [URL] = [], network: NetworkPermission = .none,
                executablePaths: [URL] = [], requiresUserConfirmation: Bool = false) {
        self.readableRoots = readableRoots; self.writableRoots = writableRoots; self.network = network
        self.executablePaths = executablePaths; self.requiresUserConfirmation = requiresUserConfirmation
    }
}

public struct WorkflowDescriptor: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var description: String
    public var inputSchema: String
    public var outputSchema: String
    public var capabilities: Set<Capability>
    public var permissions: WorkflowPermissionContract
    public var timeoutSeconds: Int
    public var cancellationBehavior: String
    public var retrySemantics: RetrySemantics
    public var idempotent: Bool
    public var checkpoints: Bool
    public var artifactKinds: [ArtifactKind]
    public var estimatedMemoryBytes: Int64?
    public init(id: String, version: String, description: String, inputSchema: String, outputSchema: String,
                capabilities: Set<Capability>, permissions: WorkflowPermissionContract,
                timeoutSeconds: Int, cancellationBehavior: String = "cooperative", retrySemantics: RetrySemantics = .never,
                idempotent: Bool, checkpoints: Bool, artifactKinds: [ArtifactKind], estimatedMemoryBytes: Int64? = nil) {
        self.id = id; self.version = version; self.description = description; self.inputSchema = inputSchema
        self.outputSchema = outputSchema; self.capabilities = capabilities; self.permissions = permissions
        self.timeoutSeconds = timeoutSeconds; self.cancellationBehavior = cancellationBehavior
        self.retrySemantics = retrySemantics; self.idempotent = idempotent; self.checkpoints = checkpoints
        self.artifactKinds = artifactKinds; self.estimatedMemoryBytes = estimatedMemoryBytes
    }
    public var qualifiedID: String { "\(id)@\(version)" }
}

public struct WorkflowInvocation: Identifiable, Codable, Sendable {
    public var id: UUID
    public var workflowID: String
    public var input: [String: String]
    public var requestedReads: [URL]
    public var requestedWrites: [URL]
    public var confirmationGranted: Bool
    public init(id: UUID = UUID(), workflowID: String, input: [String: String], requestedReads: [URL] = [],
                requestedWrites: [URL] = [], confirmationGranted: Bool = false) {
        self.id = id; self.workflowID = workflowID; self.input = input; self.requestedReads = requestedReads
        self.requestedWrites = requestedWrites; self.confirmationGranted = confirmationGranted
    }
}

public struct WorkflowResult: Codable, Equatable, Sendable {
    public var invocationID: UUID
    public var workflowID: String
    public var output: [String: String]
    public var artifacts: [PipelineArtifact]
    public var provenance: [String: String]
    public var startedAt: Date
    public var completedAt: Date
}

public struct WorkflowAuditEntry: Codable, Equatable, Sendable {
    public var invocationID: UUID
    public var workflowID: String
    public var at: Date
    public var outcome: String
    public var readPaths: [String]
    public var writePaths: [String]
    public var network: NetworkPermission
    public var detail: String
}

public enum WorkflowAuthorizationError: LocalizedError, Equatable {
    case unknownWorkflow(String), confirmationRequired(String), readDenied(String), writeDenied(String), malformedInput(String), timedOut(String)
    public var errorDescription: String? {
        switch self {
        case .unknownWorkflow(let id): "Workflow is not registered: \(id)."
        case .confirmationRequired(let id): "Workflow requires explicit user confirmation: \(id)."
        case .readDenied(let path): "Read denied outside declared file scope: \(path)."
        case .writeDenied(let path): "Write denied outside declared file scope: \(path)."
        case .malformedInput(let reason): "Workflow input is invalid: \(reason)."
        case .timedOut(let id): "Workflow timed out: \(id)."
        }
    }
}

public actor WorkflowCapabilityBroker {
    public enum BrokerError: LocalizedError { case notRegularFile(String), fileTooLarge(String), readDenied(String)
        public var errorDescription: String? { switch self {
        case .notRegularFile(let path): "Broker rejected non-regular file: \(path)."
        case .fileTooLarge(let path): "Broker rejected oversized file: \(path)."
        case .readDenied(let path): "Broker denied undeclared read: \(path)."
        } } }
    private let contract: WorkflowPermissionContract
    private var actualReads: [String] = []
    private var actualWrites: [String] = []
    init(contract: WorkflowPermissionContract) { self.contract = contract }
    public func readFile(_ url: URL, maximumBytes: Int = 64 * 1024 * 1024) throws -> Data {
        guard Self.contains(url, roots: contract.readableRoots) else { throw BrokerError.readDenied(url.path) }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = Darwin.open(resolved.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BrokerError.readDenied(resolved.path) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw BrokerError.notRegularFile(resolved.path)
        }
        guard info.st_size >= 0, info.st_size <= maximumBytes else { throw BrokerError.fileTooLarge(resolved.path) }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size)); var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), remaining)
            }
            guard count > 0 else { throw CocoaError(.fileReadUnknown) }
            offset += count
        }
        let data = Data(bytes)
        actualReads.append(resolved.path); return data
    }
    public func operations() -> (reads: [String], writes: [String]) { (actualReads, actualWrites) }
    fileprivate static func contains(_ url: URL, roots: [URL]) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains { root in
            let base = root.resolvingSymlinksInPath().standardizedFileURL.path
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }
}

public actor PermissionedWorkflowExecutor {
    /// Trusted in-process handlers must perform all declared I/O through the broker. Untrusted handlers require OS sandboxing.
    public typealias Handler = @Sendable (WorkflowInvocation, WorkflowCapabilityBroker) async throws -> WorkflowResult
    private var descriptors: [String: WorkflowDescriptor] = [:]
    private var handlers: [String: Handler] = [:]
    private var completed: [UUID: WorkflowResult] = [:]
    private let auditURL: URL?
    public init(auditURL: URL? = nil) { self.auditURL = auditURL }

    public func registerTrusted(_ descriptor: WorkflowDescriptor, handler: @escaping Handler) {
        descriptors[descriptor.qualifiedID] = descriptor; handlers[descriptor.qualifiedID] = handler
    }
    public func inspect() -> [WorkflowDescriptor] { descriptors.values.sorted { $0.qualifiedID < $1.qualifiedID } }
    public func execute(_ invocation: WorkflowInvocation) async throws -> WorkflowResult {
        guard let descriptor = descriptors[invocation.workflowID], let handler = handlers[invocation.workflowID] else {
            throw WorkflowAuthorizationError.unknownWorkflow(invocation.workflowID)
        }
        if descriptor.idempotent, let existing = completed[invocation.id] { return existing }
        let broker = WorkflowCapabilityBroker(contract: descriptor.permissions)
        do {
            try authorize(invocation, descriptor: descriptor)
            let result = try await withThrowingTaskGroup(of: WorkflowResult.self) { group in
                group.addTask { try await handler(invocation, broker) }
                group.addTask { try await Task.sleep(for: .seconds(descriptor.timeoutSeconds)); throw WorkflowAuthorizationError.timedOut(descriptor.qualifiedID) }
                guard let first = try await group.next() else { throw WorkflowAuthorizationError.timedOut(descriptor.qualifiedID) }
                group.cancelAll(); return first
            }
            if descriptor.idempotent { completed[invocation.id] = result }
            let operations = await broker.operations()
            try appendAudit(invocation, descriptor: descriptor, outcome: "success", detail: "completed",
                actualReads: operations.reads, actualWrites: operations.writes)
            return result
        } catch {
            let operations = await broker.operations()
            try? appendAudit(invocation, descriptor: descriptor, outcome: "denied_or_failed", detail: error.localizedDescription,
                actualReads: operations.reads, actualWrites: operations.writes)
            throw error
        }
    }
    private func authorize(_ invocation: WorkflowInvocation, descriptor: WorkflowDescriptor) throws {
        if descriptor.permissions.requiresUserConfirmation && !invocation.confirmationGranted { throw WorkflowAuthorizationError.confirmationRequired(descriptor.qualifiedID) }
        for url in invocation.requestedReads where !Self.contains(url, roots: descriptor.permissions.readableRoots) { throw WorkflowAuthorizationError.readDenied(url.path) }
        for url in invocation.requestedWrites where !Self.contains(url, roots: descriptor.permissions.writableRoots) { throw WorkflowAuthorizationError.writeDenied(url.path) }
    }
    private static func contains(_ url: URL, roots: [URL]) -> Bool { WorkflowCapabilityBroker.contains(url, roots: roots) }
    private func appendAudit(_ invocation: WorkflowInvocation, descriptor: WorkflowDescriptor, outcome: String, detail: String,
                             actualReads: [String], actualWrites: [String]) throws {
        guard let auditURL else { return }
        let entry = WorkflowAuditEntry(invocationID: invocation.id, workflowID: descriptor.qualifiedID, at: Date(), outcome: outcome,
            readPaths: actualReads, writePaths: actualWrites,
            network: descriptor.permissions.network, detail: detail)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let line = try encoder.encode(entry) + Data("\n".utf8)
        try FileManager.default.createDirectory(at: auditURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: auditURL.path) { FileManager.default.createFile(atPath: auditURL.path, contents: nil) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auditURL.path)
        let handle = try FileHandle(forWritingTo: auditURL); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: line)
    }
}

public enum BuiltinWorkflows {
    public static func localArtifactInspection(root: URL) -> (WorkflowDescriptor, PermissionedWorkflowExecutor.Handler) {
        let descriptor = WorkflowDescriptor(id: "construction.inspect-local-artifacts", version: "1.0.0",
            description: "Hash and inventory explicitly scoped construction inputs without network or process execution.",
            inputSchema: #"{"instruction":"string"}"#, outputSchema: #"{"files":"integer","manifest_digest":"string"}"#,
            capabilities: [.documentUnderstanding, .comparison],
            permissions: WorkflowPermissionContract(readableRoots: [root], network: .none), timeoutSeconds: 30,
            retrySemantics: .safe, idempotent: true, checkpoints: false, artifactKinds: [.json], estimatedMemoryBytes: 16_000_000)
        let handler: PermissionedWorkflowExecutor.Handler = { invocation, broker in
            let started = Date()
            var records: [String] = []
            for url in invocation.requestedReads.sorted(by: { $0.path < $1.path }) {
                let data = try await broker.readFile(url)
                records.append("\(url.lastPathComponent):\(data.count):\(StableDigest.sha256(data))")
            }
            let manifest = records.joined(separator: "\n")
            let digest = StableDigest.sha256(Data(manifest.utf8))
            let artifact = PipelineArtifact(kind: .json,
                content: #"{"files":\#(records.count),"manifest_digest":"\#(digest)"}"#,
                sourceURLs: invocation.requestedReads, confidence: 1,
                metadata: ["workflow": descriptor.qualifiedID, "network": "none"])
            return WorkflowResult(invocationID: invocation.id, workflowID: descriptor.qualifiedID,
                output: ["files": String(records.count), "manifest_digest": digest], artifacts: [artifact],
                provenance: ["executor": "deterministic-local", "workflow": descriptor.qualifiedID],
                startedAt: started, completedAt: Date())
        }
        return (descriptor, handler)
    }
}

public struct OrchestrationConfiguration: Identifiable, Codable, Sendable {
    public var id: String
    public var version: String
    public var parentModel: String
    public var parentPromptVersion: String
    public var contextStrategy: String
    public var localFirst: Bool
    public var profilePolicy: String
    public var maxChildAgents: Int
    public var toolPermissionIDs: [String]
    public var retryStrategy: String
    public var checkpointStrategy: String
    public var validationStrategy: String
    public var completionCriteria: [String]
    public var qualityBudget: Double?
    public var latencyBudgetMilliseconds: Double?
    public var apiCostBudgetUSD: Double
}

public struct OrchestrationEvaluation: Codable, Sendable {
    public var configurationID: String
    public var taskClass: String
    public var quality: Double
    public var latencyMilliseconds: Double
    public var parentTokens: Int?
    public var childTokens: Int?
    public var apiCostUSD: Double
    public var localInferenceMilliseconds: Double?
    public var failures: Int
}

/// Design-only: no provider client or authorization path exists in V3.
public struct CloudEscalationProposal: Codable, Sendable {
    public var reasonLocalInsufficient: String
    public var provider: String
    public var model: String
    public var dataLeavingMachine: [String]
    public var rawAttachmentsRequired: Bool
    public var redactionPlan: String?
    public var expectedBenefit: String
    public var estimatedTokens: Int
    public var estimatedCostUSD: Double
    public var deniedBehavior: String
    public var userAuthorized: Bool = false
}
