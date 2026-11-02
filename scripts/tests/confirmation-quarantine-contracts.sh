#!/bin/bash
# Exact production metadata reader/profile context; no UI or product execution.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-quarantine-context.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/Cadence.app"
cat > "$work/context.swift" <<'SWIFT'
import Foundation
import CoreServices
import Darwin
struct Harness {
SWIFT
awk '
    /^    private func (downloadNotice|expectedDownloadNotice)\(/ { copy=1 }
    copy { print }
    copy && /^    }$/ { copy=0 }
' "$root/qa/LaunchUIObserver/ObserverTests.swift" >> "$work/context.swift"
cat >> "$work/context.swift" <<'SWIFT'
    func run(_ app: URL) throws {
        var cases = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); cases += 1
        }
        let stamp = Date(timeIntervalSince1970: TimeInterval(0x6ae4f0d1))
        let now = stamp.addingTimeInterval(60)
        guard let zone = TimeZone(secondsFromGMT: 0), let east = TimeZone(secondsFromGMT: 3600) else { preconditionFailure("Missing fixed zone") }
        let agent = kLSQuarantineAgentNameKey as String
        let timestamp = kLSQuarantineTimeStampKey as String
        let properties: [String: Any] = [agent: "CadenceReleaseVerification", timestamp: stamp]
        let golden = "CadenceReleaseVerification downloaded this file today at 7:32 PM. Apple checked it for malicious software and none was detected."
        func normalized(_ text: String?) -> String? { text.map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") } }
        check(normalized(downloadNotice(properties, now: now, timeZone: zone)) == golden, "Native footer does not match frozen quarantine metadata")
        check(normalized(downloadNotice(properties, now: now, timeZone: east)) == golden.replacingOccurrences(of: "7:32 PM", with: "8:32 PM"), "Display zone ignored")
        for invalid: [String: Any]? in [nil, [:], [agent: "OtherAgent", timestamp: stamp], [agent: "CadenceReleaseVerification"], [agent: "CadenceReleaseVerification", timestamp: "invalid"], [agent: "CadenceReleaseVerification", timestamp: Date(timeIntervalSince1970: 0)], [agent: "CadenceReleaseVerification", timestamp: Date(timeIntervalSince1970: .nan)]] {
            check(downloadNotice(invalid, now: now, timeZone: zone) == nil, "Malformed metadata accepted")
        }
        check(downloadNotice(properties, now: stamp.addingTimeInterval(-1), timeZone: zone) == nil, "Future quarantine accepted")
        check(downloadNotice(properties, now: now.addingTimeInterval(86400), timeZone: zone) == nil, "Unobserved prior-day profile accepted")
        func setAttribute(_ value: String) throws {
            let data = Data(value.utf8)
            let result = data.withUnsafeBytes { setxattr(app.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
            guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        func attribute() throws -> Data {
            var bytes = Data(count: 4096)
            let count = bytes.withUnsafeMutableBytes { getxattr(app.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
            guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            bytes.count = count; return bytes
        }
        let nonce = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        try setAttribute("0083;6ae4f0d1;CadenceReleaseVerification;\(nonce)")
        let before = try attribute()
        check(normalized(expectedDownloadNotice(app, now: now, timeZone: zone)) == golden, "Real quarantine attribute was not read")
        check(try attribute() == before, "Metadata reader changed quarantine")
        try setAttribute("0083;6ae4f0d1;OtherAgent;\(nonce)")
        check(expectedDownloadNotice(app, now: now, timeZone: zone) == nil, "Stale cached agent retained")
        try setAttribute("0083;6ae4f10d;CadenceReleaseVerification;\(nonce)")
        check(normalized(expectedDownloadNotice(app, now: now.addingTimeInterval(60), timeZone: zone)) == golden.replacingOccurrences(of: "7:32 PM", with: "7:33 PM"), "Stale cached timestamp retained")
        print("Confirmation quarantine: \(cases) metadata/format/cache contracts passed; owned inert directory only, no UI.")
    }
}
try Harness().run(URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
swiftc "$work/context.swift" -o "$work/context"
"$work/context" "$work/Cadence.app"
