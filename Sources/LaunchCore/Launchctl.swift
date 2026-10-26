import Foundation
import Darwin

struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var errorText: String {
        let text = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "launchctl exited with code \(status)." : String(text.prefix(2_000))
    }

    var isMissingService: Bool {
        status != 0 && (stderr + stdout).contains("Could not find service")
    }
}

protocol CommandRunning: Sendable {
    func run(_ arguments: [String]) async throws -> CommandResult
}

struct LaunchctlRunner: CommandRunning {
    var timeout: TimeInterval = 10

    func run(_ arguments: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-launchctl-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let outURL = directory.appendingPathComponent("stdout")
                    let errURL = directory.appendingPathComponent("stderr")
                    guard FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                          FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw LaunchServiceError.unavailable("Could not create private launchctl output files.")
                    }
                    let stdout = try FileHandle(forWritingTo: outURL)
                    let stderr = try FileHandle(forWritingTo: errURL)
                    defer { try? stdout.close(); try? stderr.close() }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    process.arguments = arguments
                    process.standardOutput = stdout
                    process.standardError = stderr
                    process.standardInput = FileHandle.nullDevice
                    try process.run()
                    let deadline = Date().addingTimeInterval(timeout)
                    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                    if process.isRunning {
                        process.terminate()
                        let terminationDeadline = Date().addingTimeInterval(1)
                        while process.isRunning && Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.02) }
                        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                        process.waitUntilExit()
                        throw LaunchServiceError.commandFailed("launchctl \(arguments.first ?? "command") timed out. Refresh to check whether the change completed.")
                    }
                    process.waitUntilExit()
                    continuation.resume(returning: CommandResult(status: process.terminationStatus,
                        stdout: try readBounded(outURL), stderr: try readBounded(errURL)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func readBounded(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 512 * 1024) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

struct DisabledOverrides {
    /// print-disabled is diagnostic text. Reject unrecognized formats rather than guessing.
    static func parse(_ text: String) throws -> [String: Bool] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == "disabled services = {", lines.last == "}" else {
            throw LaunchServiceError.unavailable("This macOS version returned an unrecognized launchctl enable-state format.")
        }
        let expression = try NSRegularExpression(pattern: #"^("(?:[^"\\]|\\.)*")\s*=>\s*(enabled|disabled|true|false)\s*;?$"#)
        var result: [String: Bool] = [:]
        for line in lines.dropFirst().dropLast() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                  let labelRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line),
                  let data = String(line[labelRange]).data(using: .utf8),
                  let label = try? JSONDecoder().decode(String.self, from: data) else {
                throw LaunchServiceError.unavailable("launchctl returned an unrecognized enable-state entry. Controls are unavailable until the list can be read.")
            }
            let value = line[valueRange]
            result[label] = value == "disabled" || value == "true"
        }
        return result
    }
}

struct RuntimeState {
    let status: JobStatus
    let pid: Int?
    let lastExitCode: Int?
    let runCount: Int?
    let path: String?

    static func parse(_ text: String) throws -> RuntimeState {
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            // Child dictionaries also contain state/pid fields; only inspect the root dictionary.
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let parts = line.dropFirst().components(separatedBy: " = ")
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        guard let state = fields["state"] else {
            throw LaunchServiceError.unavailable("launchctl returned an unrecognized service status format.")
        }
        let status: JobStatus
        switch state {
        case "running": status = .running
        case "not running", "waiting", "spawn scheduled", "exited", "waiting for debugger": status = .waiting
        default: throw LaunchServiceError.unavailable("Unrecognized launchd service state: \(state).")
        }
        return RuntimeState(status: status, pid: fields["pid"].flatMap(Int.init),
            lastExitCode: fields["last exit code"].flatMap(Int.init),
            runCount: fields["runs"].flatMap(Int.init), path: fields["path"])
    }
}
