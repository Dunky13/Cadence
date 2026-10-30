#!/bin/bash
# Parent-owned, read-only process metadata for one sandboxed observer session.
set -euo pipefail
umask 077
[[ $# == 5 && -d $1 && ! -L $1 && $2 =~ ^[1-9][0-9]*$ &&
    $3 =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ && $4 =~ ^[1-9][0-9]*$ && -f $5 && ! -L $5 && -x $5 ]] || exit 2
exec /usr/bin/perl - "$1" "$2" "$3" "$4" "$5" <<'PERL'
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_NONBLOCK S_ISREG S_ISDIR);
use JSON::PP;
use POSIX qw(WNOHANG);
use Encode qw(decode FB_CROAK);
use Time::HiRes qw(sleep alarm clock_gettime CLOCK_MONOTONIC);
my ($control, $supervisor, $nonce, $parent, $verifier) = @ARGV;
my $launcher;
my $deadline = clock_gettime(CLOCK_MONOTONIC) + 100;
my ($child, $pending);
my $stop_child = sub {
    if ($child) {
        my $pid = $child;
        $child = undef;
        if (waitpid($pid, WNOHANG) == 0) {
            kill('KILL', $pid) == 1 or die "Cannot stop owned bridge query\n";
            waitpid($pid, 0) == $pid or die "Cannot reap owned bridge query\n";
        }
    }
};
my $cleanup = sub {
    $stop_child->();
    if (defined $pending) {
        unlink($pending) or die "Cannot clean pending bridge reply\n";
        $pending = undef;
    }
};
for my $name (qw(HUP INT TERM ALRM)) {
    my $status = {HUP=>129,INT=>130,TERM=>143,ALRM=>124}->{$name};
    $SIG{$name} = sub {
        # The parent may interrupt a bounded query after requesting shutdown.
        # Only verified requested TERM is cancellation; faults/deadlines remain failures.
        my $cancelled = $name eq 'TERM' && -e "$control/stop";
        $cleanup->();
        exit($cancelled ? 0 : $status);
    };
}
END { $cleanup->() if $cleanup; }
alarm 100;
my @directory = lstat $control;
die "Unsafe bridge control\n" unless @directory && S_ISDIR($directory[2]) && $directory[4] == $< && !($directory[2] & 077);
my @verifier_file = lstat $verifier;
die "Unsafe launcher verifier\n" unless @verifier_file && S_ISREG($verifier_file[2]) && $verifier_file[3] == 1 &&
    $verifier_file[4] == $< && !($verifier_file[2] & 022) && $verifier_file[7] <= 16777216;
sub open_owned {
    my ($path, $cap) = @_;
    my @before = lstat $path;
    die "Unsafe bridge input\n" unless @before && S_ISREG($before[2]) && $before[3] == 1 && $before[4] == $< && $before[7] <= $cap;
    sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or die "Cannot read bridge input\n";
    my @opened = stat $handle;
    die "Changed bridge input\n" unless @opened && $opened[0] == $before[0] && $opened[1] == $before[1];
    return $handle;
}
my $binding_file = open_owned("$control/binding.json", 65536);
my $count = sysread($binding_file, my $binding_data, 65537);
die "Bridge binding limit\n" unless defined($count) && $count <= 65536;
close $binding_file or die "Cannot close bridge input\n";
my $binding = decode_json($binding_data);
die "Unbound bridge input\n" unless ref($binding) eq 'HASH' && ($binding->{observationID} // '') eq $nonce &&
    defined($binding->{copiedPath}) && !ref($binding->{copiedPath}) && $binding->{copiedPath} =~ m{^/[^\r\n\0]+/Cadence\.app$} &&
    defined($binding->{snapshotPath}) && !ref($binding->{snapshotPath}) && $binding->{snapshotPath} =~ m{^/[^\r\n\0]+/startup\.png$};
my $original = "$binding->{copiedPath}/Contents/MacOS/Cadence";
my $log = open_owned("$control/xcode-private.log", 1048576);
my ($buffer, $bytes, $requests) = ('', 0, 0);
my %handled;
sub run_program {
    my ($program, @arguments) = @_;
    my ($result, $pipe, $ok);
    {
        local $SIG{ALRM} = sub { die "Bridge process query deadline\n"; };
        alarm 2;
        $ok = eval {
            $child = open($pipe, '-|', $program, @arguments);
            die "Cannot start bridge process query\n" unless $child;
            my $data = '';
            while (1) {
                my $read = sysread($pipe, my $chunk, 65536);
                die "Cannot read bridge process query\n" unless defined $read;
                last unless $read;
                $data .= $chunk;
                die "Bridge process query limit\n" if length($data) > 1048576;
            }
            my $closed = close $pipe;
            $child = undef;
            die "Bridge process query failed\n" unless $closed;
            $result = decode('UTF-8', $data, FB_CROAK);
            1;
        };
        if ($child) { $stop_child->(); close $pipe; }
        alarm 0;
    }
    my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
    die "Bridge session deadline\n" unless $remaining > 0;
    alarm $remaining;
    return $ok ? $result : undef;
}
sub ps { return run_program('/bin/ps', @_); }
sub query {
    my ($kind, $pid) = @_;
    if (!defined $launcher) {
        my $receipt_file = open_owned("$control/launch.json", 65536);
        my $length = sysread($receipt_file, my $receipt_data, 65537);
        die "Bridge receipt limit\n" unless defined($length) && $length <= 65536;
        close $receipt_file or die "Cannot close bridge receipt\n";
        my $receipt = decode_json($receipt_data);
        die "Unbound bridge receipt\n" unless ref($receipt) eq 'HASH' && ($receipt->{schema} // '') eq 'cadence/launcher/v1' &&
            ($receipt->{observationID} // '') eq $nonce && ($receipt->{supervisorPID} // 0) == $supervisor &&
            ($receipt->{launcherPID} // '') =~ /^[1-9][0-9]*$/;
        $launcher = $receipt->{launcherPID};
    }
    if ($kind eq 'processes') {
        return undef unless $pid == 0;
        my $listing = ps('-axo', 'pid=,comm=');
        return undef unless defined $listing;
        return join('', map { "$_\n" } grep { /^\s*[1-9][0-9]*\s+.*\/Cadence\.app\/Contents\/MacOS\/Cadence\s*$/ } split /\n/, $listing);
    }
    return undef unless $pid > 1 && $pid <= 2147483647;
    if ($pid == $launcher) {
        my $expected = "/usr/bin/open -n -W $binding->{copiedPath} --args --demo --snapshot $binding->{snapshotPath}\n";
        my $certified = run_program($verifier, 'verify', $control, $supervisor, $pid);
        return undef unless defined($certified) && $certified eq $expected;
        return $certified if $kind eq 'command';
        return "/usr/bin/open\n" if $kind eq 'executable';
        return ps('-p', "$pid", '-o', 'stat=');
    }
    my $executable = ps('-p', "$pid", '-o', 'comm=');
    return undef unless defined $executable;
    $executable =~ s/^\s+|\s+$//g;
    return undef unless $executable eq $original || $executable =~ m{/AppTranslocation/[^\r\n]+/d/Cadence\.app/Contents/MacOS/Cadence$};
    my $arguments = ps('-p', "$pid", '-o', 'command=');
    return undef unless defined $arguments;
    $arguments =~ s/^\s+|\s+$//g;
    return undef unless $arguments eq "$executable --demo --snapshot $binding->{snapshotPath}";
    return "$executable\n" if $kind eq 'executable';
    return "$arguments\n" if $kind eq 'command';
    return ps('-p', "$pid", '-o', 'stat=');
}
while (-d $control && !-e "$control/stop" && kill(0, $parent)) {
    my $read = sysread($log, my $chunk, 65536);
    die "Cannot read bridge log\n" unless defined $read;
    if (!$read) { sleep 0.02; next; }
    $bytes += $read;
    die "Bridge log limit exceeded\n" if $bytes > 1048576;
    $buffer .= $chunk;
    # XCTest may forward a stdout write inside a partially written logging line.
    # Resynchronize on explicit frame boundaries, including across read chunks.
    while (1) {
        my $start = index($buffer, 'CadenceObserverQuery:');
        last if $start < 0;
        $buffer = substr($buffer, $start);
        my $end_marker = ':EndCadenceObserver';
        my $end = index($buffer, $end_marker);
        last if $end < 0;
        my $line = substr($buffer, 0, $end + length($end_marker), '');
        die "Invalid bridge request\n" unless $line =~ /^CadenceObserverQuery:\Q$nonce\E:([A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}):(processes|command|state|executable):([0-9]{1,10}):EndCadenceObserver$/;
        my ($id, $kind, $pid) = ($1, $2, $3);
        die "Duplicate bridge request\n" if $handled{$id}++;
        die "Bridge request limit exceeded\n" if ++$requests > 256;
        last if -e "$control/stop";
        my $value = query($kind, $pid);
        last if -e "$control/stop";
        my $reply = encode_json({schema=>'cadence/process-query/v1',observationID=>$nonce,requestID=>$id,kind=>$kind,pid=>0+$pid,
            ok=>defined($value) ? JSON::PP::true : JSON::PP::false,output=>$value // ''});
        my $temporary = "$control/.reply-$id";
        sysopen(my $output, $temporary, O_WRONLY | O_CREAT | O_EXCL, 0600) or die "Cannot create bridge reply\n";
        $pending = $temporary;
        print {$output} $reply or die "Cannot write bridge reply\n";
        close $output or die "Cannot close bridge reply\n";
        link($temporary, "$control/reply-$id.json") or die "Occupied bridge reply\n";
        unlink $temporary or die "Cannot clean bridge reply\n";
        $pending = undef;
    }
}
close $log or die "Cannot close bridge log\n";
PERL
