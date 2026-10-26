import AppKit
import Combine
import LaunchCore

enum JobFilter: String, CaseIterable {
    case all = "All"
    case enabled = "Enabled"
    case disabled = "Disabled"
}

enum DetailTab: String, CaseIterable {
    case overview = "Overview"
    case logs = "Logs"
}

protocol JobServing: Sendable {
    func discover() async throws -> DiscoveryResult
    func setEnabled(_ enabled: Bool, job: LaunchJob) async throws
    func runNow(job: LaunchJob) async throws
    func readLog(job: LaunchJob, stream: LogStream) async -> LogSnapshot
    func createJob(_ draft: JobDraft) async throws -> JobCreationResult
}

extension LaunchService: JobServing {}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var jobs: [LaunchJob] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var busyJobs: Set<String> = []
    @Published private(set) var updatedAt: Date?
    @Published var error: String?
    @Published var query = ""
    @Published var filter: JobFilter = .all
    @Published var selectedID: String?
    @Published var tab: DetailTab = .overview
    @Published var stream: LogStream = .stdout
    @Published private(set) var log: LogSnapshot?
    @Published private(set) var isReadingLog = false

    let isDemo: Bool
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    private let service: any JobServing
    private var refreshTask: Task<Void, Never>?
    private var logGeneration = 0

    init(isDemo: Bool = false, service: any JobServing = LaunchService()) {
        self.isDemo = isDemo
        self.service = service
        if isDemo { jobs = DemoData.jobs; selectedID = jobs.first?.id; updatedAt = Date() }
    }

    var visibleJobs: [LaunchJob] {
        jobs.filter { job in
            let matchesFilter = filter == .all || (filter == .enabled && job.isEnabled == true)
                || (filter == .disabled && job.isEnabled == false)
            let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return matchesFilter && (search.isEmpty || job.label.localizedCaseInsensitiveContains(search)
                || job.name.localizedCaseInsensitiveContains(search) || job.program.localizedCaseInsensitiveContains(search))
        }
    }

    var selectedJob: LaunchJob? { visibleJobs.first { $0.id == selectedID } }
    var enabledCount: Int { jobs.filter { $0.isEnabled == true }.count }
    var runningCount: Int { jobs.filter { $0.status == .running }.count }

    func reconcileSelection() {
        if !visibleJobs.contains(where: { $0.id == selectedID }) { selectedID = visibleJobs.first?.id }
    }

    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        guard busyJobs.isEmpty else { return }
        let task = Task {
            await performRefresh()
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            if !isDemo {
                let result = try await service.discover()
                jobs = result.jobs
                warnings = result.warnings
            }
            updatedAt = Date()
            reconcileSelection()
            if tab == .logs { await refreshLog() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool, job: LaunchJob) {
        guard !isDemo, busyJobs.isEmpty else { return }
        busyJobs.insert(job.id)
        Task {
            // A native control can deliver its action before SwiftUI has applied
            // the refreshing disabled state. Preserve that click and wait for the
            // read to finish instead of silently rejecting the requested change.
            if let refreshTask { await refreshTask.value }
            do { try await service.setEnabled(enabled, job: job) }
            catch { self.error = error.localizedDescription }
            busyJobs.remove(job.id)
            await refresh()
        }
    }

    func runNow(_ job: LaunchJob) {
        guard !isDemo, busyJobs.isEmpty else { return }
        busyJobs.insert(job.id)
        Task {
            if let refreshTask { await refreshTask.value }
            do { try await service.runNow(job: job); tab = .logs }
            catch { self.error = error.localizedDescription }
            busyJobs.remove(job.id)
            await refresh()
        }
    }

    func createJob(_ draft: JobDraft) async throws -> LaunchJob {
        guard !isDemo else { throw LaunchServiceError.unavailable("Creating jobs is disabled in demo mode.") }
        guard busyJobs.isEmpty else { throw LaunchServiceError.busy }
        let operationID = "cadence:create"
        busyJobs.insert(operationID)
        defer { busyJobs.remove(operationID) }
        if let refreshTask { await refreshTask.value }
        let result = try await service.createJob(draft)
        jobs.removeAll { $0.id == result.job.id }
        jobs.append(result.job)
        jobs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        query = ""
        filter = .all
        tab = .overview
        selectedID = result.job.id
        busyJobs.remove(operationID)
        await refresh()
        if jobs.contains(where: { $0.id == result.job.id }) { selectedID = result.job.id }
        if let warning = result.warning { error = warning }
        return result.job
    }

    func refreshLog() async {
        logGeneration += 1
        let generation = logGeneration
        guard let job = selectedJob else { log = nil; isReadingLog = false; return }
        isReadingLog = true
        let selectedStream = stream
        let snapshot = isDemo ? DemoData.log(for: job, stream: selectedStream)
            : await service.readLog(job: job, stream: selectedStream)
        guard generation == logGeneration, selectedID == job.id, stream == selectedStream else { return }
        log = snapshot
        isReadingLog = false
    }

    func clearLog() {
        logGeneration += 1
        log = nil
        isReadingLog = false
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func openDirectory() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch { self.error = error.localizedDescription }
    }
}
