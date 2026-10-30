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
struct XCUIElementSnapshot {
    let elementType: XCUIElement.ElementType
    let label, title: String
    let children: [XCUIElementSnapshot]
}
struct XCUIElement {
    enum ElementType: UInt { case window, dialog, alert, sheet, button, staticText, secureTextField, textField, textView, comboBox }
    var isEnabled: Bool { scenario != "disabled-button" }
    func snapshot() throws -> XCUIElementSnapshot {
        snapshots += 1
        if scenario == "stop-during-final-query" && snapshots > 1 { requestedStop = true }
        let prompt = "“Cadence.app” is an app downloaded from the Internet. Are you sure you want to open it?"
        var labels = [prompt]
        if scenario == "warning" || (scenario == "changed-tree" && snapshots > 1) { labels += ["Apple could not verify it is free of malware."] }
        return XCUIElementSnapshot(elementType: .dialog, label: "", title: "", children:
            labels.map { XCUIElementSnapshot(elementType: .staticText, label: $0, title: "", children: []) } +
            ["Cancel", "Open"].map { XCUIElementSnapshot(elementType: .button, label: $0, title: "", children: []) })
    }
    func descendants(matching: ElementType) -> Query { Query(isOpen: false) }
    func click() { clicks += 1 }
}
struct Query {
    let isOpen: Bool
    var count: Int { isOpen ? (scenario == "duplicate-open" ? 2 : 1) : 2 }
    var element: XCUIElement { XCUIElement() }
    func matching(_ predicate: NSPredicate) -> Query { Query(isOpen: true) }
}
struct XCUIApplication {
    init(url: URL) {}
    struct Windows {
        var allElementsBoundByIndex: [XCUIElement] {
            Array(repeating: XCUIElement(), count: scenario == "multiple-windows" ? 2 : 1)
        }
    }
    var windows: Windows { Windows() }
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
    /^    struct (Binding|Launch|OwnedProcess|Owner|Node)[: ]/ ||
    /^    private func (safeTree|permissionRequest|editableContent|normalOpenConfirmation|openNormalConfirmation)\(/ {
        if ($0 ~ /} *$/) { print; next }
        copy=1
    }
    copy { print }
    copy && /^    }$/ { copy=0 }
' "$root/qa/LaunchUIObserver/ObserverTests.swift" | sed 's/private func openNormalConfirmation/mutating private func openNormalConfirmation/' >> "$work/controller.swift"
cat >> "$work/controller.swift" <<'SWIFT'
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
    private func write<T: Encodable>(_ value: T, to url: URL) throws { try JSONEncoder().encode(value).write(to: url) }
    mutating func run() throws {
        let binding = Binding(bundleID: "dev.cadence.app", teamID: "ABC1234567", version: "0.2.0", build: "15", executableSHA256: "verified", copiedPath: "/copied/Cadence.app", snapshotPath: "/unique/startup.png", observationID: "unique")
        let rejected = ["spoofed-launcher", "preexisting-prompt", "competing-cadence", "wrong-candidate", "process-query-error", "wrong-launcher", "multiple-windows", "warning", "duplicate-open", "disabled-button", "changed-owner", "invalid-owner-signature", "reused-product-pid", "changed-tree"]
        let noAction = ["disabled", "no-product", "multiple-products", "running-product", "foreign-owner", "multiple-owners", "stop-before-controller", "stop-during-capture", "stop-during-final-query"]
        for name in ["normal"] + rejected + noAction {
            scenario = name; clicks = 0; snapshots = 0; processQueries = 0; normalOpenAttempted = false; requestedStop = false
            // Model capture finishing after the parent has requested teardown.
            if name == "stop-during-capture" { requestedStop = true }
            do {
                try openNormalConfirmation(binding, Launch(launcherPID: 900))
                precondition(!rejected.contains(name), "Unsafe state did not fail: \(name)")
                try openNormalConfirmation(binding, Launch(launcherPID: 900))
                precondition(clicks == (name == "normal" ? 1 : 0), "Unexpected/repeated UI action: \(name)")
            } catch {
                precondition(rejected.contains(name) && clicks == 0, "Unexpected error or unsafe action: \(name)")
            }
        }
        print("First-open controller: \(1 + rejected.count + noAction.count) inert exact-production contracts passed; no actual UI action.")
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
"$work/controller" "$work"
