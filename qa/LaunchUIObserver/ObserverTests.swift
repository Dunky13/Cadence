import AppKit
import CryptoKit
import Security
import ScreenCaptureKit
import XCTest

// This target deliberately contains no UI actions, interruption handlers, app
// launch/activation, AX trust requests, or authorization resets.
@MainActor
final class ObserverTests: XCTestCase {
    struct Binding: Codable {
        let bundleID, teamID, version, build, executableSHA256: String
        let copiedPath, snapshotPath, observationID: String
    }
    struct Launch: Codable { let launcherPID: Int32 }
    struct OwnedProcess: Codable {
        let pid: Int32
        let executable, state: String
    }
    struct Owner: Codable {
        let pid: Int32
        let bundleID, executable, applicationPath: String
    }
    struct Node: Codable, Equatable {
        let type: UInt
        let label, title: String
        let children: [Node]
        let truncated: Bool
    }
    struct WindowIdentity { let id: UInt32; let pid: Int32; let frame: CGRect }
    struct Window: Codable {
        let owner: Owner
        let tree: Node
        let screenshot: String
        let windowID: UInt32?
    }
    struct CaptureResult {
        let imageAvailable, complete: Bool
    }
    struct ObservationProgress {
        private(set) var imageAvailable = false
        private(set) var complete = true
        var observed: Bool { imageAvailable && complete }
        mutating func include(_ sample: CaptureResult) {
            imageAvailable = imageAvailable || sample.imageAvailable
            complete = complete && sample.complete
        }
    }
    struct Observation: Codable {
        let binding: Binding
        let launcherPID: Int32
        let capturedUTC: String
        let ownedProcesses: [OwnedProcess]
        let windows: [Window]
        let unavailableOwners: [Owner]
        let limited: Bool
        let complete: Bool
        let interpretation: String
    }

    private let files = FileManager.default
    private var control: URL!
    private var evidence: URL!

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func text(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: control.appendingPathComponent(name)))
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func signing(_ url: URL, requirement: String) -> Bool {
        var code: SecStaticCode?
        var rule: SecRequirement?
        return SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess
            && SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess
            && code != nil && rule != nil
            && SecStaticCodeCheckValidity(code!, [], rule!) == errSecSuccess
    }

    private func validCandidate(_ app: URL, _ binding: Binding) -> Bool {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == binding.bundleID,
              info["CFBundleShortVersionString"] as? String == binding.version,
              info["CFBundleVersion"] as? String == binding.build,
              (try? digest(app.appendingPathComponent("Contents/MacOS/Cadence"))) == binding.executableSHA256
        else { return false }
        return signing(app, requirement: "anchor apple generic and identifier \"\(binding.bundleID)\" and certificate leaf[subject.OU] = \"\(binding.teamID)\"")
    }

    private func ps(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "ProcessQueryUnavailable", code: 1) }
        return String(decoding: data, as: UTF8.self)
    }

    private func ownedProcesses(_ binding: Binding) throws -> [OwnedProcess] {
        var owned: [OwnedProcess] = []
        let original = binding.copiedPath + "/Contents/MacOS/Cadence"
        for line in try ps(["-axo", "pid=,comm="]).split(separator: "\n") {
            let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = Int32(fields[0]), pid > 1 else { continue }
            let executable = String(fields[1])
            guard executable == original || (executable.contains("/AppTranslocation/") && executable.hasSuffix("/d/Cadence.app/Contents/MacOS/Cadence")) else { continue }
            let arguments = try ps(["-p", String(pid), "-o", "command="]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !arguments.isEmpty else { throw NSError(domain: "ProcessQueryUnavailable", code: 1) }
            guard arguments == "\(executable) --demo --snapshot \(binding.snapshotPath)" else { continue }
            let app = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard validCandidate(app, binding) else { throw NSError(domain: "CandidateIdentityMismatch", code: 1) }
            let state = try ps(["-p", String(pid), "-o", "stat="]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !state.isEmpty else { throw NSError(domain: "ProcessQueryUnavailable", code: 1) }
            owned.append(OwnedProcess(pid: pid, executable: executable, state: state))
        }
        return owned
    }

    private func systemOwners() throws -> [Owner] {
        // Discover actual owners on this image. No assumed security-agent name,
        // button title, or OS-version-specific prompt classification.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw NSError(domain: "SystemWindowQueryUnavailable", code: 1)
        }
        let visible = Set(windows.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value })
        let running = NSWorkspace.shared.runningApplications
        return running.compactMap { app -> Owner? in
            guard visible.contains(app.processIdentifier), let url = app.bundleURL, let executable = app.executableURL,
                  let id = app.bundleIdentifier,
                  ["/System/Library/", "/System/Applications/", "/usr/libexec/", "/Library/Apple/System/"].contains(where: { executable.path.hasPrefix($0) }),
                  running.filter({ $0.bundleURL == url }).count == 1,
                  signing(url, requirement: "anchor apple") else { return nil }
            return Owner(pid: app.processIdentifier, bundleID: id, executable: executable.path, applicationPath: url.path)
        }.sorted { $0.pid < $1.pid }
    }

    private func safeTree(_ snapshot: XCUIElementSnapshot, budget: inout Int, depth: Int = 0) -> Node {
        budget -= 1
        // Never retain values, editable text, placeholders, or identifiers.
        let readable: Set<XCUIElement.ElementType> = [.window, .dialog, .alert, .sheet, .button, .staticText]
        let show = readable.contains(snapshot.elementType)
        let children = depth < 16 ? snapshot.children.prefix(128).compactMap { child -> Node? in
            guard budget > 0 else { return nil }
            return safeTree(child, budget: &budget, depth: depth + 1)
        } : []
        return Node(type: snapshot.elementType.rawValue,
                    label: show ? String(snapshot.label.prefix(2048)) : "",
                    title: show ? String(snapshot.title.prefix(2048)) : "", children: children,
                    truncated: (show && (snapshot.label.count > 2048 || snapshot.title.count > 2048))
                        || children.count < snapshot.children.count || children.contains(where: { $0.truncated }))
    }

    private func permissionRequest(_ node: Node) -> Bool {
        // Conservative HOLD for authority/password UI; never handles/dismisses it.
        let words = (node.label + " " + node.title).lowercased()
        return node.type == XCUIElement.ElementType.secureTextField.rawValue
            || ["password", "authenticate", "authentication", "automation mode", "accessibility access", "would like to control", "permission to"].contains(where: words.contains)
            || node.children.contains(where: permissionRequest)
    }

    private func editableContent(_ node: Node) -> Bool {
        let editable: [XCUIElement.ElementType] = [.textField, .secureTextField, .textView, .comboBox]
        return editable.contains { $0.rawValue == node.type } || node.children.contains(where: editableContent)
    }

    private func captureWindowID(_ windows: [WindowIdentity], pid: Int32, frame: CGRect) -> UInt32? {
        guard pid > 1, !frame.isEmpty, frame.width.isFinite, frame.height.isFinite,
              frame.width <= 4096, frame.height <= 4096 else { return nil }
        let matches = windows.filter { $0.id > 0 && $0.pid == pid && $0.frame == frame }
        return matches.count == 1 ? matches[0].id : nil
    }

    private func isolatedWindowImage(_ owner: Owner, _ element: XCUIElement, _ tree: Node) async throws -> (UInt32, Data)? {
        // Never request screen-recording permission. XCTest element screenshots
        // crop the desktop and may include an overlapping editable window.
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let frame = element.frame
        let identities = content.windows.compactMap { window -> WindowIdentity? in
            guard let pid = window.owningApplication?.processID else { return nil }
            return WindowIdentity(id: window.windowID, pid: pid, frame: window.frame)
        }
        guard let id = captureWindowID(identities, pid: owner.pid, frame: frame),
              let window = content.windows.first(where: { $0.windowID == id }),
              frame.width <= 4096, frame.height <= 4096 else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(frame.width.rounded(.up)))
        config.height = max(1, Int(frame.height.rounded(.up)))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        var budget = 1024
        let after = safeTree(try element.snapshot(), budget: &budget)
        guard after == tree, !after.truncated, !editableContent(after), !permissionRequest(after),
              NSRunningApplication(processIdentifier: owner.pid)?.executableURL?.path == owner.executable,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return nil }
        return (id, png)
    }

    private func capture(_ binding: Binding, _ launch: Launch, index: Int) async throws -> CaptureResult {
        guard validCandidate(URL(fileURLWithPath: binding.copiedPath), binding) else {
            throw NSError(domain: "CopiedCandidateIdentityMismatch", code: 1)
        }
        let owned = try ownedProcesses(binding)
        let owners = try systemOwners()
        var windows: [Window] = []
        var unavailable: [Owner] = []
        var images: [(String, Data)] = []
        var limited = owners.count > 16
        for owner in owners.prefix(16) {
            guard NSRunningApplication(processIdentifier: owner.pid)?.executableURL?.path == owner.executable else {
                unavailable.append(owner); continue
            }
            let proxy = XCUIApplication(url: URL(fileURLWithPath: owner.applicationPath))
            do {
                let elements = proxy.windows.allElementsBoundByIndex
                limited = limited || elements.count > 8
                if elements.isEmpty { unavailable.append(owner) }
                for (number, element) in elements.prefix(8).enumerated() {
                    var budget = 1024
                    let tree = safeTree(try element.snapshot(), budget: &budget)
                    limited = limited || tree.truncated
                    guard !tree.truncated else { throw NSError(domain: "IncompleteSystemUIHOLD", code: 1) }
                    guard !permissionRequest(tree) else { throw NSError(domain: "UIAuthorityRequestHOLD", code: 1) }
                    // Bind an isolated window surface; never capture the desktop
                    // rectangle behind an occluded element. Missing existing
                    // authorization or an ambiguous/changing surface stays HOLD.
                    var isolated: (UInt32, Data)?
                    if !tree.truncated && !editableContent(tree) {
                        isolated = try? await isolatedWindowImage(owner, element, tree)
                    }
                    let name = isolated == nil ? "" : "system-\(index)-\(owner.pid)-\(number).png"
                    guard NSRunningApplication(processIdentifier: owner.pid)?.executableURL?.path == owner.executable else {
                        unavailable.append(owner); continue
                    }
                    windows.append(Window(owner: owner, tree: tree, screenshot: name, windowID: isolated?.0))
                    if let isolated { images.append((name, isolated.1)) }
                }
            } catch {
                if ["UIAuthorityRequestHOLD", "IncompleteSystemUIHOLD"].contains((error as NSError).domain) { throw error }
                unavailable.append(owner)
            }
        }
        // A system window can be temporally correlated to this launch; its tree
        // alone does not prove that it belongs to Cadence or classify consent.
        let complete = !limited && unavailable.isEmpty && windows.allSatisfy { !$0.screenshot.isEmpty }
        let observation = Observation(binding: binding, launcherPID: launch.launcherPID,
            capturedUTC: ISO8601DateFormatter().string(from: Date()), ownedProcesses: owned,
            windows: windows, unavailableOwners: unavailable, limited: limited, complete: complete,
            interpretation: "Read-only system UI observation; window ownership is Apple-signature/PID bound. Candidate causality and button meaning are unclassified. No runtime acceptance.")
        try write(observation, to: evidence.appendingPathComponent("observation-\(index).json"))
        for (name, data) in images { try data.write(to: evidence.appendingPathComponent(name), options: .atomic) }
        return CaptureResult(imageAvailable: !images.isEmpty, complete: complete)
    }

    func testObserveExistingLaunch() async throws {
        do {
            try await observeExistingLaunch()
        } catch {
            if let evidence {
                let known = ["CandidateIdentityMismatch", "CopiedCandidateIdentityMismatch", "UIAuthorityRequestHOLD", "IncompleteSystemUIHOLD", "ProcessQueryUnavailable", "SystemWindowQueryUnavailable", "InvalidLauncher"]
                let domain = (error as NSError).domain
                let reason = known.contains(domain) ? domain : "native-query-or-protocol-failure"
                try? text("HOLD: \(reason); no UI action or permission grant.\n", to: evidence.appendingPathComponent("session.txt"))
            }
            throw error
        }
    }

    private func observeExistingLaunch() async throws {
        continueAfterFailure = false
        executionTimeAllowance = 90
        let environment = ProcessInfo.processInfo.environment
        guard let controlPath = environment["CADENCE_OBSERVER_CONTROL"],
              let evidencePath = environment["CADENCE_OBSERVER_EVIDENCE"] else {
            XCTFail("Missing private observer protocol paths"); return
        }
        control = URL(fileURLWithPath: controlPath)
        evidence = URL(fileURLWithPath: evidencePath)
        var completed = false
        defer {
            if !completed { try? text("HOLD: native observation did not complete; no UI action or permission grant.\n", to: evidence.appendingPathComponent("session.txt")) }
            try? text("done\n", to: control.appendingPathComponent("done"))
        }
        let binding = try read(Binding.self, "binding.json")
        guard validCandidate(URL(fileURLWithPath: binding.copiedPath), binding) else {
            throw NSError(domain: "CandidateIdentityMismatch", code: 1)
        }
        // Forces the supported test-control session to initialize BEFORE launch.
        // This image is discarded. Session/permission failure cannot mark ready.
        _ = XCUIScreen.main.screenshot().pngRepresentation
        let preflightOwners = try systemOwners()
        guard preflightOwners.count <= 16 else { throw NSError(domain: "IncompleteSystemUIHOLD", code: 1) }
        for owner in preflightOwners {
            let proxy = XCUIApplication(url: URL(fileURLWithPath: owner.applicationPath))
            let elements = proxy.windows.allElementsBoundByIndex
            guard elements.count <= 8 else { throw NSError(domain: "IncompleteSystemUIHOLD", code: 1) }
            for element in elements {
                var budget = 1024
                let tree = safeTree(try element.snapshot(), budget: &budget)
                guard !tree.truncated else { throw NSError(domain: "IncompleteSystemUIHOLD", code: 1) }
                guard !permissionRequest(tree) else {
                    throw NSError(domain: "UIAuthorityRequestHOLD", code: 1)
                }
            }
        }
        try text(binding.observationID, to: control.appendingPathComponent("ready"))
        let deadline = Date().addingTimeInterval(65)
        while !files.fileExists(atPath: control.appendingPathComponent("launch.json").path) {
            if files.fileExists(atPath: control.appendingPathComponent("stop").path) || Date() > deadline { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let launch = try read(Launch.self, "launch.json")
        guard launch.launcherPID > 1 else { throw NSError(domain: "InvalidLauncher", code: 1) }
        let began = Date()
        var progress = ObservationProgress()
        for (index, delay) in [0.0, 8.0, 22.0].enumerated() {
            while Date().timeIntervalSince(began) < delay {
                if files.fileExists(atPath: control.appendingPathComponent("stop").path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            progress.include(try await capture(binding, launch, index: index))
            if files.fileExists(atPath: control.appendingPathComponent("stop").path) { break }
        }
        let status = progress.observed
            ? "Observed: read-only system window tree/screenshot captured. Dialog identity/cause remain unclassified; original startup result is authoritative.\n"
            : "HOLD: no safe Apple system window tree/screenshot pair available. Partial observations retained; dialog unavailable.\n"
        try text(status, to: evidence.appendingPathComponent("session.txt"))
        completed = true
    }
}
