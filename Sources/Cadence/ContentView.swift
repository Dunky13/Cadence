import AppKit
import SwiftUI
import LaunchCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    var onCreateJob: () -> Void = {}
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.error {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.system(size: 11)).textSelection(.enabled).lineLimit(4)
                    Spacer(minLength: 0)
                    Button { model.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }.padding(12).background(Color.orange.opacity(0.08))
                Divider()
            }
            HStack(spacing: 0) {
                sidebar.frame(width: 270)
                Divider()
                if let job = model.selectedJob {
                    JobDetailView(model: model, job: job)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyMessage(symbol: "terminal", title: model.jobs.isEmpty ? "A home for your scripts" : "No matching scripts",
                        message: model.jobs.isEmpty
                            ? "Your user LaunchAgents will appear here, with their schedules and output in one place."
                            : "Try a different search or filter.")
                }
            }.frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 790, height: 590)
        .background(Theme.canvas)
        .tint(Theme.accent)
        .onChange(of: model.query) { _, _ in model.reconcileSelection() }
        .onChange(of: model.filter) { _, _ in model.reconcileSelection() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path")
                .font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("Cadence").font(.system(size: 19, weight: .semibold)).tracking(-0.5)
                Text("A little order for your background work.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isDemo {
                Text("DEMO").font(.system(size: 10, weight: .semibold)).tracking(1)
                    .foregroundStyle(Theme.accent).padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Theme.accent.opacity(0.08), in: Capsule())
            } else if model.runningCount > 0 {
                HStack(spacing: 5) {
                    Circle().fill(Theme.green).frame(width: 5, height: 5)
                    Text("\(model.runningCount) running").font(.system(size: 11))
                }.foregroundStyle(.secondary)
            }
            Button(action: onCreateJob) {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(width: 26, height: 26)
            }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.isDemo)
                .help("Create a scheduled job (⌘N)").accessibilityLabel("New scheduled job")
                .accessibilityIdentifier("new-job").keyboardShortcut("n")
            Menu {
                Button("New Scheduled Job…", systemImage: "plus", action: onCreateJob).disabled(model.isDemo)
                Divider()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                Button("Open LaunchAgents Folder…", systemImage: "folder") { model.openDirectory() }
                Divider()
                Button("About Cadence") { showAbout() }
                Button("Quit Cadence", systemImage: "power") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis").font(.system(size: 16)).frame(width: 26, height: 26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Cadence menu")
        }.padding(.horizontal, 20).frame(height: 76)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionCaption(text: "Your scripts")
                Spacer()
                Text("\(model.jobs.count)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }.padding(.top, 19)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a script…", text: $model.query).textFieldStyle(.plain)
                    .accessibilityIdentifier("script-search")
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }.font(.system(size: 12)).padding(9)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.separator))
            Picker("Filter scripts", selection: $model.filter) {
                ForEach(JobFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .accessibilityIdentifier("script-filter")
            if model.isRefreshing && model.jobs.isEmpty {
                ProgressView("Reading LaunchAgents…").font(.system(size: 11)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleJobs.isEmpty {
                VStack(spacing: 10) {
                    Text(model.jobs.isEmpty ? "No user LaunchAgents yet." : "No scripts found.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if model.jobs.isEmpty {
                        Button("Create a scheduled job", action: onCreateJob).controlSize(.small).disabled(model.isDemo)
                        Button("Open LaunchAgents Folder") { model.openDirectory() }.controlSize(.small)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.visibleJobs) { job in
                            JobRow(model: model, job: job)
                        }
                    }.padding(.vertical, 2)
                }.scrollIndicators(.hidden).padding(.horizontal, -7)
            }
            if !model.warnings.isEmpty {
                Menu {
                    ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in Text(warning) }
                } label: {
                    Label("\(model.warnings.count) discovery \(model.warnings.count == 1 ? "notice" : "notices")", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle")
                Text("User LaunchAgents only")
            }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 14)
        }.padding(.horizontal, 17)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(model.isDemo ? Theme.accent : Theme.green).frame(width: 5, height: 5)
            Text(model.isDemo ? "Demo · sample scripts, controls disabled" : "\(model.enabledCount) of \(model.jobs.count) enabled")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
                Text("Refreshing…").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if let date = model.updatedAt {
                Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 22, height: 22)
            }.buttonStyle(.plain).disabled(model.isRefreshing || !model.busyJobs.isEmpty)
                .help("Refresh scripts and logs (⌘R)").accessibilityLabel("Refresh")
                .keyboardShortcut("r")
        }.padding(.horizontal, 18).frame(height: 35)
    }

    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Cadence"
        alert.informativeText = "A small home for your user LaunchAgents.\n\nCreate jobs with cron schedules, read output files, and enable or disable jobs. Disabling unloads a job and stops its running process.\n\nVersion 0.2.0 · macOS 14 or later"
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }
}

private struct JobRow: View {
    @ObservedObject var model: AppModel
    let job: LaunchJob
    var body: some View {
        HStack(spacing: 9) {
            Button { model.selectedID = job.id } label: {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "terminal")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(model.selectedID == job.id ? Theme.accent : Color.secondary)
                        .frame(width: 25, height: 27)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(job.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(job.scheduleDescription).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        StatusLabel(job: job).padding(.top, 1)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(job.name), \(job.scheduleDescription), \(job.status.title)")
            if model.busyJobs.contains(job.id) {
                ProgressView().controlSize(.mini).frame(width: 28)
            } else {
                Toggle("Enable \(job.name)", isOn: Binding(get: { job.isEnabled == true }, set: { model.setEnabled($0, job: job) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    .disabled(model.isDemo || job.isEnabled == nil || model.isRefreshing || !model.busyJobs.isEmpty)
                    .help(job.isEnabled == nil ? "Status unavailable; refresh before changing this job."
                        : "\(job.isEnabled == true ? "Disable and stop" : "Enable") \(job.name). This persists after restart.")
                    .accessibilityIdentifier("toggle-\(job.label)")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 11)
        .background(model.selectedID == job.id ? Theme.accent.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(model.selectedID == job.id ? Theme.accent.opacity(0.13) : .clear))
        .contextMenu {
            Button("Reveal LaunchAgent in Finder") { model.reveal(job.plistURL) }
        }
    }
}
