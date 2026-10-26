import AppKit
import SwiftUI
import LaunchCore

struct JobDetailView: View {
    @ObservedObject var model: AppModel
    let job: LaunchJob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.name).font(.system(size: 23, weight: .semibold)).tracking(-0.7).lineLimit(2)
                    Text(job.label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if job.isEnabled == false && (job.status == .running || job.status == .waiting) {
                    Button { model.setEnabled(false, job: job) } label: {
                        Label("Stop & disable", systemImage: "stop.fill").font(.system(size: 11, weight: .medium))
                    }.buttonStyle(.bordered).controlSize(.small)
                        .disabled(model.isDemo || model.isRefreshing || !model.busyJobs.isEmpty)
                        .help("Unload this job so its existing instance and triggers stop.")
                } else {
                    Button { model.runNow(job) } label: {
                        Label("Run now", systemImage: "play.fill").font(.system(size: 11, weight: .medium))
                    }.buttonStyle(.bordered).controlSize(.small)
                        .disabled(model.isDemo || job.isEnabled != true || job.status == .running
                            || job.status == .unknown || model.isRefreshing || !model.busyJobs.isEmpty)
                        .help("Ask launchd to run this job now. An existing run is never restarted.")
                        .accessibilityIdentifier("run-now")
                }
            }.padding(.top, 23).padding(.bottom, 20)
            HStack {
                Picker("Script details", selection: $model.tab) {
                    ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 177).controlSize(.small)
                    .accessibilityIdentifier("detail-tabs")
                Spacer()
                StatusLabel(job: job)
            }.padding(.bottom, 18)
            if model.tab == .overview { overview } else { logs }
        }
        .padding(.horizontal, 23).padding(.bottom, 19)
        .background(Theme.surface.opacity(0.45))
        .task(id: "\(job.id)|\(model.stream.rawValue)|\(model.tab.rawValue)") {
            model.clearLog()
            if model.tab == .logs { await model.refreshLog() }
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("EXECUTION CADENCE", systemImage: "clock")
                        .font(.system(size: 10, weight: .semibold)).tracking(0.9).foregroundStyle(Theme.accent)
                    Text(job.scheduleDescription).font(.system(size: 17, weight: .medium)).tracking(-0.3)
                    ForEach(Array(job.scheduleDetails.enumerated()), id: \.offset) { _, detail in
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .background(Theme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 11) {
                    SectionCaption(text: "At a glance")
                    metadata("Current state", value: stateDescription)
                    metadata("Previous exit", value: job.lastExitCode.map { $0 == 0 ? "0 · successful" : "\($0) · nonzero exit" } ?? "Not reported by launchd")
                    if let pid = job.pid { metadata("Process ID", value: String(pid)) }
                    if let count = job.runCount { metadata("Runs since load", value: String(count)) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        SectionCaption(text: "LaunchAgent")
                        Spacer()
                        Button { model.reveal(job.plistURL) } label: {
                            Label("Reveal", systemImage: "arrow.up.forward.square").font(.system(size: 10))
                        }.buttonStyle(.plain).foregroundStyle(.secondary).help("Show the plist in Finder")
                    }
                    Text(job.plistURL.lastPathComponent).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    Text(job.program).font(.system(size: 11, design: .monospaced)).lineLimit(3)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if !job.arguments.isEmpty {
                        Text(job.arguments.joined(separator: "  "))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(5)
                    }
                }
                if let issue = job.issue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                }
                Label("Disabling a script stops its running process and keeps it disabled after restart.", systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.bottom, 2)
        }.scrollIndicators(.automatic)
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Output stream", selection: $model.stream) {
                    Text("Standard output").tag(LogStream.stdout)
                    Text("Standard error").tag(LogStream.stderr)
                }.labelsHidden().controlSize(.small).frame(width: 162)
                    .accessibilityIdentifier("log-stream")
                Spacer()
                if model.isReadingLog { ProgressView().controlSize(.mini) }
                Button {
                    guard let log = model.log else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(model.log?.text.isEmpty != false)
                    .help("Copy displayed log").accessibilityLabel("Copy displayed log")
                Button { Task { await model.refreshLog() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.isReadingLog)
                    .help("Refresh output").accessibilityLabel("Refresh output")
            }
            if let log = model.log {
                if !log.text.isEmpty {
                    ScrollView([.horizontal, .vertical]) {
                        Text(log.text).font(.system(size: 10.5, design: .monospaced)).lineSpacing(5)
                            .foregroundStyle(Color(red: 0.81, green: 0.85, blue: 0.83))
                            .textSelection(.enabled)
                            .frame(minWidth: 400, maxWidth: .infinity, alignment: .topLeading)
                            .padding(14)
                    }
                    .background(Color(red: 0.10, green: 0.12, blue: 0.115), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(alignment: .topTrailing) {
                        Text(model.stream == .stdout ? "STDOUT" : "STDERR")
                            .font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1)
                            .foregroundStyle(.white.opacity(0.35)).padding(10)
                            .allowsHitTesting(false)
                    }
                } else {
                    EmptyMessage(symbol: "text.alignleft", title: log.fileURL == nil ? "No log file configured" : "No output to show",
                        message: log.message ?? "The configured file has no output yet.")
                        .background(Theme.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                }
                if !log.text.isEmpty, let message = log.message {
                    Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let url = log.fileURL {
                    Button { model.reveal(url) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text")
                            Text(url.lastPathComponent).lineLimit(1)
                            Image(systemName: "arrow.up.forward.square").font(.system(size: 8))
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help(url.path)
                }
                HStack {
                    Text(log.truncated ? "Showing the end of the file" : "Output from the configured log file")
                    Spacer()
                    if let modified = log.modifiedAt {
                        Text("Modified \(modified.formatted(date: .omitted, time: .shortened))")
                    }
                }.font(.system(size: 9)).foregroundStyle(.tertiary)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxHeight: .infinity)
    }

    private func metadata(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 15)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 11))
    }

    private var stateDescription: String {
        switch job.status {
        case .running: return "Running now"
        case .waiting: return "Loaded · waiting for a trigger"
        case .disabled: return "Disabled in launchd"
        case .unloaded: return "Enabled · not loaded"
        case .unknown: return "Could not read status"
        }
    }
}
