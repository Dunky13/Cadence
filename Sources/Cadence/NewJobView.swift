import AppKit
import SwiftUI
import LaunchCore

enum SchedulePreset: String, CaseIterable {
    case quarterHourly = "Every 15 minutes"
    case hourly = "Every hour"
    case daily = "Daily at 09:00"
    case weekdays = "Weekdays at 09:00"
    case custom = "Custom expression"

    var expression: String? {
        switch self {
        case .quarterHourly: return "*/15 * * * *"
        case .hourly: return "0 * * * *"
        case .daily: return "0 9 * * *"
        case .weekdays: return "0 9 * * 1-5"
        case .custom: return nil
        }
    }
}

@MainActor
final class NewJobFormModel: ObservableObject {
    @Published var name = ""
    @Published var command = ""
    @Published var expression = "*/15 * * * *"
    @Published var preset: SchedulePreset = .quarterHourly
    @Published var workingDirectory = ""
    @Published var logDirectory = ""
    @Published var isEnabled = true
    @Published var isSaving = false
    @Published var error: String?

    var schedule: CronSchedule? { try? CronSchedule(expression) }
    var scheduleError: String? {
        do { _ = try CronSchedule(expression); return nil }
        catch { return error.localizedDescription }
    }
    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a name for your job." }
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a command to run." }
        do { _ = try validatedDraft(); return nil }
        catch { return error.localizedDescription }
    }

    func validatedDraft() throws -> JobDraft {
        let draft = JobDraft(name: name.trimmingCharacters(in: .whitespacesAndNewlines), command: command,
            cronExpression: expression, workingDirectory: try directoryURL(workingDirectory),
            logDirectory: try directoryURL(logDirectory), isEnabled: isEnabled)
        try draft.validate()
        return draft
    }

    func applyPreset(_ preset: SchedulePreset) {
        if let expression = preset.expression { self.expression = expression }
    }

    func reconcilePreset() {
        preset = SchedulePreset.allCases.first { $0.expression == expression } ?? .custom
    }

    static func quotePath(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func directoryURL(_ text: String) throws -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let path = NSString(string: text).expandingTildeInPath
        guard path.hasPrefix("/") else {
            throw LaunchServiceError.invalidConfiguration("Folder paths must start with / or ~/.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

struct NewJobView: View {
    @ObservedObject var form: NewJobFormModel
    let appModel: AppModel
    let onCancel: () -> Void
    let onCreated: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "calendar.badge.plus").font(.system(size: 23)).foregroundStyle(Theme.accent)
                    .frame(width: 42, height: 42)
                    .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Create a scheduled job").font(.system(size: 21, weight: .semibold)).tracking(-0.5)
                    Text("A command, a schedule, and a place for its output.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 21) {
                    if let error = form.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionCaption(text: "Job name")
                        TextField("For example, Backup documents", text: $form.name)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("new-job-name")
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            SectionCaption(text: "Schedule")
                            Spacer()
                            Picker("Schedule preset", selection: $form.preset) {
                                ForEach(SchedulePreset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().frame(width: 181).controlSize(.small)
                        }
                        TextField("*/15 * * * *", text: $form.expression)
                            .font(.system(size: 14, design: .monospaced)).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("new-job-cron")
                        Text("minute   hour   day   month   weekday")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        if let schedule = form.schedule {
                            Label(schedule.summary, systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.green)
                        } else if let error = form.scheduleError {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        Text("Supports numbers, *, lists, ranges, and steps. Uses your Mac’s time zone; a time missed during sleep runs on wake.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionCaption(text: "Command")
                            Spacer()
                            Button("Choose file…") { chooseCommand() }.font(.system(size: 11)).buttonStyle(.link)
                        }
                        CommandEditor(text: $form.command).padding(6).frame(height: 73)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.separator))
                            .accessibilityLabel("Command").accessibilityIdentifier("new-job-command")
                        Text("Runs in /bin/zsh with a fixed PATH. Use full paths and an executable script, or include its interpreter, such as /bin/bash.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup("Folders and logs") {
                        VStack(alignment: .leading, spacing: 13) {
                            folderField("Working folder", placeholder: "Your home folder", text: $form.workingDirectory)
                            folderField("Log folder", placeholder: "Automatic · Library/Logs/Cadence", text: $form.logDirectory)
                            Text("Standard output and errors are captured in a separate folder for this job.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.top, 11)
                    }.font(.system(size: 12))
                    Toggle("Enable after creating", isOn: $form.isEnabled).toggleStyle(.switch).controlSize(.small)
                        .font(.system(size: 12)).accessibilityIdentifier("new-job-enabled")
                    Text("Creates a native LaunchAgent. Your command runs on its schedule; creation does not request an extra run.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(22).disabled(form.isSaving)
            }
            Divider()
            HStack(spacing: 10) {
                if form.isSaving {
                    ProgressView().controlSize(.small)
                    Text("Saving job…").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if let message = form.validationMessage {
                    Text(message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 5)
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction).disabled(form.isSaving)
                Button("Create job", action: create).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(form.isSaving || form.validationMessage != nil || appModel.isDemo)
                    .accessibilityIdentifier("create-job-submit")
            }.padding(.horizontal, 20).padding(.vertical, 15)
        }
        .frame(minWidth: 500, minHeight: 480)
        .background(Theme.canvas).tint(Theme.accent)
        .onChange(of: form.preset) { _, preset in form.applyPreset(preset) }
        .onChange(of: form.expression) { _, _ in form.reconcilePreset() }
    }

    private func create() {
        do {
            let draft = try form.validatedDraft()
            form.isSaving = true
            form.error = nil
            Task { @MainActor in
                do {
                    _ = try await appModel.createJob(draft)
                    form.isSaving = false
                    onCreated()
                } catch {
                    form.error = error.localizedDescription
                    form.isSaving = false
                }
            }
        } catch { form.error = error.localizedDescription }
    }

    private func folderField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.system(size: 11))
                Button { chooseFolder(text: text) } label: { Image(systemName: "folder") }
                    .help("Choose \(title.lowercased())").accessibilityLabel("Choose \(title.lowercased())")
            }
        }
    }

    private func chooseCommand() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose command"
        present(panel) { if let url = panel.url { form.command = NewJobFormModel.quotePath(url.path) } }
    }

    private func chooseFolder(text: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose folder"
        present(panel) { if let url = panel.url { text.wrappedValue = url.path } }
    }

    private func present(_ panel: NSOpenPanel, selected: @escaping () -> Void) {
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in if response == .OK { selected() } }
        } else if panel.runModal() == .OK { selected() }
    }
}

@MainActor
final class NewJobWindowController: NSWindowController, NSWindowDelegate {
    private let form = NewJobFormModel()
    var onClosed: (() -> Void)?

    init(appModel: AppModel, onCreated: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "New scheduled job"
        window.minSize = NSSize(width: 520, height: 520)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: NewJobView(form: form, appModel: appModel,
            onCancel: { [weak self] in self?.close() }, onCreated: { [weak self] in self?.close(); onCreated() }))
        window.center()
    }

    required init?(coder: NSCoder) { return nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !form.isSaving }
    func windowWillClose(_ notification: Notification) { onClosed?() }
}
