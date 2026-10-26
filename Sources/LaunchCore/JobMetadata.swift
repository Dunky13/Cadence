import Foundation
import CryptoKit
import Darwin

struct JobMetadata: Codable, Sendable {
    let version: Int
    let label: String
    let name: String
    let cronExpression: String
    let plistSHA256: String

    init(label: String, name: String, schedule: CronSchedule, plistData: Data) {
        version = 1
        self.label = label
        self.name = name
        cronExpression = schedule.expression
        plistSHA256 = Self.digest(plistData)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var schedule: CronSchedule { get throws { try CronSchedule(cronExpression) } }

    static func read(label: String, plistData: Data, directory: URL) -> (metadata: JobMetadata?, warning: String?) {
        let url = directory.appendingPathComponent(label).appendingPathExtension("json")
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return (nil, nil) }
            return (nil, "\(label): Could not read saved job details: \(String(cString: strerror(errno))). Using the plist configuration.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw LaunchServiceError.invalidConfiguration("Saved job details are not a regular file.")
            }
            let maximumBytes = 16 * 1024
            guard info.st_size <= maximumBytes else {
                throw LaunchServiceError.invalidConfiguration("Saved job details exceed 16 KiB.")
            }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else {
                throw LaunchServiceError.invalidConfiguration("Saved job details exceed 16 KiB.")
            }
            let metadata = try JSONDecoder().decode(Self.self, from: data)
            guard metadata.version == 1, metadata.label == label else {
                throw LaunchServiceError.invalidConfiguration("Saved job details have an unsupported version or label.")
            }
            try JobDraft.validateName(metadata.name)
            let schedule = try metadata.schedule
            guard metadata.plistSHA256 == digest(plistData) else {
                return (nil, "\(label): The plist changed since it was created. Saved name and cron details were ignored; the current plist configuration is shown.")
            }
            let configuration = try PropertyListDecoder().decode(AgentConfiguration.self, from: plistData)
            let intervals = configuration.startCalendarInterval?.entries.map { entry -> [String: Int] in
                var values: [String: Int] = [:]
                values["Minute"] = entry.minute
                values["Hour"] = entry.hour
                values["Day"] = entry.day
                values["Weekday"] = entry.weekday
                values["Month"] = entry.month
                return values
            }
            guard intervals == schedule.calendarIntervals else {
                throw LaunchServiceError.invalidConfiguration("The saved cron expression does not match the plist calendar entries.")
            }
            return (metadata, nil)
        } catch {
            return (nil, "\(label): Saved job details could not be used (\(error.localizedDescription)). Using the plist configuration.")
        }
    }

    var scheduleDetails: [String] {
        ["Cron: \(cronExpression)", "Local time zone: \(TimeZone.current.identifier)",
         "Missed calendar runs during sleep are coalesced into one run on wake."]
    }
}
