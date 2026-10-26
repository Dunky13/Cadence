import Foundation

public struct JobDraft: Sendable {
    public var name: String
    public var command: String
    public var cronExpression: String
    public var workingDirectory: URL?
    /// An existing base directory. Each job receives a new, private subdirectory.
    public var logDirectory: URL?
    public var isEnabled: Bool

    public init(name: String, command: String, cronExpression: String,
                workingDirectory: URL? = nil, logDirectory: URL? = nil, isEnabled: Bool = true) {
        self.name = name
        self.command = command
        self.cronExpression = cronExpression
        self.workingDirectory = workingDirectory
        self.logDirectory = logDirectory
        self.isEnabled = isEnabled
    }

    public func validate() throws {
        try Self.validateName(name)
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LaunchServiceError.invalidConfiguration("Enter a command to run.")
        }
        guard command.utf8.count <= 32_768, !command.contains("\0") else {
            throw LaunchServiceError.invalidConfiguration("The command must be at most 32,768 UTF-8 bytes and cannot contain a NUL character.")
        }
        _ = try CronSchedule(cronExpression)
        if let workingDirectory { try Self.validateExistingDirectory(workingDirectory, name: "Working directory") }
        if let logDirectory { try Self.validateExistingDirectory(logDirectory, name: "Log directory") }
    }

    static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80,
              name.utf8.count <= 1_024,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LaunchServiceError.invalidConfiguration("Enter a name of 1–80 characters, at most 1,024 UTF-8 bytes, without control characters.")
        }
    }

    static func validateExistingDirectory(_ url: URL, name: String) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw LaunchServiceError.invalidConfiguration("\(name) must be an absolute file directory.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LaunchServiceError.invalidConfiguration("\(name) must be an existing directory.")
        }
    }
}

public struct JobCreationResult: Sendable {
    public let job: LaunchJob
    public let warning: String?

    public init(job: LaunchJob, warning: String? = nil) {
        self.job = job
        self.warning = warning
    }
}
