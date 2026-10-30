#!/bin/bash
# TEMPORARY user-authorized PR-only diagnostic. Upload ciphertext only.
set -euo pipefail
umask 077
[[ ${LAUNCH_UI_ENCRYPT_CLIENT_LOG:-false} == true && ${GITHUB_ACTIONS:-} == true &&
    ${CI:-} == true && ${GITHUB_WORKFLOW:-} == 'macOS CI' &&
    ${GITHUB_EVENT_NAME:-} == pull_request && ${GITHUB_REF:-} =~ ^refs/pull/[1-9][0-9]*/merge$ ]] || exit 0
[[ $# == 2 && -f $1 && ! -L $1 && -d $2 && ! -L $2 ]] || exit 2
identity=$(/usr/bin/stat -f '%d:%i:%u:%l:%z:%m:%c' "$1")
IFS=: read -r _ _ owner links bytes _ _ <<< "$identity"
[[ $owner == "$(id -u)" && $links == 1 && $bytes =~ ^[0-9]+$ && $bytes -le 1048576 ]] || exit 2
[[ $(/usr/bin/stat -f '%u:%Lp' "$2") == "$(id -u):700" ]] || exit 2
certificate="${BASH_SOURCE[0]%/*}/../qa/LaunchUIObserver/bootstrap-diagnostic-recipient.pem"
[[ -f $certificate && ! -L $certificate ]] || exit 2
pending=$(mktemp "$2/.encrypted-client.XXXXXX")
cleanup() {
    result=$?
    trap - EXIT
    if ! rm -- "$pending"; then result=1; fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# The caller has reaped the client and verified owned observer teardown. Reject
# oversize logs rather than read beyond the approved one-MiB bound. No plaintext
# staging copy, environment/plan input, private key, or raw output enters CI.
/usr/bin/perl -MFcntl=O_RDONLY,O_NOFOLLOW,O_NONBLOCK,S_ISREG -e '
    alarm 12;
    my @before = lstat $ARGV[0];
    die unless @before && S_ISREG($before[2]) && $before[3] == 1 && $before[4] == $< && $before[7] <= 1048576;
    sysopen(my $input, $ARGV[0], O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or die;
    my @opened = stat $input;
    die unless @opened && join(":", @opened[0,1,3,4,7,9,10]) eq join(":", @before[0,1,3,4,7,9,10]);
    my $count = sysread($input, my $bytes, 1048576);
    my @after = stat $input;
    die unless defined($count) && $count == $opened[7] && @after &&
        join(":", @after[0,1,3,4,7,9,10]) eq join(":", @opened[0,1,3,4,7,9,10]);
    close($input) or die;
    print $bytes or die;
' "$1" 2>/dev/null | perl -e 'alarm 12; exec @ARGV; die "Cannot execute encryption\n";' -- \
    openssl cms -encrypt -binary -aes-256-cbc -outform DER -out "$pending" "$certificate" >/dev/null 2>&1
[[ -s $pending && $(/usr/bin/stat -f '%d:%i:%u:%l:%z:%m:%c' "$1") == "$identity" ]] || exit 2
ln "$pending" "$2/xcode-client.cms"
