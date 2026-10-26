import XCTest
import Foundation
import Darwin
@testable import LaunchCore

final class JobCreationTests: XCTestCase {
    func testDraftRejectsInvalidNamesCommandsCronAndDirectories() throws {
        let fixture = try CreationFixture()
        for name in ["", " \n ", String(repeating: "a", count: 81), "name\nline", "a" + String(repeating: "\u{0301}", count: 1_024)] {
            XCTAssertThrowsError(try JobDraft(name: name, command: "true", cronExpression: "* * * * *").validate())
        }
        for command in ["", "  \n", "printf\0bad", String(repeating: "x", count: 32_769), String(repeating: "😺", count: 10_000)] {
            XCTAssertThrowsError(try JobDraft(name: "Job", command: command, cronExpression: "* * * * *").validate())
        }
        XCTAssertThrowsError(try JobDraft(name: "Job", command: "true", cronExpression: "invalid").validate())
        XCTAssertThrowsError(try JobDraft(name: "Job", command: "true", cronExpression: "* * * * *",
            workingDirectory: fixture.root.appendingPathComponent("missing")).validate())
        XCTAssertThrowsError(try JobDraft(name: "Job", command: "true", cronExpression: "* * * * *",
            logDirectory: URL(string: "https://example.com/logs")).validate())
        let file = fixture.root.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertThrowsError(try JobDraft(name: "Job", command: "true", cronExpression: "* * * * *", logDirectory: file).validate())
        try JobDraft(name: "My job", command: "printf 'line one\\n'\nprintf 'line two\\n'", cronExpression: "*/5 * * * *",
            workingDirectory: fixture.workingDirectory, logDirectory: fixture.workingDirectory).validate()
    }

    func testDisabledCreationPersistsExactCommandEnvironmentCalendarAndPrivateFiles() async throws {
        let fixture = try CreationFixture()
        let runner = CreationRunner()
        let service = fixture.service(runner: runner)
        let witness = fixture.root.appendingPathComponent("must-not-execute")
        let command = "printf '%s\\n' '\"quoted\" $HOME'; touch '\(witness.path)'"
        let draft = JobDraft(name: "Nightly archive", command: command, cronExpression: "  15  3 * * * ",
            workingDirectory: fixture.workingDirectory, logDirectory: fixture.workingDirectory, isEnabled: false)
        let result = try await service.createJob(draft)
        let job = result.job
        let agent = try CreatedAgent.read(job.plistURL)
        XCTAssertNil(result.warning)
        XCTAssertEqual(job.name, draft.name)
        XCTAssertEqual(job.isEnabled, false)
        XCTAssertEqual(job.status, .disabled)
        XCTAssertEqual(agent.label, job.label)
        XCTAssertTrue(job.label.hasPrefix("dev.cadence.job."))
        XCTAssertEqual(agent.programArguments, ["/bin/zsh", "-f", "-c", command])
        XCTAssertEqual(agent.startCalendarInterval, try CronSchedule(draft.cronExpression).calendarIntervals)
        XCTAssertEqual(agent.disabled, true)
        XCTAssertEqual(agent.runAtLoad, false)
        XCTAssertNil(agent.keepAlive)
        XCTAssertEqual(agent.workingDirectory, fixture.workingDirectory.standardizedFileURL.path)
        XCTAssertEqual(agent.environmentVariables, ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"])
        XCTAssertEqual(job.stdoutURL?.deletingLastPathComponent().deletingLastPathComponent(), fixture.workingDirectory.standardizedFileURL)
        XCTAssertEqual(job.stdoutURL?.deletingLastPathComponent().lastPathComponent, job.label)
        let metadataURL = fixture.metadata.appendingPathComponent(job.label).appendingPathExtension("json")
        let metadata = try JSONDecoder().decode(JobMetadata.self, from: Data(contentsOf: metadataURL))
        XCTAssertEqual(metadata.name, draft.name)
        XCTAssertEqual(metadata.cronExpression, "15 3 * * *")
        XCTAssertEqual(metadata.plistSHA256, JobMetadata.digest(try Data(contentsOf: job.plistURL)))
        for url in [job.plistURL, try XCTUnwrap(job.stdoutURL), try XCTUnwrap(job.stderrURL), metadataURL] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, true)
            XCTAssertEqual(permissions(url), 0o600)
        }
        XCTAssertEqual(permissions(try XCTUnwrap(job.stdoutURL).deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(job.stdoutURL)), Data())
        XCTAssertFalse(FileManager.default.fileExists(atPath: witness.path))
        let commands = await runner.commands
        XCTAssertEqual(commands, [])
    }

    func testEnabledCreationBootstrapsWithoutKickstartAndRediscoveryPreservesDetails() async throws {
        let fixture = try CreationFixture()
        let runner = CreationRunner()
        let service = fixture.service(runner: runner)
        let draft = JobDraft(name: "Back up photos", command: "printf 'not executed by the app'", cronExpression: " */5   * * * * ")
        let result = try await service.createJob(draft)
        XCTAssertNil(result.warning)
        XCTAssertEqual(result.job.status, .waiting)
        XCTAssertEqual(result.job.isEnabled, true)
        XCTAssertEqual(result.job.scheduleDescription, "Every 5 minutes")
        let commands = await runner.commands
        XCTAssertEqual(commands, [["bootstrap", "gui/501", result.job.plistURL.path], ["print", "gui/501/\(result.job.label)"]])
        XCTAssertEqual(try CreatedAgent.read(result.job.plistURL).workingDirectory, FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        XCTAssertEqual(result.job.stdoutURL?.deletingLastPathComponent().deletingLastPathComponent(), fixture.logs.standardizedFileURL)
        let discovery = try await service.discover()
        let rediscovered = try XCTUnwrap(discovery.jobs.first)
        XCTAssertEqual(rediscovered.name, "Back up photos")
        XCTAssertEqual(rediscovered.scheduleDescription, "Every 5 minutes")
        XCTAssertEqual(rediscovered.scheduleDetails.count, 3)
        XCTAssertEqual(rediscovered.scheduleDetails.first, "Cron: */5 * * * *")
        XCTAssertTrue(rediscovered.scheduleDetails[1].contains(TimeZone.current.identifier))
        XCTAssertTrue(rediscovered.scheduleDetails[2].contains("wake"))
        XCTAssertEqual(discovery.warnings, [])
    }

    func testRepeatedNamesCreateDistinctJobsAndNeverShareLogsOrMetadata() async throws {
        let fixture = try CreationFixture()
        let runner = CreationRunner()
        let service = fixture.service(runner: runner)
        let draft = JobDraft(name: "Same name", command: "true", cronExpression: "0 3 * * *", isEnabled: false)
        let first = try await service.createJob(draft).job
        try Data("keep original log".utf8).write(to: XCTUnwrap(first.stdoutURL))
        let originalPlist = try Data(contentsOf: first.plistURL)
        let second = try await service.createJob(draft).job
        XCTAssertNotEqual(first.label, second.label)
        XCTAssertNotEqual(first.plistURL, second.plistURL)
        XCTAssertNotEqual(first.stdoutURL, second.stdoutURL)
        XCTAssertEqual(try Data(contentsOf: first.plistURL), originalPlist)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(first.stdoutURL), encoding: .utf8), "keep original log")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.agents.path).count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.metadata.path).count, 2)
    }

    func testBootstrapFailureReturnsSavedJobAndWarningRatherThanThrowingCreationFailure() async throws {
        let fixture = try CreationFixture()
        let runner = CreationRunner(mode: .failBootstrap)
        let service = fixture.service(runner: runner)
        let result = try await service.createJob(JobDraft(name: "Saved despite failure", command: "true", cronExpression: "0 3 * * *"))
        XCTAssertTrue(result.warning?.contains("job was saved") == true)
        XCTAssertTrue(result.warning?.contains("do not create it again") == true)
        XCTAssertEqual(result.job.status, .unloaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.job.plistURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.metadata.appendingPathComponent(result.job.label).appendingPathExtension("json").path))
        let jobs = try await service.discover().jobs
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.name, "Saved despite failure")
    }

    func testBootstrapTransportFailureStillReturnsThePersistedJob() async throws {
        let fixture = try CreationFixture()
        let runner = CreationRunner(mode: .throwBootstrap)
        let result = try await fixture.service(runner: runner).createJob(JobDraft(name: "Saved", command: "true", cronExpression: "0 3 * * *"))
        XCTAssertTrue(result.warning?.contains("registration could not be confirmed") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.job.plistURL.path))
    }

    func testFilesystemFailureRollsBackOnlyNewFilesAndPreservesExistingContent() async throws {
        let fixture = try CreationFixture()
        try FileManager.default.createDirectory(at: fixture.agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.logs, withIntermediateDirectories: true)
        let existingAgentContent = fixture.agents.appendingPathComponent("keep.txt")
        let existingLogContent = fixture.logs.appendingPathComponent("keep.txt")
        try Data("existing agent content".utf8).write(to: existingAgentContent)
        try Data("existing log content".utf8).write(to: existingLogContent)
        try Data("metadata path is an existing file".utf8).write(to: fixture.metadata)
        let runner = CreationRunner()
        do {
            _ = try await fixture.service(runner: runner).createJob(JobDraft(name: "Will fail", command: "true", cronExpression: "0 3 * * *"))
            XCTFail("Expected metadata path failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("could not be saved")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.agents.path), ["keep.txt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.logs.path), ["keep.txt"])
        XCTAssertEqual(try String(contentsOf: existingAgentContent, encoding: .utf8), "existing agent content")
        XCTAssertEqual(try String(contentsOf: existingLogContent, encoding: .utf8), "existing log content")
        XCTAssertEqual(try String(contentsOf: fixture.metadata, encoding: .utf8), "metadata path is an existing file")
        let commands = await runner.commands
        XCTAssertEqual(commands, [])
    }

    func testInvalidInputDoesNotCreateStorageOrInvokeLaunchctl() async throws {
        let fixture = try CreationFixture()
        let runner = CreationRunner()
        do {
            _ = try await fixture.service(runner: runner).createJob(JobDraft(name: "Invalid", command: "true", cronExpression: "not cron"))
            XCTFail("Expected validation failure")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        for url in [fixture.agents, fixture.logs, fixture.metadata] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        let commands = await runner.commands
        XCTAssertEqual(commands, [])
    }

    func testManuallyEditedPlistIgnoresStaleNameAndCronMetadata() async throws {
        let fixture = try CreationFixture()
        let service = fixture.service(runner: CreationRunner())
        let result = try await service.createJob(JobDraft(name: "Original title", command: "printf original", cronExpression: "*/5 * * * *", isEnabled: false))
        let original = try String(contentsOf: result.job.plistURL, encoding: .utf8)
        let edited = original.replacingOccurrences(of: "<string>printf original</string>", with: "<string>printf edited</string>")
        XCTAssertNotEqual(original, edited)
        try Data(edited.utf8).write(to: result.job.plistURL)
        let discovery = try await service.discover()
        let job = try XCTUnwrap(discovery.jobs.first)
        XCTAssertNotEqual(job.name, "Original title")
        XCTAssertEqual(job.arguments.last, "printf edited")
        XCTAssertNotEqual(job.scheduleDescription, "Every 5 minutes")
        XCTAssertTrue(discovery.warnings.contains { $0.contains("plist changed") })
    }

    func testCorruptAndOversizeMetadataFallsBackWithWarning() async throws {
        let fixture = try CreationFixture()
        let service = fixture.service(runner: CreationRunner())
        let job = try await service.createJob(JobDraft(name: "Saved name", command: "true", cronExpression: "0 3 * * *", isEnabled: false)).job
        let url = fixture.metadata.appendingPathComponent(job.label).appendingPathExtension("json")
        for data in [Data("not JSON".utf8), Data(repeating: 65, count: 16 * 1024 + 1)] {
            try data.write(to: url)
            let discovery = try await service.discover()
            XCTAssertNotEqual(discovery.jobs.first?.name, "Saved name")
            XCTAssertTrue(discovery.warnings.contains { $0.contains("Saved job details could not be used") })
        }
    }

    func testMetadataCronMustMatchPlistEvenWithValidChecksum() async throws {
        let fixture = try CreationFixture()
        let service = fixture.service(runner: CreationRunner())
        let job = try await service.createJob(JobDraft(name: "Saved name", command: "true", cronExpression: "0 3 * * *", isEnabled: false)).job
        let url = fixture.metadata.appendingPathComponent(job.label).appendingPathExtension("json")
        let replacement = try JobMetadata(label: job.label, name: "Misleading name", schedule: CronSchedule("0 8 * * *"), plistData: Data(contentsOf: job.plistURL))
        try JSONEncoder().encode(replacement).write(to: url)
        let discovery = try await service.discover()
        XCTAssertNotEqual(discovery.jobs.first?.name, "Misleading name")
        XCTAssertTrue(discovery.warnings.contains { $0.contains("does not match the plist") })
    }
}

final class JobCreationIntegrationTests: XCTestCase {
    func testRealCreatedJobKeepsMetadataAndRunsOnlyWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CADENCE_LAUNCHD_INTEGRATION"] == "1" else {
            throw XCTSkip("Set CADENCE_LAUNCHD_INTEGRATION=1 to test isolated job creation against launchd.")
        }
        let fixture = try CreationFixture()
        let service = LaunchService(directory: fixture.agents, metadataDirectory: fixture.metadata, logDirectory: fixture.logs)
        let runner = LaunchctlRunner()
        let month = Calendar.current.component(.month, from: Date()) % 12 + 1
        let expression = "* * * \(month) *"
        let witness = UUID().uuidString
        let draft = JobDraft(name: "Creation integration \(witness)",
            command: "printf 'stdout \(witness)\\n'; printf 'stderr \(witness)\\n' >&2",
            cronExpression: expression, workingDirectory: fixture.workingDirectory)
        let result = try await service.createJob(draft)
        let target = "gui/\(getuid())/\(result.job.label)"
        do {
            XCTAssertNil(result.warning)
            let discovery = try await service.discover()
            let job = try XCTUnwrap(discovery.jobs.first)
            XCTAssertEqual(job.name, draft.name)
            XCTAssertEqual(job.scheduleDescription, try CronSchedule(expression).summary)
            XCTAssertEqual(job.scheduleDetails.first, "Cron: \(expression)")
            XCTAssertEqual(job.status, .waiting)
            XCTAssertEqual(job.isEnabled, true)
            XCTAssertEqual(discovery.warnings, [])
            let initialOutput = await service.readLog(job: job, stream: .stdout)
            let initialError = await service.readLog(job: job, stream: .stderr)
            XCTAssertEqual(initialOutput.text, "")
            XCTAssertEqual(initialError.text, "")
            try await service.runNow(job: job)
            var output = await service.readLog(job: job, stream: .stdout)
            var error = await service.readLog(job: job, stream: .stderr)
            for _ in 0..<40 where !output.text.contains(witness) || !error.text.contains(witness) {
                try await Task.sleep(for: .milliseconds(100))
                output = await service.readLog(job: job, stream: .stdout)
                error = await service.readLog(job: job, stream: .stderr)
            }
            XCTAssertTrue(output.text.contains("stdout \(witness)"))
            XCTAssertTrue(error.text.contains("stderr \(witness)"))
            try await service.setEnabled(false, job: job)
            let disabledDiscovery = try await service.discover()
            let disabled = try XCTUnwrap(disabledDiscovery.jobs.first)
            XCTAssertEqual(disabled.name, draft.name)
            XCTAssertEqual(disabled.isEnabled, false)
            XCTAssertEqual(disabled.status, .disabled)
        } catch {
            _ = try? await runner.run(["bootout", target])
            _ = try? await runner.run(["enable", target])
            throw error
        }
        // Only this unique fixture label is touched. No supported launchctl command
        // removes an individual override, so restore its default enabled state.
        _ = try await runner.run(["bootout", target])
        let reset = try await runner.run(["enable", target])
        XCTAssertEqual(reset.status, 0)
    }
}

private final class CreationFixture {
    let root: URL
    var agents: URL { root.appendingPathComponent("LaunchAgents", isDirectory: true) }
    var metadata: URL { root.appendingPathComponent("metadata", isDirectory: true) }
    var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    var workingDirectory: URL { root.appendingPathComponent("working", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-creation-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func service(runner: any CommandRunning) -> LaunchService {
        LaunchService(directory: agents, runner: runner, metadataDirectory: metadata, logDirectory: logs)
    }
}

private struct CreatedAgent: Decodable {
    let label: String
    let programArguments: [String]
    let workingDirectory: String
    let environmentVariables: [String: String]
    let startCalendarInterval: [[String: Int]]
    let disabled: Bool
    let runAtLoad: Bool
    let keepAlive: Bool?
    let stdoutPath: String
    let stderrPath: String

    enum CodingKeys: String, CodingKey {
        case label = "Label", programArguments = "ProgramArguments", workingDirectory = "WorkingDirectory"
        case environmentVariables = "EnvironmentVariables", startCalendarInterval = "StartCalendarInterval"
        case disabled = "Disabled", runAtLoad = "RunAtLoad", keepAlive = "KeepAlive"
        case stdoutPath = "StandardOutPath", stderrPath = "StandardErrorPath"
    }

    static func read(_ url: URL) throws -> CreatedAgent {
        try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

private actor CreationRunner: CommandRunning {
    enum Mode { case success, failBootstrap, throwBootstrap }
    let mode: Mode
    private(set) var commands: [[String]] = []
    private var loaded: [String: String] = [:]

    init(mode: Mode = .success) { self.mode = mode }

    func run(_ arguments: [String]) async throws -> CommandResult {
        commands.append(arguments)
        if arguments.first == "bootstrap", arguments.count == 3 {
            if mode == .throwBootstrap { throw LaunchServiceError.commandFailed("Timed out") }
            if mode == .failBootstrap { return CommandResult(status: 5, stdout: "", stderr: "Bootstrap failed") }
            let path = arguments[2]
            let config = try AgentConfiguration.read(URL(fileURLWithPath: path))
            loaded[config.label] = path
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
        if arguments.first == "print-disabled" {
            return CommandResult(status: 0, stdout: "disabled services = {\n}", stderr: "")
        }
        if arguments.first == "print", let target = arguments.last {
            let label = target.split(separator: "/").last.map(String.init) ?? ""
            if let path = loaded[label] {
                return CommandResult(status: 0, stdout: "\(target) = {\n\tpath = \(path)\n\tstate = not running\n\truns = 0\n}", stderr: "")
            }
            return CommandResult(status: 113, stdout: "", stderr: "Could not find service \"\(label)\"")
        }
        XCTFail("Unexpected launchctl command during creation: \(arguments)")
        throw LaunchServiceError.unavailable("Unexpected test command")
    }
}

private func permissions(_ url: URL) -> mode_t {
    var info = stat()
    guard fstatat(AT_FDCWD, url.path, &info, 0) == 0 else { return 0 }
    return info.st_mode & 0o777
}
