#!/bin/bash
# Production Swift IPC client with inert replies; no UI or subprocess queries.
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-process-client.XXXXXX")
trap 'rm -r -- "$work"' EXIT
cat > "$work/client.swift" <<'SWIFT'
import Foundation
struct Harness {
    let files = FileManager.default
    let control: URL?
    let observationID: String? = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    var stopRequested: Bool { files.fileExists(atPath: control!.appendingPathComponent("stop").path) }
SWIFT
awk '
    /^    struct ProcessReply:/ || /^    private func ps\(/ { copy=1 }
    /^    enum ObserverCancellation:/ { print }
    copy { print }
    copy && /^    }$/ { copy=0 }
' "$root/qa/LaunchUIObserver/ObserverTests.swift" >> "$work/client.swift"
cat >> "$work/client.swift" <<'SWIFT'
    func run(_ scenario: String) throws {
        let arguments = scenario == "unknown" ? ["-e", "arbitrary"] : ["-p", "800", "-o", "command="]
        do {
            let output = try ps(arguments)
            precondition(scenario == "valid" && output == "owned command\n", "Invalid reply accepted")
        } catch ObserverCancellation.stopped {
            precondition(scenario == "stop", "Unexpected cancellation")
        } catch {
            precondition(scenario != "valid" && scenario != "stop", "Unexpected client failure")
        }
    }
}
try Harness(control: URL(fileURLWithPath: CommandLine.arguments[1])).run(CommandLine.arguments[2])
SWIFT
swiftc -o "$work/client" "$work/client.swift"
cat > "$work/reply.pl" <<'PERL'
use strict;
use warnings;
use JSON::PP;
use Time::HiRes qw(sleep time);
my ($control, $scenario) = @ARGV;
open(my $log, '<', "$control/client.log") or die;
my $deadline = time + 4;
while (time < $deadline) {
    my $line = <$log>;
    if (!defined $line) { seek($log, 0, 1); sleep 0.01; next; }
    next if $line eq "\n";
    die "Unexpected query\n" unless $line =~ /^CadenceObserverQuery:([^:]+):([^:]+):([^:]+):(\d+):EndCadenceObserver$/;
    my ($nonce, $id, $kind, $pid) = ($1, $2, $3, $4);
    if ($scenario eq 'stop') { open(my $stop, '>', "$control/stop") or die; close $stop; exit; }
    my $reply = {schema=>'cadence/process-query/v1',observationID=>$nonce,requestID=>$id,kind=>$kind,pid=>0+$pid,ok=>JSON::PP::true,output=>"owned command\n"};
    $reply->{observationID} = 'foreign' if $scenario eq 'nonce';
    $reply->{requestID} = 'stale' if $scenario eq 'request';
    $reply->{kind} = 'state' if $scenario eq 'kind';
    $reply->{pid} = 801 if $scenario eq 'pid';
    $reply->{schema} = 'unknown' if $scenario eq 'schema';
    $reply->{ok} = JSON::PP::false if $scenario eq 'failure';
    $reply->{output} = 'x' x 1048577 if $scenario eq 'oversized';
    open(my $out, '>', "$control/pending") or die;
    print {$out} $scenario eq 'malformed' ? '{' : encode_json($reply);
    close $out or die;
    rename("$control/pending", "$control/reply-$id.json") or die;
    exit;
}
die "Client did not request metadata\n";
PERL
cases=0
for scenario in valid nonce request kind pid schema failure oversized malformed stop unknown timeout; do
    control="$work/$scenario"
    mkdir "$control"
    : > "$control/client.log"
    "$work/client" "$control" "$scenario" > "$control/client.log" 2> "$control/private.log" &
    client=$!
    if [[ $scenario != unknown && $scenario != timeout ]]; then
        /usr/bin/perl "$work/reply.pl" "$control" "$scenario" || { kill "$client"; wait "$client" || true; exit 1; }
    fi
    wait "$client"
    cases=$((cases+1))
done
printf '%s exact-production process IPC client contracts passed; no UI or process queries.\n' "$cases"
