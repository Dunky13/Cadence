import XCTest
import Darwin
@testable import LaunchCore

/// Opt in explicitly: this creates and controls only a unique temporary test agent.
final class LaunchdIntegrationTests: XCTestCase {
    func testRealLaunchdEnableRunLogDisableAndReenable() async throws {
        guard ProcessInfo.processInfo.environment["CADENCE_LAUNCHD_INTEGRATION"] == "1" else {
            throw XCTSkip("Set CADENCE_LAUNCHD_INTEGRATION=1 to test an isolated real LaunchAgent.")
        }
        let directory = try FixtureDirectory()
        let label = "dev.cadence.integration.\(UUID().uuidString.lowercased())"
        let stdout = directory.url.appendingPathComponent("stdout.log")
        let stderr = directory.url.appendingPathComponent("stderr.log")
        try directory.write("fixture", label: label, extra: """
            <key>Disabled</key><true/><key>StartInterval</key><integer>86400</integer>
            <key>StandardOutPath</key><string>\(escapeXML(stdout.path))</string>
            <key>StandardErrorPath</key><string>\(escapeXML(stderr.path))</string>
            """, arguments: ["/bin/sh", "-c", "printf 'cadence stdout witness\\n'; printf 'cadence stderr witness\\n' >&2"])
        let service = LaunchService(directory: directory.url)
        let runner = LaunchctlRunner()
        let target = "gui/\(getuid())/\(label)"
        do {
            let initial = try await firstJob(service)
            XCTAssertEqual(initial.isEnabled, false)
            XCTAssertEqual(initial.status, .disabled)
            try await service.setEnabled(true, job: initial)
            let enabled = try await firstJob(service)
            XCTAssertEqual(enabled.isEnabled, true)
            XCTAssertNotEqual(enabled.status, .unloaded)
            try await service.runNow(job: enabled)
            var out = await service.readLog(job: enabled, stream: .stdout)
            var err = await service.readLog(job: enabled, stream: .stderr)
            for _ in 0..<40 where !out.text.contains("cadence stdout witness") || !err.text.contains("cadence stderr witness") {
                try await Task.sleep(for: .milliseconds(100))
                out = await service.readLog(job: enabled, stream: .stdout)
                err = await service.readLog(job: enabled, stream: .stderr)
            }
            XCTAssertTrue(out.text.contains("cadence stdout witness"))
            XCTAssertTrue(err.text.contains("cadence stderr witness"))
            try await service.setEnabled(false, job: enabled)
            let disabled = try await firstJob(service)
            XCTAssertEqual(disabled.isEnabled, false)
            XCTAssertEqual(disabled.status, .disabled)
            try await service.setEnabled(true, job: disabled)
            let reenabled = try await firstJob(service)
            XCTAssertEqual(reenabled.isEnabled, true)
            XCTAssertNotEqual(reenabled.status, .unloaded)
        } catch {
            _ = try? await runner.run(["bootout", target])
            _ = try? await runner.run(["enable", target])
            throw error
        }
        let removal = try await runner.run(["bootout", target])
        XCTAssertEqual(removal.status, 0)
        // launchctl has no supported per-label override deletion command. Leave the
        // unique label enabled (the default) rather than a lingering disabled override.
        let reset = try await runner.run(["enable", target])
        XCTAssertEqual(reset.status, 0)
    }
}
