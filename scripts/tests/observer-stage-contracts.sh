#!/bin/bash
# Exact optional stage writer and enum; no XCTest, UI, or client log reads.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-stage-contracts.XXXXXX")
trap 'rm -r "$work"' EXIT
cat > "$work/stage.swift" <<'SWIFT'
import Foundation
struct Harness {
    let evidence: URL?
SWIFT
awk '
    /^    enum BootstrapStage:/ || /^    struct BootstrapProgress:/ ||
    /^    private func recordBootstrapStage\(/ { copy=1 }
    copy { print }
    copy && /^    }$/ { copy=0 }
' "$root/qa/LaunchUIObserver/ObserverTests.swift" >> "$work/stage.swift"
cat >> "$work/stage.swift" <<'SWIFT'
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
    func run() throws {
        guard let evidence else { recordBootstrapStage(.ready); return }
        let output = evidence.appendingPathComponent("session-stage.json")
        for stage in BootstrapStage.allCases {
            recordBootstrapStage(stage)
            let bytes = try Data(contentsOf: output)
            guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { preconditionFailure("Malformed stage JSON") }
            precondition(Set(value.keys) == ["schema", "stage", "read_only", "runtime_acceptance"])
            precondition(value["stage"] as? String == stage.rawValue)
            precondition(value["schema"] as? String == "cadence/ui-bootstrap-stage/v1")
            precondition(value["read_only"] as? Bool == true && value["runtime_acceptance"] as? Bool == false)
        }
        try FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        recordBootstrapStage(.ready) // occupied output is optional failure
        let remaining = try FileManager.default.contentsOfDirectory(atPath: output.path)
        precondition(remaining.isEmpty)
        print("Observer stage: 8 fixed states and optional-output failure passed; no native UI/client text.")
    }
    func missingOutput() { recordBootstrapStage(.ready) }
}
try Harness(evidence: nil).run()
try Harness(evidence: URL(fileURLWithPath: CommandLine.arguments[1])).run()
let missing = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("missing-output")
precondition(!FileManager.default.fileExists(atPath: missing.path))
Harness(evidence: missing).missingOutput()
precondition(!FileManager.default.fileExists(atPath: missing.path))
SWIFT
swiftc "$work/stage.swift" -o "$work/stage"
"$work/stage" "$work"
