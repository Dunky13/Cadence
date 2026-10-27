#!/bin/bash
# Separate, read-only bootstrap telemetry. Never emits client text or plan values.
# Only the owned log, owned plan, and reaped numeric client exit are arguments.
set -euo pipefail
umask 077
[[ $# == 3 && $3 =~ ^(0|[1-9][0-9]{0,2})$ && $3 -le 255 ]] || exit 2
[[ -n ${LAUNCH_UI_EVIDENCE_DIR:-} && -d $LAUNCH_UI_EVIDENCE_DIR && ! -L $LAUNCH_UI_EVIDENCE_DIR ]] || exit 2
# No subprocess readers/parsers: the alarm bounds this same process, including
# input opens, bounded reads, regexes, hashing and atomic output. Core modules
# only. No dependency install, environment dump, xcresult reader or network.
exec /usr/bin/perl - "$1" "$2" "$3" "$LAUNCH_UI_EVIDENCE_DIR" <<'PERL'
BEGIN { $SIG{ALRM} = sub { exit 124 }; alarm 12 }
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NONBLOCK O_NOFOLLOW S_ISREG S_ISDIR);
use Digest::SHA qw(sha256_hex);
use JSON::PP;
use File::Temp qw(tempdir);
use POSIX ();

my ($log_path, $plan_path, $client_exit, $evidence) = @ARGV;
my $cap = 1048576;
my ($scratch, $temporary, @output_identity);
my $interrupted = 0;
our $active_work = 0;
my $destination = "$evidence/bootstrap.json";
my $revoke = sub {
    return 1 unless @output_identity;
    my @current = lstat $destination;
    return 1 unless @current && $current[0] == $output_identity[0] && $current[1] == $output_identity[1];
    return unlink $destination;
};
for my $signal (qw(HUP INT TERM ALRM)) {
    my $status = { HUP => 129, INT => 130, TERM => 143, ALRM => 124 }->{$signal};
    $SIG{$signal} = sub {
        $interrupted ||= $status;
        die "interrupted\n" if $active_work;
        $revoke->();
    };
}
my $bool = sub { $_[0] ? JSON::PP::true : JSON::PP::false };
my @directory = lstat $evidence;
exit 2 unless @directory && S_ISDIR($directory[2]) && $directory[4] == $< && !($directory[2] & 077);
exit 2 if lstat $destination;

sub sample {
    my ($path) = @_;
    my $input = { state => 'MISSING', sampled_bytes => 0, truncated => undef, sample_sha256 => undef };
    my @before = lstat $path;
    return ($input, '') unless @before;
    $input->{state} = 'UNSAFE';
    return ($input, '') unless S_ISREG($before[2]) && $before[3] == 1 && $before[4] == $<;
    $input->{state} = 'UNREADABLE';
    return ($input, '') unless $before[2] & 0444;
    sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or return ($input, '');
    my @opened = stat $handle;
    unless (@opened && S_ISREG($opened[2]) && $opened[0] == $before[0] && $opened[1] == $before[1] && $opened[3] == 1) {
        close $handle;
        $input->{state} = 'UNSAFE';
        return ($input, '');
    }
    my $bytes = '';
    # SAMPLE_READ: at most cap bytes, including oversize inputs; no tail scan.
    while (length($bytes) < $cap) {
        my $read = sysread($handle, my $chunk, $cap - length($bytes));
        unless (defined $read) {
            close $handle;
            $input->{state} = 'READ_FAILED';
            return ($input, '');
        }
        last unless $read;
        $bytes .= $chunk;
    }
    my @after = stat $handle;
    my @current = lstat $path;
    my $closed = close $handle;
    unless ($closed && @after && @current && S_ISREG($current[2]) &&
        $current[0] == $opened[0] && $current[1] == $opened[1] && $current[3] == 1 &&
        $after[7] == $opened[7] && $after[9] == $opened[9] && $after[10] == $opened[10] &&
        length($bytes) == ($opened[7] < $cap ? $opened[7] : $cap)) {
        $input->{state} = 'CHANGED';
        return ($input, '');
    }
    $input->{state} = length($bytes) ? 'SAMPLED' : 'EMPTY';
    $input->{sampled_bytes} = length $bytes;
    $input->{truncated} = $bool->($opened[7] > $cap);
    $input->{sample_sha256} = sha256_hex($bytes);
    return ($input, $bytes);
}

my $ok = eval {
    # Dynamic scope restores the nonthrowing handler even when eval unwinds.
    local $active_work = 1;
    die "interrupted\n" if $interrupted;
    $scratch = tempdir('.observer-bootstrap.XXXXXXXX', DIR => $evidence, CLEANUP => 0);
    chmod 0700, $scratch or die "scratch\n";
    $temporary = "$scratch/pending.json";
    my ($log, $log_bytes) = sample($log_path);
    my ($plan, $plan_bytes) = sample($plan_path);
    # FINGERPRINT_PARSE: fixed vocabulary only, never capture arbitrary strings.
    # These are lexical observations, including on truncated samples, not causes.
    my %patterns = (
        missing_private_protocol_variables => qr/Missing private observer protocol paths/i,
        runner_connection_failure => qr/Failed to establish (?:communication with|a connection to) the test runner|Lost connection to the test runner/i,
        runner_launch_failure => qr/Failed to launch test runner|Failed to launch the test runner|Unable to launch the test runner/i,
        test_bundle_load_failure => qr/Failed to load (?:the )?test bundle|The test bundle could not be loaded|Failed to load bundle/i,
        test_bundle_signature_failure => qr/Code Signature Invalid|code signature (?:is )?invalid|Failed to verify code signature|not valid for use in process/i,
        destination_or_plan_failure => qr/Unable to find a destination matching|Failed to read xctestrun file|xctestrun file does not exist|Unable to read test plan/i,
        authorization_failure => qr/not authorized|authorization denied|UIAuthorityRequestHOLD|not permitted to use UI testing/i,
        query_failure => qr/ProcessQueryUnavailable|SystemWindowQueryUnavailable|Failed to get matching snapshots|Failed to get screenshot/i,
    );
    my %signatures = map { $_ => $bool->($log_bytes =~ $patterns{$_}) } keys %patterns;
    my $log_available = $log->{state} eq 'SAMPLED' || $log->{state} eq 'EMPTY';
    my $plan_available = $plan->{state} eq 'SAMPLED' || $plan->{state} eq 'EMPTY';
    my $value = {
        schema => 'cadence/observer-bootstrap/v1', status => 'HOLD', cause => 'UNKNOWN',
        diagnostic => $log_available && $plan_available ? 'AVAILABLE' :
            ($log_available || $plan_available ? 'PARTIAL' : 'UNAVAILABLE'),
        reader_available => JSON::PP::true, read_only => JSON::PP::true,
        runtime_acceptance => JSON::PP::false, authority_established => JSON::PP::false,
        causality_established => JSON::PP::false, observations_only => JSON::PP::true,
        client_exit => 0 + $client_exit, byte_limit_per_input => $cap, deadline_seconds => 12,
        hash_scope => 'SAMPLED_BYTES_ONLY', log => $log, plan => $plan,
        signature_flags => \%signatures,
        plan_sample_tokens => {
            control_name_seen => $bool->(index($plan_bytes, 'CADENCE_OBSERVER_CONTROL') >= 0),
            evidence_name_seen => $bool->(index($plan_bytes, 'CADENCE_OBSERVER_EVIDENCE') >= 0),
            proves_test_host_environment => JSON::PP::false,
        },
    };
    my $json = JSON::PP->new->canonical->encode($value) . "\n";
    # OUTPUT_WRITE: exclusive private scratch, no partial public JSON.
    sysopen(my $output, $temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or die "output\n";
    print {$output} $json or die "output\n";
    # OUTPUT_FLUSH: a signal here must discard the private pending file.
    @output_identity = stat $output;
    close $output or die "output\n";
    my @current = lstat $evidence;
    die "directory\n" unless @current && S_ISDIR($current[2]) &&
        $current[0] == $directory[0] && $current[1] == $directory[1];
    # Hard-link publication is atomic and refuses an occupied/dangling target.
    link $temporary, $destination or die "publish\n";
    # OUTPUT_PUBLISHED: cancellation must revoke only this helper's inode.
    1;
};
my $result = $interrupted || ($ok ? 0 : 1);
# The original 12-second alarm remains active through normal cleanup. Failure
# cleanup gets at most two further seconds, so even a reader timeout stays <15s.
if ($result) {
    $SIG{ALRM} = sub { POSIX::_exit($interrupted || $result) };
    alarm 2;
    # Revoke before private cleanup can stall and exhaust its failure budget.
    $revoke->() or $result ||= 1;
} else {
    $SIG{ALRM} = sub {
        $interrupted ||= 124;
        $SIG{ALRM} = sub { POSIX::_exit(124) };
        alarm 2;
        $revoke->();
    };
}
# CLEANUP_BEGIN: discard pending output and revoke publication on any failure.
if (defined $temporary && lstat $temporary) { unlink $temporary or $result ||= 1 }
if (defined $scratch) { rmdir $scratch or $result ||= 1 }
$result ||= $interrupted;
if ($result) { $revoke->() or $result ||= 1 }
alarm 0;
exit($result || $interrupted);
PERL
