# Day-to-day server operations

These instructions apply to a server created by `zomboid.sh` on a supported,
dedicated Ubuntu 24.04 VPS. The installer sets up one Pterodactyl Panel, one
Wings node, and one Project Zomboid server. Make changes through the Panel
unless a host command is specifically required.

## Start, stop, and inspect

- **Console**: start and stop the server, read startup and player messages,
  and enter commands such as `save` and `servermsg "Maintenance in 10 minutes"`.
- **Files**: edit `.cache/Server/ProjectZomboid.ini`, sandbox variables, and
  spawn-region configuration. Keep the profile basename consistent with the
  server's **Startup** setting.
- **Schedules**: inspect the daily 04:00 backup and, if enabled, the warned
  00:00/12:00 restart schedule. Their times follow the configured Panel
  timezone; verify this before editing a schedule.
- **Backups**: create and download a verified save-data archive before
  changing map, mods, or game version.
- **Startup**: inspect the `AUTO_UPDATE` variable. The default is `0`.

The game is ready when the console shows `SERVER STARTED`; a container marked
"running" alone is not a guarantee that map scripts and mods loaded cleanly.
After a change, also confirm that a normal player can join.

The installer has no automatic in-place update mechanism for Panel or Wings.
Its release pins are **installation baselines**, not a service that keeps
existing hosts patched. Plan upgrades separately and use upstream guidance.

## Game updates and Workshop mods

Game `AUTO_UPDATE=0` prevents the egg from installing a new game version on
every startup. It does **not** pin remote Workshop content forever; clients
can update their subscriptions while the server retains an older copy, causing
version mismatches.

For a planned game update:

1. Notify players, run `save`, and create/download a successful backup.
2. Stop the game in the Panel.
3. Set **Startup** → `AUTO_UPDATE=1`, then start the game and wait for
   `SERVER STARTED`. Read the startup log for download or script errors.
4. Set `AUTO_UPDATE=0` after the update. Verify client compatibility.

For a Workshop update, first record both `Mods=` (mod IDs) and
`WorkshopItems=` (numeric Steam item IDs) from the game `.ini`. Check the
mod's release notes, supported Project Zomboid version, dependencies, and
whether its author supports updating an existing save. With the game stopped,
start it again and inspect the Workshop download checks in the console. The
game normally checks Workshop items during startup. If a specific item
remains stale, troubleshoot *that item*; do not delete the whole mod directory
or world save.

On the **client**, the error:

```text
ConnectToServerState: item state CheckItemState -> Fail ID=WORKSHOP_ID
```

means that a particular Workshop item failed validation during connection.
On the **server**, useful evidence includes:

```text
Workshop: GetItemState()=Installed ID=WORKSHOP_ID
Workshop: item state CheckItemState -> Ready ID=WORKSHOP_ID
Workshop: onItemDownloaded itemID=WORKSHOP_ID
```

Compare the exact item ID on both sides. `Ready` only confirms the server's
installed state at that instant; it does not prove the client holds the same
version. A client may need Steam to finish an update or to verify the
subscription. Avoid disabling anti-cheat or integrity checks to fix Workshop
mismatches. Server-side redownloads should be isolated to one verified item
and only while the game is stopped.

### Inspect the server without exposing secrets

On the VPS, replace the placeholder below with the server UUID **locally**.
Do not paste the resulting `.ini` or logs into public issues; the `.ini` may
contain a server password or Discord token.

```bash
GAME_VOLUME=/var/lib/pterodactyl/volumes/REPLACE_WITH_SERVER_UUID
test -d "${GAME_VOLUME}/.cache"
grep -E '^(Mods|WorkshopItems|Map)=' \
  "${GAME_VOLUME}/.cache/Server/ProjectZomboid.ini"
grep -E 'Workshop:|SERVER STARTED|Server Terminated' \
  "${GAME_VOLUME}/.cache/server-console.txt" | tail -60
```

When troubleshooting a crash, inspect errors *before* `Server Terminated`.
In particular, `WorldDictionaryException` can be a consequence of earlier
script or missing-mod errors. A line containing `WARN` or a missing optional
media path is not sufficient evidence that startup failed.

## Maps and saves

Changing `Map=` does not convert a populated world into a different map.
Before changing custom maps, preserve the entire save and mod set with the
procedure in [BACKUP-RESTORE.md](BACKUP-RESTORE.md). Start a new world only
when the intended loss of progress is understood. Keep the prior save outside
the active game volume if you need to return to it.

The `.cache/Saves/Multiplayer` directories contain world and character data.
The `.cache/Server` directory contains the game configuration and spawn
region files. Panel user accounts, allocations, schedules, and backup records
live outside those paths.

## Resource and service checks

The default is a 5,120 MiB game container with a 4 GiB Java heap on an
approximately 8 GB host. A larger Java heap than the container allowance can
cause out-of-memory termination; do not use `-Xmx8g` on an 8 GB VPS. Higher
configured player slots alone are not a guarantee of higher memory use, but
actual players, loaded map areas, and mods increase load. Monitor before
raising the limit.

Useful read-only checks on the VPS:

```bash
systemctl --failed
systemctl is-active wings pteroq docker nginx mariadb redis-server
docker ps
docker stats --no-stream
free -h
df -h /
```

If the host runs unrelated services, do not restart or purge their shared
dependencies during game troubleshooting. Keep host memory and disk headroom
for the operating system, Panel, and Wings.

## Network and access

- A public server listing depends on the game settings and Steam discovery;
  it can take time to appear. Test **direct connect** to the configured public
  address and UDP game port before changing firewall rules.
- The installer allows game UDP ports 16261–16262. Do not globally disable
  the Docker firewall or UFW to diagnose discovery.
- Server-password access, player-account creation, and safehouse permissions
  are separate settings. Inspect the live `ProjectZomboid.ini` and the game
  build's supported options before changing access rules.
- Discord integration is optional. Treat any bot token in the `.ini` as a
  secret. A bot being connected does not imply arbitrary server-admin console
  commands can be run through its chat channel.

## Shutdown and recovery

Stop the game cleanly from the Panel before rebooting the VPS, changing map
files, or copying a live world for migration. The normal backup schedule and
optional warned restart schedule are separate; check both after an outage.
For permanent removal use [UNINSTALL.md](UNINSTALL.md). For moving a save to
a new host use [BACKUP-RESTORE.md](BACKUP-RESTORE.md).
