#!/bin/bash
# Export sandboxed XCTest attachments privately; publish only bound UI evidence.
set -euo pipefail
umask 077
[[ $# == 3 && -d $1 && ! -L $1 && -d $2 && ! -L $2 &&
    $3 =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || exit 2
[[ $(stat -f '%u:%Lp' "$2") == "$(id -u):700" ]] || exit 2
work=$(mktemp -d "${1%/*}/observer-export.XXXXXX")
cleanup() { result=$?; trap - EXIT; if ! rm -r -- "$work"; then result=1; fi; exit "$result"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
perl -e 'alarm 12; exec @ARGV; die "Cannot export observer evidence\n";' -- \
    xcrun xcresulttool export attachments --path "$1" --output-path "$work" >/dev/null 2>&1
/usr/bin/perl - "$work" "$2" "$3" <<'PERL'
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_NONBLOCK S_ISREG);
use JSON::PP;
alarm 12;
my ($export, $output, $nonce) = @ARGV;
my $total = 0;
sub exact_keys {
    my ($value, @keys) = @_;
    return ref($value) eq 'HASH' && join(',', sort keys %$value) eq join(',', sort @keys);
}
sub read_owned {
    my ($path, $cap) = @_;
    my @before = lstat $path;
    die "Unsafe observer attachment\n" unless @before && S_ISREG($before[2]) &&
        $before[3] == 1 && $before[4] == $< && $before[7] <= $cap;
    sysopen(my $input, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or die "Cannot read observer attachment\n";
    my @opened = stat $input;
    die "Changed observer attachment\n" unless @opened &&
        join(':', @opened[0,1,3,4,7,9,10]) eq join(':', @before[0,1,3,4,7,9,10]);
    my $data = '';
    while (length($data) < $opened[7]) {
        my $count = sysread($input, my $chunk, $opened[7] - length($data));
        die "Cannot read observer attachment\n" unless defined($count) && $count > 0;
        $data .= $chunk;
    }
    my @after = stat $input;
    close($input) or die "Cannot close observer attachment\n";
    die "Changed observer attachment\n" unless @after &&
        join(':', @after[0,1,3,4,7,9,10]) eq join(':', @opened[0,1,3,4,7,9,10]);
    $total += length($data);
    die "Observer evidence limit exceeded\n" if $total > 134217728;
    return $data;
}
my $manifest = decode_json(read_owned("$export/manifest.json", 1048576));
die "Invalid attachment manifest\n" unless ref($manifest) eq 'ARRAY' && @$manifest <= 512;
my %selected;
my @stages = qw(protocolPathsReceived candidateCheckStarted candidateVerified screenSessionStarted screenSessionReady ownerPreflightStarted ownerPreflightReady ready);
for my $test (@$manifest) {
    die "Invalid attachment manifest\n" unless ref($test) eq 'HASH' && ref($test->{attachments}) eq 'ARRAY' && @{$test->{attachments}} <= 512;
    for my $item (@{$test->{attachments}}) {
        die "Invalid attachment record\n" unless ref($item) eq 'HASH' && defined($item->{suggestedHumanReadableName}) && !ref($item->{suggestedHumanReadableName});
        my $human = $item->{suggestedHumanReadableName};
        next unless $human =~ /^CadenceObserver-/;
        die "Foreign observer attachment\n" unless ($test->{testIdentifier} // '') eq 'ObserverTests/testObserveExistingLaunch()' &&
            $human =~ /^CadenceObserver-\Q$nonce\E-(stage-[0-7]|session|first-open|observation-[0-2]|system-[0-2]-[1-9][0-9]*-[0-7])_[0-9]+_[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}\.(json|txt|png)$/;
        my ($stem, $extension) = ($1, $2);
        my $expected = $stem eq 'session' ? 'txt' : ($stem =~ /^system-/ ? 'png' : 'json');
        die "Unexpected attachment type\n" unless $extension eq $expected;
        my $file = $item->{exportedFileName};
        die "Unsafe exported filename\n" unless defined($file) && !ref($file) && $file =~ /^[A-Za-z0-9_-]+\.\Q$extension\E$/;
        my $name = "$stem.$extension";
        my $cap = $extension eq 'png' ? 67108864 : ($extension eq 'json' ? 8388608 : 4096);
        my $data = read_owned("$export/$file", $cap);
        if ($extension eq 'json') {
            my $value = decode_json($data);
            die "Invalid observer JSON\n" unless ref($value) eq 'HASH';
            if ($stem =~ /^stage-([0-7])$/) {
                die "Invalid bootstrap stage\n" unless ($value->{stage} // '') eq $stages[$1] &&
                    ($value->{schema} // '') eq 'cadence/ui-bootstrap-stage/v1' &&
                    JSON::PP::is_bool($value->{read_only}) && $value->{read_only} &&
                    JSON::PP::is_bool($value->{runtime_acceptance}) && !$value->{runtime_acceptance} && keys(%$value) == 4;
            } elsif ($stem eq 'first-open') {
                die "Unbound first-open evidence\n" unless ($value->{observation_id} // '') eq $nonce &&
                    ($value->{action} // '') eq 'verified-normal-open' && keys(%$value) == 2;
            } else {
                die "Unbound observer evidence\n" unless
                    exact_keys($value, qw(binding launcherPID capturedUTC ownedProcesses windows unavailableOwners limited complete interpretation)) &&
                    exact_keys($value->{binding}, qw(bundleID teamID version build executableSHA256 copiedPath snapshotPath observationID)) &&
                    ($value->{binding}{observationID} // '') eq $nonce &&
                    ref($value->{ownedProcesses}) eq 'ARRAY' && ref($value->{windows}) eq 'ARRAY' && ref($value->{unavailableOwners}) eq 'ARRAY' &&
                    JSON::PP::is_bool($value->{limited}) && JSON::PP::is_bool($value->{complete});
            }
        } elsif ($extension eq 'png') {
            die "Invalid observer PNG\n" unless substr($data, 0, 8) eq "\x89PNG\r\n\x1a\n";
        } else {
            die "Invalid observer session\n" unless $data =~ /\A(?:Observed:|HOLD:)[^\r\n]*\n?\z/;
        }
        # The error path can retain both a generic and a precise HOLD. Never
        # choose a successful session if any retained session reports HOLD.
        if (exists $selected{$name}) {
            if ($name eq 'session.txt' && $data =~ /^HOLD:/) { $selected{$name} = $data; }
            elsif ($name eq 'session.txt' && $selected{$name} =~ /^HOLD:/) { next; }
            else { die "Duplicate observer attachment\n"; }
        } else { $selected{$name} = $data; }
    }
}
for my $ordinal (reverse 0..7) {
    if (exists $selected{"stage-$ordinal.json"}) {
        $selected{'session-stage.json'} = $selected{"stage-$ordinal.json"};
        last;
    }
}
delete @selected{map { "stage-$_.json" } 0..7};
die "No bound observer attachments\n" unless keys %selected;
for my $name (keys %selected) { die "Occupied observer output\n" if lstat "$output/$name"; }
for my $name (sort keys %selected) {
    sysopen(my $destination, "$output/$name", O_WRONLY | O_CREAT | O_EXCL, 0600) or die "Cannot retain observer attachment\n";
    print {$destination} $selected{$name} or die "Cannot write observer attachment\n";
    close($destination) or die "Cannot close observer attachment\n";
}
print "Collected bound observer attachments only.\n";
PERL
