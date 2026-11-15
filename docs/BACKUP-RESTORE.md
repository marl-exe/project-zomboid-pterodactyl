# Back up and restore a modded Project Zomboid server

This guide is for a **manual migration** between installations. The root
`zomboid.sh` remains a fresh-host installer; it must never be run over an
existing Panel to restore a world. Test a restoration on a disposable VPS
before you retire the original server.

## What each backup contains

The installer's Pterodactyl backup schedule deliberately includes `.cache`
(world saves, player database, server `.ini`/Lua settings and spawn regions)
and excludes re-downloadable binaries and logs. Its `.pteroignore` does **not**
include the downloaded Workshop content under `steamapps/workshop`.

| Data | Scheduled Panel backup | Full manual migration |
| --- | --- | --- |
| World saves and player database | Yes | Yes |
| `.cache/Server` configuration and spawn files | Yes | Yes |
| Downloaded mods and custom maps | No | Include `steamapps/workshop` |
| Workshop download manifest | No | Include `appworkshop_108600.acf` |
| Game binaries | No | Reinstall on destination |
| Panel accounts, nodes, schedules, and backup records | No | Recreate separately or plan a separate Panel migration |
| Panel `APP_KEY` and other secrets | No | Store securely outside any public repository |

Workshop ID configuration in `ProjectZomboid.ini` does **not** itself preserve
the downloaded mod or map files. A game save may also depend on items and
world-dictionary entries from installed mods. Do not remove a required mod
just because it appears unused: it can prevent an existing save from loading.

## Before exporting

1. Tell players about maintenance. In the game console send `save`, then use
   **Stop** in Pterodactyl and wait for a clean shutdown.
2. Verify you have enough free space for an archive and check that the archive
   destination is not inside the game volume.
3. Locate the source **server UUID** from the Panel and inspect the exact game
   volume. Do not use the sample placeholder as a real path.

```bash
SOURCE_VOLUME=/var/lib/pterodactyl/volumes/REPLACE_WITH_SOURCE_UUID
test -d "${SOURCE_VOLUME}/.cache/Saves/Multiplayer"
test -d "${SOURCE_VOLUME}/steamapps/workshop/content/108600"
test -f "${SOURCE_VOLUME}/steamapps/workshop/appworkshop_108600.acf"
du -sh "${SOURCE_VOLUME}/.cache" "${SOURCE_VOLUME}/steamapps/workshop"
df -h /
```

For a vanilla, unmodded server, the Workshop paths may not exist. In that
case, omit only the missing Workshop paths from the archive command below.

## Create and verify a migration archive

Only proceed after the checks above succeed and the game is stopped. The
archive contains the existing files; it does not change them.

```bash
umask 077
tar -czf /root/pz-migration.tar.gz -C "${SOURCE_VOLUME}" \
  .cache \
  steamapps/workshop/content/108600 \
  steamapps/workshop/appworkshop_108600.acf

sha256sum /root/pz-migration.tar.gz > /root/pz-migration.tar.gz.sha256
gzip -t /root/pz-migration.tar.gz
tar -tzf /root/pz-migration.tar.gz >/dev/null
ls -lh /root/pz-migration.tar.gz*
```

Download both the archive and checksum file to an independently controlled,
private location before the original VPS is deleted. Verify the checksum on
the destination with `sha256sum -c pz-migration.tar.gz.sha256` after both files
are in the same directory. Do not publish the archive or its checksum list:
`.cache/Server` files can contain passwords, Discord bot tokens, and other
private configuration values.

This migration archive does not preserve the old Panel database, Panel user
accounts, schedule definitions, or TLS settings. If those are required, plan a
**separate, reviewed Panel migration** instead of importing a database over
an already provisioned fresh Panel.

## Restore to a new Pterodactyl installation

1. Run the fresh installer on a **new, empty** supported VPS. Complete its
   installation, create or identify the destination server, and **Stop** it.
2. Upload the verified archive and checksum through a private channel.
3. Identify the new server's UUID and volume path. It will usually differ
   from the source UUID. Confirm the path contains the expected *new*
   game-server files before moving anything.
4. Extract the trusted archive into a separate staging directory; never
   extract an untrusted archive over `/` or directly into the game volume.

```bash
TARGET_VOLUME=/var/lib/pterodactyl/volumes/REPLACE_WITH_TARGET_UUID
test -d "${TARGET_VOLUME}/.cache"
test ! -e "${TARGET_VOLUME}/.cache.before-restore"
test ! -e /root/pz-restore-staging
sha256sum -c /root/pz-migration.tar.gz.sha256
tar -tzf /root/pz-migration.tar.gz | head -30
mkdir -m 0700 /root/pz-restore-staging
tar --no-same-owner -xzf /root/pz-migration.tar.gz -C /root/pz-restore-staging
```

If either existence check fails, inspect the old restore attempt and choose
different paths; do not overwrite it. Verify that the archive contains only
the intended `.cache` and Workshop paths before extracting it. The following
example assumes the new game has no progress worth retaining. If it does,
preserve that data separately first.

```bash
mv "${TARGET_VOLUME}/.cache" "${TARGET_VOLUME}/.cache.before-restore"
cp -a /root/pz-restore-staging/.cache "${TARGET_VOLUME}/.cache"
mkdir -p "${TARGET_VOLUME}/steamapps/workshop"
cp -a /root/pz-restore-staging/steamapps/workshop/. "${TARGET_VOLUME}/steamapps/workshop/"
TARGET_OWNER=$(stat -c '%u:%g' "${TARGET_VOLUME}")
chown -R "${TARGET_OWNER}" "${TARGET_VOLUME}/.cache" "${TARGET_VOLUME}/steamapps/workshop"
```

The `.cache.before-restore` directory is an on-disk fallback, not an offsite
backup. Remove it only after confirming the restored world works. Adjust the
Workshop copy step if you intentionally exported an unmodded server.

## Bring the world online carefully

1. In the new Panel's **Startup** page, make the game profile/server config
   basename match the files under `.cache/Server` (often `ProjectZomboid`).
2. Review `ProjectZomboid.ini`: `Map`, `Mods`, `WorkshopItems`, public listing,
   password, and announced public address may need to change for the new VPS.
3. Review spawn-region files and mod dependencies. Custom-map names and
   Workshop IDs must match the versions actually installed.
4. Start the game, watch startup logs for script or world-dictionary errors,
   and confirm `SERVER STARTED` before accepting player connections.
5. Test a player account, existing character, world location, safehouse, and
   inventory. Check a client for Workshop mismatch messages.
6. Recreate or inspect Panel-level schedules, backup retention, allocations,
   and access permissions. The fresh installer provides its own default
   backup schedule and optional restart schedule, but those are not restored
   from a game-data archive.
7. Generate and download a **new, verified** backup before opening the server
   to the public or decommissioning the source.

Never use a migration archive as a reason to run the fresh installer a second
time over a populated server. If the restored world fails, stop the game and
restore the preserved pre-restore state before troubleshooting further.
