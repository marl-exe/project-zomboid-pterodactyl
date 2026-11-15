# Uninstall and decommission safely

This is a **manual operator guide**, not an uninstall script. The repository's
installer is designed only for fresh Ubuntu 24.04 hosts and does not support
in-place upgrades, rollback, or automated removal. Do not paste an entire
cleanup procedure into a root shell without checking each target first.

The goal is to remove only installation-owned components while preserving
existing game backups and unrelated applications, network access, and data.
If the entire VPS will be terminated, **copy the backups off the VPS first**:
moving them elsewhere on the same disk does not protect them from termination.

## 1. Inventory before changing anything

Record the server UUID and volume path from the Panel. Do not assume another
server uses the same UUID or that the Panel has only one game server.

```bash
docker ps -a
docker network ls
docker volume ls
systemctl is-active wings pteroq nginx docker mariadb redis-server ssh xrdp
systemctl show -p FragmentPath wings.service pteroq.service
mariadb -e 'SHOW DATABASES;'
ls -lah /etc/nginx/sites-enabled/
ls -lah /var/lib/pterodactyl/backups/
find /var/lib/pterodactyl/volumes -mindepth 1 -maxdepth 1 -printf '%f\n'
ufw status numbered
df -h /
```

Some installations intentionally do not have xRDP; an inactive or missing
service is not by itself proof that the game installation is broken. Confirm
which services are *actually* needed on this host before purging packages.

## 2. Stop the game and preserve existing data

1. Announce downtime, run `save`, and **Stop** the game in the Panel. Wait for
   a clean shutdown. Confirm the container is exited before handling saves.
2. Identify the Wings backup path from `system.backup_directory` in
   `/etc/pterodactyl/config.yml` (normally `/var/lib/pterodactyl/backups`).
3. Move existing backup archives and any transfer archives to a directory
   **outside** `/var/lib/pterodactyl`, or securely copy them offsite.
4. Also retain the game volume's `.cache` data (world saves, player database,
   configuration, spawn regions) and its `steamapps/workshop` directory (mods,
   custom-map downloads, and Workshop manifest) if future restoration matters.
5. Preserve only the original data you need; moving existing files is not the
   same as producing a verified, offsite backup. See [BACKUP-RESTORE.md](BACKUP-RESTORE.md)
   for an archive and verification procedure.

Before removing application directories, verify the preserved copies exist and
that archives can be listed with `tar -tzf`. Keep restrictive permissions:

```bash
chmod 700 /root/pz-preserved-data
du -sh /root/pz-preserved-data
find /root/pz-preserved-data -maxdepth 2 -type f -name '*.tar.gz' -print
```

The directory above is an **example destination**, not something the installer
creates. Do not run these checks until you have actually created it and moved
your existing data there. Backup content can contain game and Discord secrets;
never upload it to a public repository or issue.

## 3. Remove only the identified game and Panel

1. Stop and disable `wings` and `pteroq` after the game has stopped.
2. Remove the exact, exited game container **without** using a global Docker
   prune. Check for other containers before removing the game-specific network
   and images.
3. Remove the dedicated service unit files identified by `systemctl show`,
   the Panel scheduler in `/etc/cron.d/pterodactyl`, and the Wings executable
   only if those files belong to this deployment. Reload systemd afterward.
4. Remove only the Pterodactyl NGINX site. If NGINX hosts other sites, keep it
   running and reload it instead of uninstalling it.
5. Inspect `SHOW DATABASES` and the Panel's `DB_DATABASE`, `DB_USERNAME`, and
   `DB_HOST` before dropping the Panel database/account. Deleting the Panel
   database also deletes **Panel users, schedules, and backup metadata**; the
   retained `.tar.gz` archives can still be restored manually, but will no
   longer appear in the old Panel.
6. Remove only the verified game volume and then the dedicated directories
   `/var/www/pterodactyl` and `/etc/pterodactyl`. Do not recursively remove
   `/var/lib/pterodactyl` until you have separately identified every file,
   volume, archive, and backup beneath it.

Do not delete an entire directory merely because its name contains
`pterodactyl`: check its contents first. Do not delete other game-server
volumes, database users, or unrelated services.

## 4. Check installer-created host changes

Removing the main game, Panel, and Wings directories is **not** a complete
cleanup. The fresh-host installer can also create these files:

| Path | Purpose / removal consideration |
| --- | --- |
| `/usr/local/sbin/pterodactyl-container-firewall` | Custom Docker firewall script; remove only after Docker/Wings are retired. |
| `/etc/systemd/system/docker.service.d/pterodactyl-firewall.conf` | Docker service override; remove before a future Docker reinstall if no longer needed. |
| `/etc/docker/daemon.json` | Docker logging configuration; preserve if another Docker application uses it. |
| `/etc/apt/sources.list.d/docker.sources` | Docker APT source; keep if Docker will remain in use. |
| `/etc/apt/keyrings/docker.asc` | Docker repository signing key, if unused. |
| `/etc/sysctl.d/99-pterodactyl-memory.conf` | Global swappiness setting. |
| `/etc/systemd/journald.conf.d/pterodactyl-limits.conf` | Global journald limits. |
| `/etc/logrotate.d/wings` | Wings log rotation. |
| `/etc/logrotate.d/pterodactyl-pz` | Game-console log rotation. |
| `/etc/tmpfiles.d/pterodactyl-pz-logs.conf` | Game-log retention. |
| `/etc/letsencrypt/renewal-hooks/deploy/pterodactyl-services` | Certificate renewal hook which reloads removed services. |
| `/var/www/certbot` | ACME webroot; verify no other certificates use it. |
| `/etc/mysql/mariadb.conf.d/99-pterodactyl-bind.cnf` | Database loopback setting; only remove if no longer needed. |
| `/etc/php/8.3/fpm/conf.d/99-pterodactyl-security.ini` | Panel-specific PHP-FPM hardening in newer installer versions. |
| `/etc/hosts` | May contain a Panel hostname entry; remove only that exact entry. |

For each path, use `ls -ld` or inspect the relevant configuration before
removing it. This inventory also applies to a partially failed installation.
Remove service overrides only when their owner service is stopped, then run
`systemctl daemon-reload`.

The installer may also have created `/swapfile` and added it to `/etc/fstab`
**only if no swap was active during installation**. Check `swapon --show` and
the exact `/etc/fstab` entry. Do not delete or disable swap automatically:
other remaining applications may depend on it. Similarly, do not blindly
revert UFW defaults, journald settings, or unattended-upgrades configuration;
these are host-wide settings and their prior values may be unknown.

## 5. Clean up packages, certificates, and firewall rules

- Use `certbot certificates` to identify the **specific** Panel certificate
  before deleting it with Certbot. Check other virtual hosts first.
- Use `apt-get -s purge ...` to preview exact Pterodactyl-only packages.
  Check the removal list for SSH, desktop, or unrelated application packages.
- After that purge, preview `apt-get -s autoremove --purge`; do not run an
  unreviewed autoremove.
- Use `ufw status numbered` and delete only old HTTP/HTTPS, Wings, and game
  port allowances. **Never reset or disable the firewall just to uninstall**;
  keep all needed SSH, RDP, and other service rules.
- Docker's package removal does not necessarily delete its data under
  `/var/lib/docker` and `/var/lib/containerd`. Delete that data only after
  confirming no other container runtime or workload uses it.

## 6. Verify the retained system

```bash
systemctl --failed
systemctl is-active ssh
ufw status numbered
df -h /
apt-get -s autoremove --purge
```

If a desktop/RDP service existed before the deployment, also verify it and
actually reconnect before considering the cleanup complete. Keep the backup
archives in a private location, verify their checksums, and retain offsite
copies before the VPS expires or is reinstalled.
