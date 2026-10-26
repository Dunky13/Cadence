import Foundation

public enum JobStatus: String, Sendable {
    case running, waiting, disabled, unloaded, unknown
}

public struct LaunchJob: Identifiable, Hashable, Sendable {
    var configurationData: Data?
    public var id: String { plistURL.path }
    public let label: String
    public let name: String
    public let plistURL: URL
    public let program: String
    public let arguments: [String]
    public let scheduleDescription: String
    public let scheduleDetails: [String]
    public let stdoutURL: URL?
    public let stderrURL: URL?
    public let isEnabled: Bool?
    public let status: JobStatus
    public let lastExitCode: Int?
    public let pid: Int?
    public let runCount: Int?
    public let issue: String?

    public init(label: String, name: String, plistURL: URL, program: String,
                arguments: [String] = [], scheduleDescription: String,
                scheduleDetails: [String] = [], stdoutURL: URL? = nil, stderrURL: URL? = nil,
                isEnabled: Bool? = nil, status: JobStatus = .unknown,
                lastExitCode: Int? = nil, pid: Int? = nil, runCount: Int? = nil,
                issue: String? = nil) {
        self.label = label
        self.name = name
        self.plistURL = plistURL
        self.program = program
        self.arguments = arguments
        self.scheduleDescription = scheduleDescription
        self.scheduleDetails = scheduleDetails
        self.stdoutURL = stdoutURL
        self.stderrURL = stderrURL
        self.isEnabled = isEnabled
        self.status = status
        self.lastExitCode = lastExitCode
        self.pid = pid
        self.runCount = runCount
        self.issue = issue
    }
}

public struct DiscoveryResult: Sendable {
    public let jobs: [LaunchJob]
    public let warnings: [String]

    public init(jobs: [LaunchJob], warnings: [String] = []) {
        self.jobs = jobs
        self.warnings = warnings
    }
}

public enum LogStream: String, CaseIterable, Sendable {
    case stdout, stderr
}

public struct LogSnapshot: Sendable {
    public let text: String
    public let message: String?
    public let fileURL: URL?
    public let modifiedAt: Date?
    public let truncated: Bool

    public init(text: String, message: String? = nil, fileURL: URL? = nil,
                modifiedAt: Date? = nil, truncated: Bool = false) {
        self.text = text
        self.message = message
        self.fileURL = fileURL
        self.modifiedAt = modifiedAt
        self.truncated = truncated
    }
}

public enum LaunchServiceError: LocalizedError {
    case invalidConfiguration(String)
    case unavailable(String)
    case changedConfiguration
    case busy
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail), .unavailable(let detail), .commandFailed(let detail):
            return detail
        case .changedConfiguration:
            return "This job's configuration changed. Refresh the list before controlling it."
        case .busy:
            return "Another job control is still in progress. Try again when it completes."
        }
    }
}
