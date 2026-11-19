import AppKit
import LocalLLMCore
import SwiftUI

@MainActor
final class ReadPageController: ObservableObject {
    @Published var textModel = ""
    @Published var imageModel = ""
    @Published private(set) var models: [RegisteredModel] = []
    @Published private(set) var units: [InterpretationUnit] = []
    @Published private(set) var reviews: [String: CandidateReviewState] = [:]
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var message = ""
    @Published private(set) var running = false
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func refresh(_ manager: ModelResourceManager) async { models = await manager.registeredModels() }
    func reset() {
        task?.cancel(); generation = UUID(); running = false
        units = []; reviews = [:]; thumbnails = [:]; message = ""
    }
    func cancel() { task?.cancel(); message = "Cancelling…" }
    func read(_ source: SourceRecord, project: URL, store: PreconProjectStore, manager: ModelResourceManager) {
        guard !running, !textModel.isEmpty else { return }
        reset(); running = true; message = "Reading page \(source.pageIndex + 1)…"
        let token = generation
        let adapter = PreconRuntimeInterpreter(manager: manager, textModelID: textModel,
                                               imageModelID: imageModel.isEmpty ? nil : imageModel)
        task = Task {
            do {
                let pipeline = try await adapter.pipeline(store: store, project: project)
                let result = try await pipeline.run([source])
                try Task.checkCancellation()
                guard generation == token else { return }
                units = result
                message = result.flatMap(\.questions).joined(separator: "\n")
                if message.isEmpty { message = "Page read. Candidates are evidence, not quantities." }
                for unit in result {
                    let crops = try await PreconReadPage.thumbnails(unit.candidates, source: source, store: store, project: project)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    for candidate in unit.candidates {
                        reviews[candidate.id] = try store.candidateReview(unitId: unit.id, candidateId: candidate.id,
                            candidateDigest: candidate.reviewDigest(), in: project)
                        if let data = crops[candidate.id] {
                            thumbnails[candidate.id] = NSImage(data: data)
                        }
                    }
                }
            } catch {
                guard generation == token else { return }
                message = error is CancellationError ? "Cancelled. A model load already in progress may finish in the background." : error.localizedDescription
            }
            if generation == token { running = false; task = nil }
        }
    }
    func review(_ candidate: InterpretationCandidate, unit: InterpretationUnit, decision: CandidateReviewDecision,
                store: PreconProjectStore, project: URL) {
        do {
            let digest = try candidate.reviewDigest()
            _ = try store.saveCandidateReview(unitId: unit.id, candidateId: candidate.id, candidateDigest: digest,
                                              decision: decision, note: nil, in: project)
            reviews[candidate.id] = try store.candidateReview(unitId: unit.id, candidateId: candidate.id,
                                                             candidateDigest: digest, in: project)
        } catch { message = error.localizedDescription }
    }
}

struct ReadPagePanel: View {
    let manager: ModelResourceManager
    let store: PreconProjectStore
    let project: URL
    let source: SourceRecord
    @StateObject private var reader = ReadPageController()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PAGE EVIDENCE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Text model", selection: $reader.textModel) {
                Text("Choose a text model").tag("")
                ForEach(PreconReadPage.textModels(reader.models)) { Text($0.id).tag($0.id) }
            }.disabled(reader.running)
            Picker("Image model", selection: $reader.imageModel) {
                Text("None — scanned pages will defer").tag("")
                ForEach(PreconReadPage.imageModels(reader.models)) { Text($0.id).tag($0.id) }
            }.disabled(reader.running)
            HStack {
                Button("Read Page") { reader.read(source, project: project, store: store, manager: manager) }
                    .disabled(reader.textModel.isEmpty || reader.running)
                if reader.running { ProgressView().controlSize(.small); Button("Cancel", action: reader.cancel) }
            }
            if reader.textModel.isEmpty {
                Text(PreconReadPage.textModels(reader.models).isEmpty ? "No registered structured reasoning model is available." : "Choose a text model to read this page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !reader.message.isEmpty { Text(reader.message).font(.caption).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(reader.units, id: \.id) { unit in
                        Text("\(unit.stage.rawValue) · \(unit.status.rawValue)").font(.caption.weight(.semibold))
                        ForEach(Array(unit.questions.enumerated()), id: \.offset) { _, question in
                            Text(question).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(unit.candidates, id: \.id) { candidate in candidateRow(candidate, unit: unit) }
                    }
                }
            }.frame(maxHeight: 280)
        }
        .padding(12)
        .task { await reader.refresh(manager) }
        .onChange(of: source.id) { _,_ in reader.reset() }
        .onChange(of: project) { _,_ in reader.reset() }
        .onDisappear { reader.reset() }
    }

    private func candidateRow(_ candidate: InterpretationCandidate, unit: InterpretationUnit) -> some View {
        let review = reader.reviews[candidate.id]
        let state = PreconReadPage.reviewState(candidate, review: review)
        return VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text(candidate.text).font(.headline)
            Text("\(URL(filePath: source.path).lastPathComponent) · page \(candidate.pageIndex + 1) · \(unit.stage.rawValue)")
                .font(.caption).foregroundStyle(.secondary)
            Text(candidate.quote.map { "“\($0)”" } ?? "No quote").textSelection(.enabled)
            if let thumbnail = reader.thumbnails[candidate.id] {
                Image(nsImage: thumbnail).resizable().scaledToFit().frame(maxHeight: 100)
                    .accessibilityLabel("Source crop for \(candidate.text)")
            } else { Text(candidate.bbox == nil ? "No bounding box — no thumbnail" : "Thumbnail unavailable").font(.caption) }
            Text("Confidence: \(candidate.confidence.map { String(format: "%.2f", $0) } ?? "unknown") · \(state.rawValue)").font(.caption)
            if let reason = candidate.heldReason { Text("Held: \(reason)").font(.caption).foregroundStyle(.orange) }
            if state == .accepted { Text("Reviewed evidence - not a quantity").font(.caption.weight(.semibold)) }
            HStack {
                Button("Accept") { reader.review(candidate, unit: unit, decision: .accepted, store: store, project: project) }
                Button("Reject") { reader.review(candidate, unit: unit, decision: .rejected, store: store, project: project) }
            }.disabled(review != nil || reader.running)
        }
    }
}
