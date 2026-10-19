import AppKit
import LocalLLMCore
import PDFKit
import SwiftUI

// Phase 2 manual takeoff: calibrate, trace, review, save. All quantities come from LocalLLMCore; this file only edits drafts.

@MainActor
final class TakeoffController: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case calibrateX = "Cal X", calibrateY = "Cal Y", area = "Area", deduction = "Deduct", route = "Route", count = "Count"
        var id: String { rawValue }
    }

    static let displayScale = 1.5
    private static let workspaceKey = "preconstructionWorkspace"

    @Published private(set) var workspace: URL?
    @Published private(set) var projects: [String] = []
    @Published private(set) var project: URL?
    @Published private(set) var revision = PreconRevision(revisionId: "R1")
    @Published private(set) var measurements: TakeoffMeasurements?
    @Published private(set) var pageImage: NSImage?
    @Published private(set) var dirty = false
    @Published var tool: Tool = .area
    @Published var pending: [[Double]] = []
    @Published var xFeet = ""
    @Published var yFeet = ""
    @Published var physicalItemID = "F01"
    @Published var message = ""

    let template: URL? = [Bundle.main.resourceURL?.appending(path: "preconstruction-template"),
                          URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Preconstruction/templates/project")]
        .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    private var store: PreconProjectStore?

    init() {
        let configured = ProcessInfo.processInfo.environment["PRECONSTRUCTION_WORKSPACE"]
            ?? UserDefaults.standard.string(forKey: Self.workspaceKey)
        if let configured { setWorkspace(URL(filePath: configured, directoryHint: .isDirectory), remember: false) }
    }

    // MARK: Workspace and project

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Project Data Root"
        if panel.runModal() == .OK, let url = panel.url { setWorkspace(url, remember: true) }
    }

    private func setWorkspace(_ url: URL, remember: Bool) {
        attempt {
            store = try PreconProjectStore(root: url)
            workspace = url
            if remember { UserDefaults.standard.set(url.path, forKey: Self.workspaceKey) }
            refreshProjects()
        }
    }

    private func refreshProjects() {
        guard let root = store?.root else { return }
        projects = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !$0.lastPathComponent.hasPrefix(".") }
            .map(\.lastPathComponent).sorted()
    }

    func createProject(named name: String) {
        guard let store, let template else { return }
        attempt {
            _ = try store.createProject(named: name, template: template)
            refreshProjects()
            openProject(named: name)
        }
    }

    /// Reopens the newest checkpoint; a stale or corrupt checkpoint is refused rather than partially loaded.
    func openProject(named name: String) {
        guard let store else { return }
        let url = store.root.appending(path: name, directoryHint: .isDirectory)
        project = url
        revision = PreconRevision(revisionId: nextRevisionID(in: url))
        measurements = nil
        pageImage = nil
        dirty = false
        pending = []
        guard let checkpoint = latestCheckpoint(in: url) else { message = "New project. Import a PDF to begin."; return }
        attempt {
            let (saved, record) = try store.resume(from: checkpoint, in: url)
            revision = saved
            if let path = record.measurementDigests.keys.first(where: { $0.hasSuffix("-measurements.json") }) {
                measurements = try PreconJSON.decoder.decode(TakeoffMeasurements.self, from: Data(contentsOf: url.appending(path: path)))
            }
            loadPage()
            message = "Reopened \(saved.revisionId) from verified checkpoint."
        }
    }

    func importPDF() {
        guard let store, let project else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt {
            let records = try store.importSource(url, into: project, role: .proposed, revision: "IMPORTED")
            let traced = measurements.map { !$0.polys.isEmpty || !$0.routes.isEmpty || !$0.counts.isEmpty } ?? false
            mutate {
                revision.sources += records.filter { record in !revision.sources.contains { $0.id == record.id } }
                // ponytail: one traced page per project revision; page picker and per-page measurement files come later
                if !traced { measurements = TakeoffMeasurements(source: records[0]) }
            }
            loadPage()
            message = "Imported \(url.lastPathComponent): \(records.count) page(s), hash \(records[0].sha256.prefix(12))."
                + (traced ? " Registered only; tracing stays on the current page." : " Tracing page 1.")
        }
    }

    private func loadPage() {
        guard let project, let source = measurements?.source,
              let page = PDFDocument(url: project.appending(path: source.path))?.page(at: source.pageIndex) else { return }
        let bounds = page.bounds(for: .mediaBox)
        // ponytail: rotated pages unsupported; coordinates assume the unrotated media box, as the plane schema does
        if page.rotation != 0 { message = "Page is rotated \(page.rotation) degrees; tracing assumes the unrotated page." }
        pageImage = page.thumbnail(of: CGSize(width: bounds.width * Self.displayScale, height: bounds.height * Self.displayScale), for: .mediaBox)
    }

    // MARK: Tracing

    func tap(at location: CGPoint) {
        guard measurements != nil else { return }
        let point = [(location.x / Self.displayScale * 100).rounded() / 100, (location.y / Self.displayScale * 100).rounded() / 100]
        switch tool {
        case .calibrateX, .calibrateY:
            pending.append(point)
            if pending.count == 2 { finishCalibration() }
        case .area, .deduction, .route:
            pending.append(point)
        case .count:
            let id = physicalItemID.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { message = "Enter a physical item ID before placing counts."; return }
            mutate { measurements?.counts.append(.init(id: nextID("C", measurements?.counts.map(\.id) ?? []), physicalItemId: id, pt: point)) }
        }
    }

    /// Axis distance only, so X and Y stay independent witnesses and anisotropic scans surface as conflicts.
    private func finishCalibration() {
        let axis: CalibrationCheck.Axis = tool == .calibrateX ? .x : .y
        let (a, b) = (pending[0], pending[1])
        pending = []
        guard let feet = Double(axis == .x ? xFeet : yFeet), feet > 0 else { message = "Enter the written \(axis.rawValue) dimension in feet first."; return }
        let length = abs(axis == .x ? b[0] - a[0] : b[1] - a[1])
        guard length > 0 else { message = "Calibration points must differ along \(axis.rawValue)."; return }
        let datum = "\(axis.rawValue) witness \(a[0]),\(a[1]) to \(b[0]),\(b[1])"
        mutate {
            measurements?.calibrationChecks.removeAll { $0.axis == axis }
            measurements?.calibrationChecks.append(CalibrationCheck(axis: axis, coordinateLength: length, realLength: feet, datum: datum))
        }
    }

    func closeShape() {
        guard var draft = measurements else { return }
        attempt {
            switch tool {
            case .area, .deduction:
                let id = nextID(tool == .area ? "G" : "D", draft.polys.map(\.id))
                try Takeoff.validatePolygon(id, pending)
                draft.polys.append(.init(id: id, zone: "Z01", sign: tool == .area ? 1 : -1, pts: pending))
            case .route:
                let id = nextID("L", draft.routes.map(\.id))
                guard pending.count >= 2 else { throw TakeoffError.invalidGeometry(id, "route needs two or more points") }
                draft.routes.append(.init(id: id, pts: pending))
            default: return
            }
            mutate { measurements = draft }
            pending = []
        }
    }

    func delete(_ id: String) {
        mutate {
            measurements?.polys.removeAll { $0.id == id }
            measurements?.routes.removeAll { $0.id == id }
            measurements?.counts.removeAll { $0.id == id }
        }
    }

    func setText(_ keyPath: WritableKeyPath<TakeoffMeasurements, String>, _ value: String) {
        guard measurements?[keyPath: keyPath] != value else { return }
        mutate { measurements?[keyPath: keyPath] = value }
    }

    // MARK: Review, approval, save

    var workingRevision: PreconRevision {
        var working = revision
        if let measurements {
            working.calibrations = [measurements.calibration]
            working.quantities = measurements.quantities()
            working.checks = measurements.checks()
        }
        return working
    }

    var canApprove: Bool {
        guard let measurements, measurements.calibration.status == .candidate else { return false }
        return (try? measurements.area?.get().topology) != .failed && workingRevision.quantities.allSatisfy { $0.value != nil }
    }

    /// Human gate: marks calibration reviewed first, then binds the approval to the resulting snapshot digest.
    func approveGeometry() {
        attempt {
            mutate(resetReview: false) { measurements?.calibrationReviewed = true }
            let digest = try workingRevision.snapshotDigest()
            revision.approvals.append(ApprovalRecord(gate: .reviewedGeometry, status: .approved, snapshotSha256: digest,
                                                     actor: NSUserName(), at: ISO8601DateFormatter().string(from: Date())))
            message = "Geometry approved for snapshot \(digest.prefix(12)). Any edit makes this approval stale."
        }
    }

    func save() {
        guard let store, let project, let measurements else { return }
        attempt {
            let saved = workingRevision
            let id = saved.revisionId
            var paths = [try store.saveMeasurement(try PreconJSON.encoder.encode(measurements), named: "\(id)-measurements.json", in: project)]
            if let plane = measurements.plane {
                paths.append(try store.saveMeasurement(try PreconJSON.encoder.encode(plane), named: "\(id)-plane.json", in: project))
            }
            _ = try store.saveRevision(saved, in: project)
            _ = try store.saveCheckpoint(for: saved, in: project, measurements: paths)
            revision = saved
            dirty = false
            message = "Saved \(id) with checkpoint."
        }
    }

    /// Every edit starts a new unsaved revision and makes earlier geometry approvals stale.
    private func mutate(resetReview: Bool = true, _ change: () -> Void) {
        if !dirty, let project {
            revision.revisionId = nextRevisionID(in: project)
            dirty = true
        }
        if resetReview { measurements?.calibrationReviewed = false }
        change()
        for index in revision.approvals.indices where revision.approvals[index].status == .approved {
            revision.approvals[index].status = .stale
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { message = error.localizedDescription }
    }

    private func nextID(_ prefix: String, _ existing: [String]) -> String {
        let used = existing.compactMap { Int($0.dropFirst(prefix.count)) }
        return String(format: "%@%02d", prefix, (used.max() ?? 0) + 1)
    }

    private func nextRevisionID(in project: URL) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: project.appending(path: "revisions").path)) ?? []
        let used = names.compactMap { name in name.hasPrefix("R") && name.hasSuffix(".json") ? Int(name.dropFirst().dropLast(5)) : nil }
        return "R\((used.max() ?? 0) + 1)"
    }

    private func latestCheckpoint(in project: URL) -> URL? {
        let directory = project.appending(path: "checkpoints")
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .max { a, b in
                let date = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
                return date(a) < date(b)
            }
    }
}

struct PreconstructionView: View {
    @StateObject private var takeoff = TakeoffController()
    @State private var newProjectName = ""

    var body: some View {
        VStack(spacing: 0) {
            projectBar
            Divider()
            if let measurements = takeoff.measurements {
                HSplitView {
                    VStack(spacing: 0) {
                        toolBar
                        Divider()
                        TakeoffCanvas(takeoff: takeoff)
                    }
                    .frame(minWidth: 480)
                    TakeoffReviewPanel(takeoff: takeoff, measurements: measurements)
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 480)
                }
            } else {
                ContentUnavailableView(takeoff.project == nil ? "Choose a project" : "Import a PDF",
                                       systemImage: "ruler",
                                       description: Text("Sources are copied, hashed and kept read-only inside the project."))
            }
            Divider()
            Text(takeoff.message.isEmpty ? " " : takeoff.message)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(minWidth: 860, minHeight: 600)
    }

    private var projectBar: some View {
        HStack(spacing: 10) {
            Button("Data Root…", action: takeoff.chooseWorkspace)
            Text(takeoff.workspace?.path ?? "Not configured").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Picker("Project", selection: Binding(get: { takeoff.project?.lastPathComponent ?? "" },
                                                 set: { if !$0.isEmpty { takeoff.openProject(named: $0) } })) {
                Text("None").tag("")
                ForEach(takeoff.projects, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 200)
            .disabled(takeoff.workspace == nil)
            TextField("New project name", text: $newProjectName).frame(width: 150)
            Button("Create") { takeoff.createProject(named: newProjectName); newProjectName = "" }
                .disabled(takeoff.workspace == nil || takeoff.template == nil || newProjectName.isEmpty)
                .help(takeoff.template == nil ? "Project template not found next to the app or in Preconstruction/templates/project." : "")
            Button("Import PDF…", action: takeoff.importPDF).disabled(takeoff.project == nil)
        }
        .padding(10)
    }

    private var toolBar: some View {
        HStack(spacing: 10) {
            Picker("Tool", selection: $takeoff.tool) {
                ForEach(TakeoffController.Tool.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 380)
            .onChange(of: takeoff.tool) { takeoff.pending = [] }
            switch takeoff.tool {
            case .calibrateX:
                TextField("Written X ft", text: $takeoff.xFeet).frame(width: 90)
                Text("Click both ends of a written horizontal dimension").font(.caption).foregroundStyle(.secondary)
            case .calibrateY:
                TextField("Written Y ft", text: $takeoff.yFeet).frame(width: 90)
                Text("Click both ends of a written vertical dimension").font(.caption).foregroundStyle(.secondary)
            case .count:
                TextField("Physical item ID", text: $takeoff.physicalItemID).frame(width: 110)
                Text("Same ID in another view counts once").font(.caption).foregroundStyle(.secondary)
            case .area, .deduction, .route:
                Button(takeoff.tool == .route ? "Finish Route" : "Close Shape", action: takeoff.closeShape)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(takeoff.pending.count < (takeoff.tool == .route ? 2 : 3))
                Button("Undo Point") { _ = takeoff.pending.popLast() }.disabled(takeoff.pending.isEmpty)
                Button("Cancel") { takeoff.pending = [] }.disabled(takeoff.pending.isEmpty)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            Spacer()
        }
        .controlSize(.small)
        .padding(8)
    }
}

/// Source page with traced geometry overlaid; clicks map to top-left-origin PDF points.
private struct TakeoffCanvas: View {
    @ObservedObject var takeoff: TakeoffController

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            if let image = takeoff.pageImage {
                Image(nsImage: image)
                    .overlay { Canvas { context, _ in draw(&context) } }
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { takeoff.tap(at: $0) }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func point(_ p: [Double]) -> CGPoint {
        CGPoint(x: p[0] * TakeoffController.displayScale, y: p[1] * TakeoffController.displayScale)
    }

    private func path(_ pts: [[Double]], closed: Bool) -> Path {
        var path = Path()
        path.addLines(pts.map(point))
        if closed { path.closeSubpath() }
        return path
    }

    private func draw(_ context: inout GraphicsContext) {
        guard let measurements = takeoff.measurements else { return }
        for poly in measurements.polys {
            let shape = path(poly.pts, closed: true)
            let color: Color = poly.sign == 1 ? .green : .red
            context.fill(shape, with: .color(color.opacity(poly.sign == 1 ? 0.18 : 0.35)))
            context.stroke(shape, with: .color(color), lineWidth: 1.5)
            context.draw(Text(poly.id).font(.caption.bold()).foregroundColor(color), at: point(poly.pts[0]), anchor: .topLeading)
        }
        for route in measurements.routes {
            context.stroke(path(route.pts, closed: route.closed), with: .color(.blue), lineWidth: 2.5)
            context.draw(Text(route.id).font(.caption.bold()).foregroundColor(.blue), at: point(route.pts[0]), anchor: .bottomLeading)
        }
        for count in measurements.counts {
            let center = point(count.pt)
            context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)), with: .color(.orange))
            context.draw(Text(count.physicalItemId).font(.caption2.bold()).foregroundColor(.orange),
                         at: CGPoint(x: center.x + 7, y: center.y), anchor: .leading)
        }
        guard !takeoff.pending.isEmpty else { return }
        context.stroke(path(takeoff.pending, closed: false), with: .color(.purple), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        for p in takeoff.pending {
            let c = point(p)
            context.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.purple))
        }
    }
}

/// Area/LF/EA review. Every number shown is recomputed by LocalLLMCore from the traced drafts.
private struct TakeoffReviewPanel: View {
    @ObservedObject var takeoff: TakeoffController
    let measurements: TakeoffMeasurements

    var body: some View {
        let calibration = measurements.calibration
        let revision = takeoff.workingRevision
        Form {
            Section("Calibration") {
                ForEach(measurements.calibrationChecks, id: \.axis) { check in
                    LabeledContent(check.axis.rawValue.uppercased(),
                                   value: "\(fmt(check.coordinateLength)) pt = \(fmt(check.realLength)) ft -> \(fmt(check.scale, 3)) pt/ft")
                }
                LabeledContent("Status") { status(calibration.status.rawValue, ok: [.candidate, .reviewed].contains(calibration.status)) }
                if calibration.status == .conflict {
                    Text("X and Y disagree. No scale is used and scaled quantities are withheld; nothing is averaged.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Section("Labels") {
                TextField("Location", text: binding(\.location))
                TextField("Area trade", text: binding(\.areaTrade))
                TextField("Route trade", text: binding(\.routeTrade))
                TextField("Count trade", text: binding(\.countTrade))
            }
            areaSection(measurements, scale: calibration.scale)
            Section("Linear (LF)") {
                ForEach(measurements.routes, id: \.id) { route in
                    row(route.id, (try? measurements.routeLength(route)).flatMap { $0 }.map { "\(fmt($0)) LF" } ?? "unknown")
                }
                total("QTY-ROUTE", in: revision)
            }
            Section("Count (EA)") {
                ForEach(measurements.counts, id: \.id) { row($0.id, $0.physicalItemId) }
                LabeledContent("Marks / physical items", value: "\(measurements.counts.count) / \(Takeoff.physicalCount(measurements.counts.map(\.physicalItemId)))")
                total("QTY-COUNT", in: revision)
            }
            Section("Review") {
                Button("Approve Calibration and Geometry", action: takeoff.approveGeometry).disabled(!takeoff.canApprove)
                Button(takeoff.dirty ? "Save \(revision.revisionId)" : "Saved \(revision.revisionId)", action: takeoff.save)
                    .keyboardShortcut("s").disabled(!takeoff.dirty)
                ForEach(Array(revision.approvals.enumerated()), id: \.offset) { _, approval in
                    LabeledContent(approval.gate.rawValue) { status("\(approval.status.rawValue) \(approval.snapshotSha256?.prefix(8) ?? "")", ok: approval.status == .approved) }
                }
                DisclosureGroup("Release blockers") {
                    ForEach((try? revision.releaseBlockers()) ?? ["Snapshot digest unavailable"], id: \.self) {
                        Text($0).font(.caption)
                    }
                }
                DisclosureGroup("Scope preview") {
                    Text(ScopePreview.render(revision)).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func areaSection(_ measurements: TakeoffMeasurements, scale: Double?) -> some View {
        let area = try? measurements.area?.get()
        return Section("Area (SF)") {
            ForEach(measurements.polys, id: \.id) { poly in
                let sf = scale.map { abs(Takeoff.signedArea(poly.pts)) / ($0 * $0) }
                row(poly.id, "\(poly.sign == 1 ? "+" : "-") \(sf.map { fmt($0) } ?? "unknown") SF")
            }
            if let area {
                LabeledContent("Gross / deductions", value: "\(fmt(area.gross)) / \(fmt(area.deductions)) SF")
                LabeledContent("Topology") { status(area.topology.rawValue, ok: area.topology == .passed) }
                ForEach(area.topologyNotes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            } else if case .failure(let error)? = measurements.area {
                Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
            }
            total("QTY-AREA", in: takeoff.workingRevision)
        }
    }

    private func row(_ id: String, _ value: String) -> some View {
        HStack {
            Text(id).font(.system(.body, design: .monospaced))
            Spacer()
            Text(value).foregroundStyle(.secondary)
            Button { takeoff.delete(id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func total(_ id: String, in revision: PreconRevision) -> some View {
        if let quantity = revision.quantities.first(where: { $0.id == id }) {
            LabeledContent("Provisional total") {
                Text(quantity.value.map { "\(fmt($0)) \(quantity.unit.rawValue)" } ?? "unknown (\(quantity.unit.rawValue))").bold()
            }
        }
    }

    private func status(_ text: String, ok: Bool) -> some View {
        Text(text).font(.caption.bold()).foregroundStyle(ok ? .green : .orange)
    }

    private func binding(_ keyPath: WritableKeyPath<TakeoffMeasurements, String>) -> Binding<String> {
        Binding(get: { takeoff.measurements?[keyPath: keyPath] ?? "" }, set: { takeoff.setText(keyPath, $0) })
    }

    private func fmt(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }
}
