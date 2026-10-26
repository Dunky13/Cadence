import Foundation

/// Decodes only launchd's documented keys; unknown keys are left to launchd.
struct AgentConfiguration: Decodable, Sendable {
    let label: String
    let program: String?
    let programArguments: [String]?
    let disabled: Bool?
    let startInterval: Int?
    let startCalendarInterval: CalendarSchedule?
    let runAtLoad: Bool?
    let keepAlive: KeepAlive?
    let watchPaths: [String]?
    let queueDirectories: [String]?
    let startOnMount: Bool?
    let stdoutPath: String?
    let stderrPath: String?
    let workingDirectory: String?
    let machServices: [String: PropertyValue]?
    let sockets: [String: PropertyValue]?

    enum CodingKeys: String, CodingKey {
        case label = "Label", program = "Program", programArguments = "ProgramArguments"
        case disabled = "Disabled", startInterval = "StartInterval"
        case startCalendarInterval = "StartCalendarInterval", runAtLoad = "RunAtLoad"
        case keepAlive = "KeepAlive", watchPaths = "WatchPaths", queueDirectories = "QueueDirectories"
        case startOnMount = "StartOnMount", stdoutPath = "StandardOutPath"
        case stderrPath = "StandardErrorPath", workingDirectory = "WorkingDirectory"
        case machServices = "MachServices", sockets = "Sockets"
    }

    static func read(_ url: URL) throws -> AgentConfiguration {
        try readSnapshot(url).configuration
    }

    static func readSnapshot(_ url: URL) throws -> (configuration: AgentConfiguration, data: Data) {
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw LaunchServiceError.invalidConfiguration("The configuration is not a regular file.")
        }
        guard let size = values.fileSize, size <= 2 * 1024 * 1024 else {
            throw LaunchServiceError.invalidConfiguration("The configuration is larger than 2 MB.")
        }
        let data = try Data(contentsOf: url)
        let configuration = try PropertyListDecoder().decode(Self.self, from: data)
        try configuration.validate()
        return (configuration, data)
    }

    func validate() throws {
        guard !label.isEmpty, !label.contains("/"), !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LaunchServiceError.invalidConfiguration("Label must be nonempty and cannot contain a slash or control character.")
        }
        guard let executable = program ?? programArguments?.first, !executable.isEmpty else {
            throw LaunchServiceError.invalidConfiguration("The job needs Program or a nonempty ProgramArguments array.")
        }
        if let startInterval, startInterval <= 0 {
            throw LaunchServiceError.invalidConfiguration("StartInterval must be greater than zero.")
        }
        try startCalendarInterval?.entries.forEach { try $0.validate() }
    }

    var executable: String { program ?? programArguments?.first ?? "" }
    var arguments: [String] { programArguments ?? [] }

    var launchesAtLoad: Bool {
        if runAtLoad == true { return true }
        switch keepAlive {
        case .flag(true): return true
        case .conditions(let values): return !values.isEmpty
        default: return false
        }
    }

    var friendlyName: String {
        let suffix = label.split(separator: ".").last.map(String.init) ?? label
        let words = suffix.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    var scheduleDetails: [String] {
        var details: [String] = []
        if let startInterval { details.append(Self.intervalDescription(startInterval)) }
        if let calendar = startCalendarInterval { details += calendar.entries.map(\.description) }
        if runAtLoad == true { details.append("When loaded / at login") }
        if let keepAlive {
            switch keepAlive {
            case .flag(true): details.append("Kept running continuously")
            case .conditions(let conditions) where !conditions.isEmpty:
                details.append("Kept alive when launchd conditions match (" + conditions.keys.sorted().joined(separator: ", ") + ")")
            default: break
            }
        }
        if let watchPaths, !watchPaths.isEmpty {
            details.append("When watched paths change (\(watchPaths.count))")
        }
        if let queueDirectories, !queueDirectories.isEmpty {
            details.append("While watched directories are nonempty (\(queueDirectories.count))")
        }
        if startOnMount == true { details.append("When a filesystem is mounted") }
        if let machServices, !machServices.isEmpty { details.append("On demand via Mach services") }
        if let sockets, !sockets.isEmpty { details.append("On demand via sockets") }
        return details.isEmpty ? ["On demand"] : details
    }

    var scheduleDescription: String {
        let details = scheduleDetails
        return details.count == 1 ? details[0] : "\(details[0]) · +\(details.count - 1) trigger\(details.count == 2 ? "" : "s")"
    }

    static func intervalDescription(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 { return "Every \(seconds / 86_400) day\(seconds == 86_400 ? "" : "s")" }
        if seconds % 3_600 == 0 { return "Every \(seconds / 3_600) hour\(seconds == 3_600 ? "" : "s")" }
        if seconds % 60 == 0 { return "Every \(seconds / 60) minute\(seconds == 60 ? "" : "s")" }
        return "Every \(seconds) second\(seconds == 1 ? "" : "s")"
    }

    func logURL(for stream: LogStream) -> URL? {
        guard let path = stream == .stdout ? stdoutPath : stderrPath, !path.isEmpty else { return nil }
        // launchd does not expand ~ or environment variables in these paths.
        guard path.hasPrefix("/") else {
            if let workingDirectory, workingDirectory.hasPrefix("/") {
                return URL(fileURLWithPath: workingDirectory, isDirectory: true).appendingPathComponent(path)
            }
            return URL(fileURLWithPath: "/", isDirectory: true).appendingPathComponent(path)
        }
        return URL(fileURLWithPath: path)
    }
}

enum PropertyValue: Decodable, Sendable {
    case bool(Bool), integer(Int), string(String), array([PropertyValue]), dictionary([String: PropertyValue]), real(Double), data(Data), date(Date)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: PropertyValue].self) { self = .dictionary(value) }
        else if let value = try? container.decode([PropertyValue].self) { self = .array(value) }
        else if let value = try? container.decode(Double.self) { self = .real(value) }
        else if let value = try? container.decode(Data.self) { self = .data(value) }
        else { self = .date(try container.decode(Date.self)) }
    }
}

enum KeepAlive: Decodable, Sendable {
    case flag(Bool), conditions([String: PropertyValue])
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) { self = .flag(flag) }
        else { self = .conditions(try container.decode([String: PropertyValue].self)) }
    }
}

enum CalendarSchedule: Decodable, Sendable {
    case one(CalendarEntry), multiple([CalendarEntry])
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let entries = try? container.decode([CalendarEntry].self) { self = .multiple(entries) }
        else { self = .one(try container.decode(CalendarEntry.self)) }
    }
    var entries: [CalendarEntry] {
        switch self { case .one(let entry): return [entry]; case .multiple(let entries): return entries }
    }
}

struct CalendarEntry: Decodable, Sendable {
    let minute: Int?
    let hour: Int?
    let day: Int?
    let weekday: Int?
    let month: Int?

    enum CodingKeys: String, CodingKey {
        case minute = "Minute", hour = "Hour", day = "Day", weekday = "Weekday", month = "Month"
    }

    func validate() throws {
        for (name, value, range) in [("Minute", minute, 0...59), ("Hour", hour, 0...23), ("Day", day, 1...31), ("Weekday", weekday, 0...7), ("Month", month, 1...12)] {
            if let value, !range.contains(value) {
                throw LaunchServiceError.invalidConfiguration("StartCalendarInterval \(name) is outside \(range).")
            }
        }
    }

    var description: String {
        let time: String
        switch (hour, minute) {
        case (.some(let h), .some(let m)): time = String(format: "%02d:%02d", h, m)
        case (.none, .some(let m)): time = String(format: "Every hour at :%02d", m)
        case (.some(let h), .none): time = String(format: "Every minute during %02d:00–%02d:59", h, h)
        case (.none, .none): time = "Every minute"
        }
        var dateParts: [String] = []
        if let month { dateParts.append("month \(month)") }
        if let day { dateParts.append("day \(day)") }
        if let weekday {
            let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
            let value = days.indices.contains(weekday) ? days[weekday] : "weekday \(weekday)"
            if day != nil { dateParts.append("or \(value)") }
            else { dateParts.append(value) }
        }
        if dateParts.isEmpty, hour != nil, minute != nil { return "Daily at \(time)" }
        return dateParts.isEmpty ? time : "\(time) · \(dateParts.joined(separator: " "))"
    }
}
