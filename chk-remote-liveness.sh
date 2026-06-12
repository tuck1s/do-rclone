#!/usr/bin/env bash
# Run a remote uptime check to prove the OS is fully functional

remote_host="pi5.netbird.cloud"
logdir=$(dirname "$(readlink -f "$0")")
logfile="$logdir/${remote_host}.log"
authfile="$logdir/.swaks_auth"

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 steve@"$remote_host" 'printf "%s %s %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$(hostname)" "$(uptime -p)"' >> "$logfile" 2>&1; then
    if [[ -f "$authfile" ]]; then
        . "$authfile"
    fi

    if [[ -z "${SWAKS_AUTH_USER:-}" || -z "${SWAKS_AUTH_PASS:-}" ]]; then
        echo "WARN: Missing swaks auth variables in $authfile; email notification skipped" >>"$logfile"
        exit 0
    fi
    
    # If the exit code is non-zero, fire the email alert!
    swaks --server smtp.ntlworld.com --to steve@thetucks.com --ehlo there --from steven.tuck@ntlworld.com --header "Subject: ALARM ${remote_host} Unreachable" \
        --body "ALERT: Remote $remote_host failed SSH liveness validation test." \
        --tlsc --auth-user "$SWAKS_AUTH_USER" --auth-pass "$SWAKS_AUTH_PASS" --silent 1
fi