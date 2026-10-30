#!/bin/bash
# Exact native attachment/signal policy with inert XCTest attachment storage.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-attachment-contracts.XXXXXX")
trap 'rm -r "$work"' EXIT
cat > "$work/attachments.swift" <<'SWIFT'
import Foundation
final class XCTAttachment {
    enum Lifetime { case keepAlways }
    let data: Data
    let type: String
    var name = ""
    var lifetime = Lifetime.keepAlways
    init(data: Data, uniformTypeIdentifier: String) { self.data = data; self.type = uniformTypeIdentifier }
}
final class Harness {
    private var observationID: String?
    private var stored: [XCTAttachment] = []
    private func add(_ value: XCTAttachment) { stored.append(value) }
SWIFT
awk '
    /^    private func (retainEvidence|signal)\(/ { copy=1 }
    copy { print }
    copy && /^    }$/ { copy=0 }
' "$root/qa/LaunchUIObserver/ObserverTests.swift" >> "$work/attachments.swift"
cat >> "$work/attachments.swift" <<'SWIFT'
    func run() throws {
        let nonce = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let bytes = Data("SYNTHETIC bound payload".utf8)
        for invalid in [Optional<String>.none, "invalid"] {
            observationID = invalid
            do { try retainEvidence(bytes, name: "session.txt"); preconditionFailure("Unbound attachment accepted") }
            catch { precondition(stored.isEmpty) }
        }
        observationID = nonce
        let allowed = ["stage-0.json", "stage-7.json", "session.txt", "first-open.json", "confirmation.json", "observation-0.json", "observation-2.json", "system-0-50-0.png", "system-2-50-7.png"]
        for name in allowed {
            try retainEvidence(bytes, name: name)
            guard let item = stored.last else { preconditionFailure("Attachment missing") }
            precondition(item.name == "CadenceObserver-\(nonce)-\(name)" && item.data == bytes)
            precondition(item.type == (name.hasSuffix(".json") ? "public.json" : (name.hasSuffix(".png") ? "public.png" : "public.plain-text")))
        }
        let rejected = ["../session.txt", "xcode-private.log", "bootstrap.json", "confirmation.txt", "confirmation-1.json", "binding.json", "environment.txt", "stage-8.json", "observation-3.json", "system-3-50-0.png", "system-0-0-0.png", "system-0-50-8.png"]
        for name in rejected {
            do { try retainEvidence(bytes, name: name); preconditionFailure("Unsafe attachment accepted") }
            catch { precondition(stored.count == allowed.count) }
        }
        try signal("Ready", id: nonce)
        try signal("Done", id: nonce)
        for (kind, id) in [("Other", nonce), ("Ready", "invalid")] {
            do { try signal(kind, id: id); preconditionFailure("Invalid signal accepted") }
            catch {}
        }
        print("Attachment policy: \(2 + allowed.count + rejected.count + 4) binding/name/type/signal cases passed; inert XCTest only.")
    }
}
try Harness().run()
SWIFT
swiftc "$work/attachments.swift" -o "$work/attachments"
"$work/attachments" > "$work/result"
grep -qx 'CadenceObserverReady:AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA:EndCadenceObserver' "$work/result"
grep -qx 'CadenceObserverDone:AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA:EndCadenceObserver' "$work/result"
tail -1 "$work/result"
