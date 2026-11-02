#!/bin/bash
# Exact production sampling loop with inert controller/capture/file/clock edges.
# Scheduling waits are bypassed by the fixture clock; no native UI is executed.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-observer-session.XXXXXX")
trap 'rm -r -- "$work"' EXIT
cat > "$work/session.swift" <<'SWIFT'
import Foundation
struct Date { func timeIntervalSince(_ other: Date) -> Double { 30 } }
struct Binding {}
struct Launch {}
struct Files {
    let stopped: () -> Bool
    func fileExists(atPath: String) -> Bool { stopped() }
}
final class Harness {
    var scenario = ""
    var normalOpenAttempted = false
    var stopped = false
    var captures = 0
    var probes = 0
    var recorded = false
    let control = URL(fileURLWithPath: "/inert-control")
    var files: Files { Files(stopped: { self.stopped }) }
    var stopRequested: Bool { stopped }
SWIFT
{
awk '
    /^    struct (CaptureResult|ObservationProgress)[: ]/ { copy=1 }
    /^    enum ObserverCancellation:/ { print }
    copy { print }
    copy && /^    }$/ { copy=0 }
' "$root/qa/LaunchUIObserver/ObserverTests.swift"
cat <<'SWIFT'
    private func capture(_ binding: Binding, _ launch: Launch, index: Int) async throws -> CaptureResult {
        captures += 1
        if scenario == "capture-failure" { throw NSError(domain: "IncompleteSystemUIHOLD", code: 1) }
        if scenario == "capture-cancelled" { throw ObserverCancellation.stopped }
        if scenario == "stop-after-capture" { stopped = true }
        return CaptureResult(imageAvailable: scenario != "open-without-image", complete: scenario != "open-without-image")
    }
    private func openNormalConfirmation(_ binding: Binding, _ launch: Launch) throws {
        probes += 1
        if scenario == "read-only" || scenario == "waiting-confirmation" { return }
        if scenario == "policy-refusal" { throw NSError(domain: "UnknownFirstOpenHOLD", code: 1) }
        normalOpenAttempted = true
        if scenario == "record-failure" { throw NSError(domain: "SyntheticWriteFailure", code: 1) }
        recorded = true
        if scenario == "stop-after-open" { stopped = true }
    }
    private func sample() async throws -> ObservationProgress {
        let binding = Binding(), launch = Launch()
SWIFT
awk '
    /^        let began = Date\(\)/ { copy=1 }
    copy && /^        let status = progress.observed/ { exit }
    copy { print }
' "$root/qa/LaunchUIObserver/ObserverTests.swift"
cat <<'SWIFT'
        return progress
    }
    func run() async throws {
        let failures = ["capture-failure", "policy-refusal", "record-failure"]
        let scenarios = ["controlled-open", "open-without-image", "read-only", "waiting-confirmation", "stop-before", "stop-after-capture", "capture-cancelled", "stop-after-open"] + failures
        for name in scenarios {
            scenario = name; normalOpenAttempted = false; stopped = name == "stop-before"
            captures = 0; probes = 0; recorded = false
            do {
                let progress = try await sample()
                precondition(!failures.contains(name), "Controller/capture failure became a completed session")
                switch name {
                case "controlled-open", "open-without-image", "stop-after-open":
                    precondition(captures == 1 && probes == 1 && recorded, "Post-Open sampling delays session completion")
                    precondition(progress.observed == (name != "open-without-image"), "Optional imagery changed authority")
                case "read-only", "waiting-confirmation":
                    precondition(captures == 3 && probes == 3 && !recorded, "Unfinished/read-only sampling coverage lost")
                case "stop-before": precondition(captures == 0 && probes == 0)
                default: precondition(captures == 1 && probes == 0 && !recorded)
                }
            } catch {
                precondition(failures.contains(name) && captures == 1 && !recorded, "Failure/cancellation was hidden")
                precondition(probes == (name == "capture-failure" ? 0 : 1))
            }
        }
        print("Observer session: \(scenarios.count) exact-loop completion/cancellation contracts passed; inert clock, no UI.")
    }
}
@main struct Main { static func main() async throws { try await Harness().run() } }
SWIFT
} >> "$work/session.swift"
swiftc -j 2 -parse-as-library "$work/session.swift" -o "$work/session"
perl -e 'alarm 8; exec @ARGV; die "Cannot execute session fixture\n";' -- "$work/session"
