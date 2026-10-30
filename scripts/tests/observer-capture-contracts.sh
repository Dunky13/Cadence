#!/bin/bash
# Exact production capture/discovery/aggregation with inert framework edges.
# No XCTest, AppKit, capture APIs, real process query or product execution.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-observer-capture.XXXXXX")
trap 'rm -rf "$work"' EXIT
cat > "$work/capture.swift" <<'SWIFT'
import Foundation
import CoreGraphics
var scenario = "baseline"
var ownerLookups: [Int32: Int] = [:]
var requestedStop = false
var snapshotQueries = 0
var surfaceQueries = 0
var imageQueries = 0
struct XCUIElementSnapshot {
    var elementType: XCUIElement.ElementType
    var label = "Safe synthetic text"
    var title = ""
    var children: [XCUIElementSnapshot] = []
    var value: Any? = nil
}
struct XCUIElement {
    enum ElementType: UInt { case any, window, dialog, alert, sheet, button, staticText, secureTextField, textField, textView, comboBox, image = 43 }
    let owner: Int32
    var elementType: ElementType { scenario == "dialog-surface" ? .dialog : .window }
    func snapshot() throws -> XCUIElementSnapshot {
        snapshotQueries += 1
        if scenario == "stop-during-snapshot" { requestedStop = true }
        if scenario == "query-throws" && owner == 101 { throw NSError(domain: "SyntheticQueryError", code: 1) }
        var tree = XCUIElementSnapshot(elementType: .window)
        if scenario == "truncated" { tree.label = String(repeating: "x", count: 2049) }
        if scenario == "authority" { tree.children = [XCUIElementSnapshot(elementType: .secureTextField)] }
        if scenario == "editable-window" { tree.children = [XCUIElementSnapshot(elementType: .textField)] }
        return tree
    }
}
struct XCUIApplication {
    let url: URL
    struct Windows { let allElementsBoundByIndex: [XCUIElement] }
    func children(matching: XCUIElement.ElementType) -> Windows {
        precondition(matching == .any)
        surfaceQueries += 1
        if scenario == "stop-during-surfaces" { requestedStop = true }
        let owner: Int32 = url.lastPathComponent == "Owner101.app" ? 101 : 100
        if scenario == "missing-owner" && owner == 101 { return Windows(allElementsBoundByIndex: []) }
        return Windows(allElementsBoundByIndex: Array(repeating: XCUIElement(owner: owner), count: scenario == "too-many-windows" ? 9 : 1))
    }
}
struct NSRunningApplication {
    let processIdentifier: Int32
    init?(processIdentifier: Int32) { self.processIdentifier = processIdentifier }
    var executableURL: URL? {
        ownerLookups[processIdentifier, default: 0] += 1
        if scenario == "stop-during-owner" { requestedStop = true }
        if scenario == "changed-owner" || (scenario == "changed-owner-after-capture" && ownerLookups[processIdentifier, default: 0] > 1) { return nil }
        return URL(fileURLWithPath: "/System/Library/Owner\(processIdentifier).app/Contents/MacOS/Owner")
    }
}
struct Harness {
    let evidence: URL
    var stopRequested: Bool { requestedStop }
    private func openNormalConfirmation(_ binding: Binding, _ launch: Launch) throws {}
SWIFT
awk '
    /^    enum ObserverCancellation:/ { print }
    /^    struct (Binding|Launch|OwnedProcess|Owner|Node|Window|CaptureResult|ObservationProgress|Observation)[: ]/ ||
    /^    private func (systemSurfaces|ownedProcesses|safeTree|permissionRequest|editableContent|capture)\(/ {
        if ($0 ~ /} *$/) { print; next }
        copy=1
    }
    copy { print }
    copy && /^    }$/ { copy=0 }
' "$root/qa/LaunchUIObserver/ObserverTests.swift" >> "$work/capture.swift"
cat >> "$work/capture.swift" <<'SWIFT'
    private func ps(_ arguments: [String]) throws -> String {
        if (scenario == "enumeration-failure" && arguments == ["-axo", "pid=,comm="]) ||
            (scenario == "argument-failure" && arguments.last == "command=") ||
            (scenario == "state-failure" && arguments.last == "stat=") { throw NSError(domain: "ProcessQueryUnavailable", code: 1) }
        if scenario == "verified-absence" { return "" }
        let executable = "/copied/Cadence.app/Contents/MacOS/Cadence"
        if arguments == ["-axo", "pid=,comm="] { return "800 \(executable)\n" }
        if arguments.last == "command=" { return scenario == "empty-command" ? "" : "\(executable) --demo --snapshot /unique/startup.png\n" }
        return scenario == "empty-state" ? "" : "T\n"
    }
    private func validCandidate(_ app: URL, _ binding: Binding) -> Bool { true }
    private func systemOwners() throws -> [Owner] {
        if scenario == "stop-after-discovery" || scenario == "stop-empty-discovery" { requestedStop = true }
        if scenario == "system-query-failure" { throw NSError(domain: "SystemWindowQueryUnavailable", code: 1) }
        if scenario == "no-windows" || scenario == "stop-empty-discovery" { return [] }
        let count = scenario == "too-many-owners" ? 17 : (["missing-owner", "query-throws"].contains(scenario) ? 2 : 1)
        return (100..<(100 + count)).map { number in
            Owner(pid: Int32(number), bundleID: "synthetic.owner", executable: "/System/Library/Owner\(number).app/Contents/MacOS/Owner", applicationPath: "/System/Library/Owner\(number).app")
        }
    }
    private func isolatedWindowImage(_ owner: Owner, _ element: XCUIElement, _ tree: Node) async throws -> (UInt32, Data)? {
        imageQueries += 1
        if scenario == "helper-cancelled" { throw ObserverCancellation.stopped }
        if scenario == "image-error" { throw NSError(domain: "SyntheticImageUnavailable", code: 1) }
        if scenario == "stop-during-image" { requestedStop = true }
        if scenario == "capture-unavailable" { return nil }
        return (UInt32(owner.pid), Data("INERT-IMAGE-NOT-PNG".utf8))
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url)
    }
    private func retainEvidence(_ data: Data, name: String) throws {
        try data.write(to: evidence.appendingPathComponent(name))
    }
    func run() async throws {
        let binding = Binding(bundleID: "dev.cadence.app", teamID: "SYNTHETIC0", version: "0.2.0", build: "15", executableSHA256: "synthetic", copiedPath: "/copied/Cadence.app", snapshotPath: "/unique/startup.png", observationID: "synthetic-unique")
        let failures = ["enumeration-failure", "argument-failure", "state-failure", "empty-command", "empty-state", "system-query-failure", "truncated", "authority"]
        let partial = ["too-many-owners", "too-many-windows", "missing-owner", "query-throws", "capture-unavailable", "image-error", "editable-window", "changed-owner", "changed-owner-after-capture"]
        let cancelled = ["stop-before", "stop-after-discovery", "stop-empty-discovery", "stop-during-owner", "stop-during-surfaces", "stop-during-snapshot", "stop-during-image", "helper-cancelled"]
        var cases = 0
        for name in ["baseline", "dialog-surface", "verified-absence"] + partial + failures + cancelled {
            scenario = name
            ownerLookups = [:]
            requestedStop = name == "stop-before"; snapshotQueries = 0; surfaceQueries = 0; imageQueries = 0
            do {
                let result = try await capture(binding, Launch(launcherPID: 900), index: cases)
                precondition(!failures.contains(name) && !cancelled.contains(name), "Failed/cancelled query was treated as success")
                precondition(result.complete == !partial.contains(name), "Partial sample was treated as complete")
                let recorded = try JSONDecoder().decode(Observation.self, from: Data(contentsOf: evidence.appendingPathComponent("observation-\(cases).json")))
                precondition(recorded.complete == result.complete, "Recorded completeness differs")
                if name == "verified-absence" { precondition(recorded.ownedProcesses.isEmpty && result.complete) }
                var progress = ObservationProgress()
                progress.include(result)
                precondition(progress.observed == !partial.contains(name), "Partial sample reported OBSERVED")
                print("\(name): complete=\(result.complete) observed=\(progress.observed)")
            } catch ObserverCancellation.stopped {
                precondition(cancelled.contains(name) && snapshotQueries <= 1, "Cancellation began later UI work")
                precondition(surfaceQueries == (["stop-during-surfaces", "stop-during-snapshot", "stop-during-image", "helper-cancelled"].contains(name) ? 1 : 0))
                precondition(snapshotQueries == (["stop-during-snapshot", "stop-during-image", "helper-cancelled"].contains(name) ? 1 : 0))
                precondition(imageQueries == (["stop-during-image", "helper-cancelled"].contains(name) ? 1 : 0))
                precondition(!FileManager.default.fileExists(atPath: evidence.appendingPathComponent("observation-\(cases).json").path), "Cancelled capture published an observation")
            } catch {
                precondition(failures.contains(name), "Unexpected inert failure")
                let expected = name == "authority" ? "UIAuthorityRequestHOLD" : (name == "truncated" ? "IncompleteSystemUIHOLD" : (name == "system-query-failure" ? "SystemWindowQueryUnavailable" : "ProcessQueryUnavailable"))
                precondition((error as NSError).domain == expected, "Unavailable query lost its explicit reason")
                print("\(name): HOLD \(expected)")
            }
            cases += 1
        }
        requestedStop = false
        for sequence in [["baseline", "missing-owner"], ["missing-owner", "baseline"], ["no-windows", "baseline"]] {
            var progress = ObservationProgress()
            for name in sequence {
                scenario = name
                ownerLookups = [:]
                progress.include(try await capture(binding, Launch(launcherPID: 900), index: cases))
            }
            precondition(progress.observed == !sequence.contains("missing-owner"), "Incomplete sample lost during aggregation")
            cases += 1
        }
        print("Observer capture: \(cases) inert exact-production contracts passed; no native UI or real process queries.")
    }
}
@main struct Main {
    static func main() async throws { try await Harness(evidence: URL(fileURLWithPath: CommandLine.arguments[1])).run() }
}
SWIFT
swiftc -swift-version 5 -parse-as-library "$work/capture.swift" -o "$work/capture"
"$work/capture" "$work"
