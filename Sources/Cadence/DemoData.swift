import Foundation
import LaunchCore

// Explicit, read-only demo mode. These fixtures are never mixed into live discovery.
enum DemoData {
    static let jobs: [LaunchJob] = [
        make("backup-documents", name: "Backup Documents", schedule: "Every day at 09:00", status: .waiting,
            details: ["Runs daily at 09:00, in your Mac’s local time.", "Calendar triggers missed during sleep run on wake."], runs: 12),
        make("sync-projects", name: "Sync Projects", schedule: "Every 15 minutes", status: .running,
            details: ["Interval: 900 seconds.", "Interval triggers can be skipped while asleep or already running."], runs: 48, pid: 4821),
        make("tidy-downloads", name: "Tidy Downloads", schedule: "Every Sunday at 18:30", status: .waiting,
            details: ["Calendar schedule: Sunday at 18:30."], runs: 3),
        make("refresh-dashboard", name: "Refresh Dashboard", schedule: "Every hour", status: .disabled,
            details: ["Interval: 3,600 seconds."], runs: nil),
        make("archive-notes", name: "Archive Notes", schedule: "At login", status: .waiting,
            details: ["RunAtLoad starts the job when launchd loads it, including at login."], runs: 1)
    ]

    static func log(for job: LaunchJob, stream: LogStream) -> LogSnapshot {
        let text = stream == .stdout ? """
        [09:00:00] Starting \(job.name.lowercased())
        [09:00:00] Checking source directory…
        [09:00:01] Found 142 files to process
        [09:00:01] Comparing with previous snapshot
        [09:00:02] 8 new files · 3 updated · 131 unchanged
        [09:00:03] Writing changes…
        [09:00:04] Verifying output
        [09:00:04] Everything is up to date.
        [09:00:04] Finished successfully (exit 0)
        """ : ""
        return LogSnapshot(text: text, message: text.isEmpty ? "No standard error output." : nil,
            fileURL: stream == .stdout ? job.stdoutURL : job.stderrURL,
            modifiedAt: Date(), truncated: false)
    }

    private static func make(_ slug: String, name: String, schedule: String, status: JobStatus,
                             details: [String], runs: Int?, pid: Int? = nil) -> LaunchJob {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return LaunchJob(label: "dev.example.\(slug)", name: name,
            plistURL: home.appendingPathComponent("Library/LaunchAgents/dev.example.\(slug).plist"),
            program: "/bin/zsh", arguments: ["scripts/\(slug).sh"],
            scheduleDescription: schedule, scheduleDetails: details,
            stdoutURL: home.appendingPathComponent("Library/Logs/\(slug).log"),
            stderrURL: home.appendingPathComponent("Library/Logs/\(slug).error.log"),
            isEnabled: status != .disabled, status: status, lastExitCode: status == .disabled ? nil : 0,
            pid: pid, runCount: runs, issue: nil)
    }
}
