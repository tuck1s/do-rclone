#!/usr/bin/env bash

# Trap SIGINT (Ctrl+C) and SIGTERM to exit the entire script immediately, not just the current loop item
trap 'echo -e "\n[!] Backup script aborted by user."; exit 1' INT TERM

logdir=$(dirname "$(readlink -f "$0")")
logfile=$logdir/rclone.log
authfile=$logdir/.swaks_auth
# force the log to rotate before starting
/usr/sbin/logrotate $logdir/.logrotaterc --state $logdir/.logrotate.status -f

#
for d in Kathy Hannah Olly Steve Qmultimedia
do
  # echo "====== Starting \"$d\" to Backblaze ======" >>$logfile
  #   need to specify a modify time window of 2 seconds to prevent needless "modification time" updates
  #   use separate buckets for each share, for quicker browsing on BackBlaze UI
  #   set the config file directly, for compatibility with crontab
  #   now we have more virtual memory set up, use more checkers and transfers (was: 2, 2)
  #   use terse one-line stats logging
  #   try to optimise costs with --fast-list, ignore-existing and cache
  #   Address each target sequentially
  # rclone sync /mnt/$d/ backblaze:/TuckStore-$d \
  #   --fast-list \
  #   --ignore-existing \
  #   --exclude-from "$logdir/rclone_exclude" \
  #   --cache-dir "$logdir/rclone-cache-$d" \
  #   --cache-tmp-upload-path "$logdir/rclone-cache-tmp-$d" \
  #   --config="$logdir/rclone.conf" \
  #   --verbose --checkers=8 --transfers=4 --modify-window=2s \
  #   --buffer-size 64M --log-file=$logfile --stats-one-line
    
echo "====== Starting \"$d\" to Pi 5 Vault (via Native Rsync) ======" >>$logfile
  # Phase 2: Use native system rsync to stream straight to the Pi 5 module
  #   -a: archive mode (preserves permissions, times, symlinks)
  #   -v: verbose
  #   -z: compress data during transfer
  #   --delete: mimics rclone sync by removing files at destination that were deleted at source
rsync -avz --delete \
    --exclude-from="$logdir/rclone_exclude" \
    --out-format="%t [RSYNC] : %f (%b bytes, xfer %U bytes)" \
    /mnt/$d/ rsync://pi5.netbird.cloud/offsite_vault/$d/ >>$logfile 2>&1

done
echo ====== Done >>$logfile
if [[ -f "$authfile" ]]; then
  . "$authfile"
fi

if [[ -z "${SWAKS_AUTH_USER:-}" || -z "${SWAKS_AUTH_PASS:-}" ]]; then
  echo "WARN: Missing swaks auth variables in $authfile; email notification skipped" >>"$logfile"
  exit 0
fi

swaks --server smtp.ntlworld.com --to steve@thetucks.com --ehlo there --from steven.tuck@ntlworld.com --header "Subject: rclone backup complete" \
  --body "Log file attached." --attach-name rclone.log.txt --attach @"$logfile" --tlsc --auth-user "$SWAKS_AUTH_USER" --auth-pass "$SWAKS_AUTH_PASS" --silent 1

