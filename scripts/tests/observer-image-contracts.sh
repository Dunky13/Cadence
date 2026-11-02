#!/bin/bash
# Exact isolated-image helper; inert framework edges only, no UI/capture APIs.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-observer-image.XXXXXX")
trap 'rm -r -- "$work"' EXIT
cat > "$work/image.swift" <<'SWIFT'
import Foundation
import CoreGraphics
var scenario = ""
var requestedStop = false
var operations: [String] = []
var afterStop: [String] = []
func note(_ value: String) {
    if requestedStop { afterStop.append(value) }
    operations.append(value)
    if scenario == "stop-" + value { requestedStop = true }
}
func CGPreflightScreenCaptureAccess() -> Bool { note("preflight"); return scenario != "no-access" }
struct InertApplication { let processID: Int32 = 100 }
struct InertWindow {
    let windowID: UInt32 = 11
    let owningApplication: InertApplication? = InertApplication()
    let frame = CGRect(x: 0, y: 0, width: 20, height: 20)
}
struct SCShareableContent {
    let windows: [InertWindow]
    static func excludingDesktopWindows(_ value: Bool, onScreenWindowsOnly: Bool) async throws -> SCShareableContent {
        await Task.yield()
        note("discovery")
        return SCShareableContent(windows: scenario == "duplicate-window" ? [InertWindow(), InertWindow()] : [InertWindow()])
    }
}
struct SCContentFilter { init(desktopIndependentWindow: InertWindow) { note("filter") } }
final class SCStreamConfiguration { var width = 0; var height = 0; var showsCursor = false }
struct InertImage {}
enum SCScreenshotManager {
    static func captureImage(contentFilter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> InertImage {
        await Task.yield()
        note("capture")
        return InertImage()
    }
}
struct NSBitmapImageRep {
    enum Format { case png }
    init(cgImage: InertImage) { note("bitmap") }
    func representation(using: Format, properties: [String: String]) -> Data? { note("encode"); return Data("INERT".utf8) }
}
struct NSRunningApplication {
    init?(processIdentifier: Int32) { note("identity") }
    var executableURL: URL? {
        scenario == "changed-owner" ? nil : URL(fileURLWithPath: "/System/Library/Inert.app/Contents/MacOS/Inert")
    }
}
struct XCUIElement {
    var frame: CGRect {
        note("frame")
        return CGRect(x: scenario == "wrong-frame" ? 1 : 0, y: 0, width: 20, height: 20)
    }
    func snapshot() throws -> Harness.Node {
        note("snapshot")
        return scenario == "changed-tree" ? Harness.Node(type: 1, label: "Changed", title: "", children: [], truncated: false) : Harness.tree
    }
}
struct Harness {
    static let tree = Node(type: 1, label: "Inert", title: "", children: [], truncated: false)
    var stopRequested: Bool { requestedStop }
SWIFT
{
awk '
    /^    enum ObserverCancellation:/ || /^    struct WindowIdentity / { print; next }
    /^    struct (Owner|Node):/ || /^    private func (captureWindowID|isolatedWindowImage)\(/ { copy=1 }
    copy { print }
    copy && /^    }$/ { copy=0 }
' "$root/qa/LaunchUIObserver/ObserverTests.swift"
cat <<'SWIFT'
    private func safeTree(_ snapshot: Node, budget: inout Int) -> Node { snapshot }
    private func editableContent(_ tree: Node) -> Bool { scenario == "editable" }
    private func permissionRequest(_ tree: Node) -> Bool { scenario == "authority" }
    func run() async throws {
        let owner = Owner(pid: 100, bundleID: "synthetic", executable: "/System/Library/Inert.app/Contents/MacOS/Inert", applicationPath: "/System/Library/Inert.app")
        let stopped = ["stop-discovery", "stop-capture", "stop-before", "stop-preflight", "stop-frame", "stop-filter", "stop-snapshot"]
        let refused = ["no-access", "duplicate-window", "wrong-frame", "changed-tree", "changed-owner", "editable", "authority"]
        let scenarios = ["baseline"] + stopped + refused
        var failures: [String] = []
        for name in scenarios {
            scenario = name; requestedStop = name == "stop-before"; operations = []; afterStop = []
            var cancelled = false
            var image: (UInt32, Data)?
            do { image = try await isolatedWindowImage(owner, XCUIElement(), Harness.tree) }
            catch ObserverCancellation.stopped { cancelled = true }
            if stopped.contains(name) {
                if !cancelled || !requestedStop || !afterStop.isEmpty || image != nil || (name == "stop-before" && !operations.isEmpty) {
                    failures.append(name)
                    print("FAIL \(name): cancellation=\(cancelled), laterWork=\(afterStop.joined(separator: ","))")
                }
            } else if name == "baseline" {
                precondition(!cancelled && image?.0 == 11 && image?.1 == Data("INERT".utf8))
                precondition(operations == ["preflight", "discovery", "frame", "filter", "capture", "snapshot", "identity", "bitmap", "encode"])
            } else {
                precondition(!cancelled && image == nil, "Unsafe image accepted")
                if name == "no-access" { precondition(operations == ["preflight"]) }
                if ["duplicate-window", "wrong-frame"].contains(name) { precondition(!operations.contains("capture")) }
                precondition(!operations.contains("encode"))
            }
        }
        fflush(stdout)
        precondition(failures.isEmpty, "Image helper began work after cancellation: \(failures)")
        print("Observer image: \(scenarios.count) exact-helper cancellation/binding contracts passed; no native APIs/UI.")
    }
}
@main struct Main { static func main() async throws { try await Harness().run() } }
SWIFT
} >> "$work/image.swift"
swiftc -j 2 -swift-version 5 -parse-as-library "$work/image.swift" -o "$work/image"
perl -e 'alarm 8; exec @ARGV; die "Cannot execute image fixture\n";' -- "$work/image"
