import Foundation
import Darwin

/// Persists new files exclusively. It never modifies an existing job or log.
enum JobStorage {
    struct SavedJob {
        let url: URL
        let data: Data
        let configuration: AgentConfiguration
        let metadata: JobMetadata
    }

    private struct NewAgent: Encodable {
        let label: String
        let programArguments: [String]
        let workingDirectory: String
        let environmentVariables: [String: String]
        let startCalendarInterval: [[String: Int]]
        let disabled: Bool
        let runAtLoad = false
        let stdoutPath: String
        let stderrPath: String

        enum CodingKeys: String, CodingKey {
            case label = "Label", programArguments = "ProgramArguments"
            case workingDirectory = "WorkingDirectory", environmentVariables = "EnvironmentVariables"
            case startCalendarInterval = "StartCalendarInterval", disabled = "Disabled"
            case runAtLoad = "RunAtLoad", stdoutPath = "StandardOutPath", stderrPath = "StandardErrorPath"
        }
    }

    static func persist(_ draft: JobDraft, schedule: CronSchedule, directory: URL,
                        metadataDirectory: URL, logDirectory: URL) throws -> SavedJob {
        try draft.validate()
        let label = "dev.cadence.job.\(UUID().uuidString.lowercased())"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logs = (draft.logDirectory ?? logDirectory).appendingPathComponent(label, isDirectory: true).standardizedFileURL
        let stdout = logs.appendingPathComponent("stdout.log")
        let stderr = logs.appendingPathComponent("stderr.log")
        let plistURL = directory.appendingPathComponent(label).appendingPathExtension("plist").standardizedFileURL
        let agent = NewAgent(label: label, programArguments: ["/bin/zsh", "-f", "-c", draft.command],
            workingDirectory: (draft.workingDirectory ?? home).standardizedFileURL.path,
            environmentVariables: ["HOME": home.path,
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
            startCalendarInterval: schedule.calendarIntervals, disabled: !draft.isEnabled,
            stdoutPath: stdout.path, stderrPath: stderr.path)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(agent)
        let configuration = try PropertyListDecoder().decode(AgentConfiguration.self, from: data)
        try configuration.validate()
        let metadata = JobMetadata(label: label, name: draft.name, schedule: schedule, plistData: data)
        let metadataEncoder = JSONEncoder()
        metadataEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataData = try metadataEncoder.encode(metadata)
        guard data.count <= 2 * 1024 * 1024 else {
            throw LaunchServiceError.invalidConfiguration("The generated configuration exceeds 2 MiB. Use a simpler schedule or shorter command.")
        }
        guard metadataData.count <= 16 * 1024 else {
            throw LaunchServiceError.invalidConfiguration("The saved job details exceed 16 KiB. Use a shorter name or schedule.")
        }
        var transaction = OwnedFiles()
        do {
            try transaction.ensureDirectory(directory)
            try transaction.ensureDirectory(draft.logDirectory ?? logDirectory)
            try transaction.createDirectory(logs)
            try transaction.createFile(stdout, data: Data())
            try transaction.createFile(stderr, data: Data())
            try transaction.createFile(plistURL, data: data)
            try transaction.ensureDirectory(metadataDirectory)
            try transaction.createFile(metadataDirectory.appendingPathComponent(label).appendingPathExtension("json"), data: metadataData)
            return SavedJob(url: plistURL, data: data, configuration: configuration, metadata: metadata)
        } catch {
            let cleanupErrors = transaction.rollback()
            let cleanup = cleanupErrors.isEmpty ? "" : " Cleanup needs attention: " + cleanupErrors.joined(separator: "; ")
            throw LaunchServiceError.unavailable("The job could not be saved: \(error.localizedDescription)\(cleanup)")
        }
    }
}

private struct OwnedFiles {
    private struct Entry {
        let url: URL
        let device: dev_t
        let inode: ino_t
        let isDirectory: Bool
    }
    private var entries: [Entry] = []

    mutating func ensureDirectory(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw LaunchServiceError.invalidConfiguration("Storage directories must be absolute file directories.")
        }
        var info = stat()
        if fstatat(AT_FDCWD, url.path, &info, 0) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw LaunchServiceError.unavailable("A file already exists where a directory is required: \(url.path)")
            }
            return
        }
        guard errno == ENOENT else { throw failure("Inspect directory", url) }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { throw failure("Create directory", url) }
        try ensureDirectory(parent)
        try createDirectory(url)
    }

    mutating func createDirectory(_ url: URL) throws {
        guard Darwin.mkdir(url.path, 0o700) == 0 else { throw failure("Create directory", url) }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw failure("Inspect new directory", url) }
        entries.append(Entry(url: url, device: info.st_dev, inode: info.st_ino, isDirectory: true))
    }

    mutating func createFile(_ url: URL, data: Data) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure("Create file", url) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure("Inspect new file", url) }
        entries.append(Entry(url: url, device: info.st_dev, inode: info.st_ino, isDirectory: false))
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("Write file", url) }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw failure("Save file", url) }
    }

    mutating func rollback() -> [String] {
        var failures: [String] = []
        for entry in entries.reversed() {
            var info = stat()
            if lstat(entry.url.path, &info) != 0 {
                if errno != ENOENT { failures.append("Could not inspect \(entry.url.lastPathComponent)") }
                continue
            }
            guard info.st_dev == entry.device && info.st_ino == entry.inode else {
                failures.append("Preserved a replaced path: \(entry.url.path)")
                continue
            }
            let status = entry.isDirectory ? Darwin.rmdir(entry.url.path) : Darwin.unlink(entry.url.path)
            if status != 0 { failures.append("\(entry.url.path): \(String(cString: strerror(errno)))") }
        }
        entries.removeAll()
        return failures
    }

    private func failure(_ action: String, _ url: URL) -> LaunchServiceError {
        .unavailable("\(action) failed for \(url.path): \(String(cString: strerror(errno))).")
    }
}
