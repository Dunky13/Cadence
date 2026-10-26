import Foundation
import Darwin

public actor LaunchService {
    private let directory: URL
    private let runner: any CommandRunning
    private let domain: String
    private let metadataDirectory: URL
    private let logDirectory: URL
    private var mutationInProgress = false

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),
                metadataDirectory: URL? = nil, logDirectory: URL? = nil) {
        self.directory = directory.standardizedFileURL
        self.runner = LaunchctlRunner()
        self.domain = "gui/\(getuid())"
        self.metadataDirectory = (metadataDirectory ?? Self.defaultMetadataDirectory).standardizedFileURL
        self.logDirectory = (logDirectory ?? Self.defaultLogDirectory).standardizedFileURL
    }

    init(directory: URL, runner: any CommandRunning, domain: String = "gui/501",
         metadataDirectory: URL? = nil, logDirectory: URL? = nil) {
        self.directory = directory.standardizedFileURL
        self.runner = runner
        self.domain = domain
        self.metadataDirectory = (metadataDirectory ?? Self.defaultMetadataDirectory).standardizedFileURL
        self.logDirectory = (logDirectory ?? Self.defaultLogDirectory).standardizedFileURL
    }

    private static var defaultMetadataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cadence/Jobs", isDirectory: true)
    }

    private static var defaultLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Cadence", isDirectory: true)
    }

    public func discover() async throws -> DiscoveryResult {
        let candidates = try configurations()
        var warnings = candidates.warnings
        let overrides: [String: Bool]?
        do { overrides = try await disabledOverrides() }
        catch {
            overrides = nil
            warnings.append("Could not read enabled states: \(error.localizedDescription)")
        }
        let duplicates = Dictionary(grouping: candidates.entries, by: { $0.configuration.label }).filter { $0.value.count > 1 }
        var jobs: [LaunchJob] = []
        for candidate in candidates.entries {
            let configuration = candidate.configuration
            let savedDetails = JobMetadata.read(label: configuration.label, plistData: candidate.data, directory: metadataDirectory)
            if let warning = savedDetails.warning { warnings.append(warning) }
            let metadata = savedDetails.metadata
            let cronSchedule = metadata.flatMap { try? $0.schedule }
            var issue: String?
            var enabled = overrides.map { !($0[configuration.label] ?? configuration.disabled ?? false) }
            var runtime: RuntimeState?
            var status: JobStatus = .unknown
            if duplicates[configuration.label] != nil {
                enabled = nil
                issue = "Multiple configuration files use this label. Resolve the duplicate before controlling it."
            } else {
                do {
                    runtime = try await runtimeState(for: configuration.label)
                    if let runtime { try validateRuntimePath(runtime, expected: candidate.url) }
                    status = runtime?.status ?? .unloaded
                    if enabled == false && runtime == nil { status = .disabled }
                    if enabled == false && runtime != nil {
                        issue = "Disabled for future loads, but still loaded. It may continue running until it is stopped and unloaded."
                    }
                } catch {
                    enabled = nil
                    status = .unknown
                    issue = error.localizedDescription
                }
            }
            if overrides == nil {
                issue = [issue, "Enabled state is unavailable. Refresh before controlling this job."].compactMap { $0 }.joined(separator: " ")
            }
            var job = LaunchJob(label: configuration.label, name: metadata?.name ?? configuration.friendlyName,
                plistURL: candidate.url, program: configuration.executable,
                arguments: configuration.arguments, scheduleDescription: cronSchedule?.summary ?? configuration.scheduleDescription,
                scheduleDetails: metadata?.scheduleDetails ?? configuration.scheduleDetails, stdoutURL: configuration.logURL(for: .stdout),
                stderrURL: configuration.logURL(for: .stderr), isEnabled: enabled, status: status,
                lastExitCode: runtime?.lastExitCode, pid: runtime?.pid, runCount: runtime?.runCount, issue: issue)
            job.configurationData = candidate.data
            jobs.append(job)
        }
        jobs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return DiscoveryResult(jobs: jobs, warnings: warnings)
    }

    /// Saves a new job first. Registration failures return the saved job rather than
    /// inviting a retry that could create a duplicate or remove an uncertain loaded job.
    public func createJob(_ draft: JobDraft) async throws -> JobCreationResult {
        guard !mutationInProgress else { throw LaunchServiceError.busy }
        mutationInProgress = true
        defer { mutationInProgress = false }
        try draft.validate()
        let schedule = try CronSchedule(draft.cronExpression)
        let saved = try JobStorage.persist(draft, schedule: schedule, directory: directory,
            metadataDirectory: metadataDirectory, logDirectory: logDirectory)
        var warnings: [String] = []
        var runtime: RuntimeState?
        var status: JobStatus = draft.isEnabled ? .unloaded : .disabled
        if draft.isEnabled {
            do {
                let result = try await runner.run(["bootstrap", domain, saved.url.path])
                if result.status != 0 {
                    warnings.append("The job was saved, but launchd could not load it: \(result.errorText) Refresh to check its state; do not create it again.")
                }
            } catch {
                warnings.append("The job was saved, but launchd registration could not be confirmed: \(error.localizedDescription) Refresh to check its state; do not create it again.")
            }
            do {
                runtime = try await runtimeState(for: saved.configuration.label)
                if let runtime {
                    try validateRuntimePath(runtime, expected: saved.url)
                    status = runtime.status
                } else if warnings.isEmpty {
                    warnings.append("The job was saved, but launchd did not report it as loaded. Refresh its state before trying to enable it.")
                }
            } catch {
                status = .unknown
                warnings.append("The job was saved, but its loaded state could not be read: \(error.localizedDescription)")
            }
        }
        let warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        var job = LaunchJob(label: saved.configuration.label, name: saved.metadata.name,
            plistURL: saved.url, program: saved.configuration.executable,
            arguments: saved.configuration.arguments, scheduleDescription: schedule.summary,
            scheduleDetails: saved.metadata.scheduleDetails, stdoutURL: saved.configuration.logURL(for: .stdout),
            stderrURL: saved.configuration.logURL(for: .stderr), isEnabled: draft.isEnabled, status: status,
            lastExitCode: runtime?.lastExitCode, pid: runtime?.pid, runCount: runtime?.runCount, issue: warning)
        job.configurationData = saved.data
        return JobCreationResult(job: job, warning: warning)
    }

    /// Disabling persists launchd's override and unloads the service, stopping any running process.
    public func setEnabled(_ enabled: Bool, job: LaunchJob) async throws {
        guard !mutationInProgress else { throw LaunchServiceError.busy }
        mutationInProgress = true
        defer { mutationInProgress = false }
        _ = try revalidate(job)
        _ = try await disabledOverrides()
        let state = try await runtimeState(for: job.label)
        if let state { try validateRuntimePath(state, expected: job.plistURL) }
        let target = "\(domain)/\(job.label)"
        let change = try await runner.run([enabled ? "enable" : "disable", target])
        guard change.status == 0 else { throw LaunchServiceError.commandFailed(change.errorText) }

        if enabled && state == nil {
            // Recheck the file after the async enable call before launchd consumes it.
            _ = try revalidate(job)
            let result = try await runner.run(["bootstrap", domain, job.plistURL.path])
            guard result.status == 0 else {
                throw LaunchServiceError.commandFailed("The job is enabled, but could not be loaded: \(result.errorText)")
            }
        } else if !enabled && state != nil {
            let result = try await runner.run(["bootout", target])
            guard result.status == 0 || result.isMissingService else {
                throw LaunchServiceError.commandFailed("The job is disabled for future loads, but could not be stopped: \(result.errorText)")
            }
        }
    }

    /// Starts a waiting job without killing an instance that is already running.
    public func runNow(job: LaunchJob) async throws {
        guard !mutationInProgress else { throw LaunchServiceError.busy }
        mutationInProgress = true
        defer { mutationInProgress = false }
        let configuration = try revalidate(job)
        let overrides = try await disabledOverrides()
        guard !(overrides[job.label] ?? configuration.disabled ?? false) else {
            throw LaunchServiceError.unavailable("Enable this job before running it.")
        }
        let state = try await runtimeState(for: job.label)
        if let state { try validateRuntimePath(state, expected: job.plistURL) }
        if state == nil {
            _ = try revalidate(job)
            let load = try await runner.run(["bootstrap", domain, job.plistURL.path])
            guard load.status == 0 else { throw LaunchServiceError.commandFailed("Could not load the job: \(load.errorText)") }
            // Loading already requests a run for these jobs. A second kickstart
            // could execute a short-lived script twice if its first run finishes
            // between bootstrap and kickstart.
            if configuration.launchesAtLoad { return }
        }
        let result = try await runner.run(["kickstart", "\(domain)/\(job.label)"])
        guard result.status == 0 else { throw LaunchServiceError.commandFailed(result.errorText) }
    }

    public func readLog(job: LaunchJob, stream: LogStream) async -> LogSnapshot {
        let url = stream == .stdout ? job.stdoutURL : job.stderrURL
        guard let url else {
            return LogSnapshot(text: "", message: "No \(stream.rawValue) file is configured. Add \(stream == .stdout ? "StandardOutPath" : "StandardErrorPath") to this job's plist to capture output.")
        }
        return LogReader.read(url)
    }

    private struct Candidate {
        let url: URL
        let configuration: AgentConfiguration
        let data: Data
    }

    private func configurations() throws -> (entries: [Candidate], warnings: [String]) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return ([], [])
        }
        guard isDirectory.boolValue else {
            throw LaunchServiceError.unavailable("LaunchAgents is not a directory: \(directory.path)")
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]).filter { $0.pathExtension.lowercased() == "plist" }.sorted { $0.path < $1.path }
        var entries: [Candidate] = []
        var warnings: [String] = []
        for url in urls {
            do {
                let snapshot = try AgentConfiguration.readSnapshot(url)
                // Directory enumeration can return /private/var while the requested
                // directory uses /var. Keep job IDs and command paths consistent.
                entries.append(Candidate(url: url.standardizedFileURL, configuration: snapshot.configuration, data: snapshot.data))
            } catch { warnings.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return (entries, warnings)
    }

    private func disabledOverrides() async throws -> [String: Bool] {
        let result = try await runner.run(["print-disabled", domain])
        guard result.status == 0 else { throw LaunchServiceError.commandFailed(result.errorText) }
        return try DisabledOverrides.parse(result.stdout)
    }

    private func runtimeState(for label: String) async throws -> RuntimeState? {
        let result = try await runner.run(["print", "\(domain)/\(label)"])
        if result.isMissingService { return nil }
        guard result.status == 0 else { throw LaunchServiceError.commandFailed(result.errorText) }
        return try RuntimeState.parse(result.stdout)
    }

    private func validateRuntimePath(_ runtime: RuntimeState, expected: URL) throws {
        guard let path = runtime.path else {
            throw LaunchServiceError.unavailable("launchd did not report the loaded configuration path. Controls are unavailable.")
        }
        let actual = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard actual == expected.resolvingSymlinksInPath().standardizedFileURL else {
            throw LaunchServiceError.unavailable("Another loaded job uses this label from a different configuration file.")
        }
    }

    private func revalidate(_ job: LaunchJob) throws -> AgentConfiguration {
        guard job.plistURL.deletingLastPathComponent().standardizedFileURL == directory,
              let expectedData = job.configurationData else { throw LaunchServiceError.changedConfiguration }
        let candidates = try configurations()
        let matching = candidates.entries.filter { $0.configuration.label == job.label }
        guard matching.count == 1, let candidate = matching.first,
              candidate.url.standardizedFileURL == job.plistURL.standardizedFileURL,
              candidate.data == expectedData else { throw LaunchServiceError.changedConfiguration }
        return candidate.configuration
    }
}
