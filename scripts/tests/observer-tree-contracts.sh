#!/bin/bash
# Exact pure production filtering/selection functions with inert snapshot data.
# Foundation/CoreGraphics geometry only: no XCTest/AppKit or capture API calls.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-observer-policy.XXXXXX")
trap 'rm -rf "$work"' EXIT
source_file="$root/qa/LaunchUIObserver/ObserverTests.swift"
cat > "$work/policy.swift" <<'SWIFT'
import Foundation
import CoreGraphics
enum XCUIElement {
    enum ElementType: UInt { case any = 0, window = 4, sheet = 5, alert = 7, dialog = 8, button = 9, comboBox = 15, image = 43, staticText = 48, textField = 49, secureTextField = 50, textView = 52, menuBar = 55 }
}
var valueReads = 0
struct XCUIElementSnapshot {
    let elementType: XCUIElement.ElementType
    let label, title: String
    let children: [XCUIElementSnapshot]
    var rawValue: Any? = nil
    var value: Any? { valueReads += 1; return rawValue }
}
struct Harness {
SWIFT
awk '
    /^    struct Node:/ || /^    private func (safeTree|permissionRequest|editableContent|captureWindowID|normalOpenConfirmation)\(/ { copy=1 }
    /^    struct WindowIdentity / { print; next }
    copy { print }
    copy && /^    }$/ { copy=0 }
' "$source_file" >> "$work/policy.swift"
cat >> "$work/policy.swift" <<'SWIFT'
    func run() throws {
        var cases = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            cases += 1
        }
        func filtered(_ kind: XCUIElement.ElementType = .staticText, _ label: String = "", _ title: String = "", _ children: [XCUIElementSnapshot] = []) -> Node {
            var budget = 1024
            return safeTree(XCUIElementSnapshot(elementType: kind, label: label, title: title, children: children), budget: &budget)
        }
        check(!filtered(.staticText, String(repeating: "x", count: 2048)).truncated, "Exact label limit changed")
        let clipped = filtered(.staticText, String(repeating: "x", count: 2048) + " authentication required")
        check(clipped.truncated && clipped.label.count == 2048, "Long label must report truncation")
        let title = filtered(.window, "", String(repeating: "x", count: 2048) + " permission to control")
        check(title.truncated && title.title.count == 2048, "Long title must report truncation")
        let longChild = XCUIElementSnapshot(elementType: .staticText, label: String(repeating: "x", count: 2049), title: "", children: [])
        check(filtered(.window, "", "", [longChild]).truncated, "Child truncation must propagate")
        for kind in [XCUIElement.ElementType.secureTextField, .textField, .textView, .comboBox] {
            let node = filtered(kind, "SYNTHETIC private input", "SYNTHETIC private title")
            check(editableContent(node) && node.label.isEmpty && node.title.isEmpty, "Editable text retained")
        }
        check(permissionRequest(filtered(.staticText, "authentication required")), "Authority request lost")
        let secure = XCUIElementSnapshot(elementType: .secureTextField, label: "secret", title: "", children: [])
        check(permissionRequest(filtered(.window, "", "", [secure])), "Secure child not recognized")
        let normalPrompt = "“Cadence.app” is an app downloaded from the Internet. Are you sure you want to open it?"
        let normalChildren = [normalPrompt, "Apple checked it for malicious software and none was detected."].map {
            XCUIElementSnapshot(elementType: .staticText, label: $0, title: "", children: [])
        } + ["Open", "Cancel"].map { XCUIElementSnapshot(elementType: .button, label: $0, title: "", children: []) }
        check(normalOpenConfirmation(filtered(.dialog, "", "", normalChildren)), "Normal first-open confirmation rejected")
        func withValue(_ kind: XCUIElement.ElementType, _ value: Any?, optedIn: Bool = true, label: String = "") -> Node {
            var budget = 1024
            return safeTree(XCUIElementSnapshot(elementType: kind, label: label, title: "", children: [], rawValue: value), budget: &budget, staticTextValues: optedIn)
        }
        valueReads = 0
        check(withValue(.staticText, "EXCLUDED generic static value", optedIn: false).staticText == nil && valueReads == 0, "Generic capture read a value")
        let immutable = withValue(.staticText, normalPrompt)
        check(immutable.staticText == normalPrompt && !immutable.truncated && valueReads == 1, "Confirmation lost immutable text")
        let oldButtonNodes = normalChildren.suffix(2).map { filtered($0.elementType, $0.label) }
        let valuePrompt = Node(type: XCUIElement.ElementType.dialog.rawValue, label: "", title: "", children: [immutable] + oldButtonNodes, truncated: false)
        check(normalOpenConfirmation(valuePrompt), "Value-only normal prompt rejected")
        let valueWarning = withValue(.staticText, "Apple could not verify it is free of malware.")
        check(!normalOpenConfirmation(Node(type: valuePrompt.type, label: "", title: "", children: valuePrompt.children + [valueWarning], truncated: false)), "Warning in immutable value was ignored")
        check(permissionRequest(withValue(.staticText, "authentication required")), "Immutable authority request was ignored")
        let longValue = withValue(.staticText, String(repeating: "x", count: 2049))
        check(longValue.truncated && longValue.staticText?.count == 2048, "Immutable text truncation lost")
        check(withValue(.staticText, 42).truncated, "Non-string immutable value was accepted")
        check(!withValue(.staticText, nil).truncated, "Absent optional value became a malformed value")
        let conflicting = withValue(.staticText, normalPrompt, label: "Unknown warning")
        check(!normalOpenConfirmation(Node(type: valuePrompt.type, label: "", title: "", children: [conflicting] + oldButtonNodes, truncated: false)), "Value replaced an unknown semantic label")
        valueReads = 0
        for kind in [XCUIElement.ElementType.textField, .secureTextField, .textView, .comboBox] {
            let hidden = withValue(kind, "EXCLUDED editable value")
            check(hidden.staticText == nil && valueReads == 0 && hidden.label.isEmpty, "Editable value was read or retained")
        }
        let native = try JSONDecoder().decode(Node.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let notice = "CadenceReleaseVerification downloaded this file today at 7:32 PM. Apple checked it for malicious software and none was detected."
        check(normalOpenConfirmation(native, expectedDownloadNotice: notice), "Observed native profile rejected")
        check(!normalOpenConfirmation(native), "Missing quarantine context accepted")
        check(!normalOpenConfirmation(native, expectedDownloadNotice: notice.replacingOccurrences(of: "7:32", with: "7:31")), "Wrong bound timestamp accepted")
        func changed(_ node: Node, type: UInt? = nil, label: String? = nil, title: String? = nil, children: [Node]? = nil, truncated: Bool? = nil) -> Node {
            Node(type: type ?? node.type, label: label ?? node.label, title: title ?? node.title, children: children ?? node.children, truncated: truncated ?? node.truncated, staticText: node.staticText)
        }
        func text(_ node: Node, _ value: String?) -> Node {
            Node(type: node.type, label: node.label, title: node.title, children: node.children, truncated: node.truncated, staticText: value)
        }
        func child(_ index: Int, _ node: Node) -> Node {
            var children = native.children; children[index] = node
            return changed(native, children: children)
        }
        let invalidNative = [
            changed(native, type: XCUIElement.ElementType.window.rawValue),
            changed(native, label: "other"), changed(native, title: "Unknown warning"), changed(native, truncated: true),
            changed(native, children: Array(native.children.dropLast())),
            changed(native, children: native.children + [native.children[3]]),
            child(0, changed(native.children[0], label: "Unknown image label")),
            child(1, changed(native.children[1], label: "Unknown label")),
            child(1, changed(native.children[1], title: "Unknown title")),
            child(1, text(native.children[1], nil)),
            child(1, text(native.children[1], "Other.app is an app downloaded from the Internet.")),
            child(2, text(native.children[2], nil)),
            child(2, text(native.children[2], notice + " Unknown warning")),
            child(2, text(native.children[2], notice.replacingOccurrences(of: "none was detected", with: "malware was detected"))),
            child(2, text(native.children[2], notice.replacingOccurrences(of: "CadenceReleaseVerification", with: "OtherAgent"))),
            child(2, changed(native.children[2], truncated: true)),
            child(3, changed(native.children[3], label: "Allow")),
            child(3, changed(native.children[3], title: "Open")),
            child(4, changed(native.children[4], title: "Don't Allow")),
            child(5, changed(native.children[5], title: "Open Anyway")),
            child(5, changed(native.children[5], children: [oldButtonNodes[0]]))
        ]
        for modified in invalidNative { check(!normalOpenConfirmation(modified, expectedDownloadNotice: notice), "Unknown native variant accepted") }
        check(!normalOpenConfirmation(filtered(.dialog, "", "", Array(normalChildren.dropLast()))), "Missing Cancel accepted")
        for warning in ["Cadence.app will damage your computer.", "Apple could not verify it is free of malware.", "password", "Unrelated.app"] {
            let extra = XCUIElementSnapshot(elementType: .staticText, label: warning, title: "", children: [])
            check(!normalOpenConfirmation(filtered(.dialog, "", "", normalChildren + [extra])), "Unknown/warning text accepted")
        }
        let foreign = normalChildren.map { child in
            XCUIElementSnapshot(elementType: child.elementType, label: child.label.replacingOccurrences(of: "Cadence.app", with: "Other.app"), title: child.title, children: child.children)
        }
        check(!normalOpenConfirmation(filtered(.dialog, "", "", foreign)), "Other app confirmation accepted")
        var deep = longChild
        for _ in 0..<18 { deep = XCUIElementSnapshot(elementType: .window, label: "", title: "", children: [deep]) }
        check(filtered(.window, "", "", [deep]).truncated, "Depth truncation lost")
        let child = XCUIElementSnapshot(elementType: .button, label: "Open", title: "", children: [])
        check(filtered(.window, "", "", Array(repeating: child, count: 129)).truncated, "Child limit lost")
        var budget = 2
        let limited = safeTree(XCUIElementSnapshot(elementType: .window, label: "", title: "", children: [child, child]), budget: &budget)
        check(limited.truncated && limited.children.count == 1, "Node budget lost")
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = WindowIdentity(id: 10, pid: 50, frame: frame)
        let overlapping = WindowIdentity(id: 11, pid: 60, frame: frame)
        check(captureWindowID([target, overlapping], pid: 50, frame: frame) == 10, "Isolated capture must select only target ID")
        check(captureWindowID([target, WindowIdentity(id: 12, pid: 50, frame: frame)], pid: 50, frame: frame) == nil, "Ambiguous window accepted")
        check(captureWindowID([target], pid: 60, frame: frame) == nil, "Foreign owner accepted")
        check(captureWindowID([target], pid: 1, frame: frame) == nil, "Invalid owner accepted")
        check(captureWindowID([WindowIdentity(id: 0, pid: 50, frame: frame)], pid: 50, frame: frame) == nil, "Invalid window ID accepted")
        check(captureWindowID([target], pid: 50, frame: .zero) == nil, "Empty window accepted")
        check(captureWindowID([target], pid: 50, frame: CGRect(x: 100, y: 100, width: 5000, height: 300)) == nil, "Unbounded window accepted")
        print("Observer policy: \(cases) pure synthetic filtering/window-binding contracts passed; no native UI executed.")
    }
}
try Harness().run()
SWIFT
swiftc "$work/policy.swift" -o "$work/policy"
"$work/policy" "$root/scripts/tests/fixtures/NativeFirstOpen.json"
# Regression tripwires for the demonstrated occlusion API and permission grants.
if grep -Eq 'element\.screenshot\(|CGRequestScreenCaptureAccess\(' "$source_file"; then
    printf 'Observer reintroduced desktop-cropped pixels or an authorization request.\n' >&2
    exit 1
fi
