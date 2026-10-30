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
    enum ElementType: UInt { case window, dialog, alert, sheet, button, staticText, secureTextField, textField, textView, comboBox }
}
struct XCUIElementSnapshot {
    let elementType: XCUIElement.ElementType
    let label, title: String
    let children: [XCUIElementSnapshot]
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
    func run() {
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
Harness().run()
SWIFT
swiftc "$work/policy.swift" -o "$work/policy"
"$work/policy"
# Regression tripwires for the demonstrated occlusion API and permission grants.
if grep -Eq 'element\.screenshot\(|CGRequestScreenCaptureAccess\(' "$source_file"; then
    printf 'Observer reintroduced desktop-cropped pixels or an authorization request.\n' >&2
    exit 1
fi
