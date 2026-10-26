import AppKit
import Combine
import SwiftUI

@main
enum CadenceApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let model = AppModel(isDemo: CommandLine.arguments.contains("--demo"))
    private var refreshTask: Task<Void, Never>?
    private var subscription: AnyCancellable?
    private var creationWindow: NewJobWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "Cadence")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "Cadence — your background scripts"
            button.setAccessibilityIdentifier("cadence-menu-bar")
        }
        statusItem = item
        popover.contentSize = NSSize(width: 790, height: 590)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ContentView(model: model,
            onCreateJob: { [weak self] in self?.showCreationWindow() }))
        subscription = model.$jobs.sink { [weak self] jobs in
            let enabled = jobs.filter { $0.isEnabled == true }.count
            self?.statusItem?.button?.toolTip = "Cadence — \(enabled) of \(jobs.count) scripts enabled"
        }
        if let snapshotPath = argument(after: "--snapshot") {
            Task { await captureSnapshot(at: snapshotPath) }
        } else {
            Task { await model.refresh() }
            if CommandLine.arguments.contains("--show") || model.isDemo { showPopover() }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    @objc private func showCreationWindow() {
        popover.performClose(nil)
        if creationWindow == nil {
            let controller = NewJobWindowController(appModel: model, onCreated: { [weak self] in self?.showPopover() })
            controller.onClosed = { [weak self] in self?.creationWindow = nil }
            creationWindow = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        creationWindow?.showWindow(nil)
        creationWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func installMainMenu() {
        // Text fields use the responder chain's menu actions for standard editing
        // shortcuts, including in accessory apps with no Dock icon.
        let main = NSMenu()
        let application = NSMenu(title: "Cadence")
        let quit = NSMenuItem(title: "Quit Cadence", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        application.addItem(quit)
        let applicationItem = NSMenuItem(title: "Cadence", action: nil, keyEquivalent: "")
        applicationItem.submenu = application
        main.addItem(applicationItem)

        let file = NSMenu(title: "File")
        let create = NSMenuItem(title: "New Scheduled Job…", action: #selector(showCreationWindow), keyEquivalent: "n")
        create.target = self
        create.isEnabled = !model.isDemo
        file.autoenablesItems = false
        file.addItem(create)
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        main.addItem(fileItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.model.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func applicationWillTerminate(_ notification: Notification) { refreshTask?.cancel() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { showPopover() }
        return true
    }

    private func argument(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private func captureSnapshot(at path: String) async {
        // Render the real native view in its own window; no screen-recording permission needed.
        await model.refresh()
        if CommandLine.arguments.contains("--logs") {
            model.tab = .logs
            await model.refreshLog()
        }
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        let root: AnyView
        let size: NSSize
        if CommandLine.arguments.contains("--new-job") {
            let form = NewJobFormModel()
            form.name = "Backup documents"
            form.command = "/bin/bash /path/to/backup-documents.sh"
            root = AnyView(NewJobView(form: form, appModel: model, onCancel: {}, onCreated: {}))
            size = NSSize(width: 550, height: 650)
        } else {
            root = AnyView(ContentView(model: model))
            size = NSSize(width: 790, height: 590)
        }
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        do { try await Task.sleep(for: .milliseconds(600)) } catch {}
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fputs("Unable to create native view bitmap.\n", stderr)
            NSApp.terminate(nil)
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do {
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: URL(fileURLWithPath: path))
            print("Snapshot saved: \(path)")
        } catch { fputs("Snapshot failed: \(error.localizedDescription)\n", stderr) }
        // Keep the native window alive until capture completes, then exit the QA process.
        withExtendedLifetime(window) {}
        NSApp.terminate(nil)
    }
}
