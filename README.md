# Backup scripts

These are my personal scripts for auto-backing up various files to a server over SFTP using [restic](https://restic.net/) with alerting through [Healthchecks.io](https://healthchecks.io).

## Setup

First install restic and create a repo [following the docs](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html). Make sure to auto-generate a strong password for the repo and store it in a file: e.g. at `~/.restic-<repo-name>-password`. **Save the password in a password manager too!**

**Make sure you use the latest version of restic so that the repo is created with version 2 format which includes automatic compression**. The latest Ubuntu versions do not self-update, so it's better to just install the binary [directly from github](https://github.com/restic/restic/releases), and remember to periodically run `restic self-update`.

Then create a [Healthchecks.io](https://healthchecks.io) project and two checks: one for the backup itself and another for the restic integrity check. Don't forget to setup an email integration so you are actually alerted. Also, I like to go to settings and generate a "Ping key" so that I can use the [slug URLs](https://healthchecks.io/docs/slug_urls/) instead of the default UUID URLs.

## Running the scripts

Run the first backup manually in the shell, e.g.:

```
./backup.sh --password-file /home/user/.restic-repo-password --log-file /home/user/logs/repo-backup.log --healthcheck https://hc-ping.com/slug/repo-backup /home/user/folder sftp:storage-server:/backups/repo --verbose
```

**NOTE: unfortunately there's something wrong with the script and it does not output anything to the log unless the `--verbose` flag is passed so I just always pass the flag.**

To leave parts of the source folder out of the snapshot, pass `--exclude` one or more times (same pattern syntax as restic's own `--exclude`), e.g. to skip a live database directory that is dumped separately:

```
./backup.sh --exclude /home/user/app/data/postgres --exclude /home/user/app/data/tmp ... /home/user/app sftp:storage-server:/backups/app --verbose
```

For the integrity check (note it may take a long time to run for large repos), e.g.:

```
./restic-integrity-check.sh --password-file /home/user/.restic-repo-password --log-file /home/user/logs/repo-integrity-check.log --healthcheck https://hc-ping.com/slug/restic-integrity-check sftp:storage-server:/backups/repo --verbose
```

It's best to set up a cronjobs for the backup and integrity check:

```
crontab -e
# enter same command above but with absolute paths and prefixed with a cron schedule expression (see https://crontab.guru/)
# note that I use output redirection instead of the `log-file` option in the crontab because I want ALL ouput including errors redirected to the log
3 3 * * * /home/user/backups/backup.sh --password-file /home/user/.restic-repo-password --healthcheck https://hc-ping.com/slug/repo-backup /home/user/folder sftp:storage-server:/backups/repo --verbose >> /home/user/logs/repo-backup.log 2>&1
```

## Monitor

You should automatically get emails when a backup fails or fails to run at all. Check the logs to see what went wrong.

## Stats

To see how much space a repo is taking up in the remote, run:

```
restic -r sftp:storage-server:/backup/repo --password-file /home/user/.restic-repo-password stats
```

## Test Restoring

Backups are only good if you know you can restore them...

```
restic -r sftp:storage-server:/backups/repo --password-file /home/user/.restic-repo-password restore latest --target /tmp/repo
ls -lath /tmp/repo
```
