import XCTest
@testable import LaunchCore

final class ConfigurationTests: XCTestCase {
    func testIntervalAndAllIndependentTriggersAreVisible() throws {
        let directory = try FixtureDirectory()
        let url = try directory.write("job", extra: "<key>StartInterval</key><integer>300</integer><key>RunAtLoad</key><true/><key>WatchPaths</key><array><string>/tmp/inbox</string></array>")
        let config = try AgentConfiguration.read(url)
        XCTAssertEqual(config.scheduleDescription, "Every 5 minutes · +2 triggers")
        XCTAssertEqual(config.scheduleDetails, ["Every 5 minutes", "When loaded / at login", "When watched paths change (1)"])
        XCTAssertEqual(AgentConfiguration.intervalDescription(90), "Every 90 seconds")
        XCTAssertEqual(AgentConfiguration.intervalDescription(3_600), "Every 1 hour")
        XCTAssertEqual(AgentConfiguration.intervalDescription(172_800), "Every 2 days")
    }

    func testCalendarWildcardsAreNotInventedAsMidnight() throws {
        let directory = try FixtureDirectory()
        let hour = try directory.write("hour", extra: "<key>StartCalendarInterval</key><dict><key>Hour</key><integer>9</integer></dict>")
        XCTAssertEqual(try AgentConfiguration.read(hour).scheduleDetails, ["Every minute during 09:00–09:59"])
        let minute = try directory.write("minute", extra: "<key>StartCalendarInterval</key><dict><key>Minute</key><integer>15</integer></dict>")
        XCTAssertEqual(try AgentConfiguration.read(minute).scheduleDetails, ["Every hour at :15"])
        let any = try directory.write("any", extra: "<key>StartCalendarInterval</key><dict/>")
        XCTAssertEqual(try AgentConfiguration.read(any).scheduleDetails, ["Every minute"])
    }

    func testCalendarArraysAndDayWeekdayOrSemantics() throws {
        let directory = try FixtureDirectory()
        let url = try directory.write("calendar", extra: """
            <key>StartCalendarInterval</key><array>
            <dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>30</integer></dict>
            <dict><key>Hour</key><integer>20</integer><key>Minute</key><integer>0</integer><key>Day</key><integer>1</integer><key>Weekday</key><integer>7</integer></dict>
            </array>
            """)
        XCTAssertEqual(try AgentConfiguration.read(url).scheduleDetails, ["Daily at 08:30", "20:00 · day 1 or Sunday"])
    }

    func testInvalidCalendarAndIntervalFailLoudly() throws {
        let directory = try FixtureDirectory()
        let badCalendar = try directory.write("bad", extra: "<key>StartCalendarInterval</key><dict><key>Minute</key><integer>60</integer></dict>")
        XCTAssertThrowsError(try AgentConfiguration.read(badCalendar))
        let badInterval = try directory.write("badInterval", extra: "<key>StartInterval</key><integer>0</integer>")
        XCTAssertThrowsError(try AgentConfiguration.read(badInterval))
    }

    func testKeepAliveFlagsAndConditions() throws {
        let directory = try FixtureDirectory()
        let always = try directory.write("always", extra: "<key>KeepAlive</key><true/>")
        XCTAssertEqual(try AgentConfiguration.read(always).scheduleDetails, ["Kept running continuously"])
        let conditional = try directory.write("conditional", extra: "<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>")
        XCTAssertEqual(try AgentConfiguration.read(conditional).scheduleDetails, ["Kept alive when launchd conditions match (SuccessfulExit)"])
        let demand = try directory.write("demand", extra: "<key>KeepAlive</key><false/>")
        XCTAssertEqual(try AgentConfiguration.read(demand).scheduleDetails, ["On demand"])
    }

    func testPathValuesAreLiteralAndRelativeToWorkingDirectory() throws {
        let directory = try FixtureDirectory()
        let url = try directory.write("paths", extra: "<key>WorkingDirectory</key><string>/tmp/work</string><key>StandardOutPath</key><string>output.log</string><key>StandardErrorPath</key><string>/tmp/error.log</string>")
        let config = try AgentConfiguration.read(url)
        XCTAssertEqual(config.logURL(for: .stdout)?.path, "/tmp/work/output.log")
        XCTAssertEqual(config.logURL(for: .stderr)?.path, "/tmp/error.log")
    }

    func testMissingProgramAndUnsafeLabelAreRejected() throws {
        let directory = try FixtureDirectory()
        let url = directory.url.appendingPathComponent("invalid.plist")
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>job</string></dict></plist>".utf8).write(to: url)
        XCTAssertThrowsError(try AgentConfiguration.read(url))
        let badLabel = try directory.write("badLabel", label: "bad/label")
        XCTAssertThrowsError(try AgentConfiguration.read(badLabel))
    }
}

final class LaunchctlParsingTests: XCTestCase {
    func testBothKnownDisabledOutputFormatsAndEmptyMap() throws {
        XCTAssertEqual(try DisabledOverrides.parse("\n\tdisabled services = {\n\t\t\"a\" => disabled\n\t\t\"b\" => enabled\n\t}\n"), ["a": true, "b": false])
        XCTAssertEqual(try DisabledOverrides.parse("disabled services = {\n\"a\" => true\n\"b\" => false\n}"), ["a": true, "b": false])
        XCTAssertEqual(try DisabledOverrides.parse("disabled services = {\n}"), [:])
    }

    func testFutureDisabledFormatIsRejected() {
        XCTAssertThrowsError(try DisabledOverrides.parse("services = {}"))
        XCTAssertThrowsError(try DisabledOverrides.parse("disabled services = {\n\"a\" => maybe\n}"))
    }

    func testRuntimeStateIgnoresNestedStateAndExposesExitCode() throws {
        let result = try RuntimeState.parse([
            "gui/501/test = {",
            "\tpath = /tmp/test.plist",
            "\tstate = not running",
            "\truns = 7",
            "\tlast exit code = 1",
            "\tnested = {",
            "\t\tstate = running",
            "\t\tpid = 99",
            "\t}",
            "}"
        ].joined(separator: "\n"))
        XCTAssertEqual(result.status, .waiting)
        XCTAssertEqual(result.runCount, 7)
        XCTAssertEqual(result.lastExitCode, 1)
        XCTAssertNil(result.pid)
        XCTAssertThrowsError(try RuntimeState.parse("state = something new"))
    }

    func testOnlyMissingServiceDiagnosticCountsAsUnloaded() {
        XCTAssertTrue(missing.isMissingService)
        XCTAssertFalse(CommandResult(status: 1, stdout: "", stderr: "Operation not permitted").isMissingService)
        XCTAssertFalse(CommandResult(status: 0, stdout: "Could not find service", stderr: "").isMissingService)
    }
}

final class DiscoveryAndControlTests: XCTestCase {
    func testDisabledButLoadedWaitingJobStillShowsLoadedStatus() async throws {
        let directory = try FixtureDirectory()
        let url = try directory.write("job")
        let runner = ScriptedRunner([
            .init(["print-disabled", "gui/501"], output: overrides("\"job\" => disabled")),
            .init(["print", "gui/501/job"], output: runtime(path: url.path))
        ])
        let job = try await firstJob(LaunchService(directory: directory.url, runner: runner))
        XCTAssertEqual(job.isEnabled, false)
        XCTAssertEqual(job.status, .waiting)
        XCTAssertTrue(job.issue?.contains("still loaded") == true)
    }

    func testDisabledOverrideTakesPrecedenceOverPlistDefault() async throws {
        let directory = try FixtureDirectory()
        try directory.write("job", extra: "<key>Disabled</key><true/>")
        let runner = ScriptedRunner([
            .init(["print-disabled", "gui/501"], output: overrides("\"job\" => enabled")),
            .init(["print", "gui/501/job"], result: missing)
        ])
        let service = LaunchService(directory: directory.url, runner: runner)
        let jobs = try await service.discover().jobs
        XCTAssertEqual(jobs.first?.isEnabled, true)
        XCTAssertEqual(jobs.first?.status, .unloaded)
        await runner.assertComplete()
    }

    func testUnloadedDisabledDefaultAndMalformedPlistWarning() async throws {
        let directory = try FixtureDirectory()
        try directory.write("job", extra: "<key>Disabled</key><true/>")
        try Data("broken plist".utf8).write(to: directory.url.appendingPathComponent("broken.plist"))
        let runner = ScriptedRunner([.init(["print-disabled", "gui/501"], output: overrides()), .init(["print", "gui/501/job"], result: missing)])
        let result = try await LaunchService(directory: directory.url, runner: runner).discover()
        XCTAssertEqual(result.jobs.first?.isEnabled, false)
        XCTAssertEqual(result.jobs.first?.status, .disabled)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("broken.plist"))
    }

    func testDuplicateLabelsCannotBeControlled() async throws {
        let directory = try FixtureDirectory()
        try directory.write("one", label: "same")
        try directory.write("two", label: "same")
        let runner = ScriptedRunner([.init(["print-disabled", "gui/501"], output: overrides())])
        let service = LaunchService(directory: directory.url, runner: runner)
        let result = try await service.discover()
        XCTAssertEqual(result.jobs.count, 2)
        XCTAssertTrue(result.jobs.allSatisfy { $0.isEnabled == nil && $0.issue?.contains("Multiple") == true })
        do { try await service.setEnabled(true, job: result.jobs[0]); XCTFail("Expected duplicate to fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("configuration changed")) }
        await runner.assertComplete()
    }

    func testStatusFailureDoesNotBecomeUnloadedOrEnabled() async throws {
        let directory = try FixtureDirectory()
        try directory.write("job")
        let runner = ScriptedRunner([
            .init(["print-disabled", "gui/501"], output: overrides()),
            .init(["print", "gui/501/job"], result: .init(status: 1, stdout: "", stderr: "Operation not permitted"))
        ])
        let job = try await firstJob(LaunchService(directory: directory.url, runner: runner))
        XCTAssertNil(job.isEnabled)
        XCTAssertEqual(job.status, .unknown)
        XCTAssertEqual(job.issue, "Operation not permitted")
    }

    func testUnknownDisabledFormatDisablesControls() async throws {
        let directory = try FixtureDirectory()
        try directory.write("job")
        let runner = ScriptedRunner([.init(["print-disabled", "gui/501"], output: "new output"), .init(["print", "gui/501/job"], result: missing)])
        let result = try await LaunchService(directory: directory.url, runner: runner).discover()
        XCTAssertNil(result.jobs.first?.isEnabled)
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testLoadedConfigurationPathConflictDisablesControls() async throws {
        let directory = try FixtureDirectory()
        try directory.write("job")
        let runner = ScriptedRunner([
            .init(["print-disabled", "gui/501"], output: overrides()),
            .init(["print", "gui/501/job"], output: runtime(path: "/tmp/another-job.plist"))
        ])
        let job = try await firstJob(LaunchService(directory: directory.url, runner: runner))
        XCTAssertNil(job.isEnabled)
        XCTAssertTrue(job.issue?.contains("different configuration") == true)
    }

    func testEnableRegistersAndDisableUnloadsWithoutKillingOnRunNow() async throws {
        let directory = try FixtureDirectory()
        let url = try directory.write("job")
        let runner = ScriptedRunner([
            .init(["print-disabled", "gui/501"], output: overrides()),
            .init(["print", "gui/501/job"], result: missing),
            .init(["print-disabled", "gui/501"], output: overrides()),
            .init(["print", "gui/501/job"], result: missing),
            .init(["enable", "gui/501/job"]),
            .init(["bootstrap", "gui/501", url.path]),
            .init(["print-disabled", "gui/501"], output: overrides()),
            .init(["print", "gui/501/job"], output: runtime(path: url.path)),
            .init(["kickstart", "gui/501/job"]),
            .init(["print-disabled", "gui/501"], output: overrides()),
            .init(["print", "gui/501/job"], output: runtime(path: url.path)),
            .init(["disable", "gui/501/job"]),
            .init(["bootout", "gui/501/job"])
        ])
        let service = LaunchService(directory: directory.url, runner: runner)
        let job = try await firstJob(service)
        try await service.setEnabled(true, job: job)
        try await service.runNow(job: job)
        try await service.setEnabled(false, job: job)
        await runner.assertComplete()
    }

    func testPartialDisableFailureExplainsPersistedState() async throws {
        let directory = try FixtureDirectory()
        let url = try directory.write("job")
        let runner = ScriptedRunner([
            .init(["print-disabled", "gui/501"], output: overrides()),
            .init(["print", "gui/501/job"], output: runtime(path: url.path)),
            .init(["print-disabled", "gui/501"], output: overrides()),
            .init(["print", "gui/501/job"], output: runtime(path: url.path)),
            .init(["disable", "gui/501/job"]),
            .init(["bootout", "gui/501/job"], result: .init(status: 1, stdout: "", stderr: "Permission denied"))
        ])
        let service = LaunchService(directory: directory.url, runner: runner)
        let job = try await firstJob(service)
        do { try await service.setEnabled(false, job: job); XCTFail("Expected partial failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("disabled for future loads, but could not be stopped")) }
        await runner.assertComplete()
    }

    func testStaleConfigurationIsRejectedBeforeAnyMutation() async throws {
        let directory = try FixtureDirectory()
        try directory.write("job")
        let runner = ScriptedRunner([.init(["print-disabled", "gui/501"], output: overrides()), .init(["print", "gui/501/job"], result: missing)])
        let service = LaunchService(directory: directory.url, runner: runner)
        let job = try await firstJob(service)
        try directory.write("job", extra: "<key>RunAtLoad</key><true/>")
        do { try await service.setEnabled(true, job: job); XCTFail("Expected stale configuration error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("configuration changed")) }
        await runner.assertComplete()
    }

    func testRunNowRefusesDisabledJob() async throws {
        let directory = try FixtureDirectory()
        try directory.write("job", extra: "<key>Disabled</key><true/>")
        let runner = ScriptedRunner([
            .init(["print-disabled", "gui/501"], output: overrides()),
            .init(["print", "gui/501/job"], result: missing),
            .init(["print-disabled", "gui/501"], output: overrides())
        ])
        let service = LaunchService(directory: directory.url, runner: runner)
        let job = try await firstJob(service)
        do { try await service.runNow(job: job); XCTFail("Expected disabled job error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Enable this job")) }
        await runner.assertComplete()
    }

    func testRunNowDoesNotDoubleStartJobsThatLaunchOnBootstrap() async throws {
        for trigger in ["<key>RunAtLoad</key><true/>", "<key>KeepAlive</key><true/>",
                        "<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>"] {
            let directory = try FixtureDirectory()
            let url = try directory.write("job", extra: trigger)
            let runner = ScriptedRunner([
                .init(["print-disabled", "gui/501"], output: overrides()),
                .init(["print", "gui/501/job"], result: missing),
                .init(["print-disabled", "gui/501"], output: overrides()),
                .init(["print", "gui/501/job"], result: missing),
                .init(["bootstrap", "gui/501", url.path])
            ])
            let service = LaunchService(directory: directory.url, runner: runner)
            let job = try await firstJob(service)
            try await service.runNow(job: job)
            await runner.assertComplete()
        }
    }

    func testMutationsAreSerializedAcrossActorReentrancy() async throws {
        let directory = try FixtureDirectory()
        let url = try directory.write("job")
        let runner = BlockingRunner()
        let service = LaunchService(directory: directory.url, runner: runner)
        var job = LaunchJob(label: "job", name: "Job", plistURL: url, program: "/bin/echo", scheduleDescription: "On demand")
        job.configurationData = try Data(contentsOf: url)
        let first = Task { try await service.setEnabled(true, job: job) }
        await runner.waitUntilBlocked()
        do { try await service.runNow(job: job); XCTFail("Expected concurrent mutation to be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("still in progress")) }
        await runner.release()
        try await first.value
    }
}

final class LogReaderTests: XCTestCase {
    func testBoundedTailPreservesLatestLinesAndInvalidUTF8() throws {
        let directory = try FixtureDirectory()
        let url = directory.url.appendingPathComponent("log")
        var data = Data(repeating: 65, count: LogReader.maximumBytes + 50)
        data.append(contentsOf: [10, 0xff, 66, 10])
        try data.write(to: url)
        let snapshot = LogReader.read(url)
        XCTAssertTrue(snapshot.truncated)
        XCTAssertEqual(snapshot.text, "�B\n")
        XCTAssertNotNil(snapshot.modifiedAt)
        XCTAssertNil(snapshot.message)
    }

    func testMissingEmptyAndNonRegularPathsAreExplicit() throws {
        let directory = try FixtureDirectory()
        let url = directory.url.appendingPathComponent("missing")
        XCTAssertTrue(LogReader.read(url).message?.contains("does not exist yet") == true)
        try Data().write(to: url)
        XCTAssertTrue(LogReader.read(url).message?.contains("No output") == true)
        XCTAssertTrue(LogReader.read(directory.url).message?.contains("not a regular file") == true)
    }

    func testFIFOLogDoesNotBlock() throws {
        let directory = try FixtureDirectory()
        let url = directory.url.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        XCTAssertTrue(LogReader.read(url).message?.contains("not a regular file") == true)
    }
}

private let missing = CommandResult(status: 113, stdout: "", stderr: "Bad request.\nCould not find service \"job\" in domain for user gui: 501")
func firstJob(_ service: LaunchService) async throws -> LaunchJob {
    let result = try await service.discover()
    return try XCTUnwrap(result.jobs.first)
}
private func overrides(_ entries: String = "") -> String { "disabled services = {\n\(entries)\n}" }
private func runtime(path: String) -> String { "gui/501/job = {\n\tpath = \(path)\n\tstate = not running\n\truns = 0\n}" }

final class FixtureDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    @discardableResult
    func write(_ name: String, label: String? = nil, extra: String = "", arguments: [String] = ["/bin/echo", "hello"]) throws -> URL {
        let url = url.appendingPathComponent(name).appendingPathExtension("plist")
        let argumentsXML = arguments.map { "<string>\(escapeXML($0))</string>" }.joined()
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>Label</key><string>\(escapeXML(label ?? name))</string>
            <key>ProgramArguments</key><array>\(argumentsXML)</array>\(extra)</dict></plist>
            """
        try Data(xml.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}

func escapeXML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

private actor ScriptedRunner: CommandRunning {
    struct Step: Sendable {
        let arguments: [String]
        let result: CommandResult
        init(_ arguments: [String], output: String = "", result: CommandResult? = nil) {
            self.arguments = arguments
            self.result = result ?? CommandResult(status: 0, stdout: output, stderr: "")
        }
    }
    private var steps: [Step]
    init(_ steps: [Step]) { self.steps = steps }
    func run(_ arguments: [String]) async throws -> CommandResult {
        guard !steps.isEmpty else {
            XCTFail("Unexpected launchctl call: \(arguments)")
            throw LaunchServiceError.unavailable("Unexpected test command")
        }
        let next = steps.removeFirst()
        XCTAssertEqual(arguments, next.arguments)
        return next.result
    }
    func assertComplete(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(steps.isEmpty, "Unconsumed commands: \(steps.map(\.arguments))", file: file, line: line)
    }
}

private actor BlockingRunner: CommandRunning {
    private var blocked: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var didBlock = false

    func run(_ arguments: [String]) async throws -> CommandResult {
        if arguments.first == "print-disabled" {
            await withCheckedContinuation { continuation in
                blocked = continuation
                didBlock = true
                observers.forEach { $0.resume() }
                observers.removeAll()
            }
            return CommandResult(status: 0, stdout: overrides(), stderr: "")
        }
        if arguments.first == "print" { return missing }
        return CommandResult(status: 0, stdout: "", stderr: "")
    }

    func waitUntilBlocked() async {
        guard !didBlock else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() { blocked?.resume(); blocked = nil }
}
