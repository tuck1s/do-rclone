#!/usr/bin/env bash
logdir=$HOME/do-rclone
logfile=$logdir/rclone.log
# Control whether this actually deletes, or just does a dry run
DRY_RUN_FLAG="--dry-run"
# DRY_RUN_FLAG=""

# force the log to rotate before starting
/usr/sbin/logrotate $logdir/.logrotaterc --state $logdir/.logrotate.status -f

#
# Cleanup script REMOVES all files from the Backblaze buckets, that match our exclude list
#
for d in Kathy Hannah Olly Steve Qmultimedia
do
  echo ====== CLEANUP $DRY_RUN_FLAG of junk files and recycle areas \"$d\" >>$logfile
  #   use separate buckets for each share, for quicker browsing on BackBlaze UI
  #   set the config file directly, for compatibility with crontab
  #   now we have more virtual memory set up, use more checkers and transfers (was: 2, 2)./x
  #   use terse one-line stats logging
  rclone delete backblaze:/TuckStore-$d \
    --include-from "$logdir/cleanup_list" \
    --config="$logdir/rclone.conf" \
    --verbose --checkers=8 --transfers=4 --modify-window=2s \
    --buffer-size 64M --log-file=$logfile --stats-one-line $DRY_RUN_FLAG
done
echo ====== Done >>$logfile
swaks --server smtp.ntlworld.com --to steve@thetucks.com --ehlo there --from steven.tuck@ntlworld.com --header "Subject: rclone backup complete" \
  --body "Log file attached." --attach-name $logfile.txt --attach @$logfile --tlsc --auth-user steven.tuck@ntlworld.com --auth-pass i2pkEI3H4v --silent 1

