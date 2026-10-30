import AppKit
import CoreServices
import CryptoKit
import Security
import ScreenCaptureKit
import XCTest

// Product launch remains owned by LaunchServices. The optional consent path
// permits only a fully verified normal first-open confirmation, once per launch.
@MainActor
final class ObserverTests: XCTestCase {
    struct Binding: Codable {
        let bundleID, teamID, version, build, executableSHA256: String
        let copiedPath, snapshotPath, observationID: String
    }
    struct Launch: Codable { let launcherPID: Int32 }
    struct ProcessReply: Decodable {
        let schema, observationID, requestID, kind: String
        let pid: Int32
        let ok: Bool
        let output: String
    }
    enum ObserverCancellation: Error { case stopped }
    enum BootstrapStage: String, CaseIterable, Codable {
        case protocolPathsReceived, candidateCheckStarted, candidateVerified
        case screenSessionStarted, screenSessionReady
        case ownerPreflightStarted, ownerPreflightReady, ready
    }
    struct BootstrapProgress: Encodable {
        let schema = "cadence/ui-bootstrap-stage/v1"
        let stage: BootstrapStage
        let read_only = true
        let runtime_acceptance = false
    }
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
        var staticText: String? = nil
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
    private var observationID: String?
    private var normalOpenAttempted = false
    private var preflightConsentWindowsAbsent = false
    private var normalOpenAllowed: Bool {
        ProcessInfo.processInfo.environment["CADENCE_ALLOW_NORMAL_OPEN"] == "true"
    }
    private var stopRequested: Bool {
        guard let control else { return true }
        return files.fileExists(atPath: control.appendingPathComponent("stop").path)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try retainEvidence(encoder.encode(value), name: url.lastPathComponent)
    }

    private func text(_ value: String, to url: URL) throws {
        try retainEvidence(Data(value.utf8), name: url.lastPathComponent)
    }

    private func retainEvidence(_ data: Data, name: String) throws {
        guard let observationID, UUID(uuidString: observationID) != nil,
              name.range(of: "^(stage-[0-7]\\.json|session\\.txt|first-open\\.json|confirmation\\.json|observation-[0-2]\\.json|system-[0-2]-[1-9][0-9]*-[0-7]\\.png)$", options: .regularExpression) != nil else {
            throw NSError(domain: "InvalidEvidenceNameHOLD", code: 1)
        }
        let type = name.hasSuffix(".json") ? "public.json" : (name.hasSuffix(".png") ? "public.png" : "public.plain-text")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
        attachment.name = "CadenceObserver-\(observationID)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func signal(_ kind: String, id: String) throws {
        guard ["Ready", "Done"].contains(kind), UUID(uuidString: id) != nil else {
            throw NSError(domain: "InvalidObserverSignalHOLD", code: 1)
        }
        try FileHandle.standardOutput.write(contentsOf: Data("\nCadenceObserver\(kind):\(id):EndCadenceObserver\n".utf8))
    }

    private func recordBootstrapStage(_ stage: BootstrapStage) {
        guard let evidence else { return }
        // Fixed vocabulary only. Failure of this optional diagnostic must not
        // change controller readiness, assertions, or the startup outcome.
        guard let ordinal = BootstrapStage.allCases.firstIndex(of: stage) else { return }
        // An interrupted xcresult may never finalize its attachments. Keep only
        // a nonce-bound, fixed-vocabulary stage in the private stdout protocol.
        if let observationID, UUID(uuidString: observationID) != nil {
            let frame = "\nCadenceObserverStage:\(observationID):\(stage.rawValue):EndCadenceObserver\n"
            try? FileHandle.standardOutput.write(contentsOf: Data(frame.utf8))
        }
        try? write(BootstrapProgress(stage: stage), to: evidence.appendingPathComponent("stage-\(ordinal).json"))
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
        guard !stopRequested else { throw ObserverCancellation.stopped }
        guard let control, let observationID else { throw NSError(domain: "ProcessQueryUnavailable", code: 1) }
        let kind: String
        let pid: Int32
        if arguments == ["-axo", "pid=,comm="] {
            kind = "processes"; pid = 0
        } else if arguments.count == 4, arguments[0] == "-p", arguments[2] == "-o",
                  let value = Int32(arguments[1]), value > 1,
                  let query = ["command=": "command", "comm=": "executable", "stat=": "state"][arguments[3]] {
            kind = query; pid = value
        } else { throw NSError(domain: "ProcessQueryUnavailable", code: 1) }
        let requestID = UUID().uuidString
        let marker = "\nCadenceObserverQuery:\(observationID):\(requestID):\(kind):\(pid):EndCadenceObserver\n"
        try FileHandle.standardOutput.write(contentsOf: Data(marker.utf8))
        let replyURL = control.appendingPathComponent("reply-\(requestID).json")
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !stopRequested else { throw ObserverCancellation.stopped }
            if files.fileExists(atPath: replyURL.path) {
                let attributes = try files.attributesOfItem(atPath: replyURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.intValue <= 1100000 else {
                    throw NSError(domain: "ProcessQueryUnavailable", code: 1)
                }
                let reply = try JSONDecoder().decode(ProcessReply.self, from: Data(contentsOf: replyURL))
                guard reply.schema == "cadence/process-query/v1", reply.observationID == observationID,
                      reply.requestID == requestID, reply.kind == kind, reply.pid == pid, reply.ok,
                      reply.output.utf8.count <= 1048576 else {
                    throw NSError(domain: "ProcessQueryUnavailable", code: 1)
                }
                guard !stopRequested else { throw ObserverCancellation.stopped }
                return reply.output
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw NSError(domain: "ProcessQueryUnavailable", code: 1)
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

    private func systemSurfaces(_ proxy: XCUIApplication) throws -> [XCUIElement] {
        // App-modal confirmations can be dialogs/alerts rather than windows.
        // Query top-level children once, so a dialog inside a window is never
        // counted twice. Its entire subtree still receives the same policy.
        let children = proxy.children(matching: .any).allElementsBoundByIndex
        guard children.count <= 64 else { throw NSError(domain: "IncompleteSystemUIHOLD", code: 1) }
        let surfaces: Set<XCUIElement.ElementType> = [.window, .dialog, .alert, .sheet]
        return children.filter { surfaces.contains($0.elementType) }
    }

    private func safeTree(_ snapshot: XCUIElementSnapshot, budget: inout Int, depth: Int = 0, staticTextValues: Bool = false) -> Node {
        budget -= 1
        // Generic telemetry never reads values. Only the verified confirmation
        // caller opts into immutable static-text strings, never editable values.
        let readable: Set<XCUIElement.ElementType> = [.window, .dialog, .alert, .sheet, .button, .staticText]
        // In that same verified context, preserve image labels/titles so the
        // exact image profile and final equality validate actual metadata.
        let show = readable.contains(snapshot.elementType) || (staticTextValues && snapshot.elementType == .image)
        var text: String?
        var invalidText = false
        if staticTextValues, snapshot.elementType == .staticText, let value = snapshot.value {
            if let value = value as? String { text = value }
            else { invalidText = true }
        }
        let children = depth < 16 ? snapshot.children.prefix(128).compactMap { child -> Node? in
            guard budget > 0 else { return nil }
            return safeTree(child, budget: &budget, depth: depth + 1, staticTextValues: staticTextValues)
        } : []
        return Node(type: snapshot.elementType.rawValue,
                    label: show ? String(snapshot.label.prefix(2048)) : "",
                    title: show ? String(snapshot.title.prefix(2048)) : "", children: children,
                    truncated: (show && (snapshot.label.count > 2048 || snapshot.title.count > 2048))
                        || invalidText || (text?.count ?? 0) > 2048
                        || children.count < snapshot.children.count || children.contains(where: { $0.truncated }),
                    staticText: text.map { String($0.prefix(2048)) })
    }

    private func permissionRequest(_ node: Node) -> Bool {
        // Conservative HOLD for authority/password UI; never handles/dismisses it.
        let words = (node.label + " " + node.title + " " + (node.staticText ?? "")).lowercased()
        return node.type == XCUIElement.ElementType.secureTextField.rawValue
            || ["password", "authenticate", "authentication", "automation mode", "accessibility access", "would like to control", "permission to"].contains(where: words.contains)
            || node.children.contains(where: permissionRequest)
    }

    private func editableContent(_ node: Node) -> Bool {
        let editable: [XCUIElement.ElementType] = [.textField, .secureTextField, .textView, .comboBox]
        return editable.contains { $0.rawValue == node.type } || node.children.contains(where: editableContent)
    }

    private func downloadNotice(_ properties: [String: Any]?, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        guard let properties,
              properties[kLSQuarantineAgentNameKey as String] as? String == "CadenceReleaseVerification",
              let timestamp = properties[kLSQuarantineTimeStampKey as String] as? Date,
              timestamp.timeIntervalSince1970.isFinite, timestamp.timeIntervalSince1970 > 0,
              timestamp <= now else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard calendar.isDate(timestamp, inSameDayAs: now) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        return "CadenceReleaseVerification downloaded this file today at \(formatter.string(from: timestamp)). Apple checked it for malicious software and none was detected."
    }

    private func expectedDownloadNotice(_ app: URL, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        var fresh = app
        fresh.removeCachedResourceValue(forKey: .quarantinePropertiesKey)
        guard let values = try? fresh.resourceValues(forKeys: [.quarantinePropertiesKey]) else { return nil }
        return downloadNotice(values.quarantineProperties, now: now, timeZone: timeZone)
    }

    private func normalOpenConfirmation(_ node: Node, expectedDownloadNotice: String? = nil) -> Bool {
        guard !node.truncated, !permissionRequest(node), !editableContent(node) else { return false }
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "“", with: "\"")
                .replacingOccurrences(of: "”", with: "\"")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
        let all = nodes(node)
        let buttons = all.filter { $0.type == XCUIElement.ElementType.button.rawValue }
            .map { normalized($0.label.isEmpty ? $0.title : $0.label) }.sorted()
        let prompts = ["Cadence", "Cadence.app"].map {
            "\"\($0)\" is an app downloaded from the Internet. Are you sure you want to open it?"
        }
        if buttons == ["Cancel", "Help", "Open"] {
            // Closed profile observed on the native public-install runner. Help
            // is passive; the sole action below still targets exactly Open.
            guard let expectedDownloadNotice,
                  node.type == XCUIElement.ElementType.dialog.rawValue, node.label == "alert", node.title.isEmpty, node.staticText == nil,
                  node.children.map(\.type) == [XCUIElement.ElementType.image.rawValue, XCUIElement.ElementType.staticText.rawValue,
                    XCUIElement.ElementType.staticText.rawValue, XCUIElement.ElementType.button.rawValue,
                    XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.button.rawValue],
                  node.children.allSatisfy({ $0.children.isEmpty && !$0.truncated }) else { return false }
            let parts = node.children
            guard parts[0].label == "alert", parts[0].title.isEmpty, parts[0].staticText == nil,
                  parts[1].label.isEmpty, parts[1].title.isEmpty, let prompt = parts[1].staticText,
                  prompts.contains(normalized(prompt)),
                  parts[2].label.isEmpty, parts[2].title.isEmpty, let notice = parts[2].staticText,
                  normalized(notice) == normalized(expectedDownloadNotice),
                  parts[3].label == "Help", parts[3].title.isEmpty, parts[3].staticText == nil,
                  parts[4].label.isEmpty, parts[4].title == "Cancel", parts[4].staticText == nil,
                  parts[5].label.isEmpty, parts[5].title == "Open", parts[5].staticText == nil else { return false }
            return true
        }
        guard buttons == ["Cancel", "Open"] else { return false }
        let labels = Set(all.flatMap { [normalized($0.label), normalized($0.title), normalized($0.staticText ?? "")] }.filter { !$0.isEmpty })
        let allowed = Set(prompts + ["Cancel", "Open", "Cadence", "Cadence.app",
            "Apple checked it for malicious software and none was detected."])
        return prompts.contains(where: labels.contains) && labels.isSubset(of: allowed)
    }

    private func recordRejectedConfirmation(_ tree: Node, owner: Owner, owned: [OwnedProcess], binding: Binding, launch: Launch) {
        // Optional, filtered diagnostic at the exact rejected policy boundary.
        // No editable/authority UI, identifiers, pixels, or automatic acceptance.
        guard !tree.truncated, !editableContent(tree), !permissionRequest(tree),
              NSRunningApplication(processIdentifier: owner.pid)?.executableURL?.path == owner.executable,
              signing(URL(fileURLWithPath: owner.applicationPath), requirement: "anchor apple") else { return }
        let observation = Observation(binding: binding, launcherPID: launch.launcherPID,
            capturedUTC: ISO8601DateFormatter().string(from: Date()), ownedProcesses: owned,
            windows: [Window(owner: owner, tree: tree, screenshot: "", windowID: nil)],
            unavailableOwners: [], limited: false, complete: false,
            interpretation: "Rejected first-open tree; filtered diagnostic only. No Open action or runtime acceptance.")
        try? write(observation, to: evidence.appendingPathComponent("confirmation.json"))
    }

    private func openNormalConfirmation(_ binding: Binding, _ launch: Launch) throws {
        guard normalOpenAllowed, !normalOpenAttempted, !stopRequested else { return }
        guard preflightConsentWindowsAbsent else { throw NSError(domain: "UnknownFirstOpenHOLD", code: 1) }
        // No trust/permission configuration, interruption handler, app activation,
        // warning override, or generic button matching is permitted here.
        guard validCandidate(URL(fileURLWithPath: binding.copiedPath), binding) else {
            throw NSError(domain: "CandidateIdentityMismatch", code: 1)
        }
        let owned = try ownedProcesses(binding)
        guard owned.count == 1, owned[0].state.hasPrefix("T") else { return }
        let products = try ps(["-axo", "pid=,comm="]).split(separator: "\n").compactMap { line -> Int32? in
            let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, fields[1].hasSuffix("/Cadence.app/Contents/MacOS/Cadence") else { return nil }
            return Int32(fields[0])
        }
        guard products == owned.map(\.pid) else { throw NSError(domain: "UnknownFirstOpenHOLD", code: 1) }
        let command = try ps(["-p", String(launch.launcherPID), "-o", "command="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let launcherExecutable = try ps(["-p", String(launch.launcherPID), "-o", "comm="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = "-n -W \(binding.copiedPath) --args --demo --snapshot \(binding.snapshotPath)"
        guard launcherExecutable == "/usr/bin/open",
              command == "open \(expected)" || command == "/usr/bin/open \(expected)" else {
            throw NSError(domain: "InvalidLauncher", code: 1)
        }
        let owners = try systemOwners().filter {
            $0.bundleID == "com.apple.coreservices.uiagent" &&
                $0.applicationPath == "/System/Library/CoreServices/CoreServicesUIAgent.app"
        }
        guard owners.count == 1 else { return }
        let owner = owners[0]
        let proxy = XCUIApplication(url: URL(fileURLWithPath: owner.applicationPath))
        let windows = try systemSurfaces(proxy)
        // A visible system owner can precede its accessibility surface. Leave
        // Open unattempted and sample again within the existing startup bound.
        guard !windows.isEmpty else { return }
        guard windows.count == 1 else { throw NSError(domain: "UnknownFirstOpenHOLD", code: 1) }
        let window = windows[0]
        var budget = 1024
        let tree = safeTree(try window.snapshot(), budget: &budget, staticTextValues: true)
        let app = URL(fileURLWithPath: binding.copiedPath)
        let notice = expectedDownloadNotice(app)
        guard normalOpenConfirmation(tree, expectedDownloadNotice: notice) else {
            recordRejectedConfirmation(tree, owner: owner, owned: owned, binding: binding, launch: launch)
            throw NSError(domain: "UnknownFirstOpenHOLD", code: 1)
        }
        let buttons = window.descendants(matching: .button)
        let open = buttons.matching(NSPredicate(format: "label == %@ OR title == %@", "Open", "Open"))
        func buttonCount(_ node: Node) -> Int {
            (node.type == XCUIElement.ElementType.button.rawValue ? 1 : 0) + node.children.map(buttonCount).reduce(0, +)
        }
        guard buttons.count == buttonCount(tree), open.count == 1, open.element.isEnabled,
              NSRunningApplication(processIdentifier: owner.pid)?.executableURL?.path == owner.executable,
              signing(URL(fileURLWithPath: owner.applicationPath), requirement: "anchor apple"),
              try ownedProcesses(binding).map(\.pid) == owned.map(\.pid) else {
            throw NSError(domain: "UnknownFirstOpenHOLD", code: 1)
        }
        budget = 1024
        guard safeTree(try window.snapshot(), budget: &budget, staticTextValues: true) == tree,
              expectedDownloadNotice(app) == notice else {
            throw NSError(domain: "UnknownFirstOpenHOLD", code: 1)
        }
        guard !stopRequested else { return }
        normalOpenAttempted = true
        open.element.click()
        try write(["action": "verified-normal-open", "observation_id": binding.observationID],
                  to: evidence.appendingPathComponent("first-open.json"))
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
                let elements = try systemSurfaces(proxy)
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
        for (name, data) in images { try retainEvidence(data, name: name) }
        return CaptureResult(imageAvailable: !images.isEmpty, complete: complete)
    }

    func testObserveExistingLaunch() async throws {
        do {
            try await observeExistingLaunch()
        } catch {
            if let evidence {
                let known = ["CandidateIdentityMismatch", "CopiedCandidateIdentityMismatch", "UIAuthorityRequestHOLD", "IncompleteSystemUIHOLD", "ProcessQueryUnavailable", "SystemWindowQueryUnavailable", "InvalidLauncher", "UnknownFirstOpenHOLD"]
                let domain = (error as NSError).domain
                let reason = known.contains(domain) ? domain : "native-query-or-protocol-failure"
                try? text("HOLD: \(reason); normal Open attempted=\(normalOpenAttempted); no permission grant.\n", to: evidence.appendingPathComponent("session.txt"))
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
        let binding = try read(Binding.self, "binding.json")
        observationID = binding.observationID
        recordBootstrapStage(.protocolPathsReceived)
        var completed = false
        defer {
            if !completed { try? text("HOLD: native observation did not complete; normal Open attempted=\(normalOpenAttempted); no permission grant.\n", to: evidence.appendingPathComponent("session.txt")) }
            try? signal("Done", id: binding.observationID)
        }
        recordBootstrapStage(.candidateCheckStarted)
        guard validCandidate(URL(fileURLWithPath: binding.copiedPath), binding) else {
            throw NSError(domain: "CandidateIdentityMismatch", code: 1)
        }
        recordBootstrapStage(.candidateVerified)
        // Forces the supported test-control session to initialize BEFORE launch.
        // This image is discarded. Session/permission failure cannot mark ready.
        recordBootstrapStage(.screenSessionStarted)
        _ = XCUIScreen.main.screenshot().pngRepresentation
        recordBootstrapStage(.screenSessionReady)
        recordBootstrapStage(.ownerPreflightStarted)
        let preflightOwners = try systemOwners()
        guard preflightOwners.count <= 16 else { throw NSError(domain: "IncompleteSystemUIHOLD", code: 1) }
        for owner in preflightOwners {
            let proxy = XCUIApplication(url: URL(fileURLWithPath: owner.applicationPath))
            let elements = try systemSurfaces(proxy)
            if normalOpenAllowed && owner.bundleID == "com.apple.coreservices.uiagent" && !elements.isEmpty {
                throw NSError(domain: "UnknownFirstOpenHOLD", code: 1)
            }
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
        recordBootstrapStage(.ownerPreflightReady)
        preflightConsentWindowsAbsent = true
        try signal("Ready", id: binding.observationID)
        recordBootstrapStage(.ready)
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
            if files.fileExists(atPath: control.appendingPathComponent("stop").path) { break }
            do {
                progress.include(try await capture(binding, launch, index: index))
                if stopRequested { break }
                try openNormalConfirmation(binding, launch)
            } catch ObserverCancellation.stopped { break }
            if files.fileExists(atPath: control.appendingPathComponent("stop").path) { break }
        }
        let status = progress.observed
            ? "Observed: system window tree/screenshot captured; normal Open attempted=\(normalOpenAttempted); original startup result is authoritative.\n"
            : "HOLD: no safe Apple system window tree/screenshot pair available. Partial observations retained; dialog unavailable.\n"
        try text(status, to: evidence.appendingPathComponent("session.txt"))
        completed = true
    }
}
