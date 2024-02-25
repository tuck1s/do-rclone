#!/usr/bin/env bash
logdir=$HOME/do-rclone
logfile=$logdir/rclone.log
# force the log to rotate before starting
/usr/sbin/logrotate $logdir/.logrotaterc --state $logdir/.logrotate.status -f

#
for d in Kathy Hannah Olly Steve Qmultimedia Music
do
  echo ====== Starting \"$d\" >>$logfile
  # need to specify a modify time window of 2 seconds to prevent needless "modification time" updates
  #   use separate buckets for each share, for quicker browsing on BackBlaze UI
  #   set the config file directly, for compatibility with crontab
  #   now we have more virtual memory set up, use more checkers and transfers (was: 2, 2)
  #   use terse one-line stats logging

  rclone sync /mnt/$d/ backblaze:/TuckStore-$d --exclude-from "$logdir/rclone_exclude" --verbose --checkers=8 --transfers=4 --modify-window=2s \
    --buffer-size 64M --config="$logdir/rclone.conf" --log-file=$logfile --stats-one-line
done
echo ====== Done >>$logfile
swaks --server smtp.ntlworld.com --to steve@thetucks.com --ehlo there --from steven.tuck@ntlworld.com --header "Subject: rclone backup complete" \
  --body "Log file attached." --attach-name $logfile.txt --attach @$logfile --tlsc --silent 1

