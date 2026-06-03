# Script for Raspberry Pi to back up NAS using `rclone`

Note `rclone.conf` is not included in repo as it contains access tokens.

## Configuration

See example in `etc`. Edit these lines into the file (with sudo) /etc/fstab.
Then make the mounts active, and set up Pi to wait for network on boot:

```
sudo systemctl daemon-reload
sudo systemctl restart remote-fs.target

systemctl status NetworkManager-wait-online.service
```
