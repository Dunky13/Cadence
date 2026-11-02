#!/bin/bash
# Exact consent policy/controller with inert UI, process, and signing edges.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-first-open.XXXXXX")
trap 'rm -rf "$work"' EXIT
cat > "$work/controller.swift" <<'SWIFT'
import Foundation
var scenario = "normal"
var clicks = 0
var snapshots = 0
var processQueries = 0
var requestedStop = false
var noticeReads = 0
struct XCUIElementSnapshot {
    let elementType: XCUIElement.ElementType
    let label, title: String
    let children: [XCUIElementSnapshot]
    var value: Any? = nil
}
struct XCUIElement {
    enum ElementType: UInt { case any = 0, window = 4, sheet = 5, alert = 7, dialog = 8, button = 9, comboBox = 15, image = 43, staticText = 48, textField = 49, secureTextField = 50, textView = 52, menuBar = 55 }
    var elementType: ElementType {
        (scenario == "dialog-surface" || scenario.hasPrefix("native-")) ? .dialog : (scenario == "alert-surface" ? .alert : (scenario == "sheet-surface" ? .sheet : .window))
    }
    var actionName: String? = nil
    var isEnabled: Bool { scenario != "disabled-button" && scenario != "native-disabled-open" }
    func snapshot() throws -> XCUIElementSnapshot {
        snapshots += 1
        if scenario == "stop-during-final-query" && snapshots > 1 { requestedStop = true }
        if scenario.hasPrefix("native-") {
            let node = try JSONDecoder().decode(Harness.Node.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            func convert(_ node: Harness.Node) -> XCUIElementSnapshot {
                guard let type = ElementType(rawValue: node.type) else { preconditionFailure("Unknown fixture type") }
                var label = node.label
                var title = node.title
                var value = node.staticText
                var children = node.children.map(convert)
                if type == .dialog {
                    if scenario == "native-unknown-root" { label = "unknown" }
                    if scenario == "native-root-title" { title = "Unknown warning" }
                    if scenario == "native-extra-button" { children.append(XCUIElementSnapshot(elementType: .button, label: "Open Anyway", title: "", children: [])) }
                }
                if type == .image {
                    if scenario == "native-image-missing-label" { label = "" }
                    if scenario == "native-image-label" || (scenario == "native-image-label-changed" && snapshots > 1) { label = "Unexpected image label" }
                    if scenario == "native-image-title" { title = "authentication required" }
                    if scenario == "native-image-title-changed" && snapshots > 1 { title = "Changed image title" }
                }
                if type == .staticText, let text = value {
                    if scenario == "native-warning" { value = text + " Apple could not verify this app." }
                    if scenario == "native-other-agent" { value = text.replacingOccurrences(of: "CadenceReleaseVerification", with: "OtherAgent") }
                    if scenario == "native-changed-tree" && snapshots > 1 { value = text + " Changed warning" }
                }
                return XCUIElementSnapshot(elementType: type, label: label, title: title, children: children, value: value)
            }
            return convert(node)
        }
        let prompt = "“Cadence.app” is an app downloaded from the Internet. Are you sure you want to open it?"
        var labels = [prompt]
        if (scenario == "warning" || scenario == "diagnostic-write-failure") || (scenario == "changed-tree" && snapshots > 1) { labels += ["Apple could not verify it is free of malware."] }
        func immutableValue(_ text: String) -> Any? {
            if scenario == "value-only-text" { return text }
            if scenario == "changed-static-value" && snapshots > 1 { return "Apple could not verify it is free of malware." }
            if scenario == "non-string-static-value" { return 42 }
            if scenario == "long-static-value" { return String(repeating: "x", count: 2049) }
            return nil
        }
        let valueWarning = scenario == "static-value-warning" ? [XCUIElementSnapshot(elementType: .staticText, label: "", title: "", children: [], value: "Apple could not verify it is free of malware.")] : []
        return XCUIElementSnapshot(elementType: .dialog, label: "", title: "", children:
            labels.map { XCUIElementSnapshot(elementType: .staticText, label: scenario == "value-only-text" ? "" : $0, title: "", children: [], value: immutableValue($0)) } +
            valueWarning + ["Cancel", "Open"].map { XCUIElementSnapshot(elementType: .button, label: $0, title: "", children: []) })
    }
    func descendants(matching: ElementType) -> Query { Query(isOpen: false) }
    func click() { precondition(actionName == "Open", "Non-Open action attempted"); clicks += 1 }
}
struct Query {
    let isOpen: Bool
    var count: Int {
        if isOpen { return ["duplicate-open", "native-duplicate-open"].contains(scenario) ? 2 : 1 }
        if ["native-extra-query-button", "native-extra-button"].contains(scenario) { return 4 }
        return scenario.hasPrefix("native-") ? 3 : 2
    }
    var element: XCUIElement { XCUIElement(actionName: isOpen ? "Open" : "unfiltered") }
    func matching(_ predicate: NSPredicate) -> Query {
        precondition(predicate.evaluate(with: ["label":"Open", "title":""]) && predicate.evaluate(with: ["label":"", "title":"Open"]))
        precondition(!predicate.evaluate(with: ["label":"Help", "title":""]) && !predicate.evaluate(with: ["label":"", "title":"Cancel"]))
        return Query(isOpen: true)
    }
}
struct XCUIApplication {
    init(url: URL) {}
    struct Windows {
        var windowOnly = false
        var allElementsBoundByIndex: [XCUIElement] {
            if windowOnly && XCUIElement().elementType != .window { return [] }
            return Array(repeating: XCUIElement(), count: scenario == "missing-surface" ? 0 : (scenario == "multiple-windows" ? 2 : (scenario == "too-many-children" ? 65 : 1)))
        }
    }
    func children(matching: XCUIElement.ElementType) -> Windows { precondition(matching == .any); return Windows() }
    var windows: Windows { Windows(windowOnly: true) }
}
struct NSRunningApplication {
    init?(processIdentifier: Int32) {}
    var executableURL: URL? {
        scenario == "changed-owner" ? nil : URL(fileURLWithPath: "/System/Library/CoreServices/CoreServicesUIAgent.app/Contents/MacOS/CoreServicesUIAgent")
    }
}
struct Harness {
    let evidence: URL
    var normalOpenAttempted = false
    var preflightConsentWindowsAbsent: Bool { scenario != "preexisting-prompt" }
    var normalOpenAllowed: Bool { scenario != "disabled" }
    var stopRequested: Bool { scenario == "stop-before-controller" || requestedStop }
SWIFT
awk '
    /^    struct (Binding|Launch|OwnedProcess|Owner|Node|Window|Observation)[: ]/ ||
    /^    private func (systemSurfaces|safeTree|permissionRequest|editableContent|normalOpenConfirmation|recordRejectedConfirmation|openNormalConfirmation)\(/ {
        if ($0 ~ /} *$/) { print; next }
        copy=1
    }
    copy { print }
    copy && /^    }$/ { copy=0 }
' "$root/qa/LaunchUIObserver/ObserverTests.swift" | sed 's/private func openNormalConfirmation/mutating private func openNormalConfirmation/' >> "$work/controller.swift"
cat >> "$work/controller.swift" <<'SWIFT'
    private func expectedDownloadNotice(_ app: URL) -> String? {
        noticeReads += 1
        if scenario == "native-missing-metadata" || (scenario == "native-changed-metadata" && noticeReads > 1) { return nil }
        if scenario == "native-wrong-time" { return "CadenceReleaseVerification downloaded this file today at 8:39 PM. Apple checked it for malicious software and none was detected." }
        return "CadenceReleaseVerification downloaded this file today at 8:40 PM. Apple checked it for malicious software and none was detected."
    }
    private func validCandidate(_ app: URL, _ binding: Binding) -> Bool { scenario != "wrong-candidate" }
    private func ownedProcesses(_ binding: Binding) throws -> [OwnedProcess] {
        processQueries += 1
        if scenario == "process-query-error" { throw NSError(domain: "ProcessQueryUnavailable", code: 1) }
        let count = scenario == "multiple-products" ? 2 : (scenario == "no-product" ? 0 : 1)
        return (0..<count).map { index in OwnedProcess(pid: scenario == "reused-product-pid" && processQueries > 1 ? 99 : Int32(800 + index), executable: "verified", state: scenario == "running-product" ? "S" : "T") }
    }
    private func ps(_ arguments: [String]) throws -> String {
        if arguments.last == "comm=" { return scenario == "spoofed-launcher" ? "/other/open" : "/usr/bin/open" }
        if arguments == ["-axo", "pid=,comm="] {
            return "800 /copied/Cadence.app/Contents/MacOS/Cadence\n" + (scenario == "competing-cadence" ? "801 /other/Cadence.app/Contents/MacOS/Cadence\n" : "")
        }
        return scenario == "wrong-launcher" ? "open /unrelated.app" : "open -n -W /copied/Cadence.app --args --demo --snapshot /unique/startup.png"
    }
    private func systemOwners() throws -> [Owner] {
        let owner = Owner(pid: 100, bundleID: scenario == "foreign-owner" ? "other" : "com.apple.coreservices.uiagent",
            executable: "/System/Library/CoreServices/CoreServicesUIAgent.app/Contents/MacOS/CoreServicesUIAgent",
            applicationPath: "/System/Library/CoreServices/CoreServicesUIAgent.app")
        return Array(repeating: owner, count: scenario == "multiple-owners" ? 2 : 1)
    }
    private func signing(_ url: URL, requirement: String) -> Bool { scenario != "invalid-owner-signature" }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        if scenario == "diagnostic-write-failure" { throw NSError(domain: "SyntheticWriteFailure", code: 1) }
        try JSONEncoder().encode(value).write(to: url)
    }
    mutating func run() throws {
        let binding = Binding(bundleID: "dev.cadence.app", teamID: "ABC1234567", version: "0.2.0", build: "15", executableSHA256: "verified", copiedPath: "/copied/Cadence.app", snapshotPath: "/unique/startup.png", observationID: "unique")
        let accepted = ["native-profile", "value-only-text", "normal", "dialog-surface", "alert-surface", "sheet-surface"]
        let rejected = ["native-image-missing-label", "native-image-label", "native-image-title", "native-image-label-changed", "native-image-title-changed", "native-missing-metadata", "native-wrong-time", "native-changed-metadata", "native-extra-query-button", "native-duplicate-open", "native-disabled-open", "native-changed-tree", "native-unknown-root", "native-root-title", "native-extra-button", "native-warning", "native-other-agent", "changed-static-value", "non-string-static-value", "long-static-value", "static-value-warning", "diagnostic-write-failure", "too-many-children", "spoofed-launcher", "preexisting-prompt", "competing-cadence", "wrong-candidate", "process-query-error", "wrong-launcher", "multiple-windows", "warning", "duplicate-open", "disabled-button", "changed-owner", "invalid-owner-signature", "reused-product-pid", "changed-tree"]
        let noAction = ["missing-surface", "disabled", "no-product", "multiple-products", "running-product", "foreign-owner", "multiple-owners", "stop-before-controller", "stop-during-capture", "stop-during-final-query"]
        for name in accepted + rejected + noAction {
            scenario = name; noticeReads = 0; clicks = 0; snapshots = 0; processQueries = 0; normalOpenAttempted = false; requestedStop = false
            // Model capture finishing after the parent has requested teardown.
            if name == "stop-during-capture" { requestedStop = true }
            do {
                try openNormalConfirmation(binding, Launch(launcherPID: 900))
                precondition(!rejected.contains(name), "Unsafe state did not fail: \(name)")
                try openNormalConfirmation(binding, Launch(launcherPID: 900))
                precondition(clicks == (accepted.contains(name) ? 1 : 0), "Unexpected/repeated UI action: \(name)")
            } catch {
                precondition(rejected.contains(name) && clicks == 0, "Unexpected error or unsafe action: \(name)")
                if name == "warning" {
                    let record = try JSONDecoder().decode(Observation.self, from: Data(contentsOf: evidence.appendingPathComponent("confirmation.json")))
                    precondition(!record.complete && record.ownedProcesses.count == 1 && record.windows.count == 1)
                    precondition(record.windows[0].tree.children.contains { $0.label.contains("could not verify") }, "Rejected call site lost its filtered tree")
                }
            }
        }
        scenario = "missing-surface"; normalOpenAttempted = false; clicks = 0; requestedStop = false
        try openNormalConfirmation(binding, Launch(launcherPID: 900))
        precondition(clicks == 0 && !normalOpenAttempted)
        scenario = "dialog-surface"
        try openNormalConfirmation(binding, Launch(launcherPID: 900))
        precondition(clicks == 1 && normalOpenAttempted, "Late accessibility surface never retried")
        let owner = Owner(pid: 100, bundleID: "com.apple.coreservices.uiagent",
            executable: "/System/Library/CoreServices/CoreServicesUIAgent.app/Contents/MacOS/CoreServicesUIAgent",
            applicationPath: "/System/Library/CoreServices/CoreServicesUIAgent.app")
        let owned = [OwnedProcess(pid: 800, executable: "verified", state: "T")]
        let safe = Node(type: XCUIElement.ElementType.dialog.rawValue, label: "SYNTHETIC unsupported confirmation", title: "", children: [], truncated: false)
        let unsafe = [
            Node(type: safe.type, label: safe.label, title: "", children: [], truncated: true),
            Node(type: safe.type, label: "authentication required", title: "", children: [], truncated: false),
            Node(type: XCUIElement.ElementType.staticText.rawValue, label: "", title: "", children: [], truncated: false, staticText: "authentication required"),
            Node(type: XCUIElement.ElementType.textField.rawValue, label: "EXCLUDED editable value", title: "", children: [], truncated: false),
            Node(type: XCUIElement.ElementType.secureTextField.rawValue, label: "EXCLUDED secure value", title: "", children: [], truncated: false)
        ]
        let output = evidence.appendingPathComponent("confirmation.json")
        for (name, tree) in [("normal", safe), ("changed-owner", safe), ("invalid-owner-signature", safe), ("diagnostic-write-failure", safe)] + unsafe.map({ ("unsafe-tree", $0) }) {
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            scenario = name; clicks = 0
            recordRejectedConfirmation(tree, owner: owner, owned: owned, binding: binding, launch: Launch(launcherPID: 900))
            let exists = FileManager.default.fileExists(atPath: output.path)
            precondition(exists == (name == "normal") && clicks == 0, "Unsafe diagnostic retained or Open attempted")
            if exists {
                let record = try JSONDecoder().decode(Observation.self, from: Data(contentsOf: output))
                precondition(!record.complete && !record.limited && record.windows.count == 1 && record.windows[0].tree == safe)
                precondition(record.windows[0].screenshot.isEmpty && record.windows[0].windowID == nil && record.binding.observationID == binding.observationID)
            }
        }
        print("First-open controller: \(accepted.count + rejected.count + noAction.count + 5 + unsafe.count) inert exact-production contracts passed; no actual UI action.")
    }
}
@main struct Main {
    static func main() throws {
        var harness = Harness(evidence: URL(fileURLWithPath: CommandLine.arguments[1]))
        try harness.run()
    }
}
SWIFT
swiftc -swift-version 5 -parse-as-library "$work/controller.swift" -o "$work/controller"
"$work/controller" "$work" "$root/scripts/tests/fixtures/NativeFirstOpen.json"
