# Project Zomboid on Pterodactyl

> **Looking for a $10.88/year VPS?**
>
> DediRock Promo VPS - New York: https://billing.dedirock.com/aff.php?aff=898&pid=264
>
> DediRock Promo VPS - Los Angeles: https://billing.dedirock.com/aff.php?aff=898&pid=265
>
> **For this set-up, recommended is 4vCPU and 5GB RAM $45/year VPS**
>
> GreenCloudVPS: https://greencloudvps.com/billing/aff.php?aff=10195&gid=68
>
> These are referral/affiliate links, which may provide me with a referral benefit if you sign up through them. Pricing and stock can change.

`zomboid.sh` installs a small, production-oriented Pterodactyl deployment and
one Project Zomboid dedicated server on a **fresh Ubuntu 24.04 amd64 VPS**.
It installs the Panel, Wings, Docker CE, NGINX, MariaDB, Redis, HTTPS, firewall
rules, backups, bounded logging, and the maintained Project Zomboid egg.

This is intentionally a narrow fresh-host installer, not a general Pterodactyl
installer or an updater. Read the script and take a provider snapshot before
using it. Do not run it on a VPS that already hosts applications or data.

## Supported baseline

- Ubuntu 24.04 LTS on amd64/x86_64
- KVM or dedicated hardware; OpenVZ and LXC are rejected
- At least 4 vCPU
- At least approximately 8 GB RAM
- At least 40 GB free on `/`
- A public IPv4 address assigned directly to the VPS
- A panel hostname with a working public DNS `A` record
- Root access through `sudo`

The default game allocation is designed for roughly two to eight players:

- 5,120 MiB Pterodactyl memory limit
- 4 GiB Project Zomboid Java heap
- No container swap
- 350% CPU limit
- 30 GB game disk limit
- Eight player slots
- Private listing
- No Workshop mods or custom maps

The installer accepts at most ten slots, but ten active players or a modded
world can exceed the safe capacity of an 8 GB VPS. Player slots are not a
performance guarantee.

## What is installed

| Component | Pinned baseline |
| --- | --- |
| Pterodactyl Panel | `v1.15.1` |
| Pterodactyl Wings | `v1.13.3` |
| Project Zomboid egg | `pterodactyl/game-eggs` commit `c637a6d1e0449b167efeff81bb9a0177aa3df6c2` |
| Runtime images | `ptero-eggs/steamcmd:debian` and `ptero-eggs/installers:debian`, pinned by manifest digest |
| Project Zomboid Steam app | `380870`, normal stable branch |
| PHP | Ubuntu 24.04 PHP 8.3 packages |
| Container runtime | Docker CE from Docker's official Ubuntu repository |

The pinned Panel and Wings releases were published on 2026-08-14. Their
GitHub release asset SHA-256 digests and the reviewed egg digest are embedded
in the installer and verified before execution continues. The egg's runtime
and installation container tags are rewritten to reviewed GHCR manifest
digests before import.

Upstream references:

- [Pterodactyl Panel installation](https://pterodactyl.io/panel/1.0/getting_started.html)
- [Pterodactyl Wings installation](https://pterodactyl.io/wings/1.0/installing)
- [Pterodactyl Cloudflare guidance](https://pterodactyl.io/wings/1.0/configuration.html#enabling-cloudflare-proxy)
- [Maintained Project Zomboid egg](https://github.com/pterodactyl/game-eggs/tree/main/project_zomboid)
- [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker firewall behavior](https://docs.docker.com/engine/network/packet-filtering-firewalls/)

## DNS preparation

Create an `A` record before running the installer:

```text
panel.example.com -> SERVER_PUBLIC_IPV4
```

If Cloudflare proxying is enabled, use `--cloudflare-proxied`, set Cloudflare
SSL/TLS mode to **Full (strict)**, and ensure edge rules do not intercept
`/.well-known/acme-challenge/`. Pterodactyl's guidance requires Wings on an
HTTPS-compatible Cloudflare port such as 8443 and the node set to **Not Behind
Proxy** when Full SSL is used; this installer applies that layout.

Cloudflare does not conceal the game server IP because players connect to the
VPS directly.

## Recommended interactive workflow

Clone and inspect the repository:

```bash
git clone https://github.com/marl-exe/project-zomboid-pterodactyl.git
cd project-zomboid-pterodactyl
less zomboid.sh
```

Run the non-mutating preflight first:

```bash
sudo ./zomboid.sh --preflight-only
```

The script prompts for:

- Panel and Wings hostname
- Administrator and Let's Encrypt email
- Public IPv4 address
- Panel administrator username and name
- Timezone
- Project Zomboid server display name
- Player limit
- Public or private server listing
- Whether Cloudflare proxying is enabled

If preflight passes, run the installation and review the final summary before
typing `INSTALL`:

```bash
sudo ./zomboid.sh
```

The installer never reboots the VPS.

## Unattended input

Automation is supported, but generated passwords are still created only on the
target VPS. Use placeholders like the following as a format reference and
replace every value:

```bash
sudo ./zomboid.sh \
  --domain panel.example.com \
  --email admin@example.com \
  --public-ip 203.0.113.10 \
  --username admin \
  --first-name Admin \
  --last-name User \
  --timezone UTC \
  --server-name "Project Zomboid" \
  --players 8 \
  --non-interactive \
  --preflight-only
```

Remove `--preflight-only` only after reviewing the checks. Add `--yes` to skip
the final `INSTALL` confirmation. Add `--public-server` only when public server
listing is intentional. Add `--cloudflare-proxied` only for an orange-cloud DNS
record configured as described above.

Use `./zomboid.sh --help` for the complete option list.

## Safety behavior

The installer fails closed when it detects:

- an unsupported OS, CPU architecture, or virtualization type;
- insufficient CPU, RAM, or disk;
- missing or mismatched DNS;
- a public IPv4 not assigned to a host interface;
- occupied required ports;
- an existing Panel, Wings, Docker, MariaDB/MySQL, Redis, or NGINX deployment;
- Docker-conflicting distribution packages;
- an unknown SSH port;
- mismatched Panel, Wings, or egg checksums;
- a failed service, game install, startup, backup, or health check.

It does not remove conflicting packages, reinstall the OS, alter SSH
authentication policy, or reboot. It preserves every configured SSH listening
port when enabling UFW.

The installation is not transactional. If it fails after package installation
begins, inspect the reported error and restore the fresh VPS snapshot before
retrying. Do not repeatedly run the script over a partial deployment.

## Network exposure

The intended inbound ports are:

| Port | Protocol | Purpose |
| --- | --- | --- |
| Existing SSH port(s) | TCP | Administration |
| 80 | TCP | ACME HTTP-01 and HTTPS redirect |
| 443 | TCP | Pterodactyl Panel HTTPS |
| 2022 | TCP | Pterodactyl SFTP |
| 8443 | TCP | Wings HTTPS |
| 16261 | UDP | Project Zomboid primary port |
| 16262 | UDP | Project Zomboid Steam/UDP port |

MariaDB and Redis bind only to loopback.

Docker-published ports bypass ordinary UFW input rules. The installer therefore
adds a persistent `DOCKER-USER` policy through Docker's systemd unit. It allows
only UDP 16261-16262 from the public interface and drops other new public
traffic forwarded to containers. The installer validates these rules after the
game starts.

## Credentials and recovery material

No credentials, tokens, private keys, production domains, or production IPs
are stored in this repository.

At installation time the script generates strong random passwords and stores
them in root-only mode-0600 files:

```text
/root/pterodactyl-initial-credentials.txt
/root/project-zomboid-initial-credentials.txt
/root/pterodactyl-app-key.txt
```

The first two files are displayed once at successful completion. The Panel
`APP_KEY` is deliberately not printed. Copy it from the third file into a
password manager because encrypted Panel data cannot be recovered without it.
After recording and changing the initial passwords, securely remove all three
files from the VPS.

The generated Panel password is delivered to the Panel application over
standard input, not a process argument. Generated secrets are never accepted as
installer command-line options.

## Backups and updates

The server receives a daily 04:00 schedule that sends `save`, waits 30 seconds,
and creates a Wings backup. It keeps at most seven backups and includes world
saves, configuration, and the player database while excluding re-downloadable
game binaries and logs. The installer creates and validates an initial backup.

Backups remain on the same VPS under `/var/lib/pterodactyl/backups`; download
important backups or copy them to independently managed offsite storage.

Automatic game updates are disabled. To update safely:

1. Warn players and create a verified manual backup.
2. Stop the server.
3. In **Startup**, set `AUTO_UPDATE` to `1`.
4. Start the server and wait for `SERVER STARTED` in the console.
5. Set `AUTO_UPDATE` back to `0`.
6. Test client and mod compatibility.

The startup command enforces a 4 GiB Java heap after each update so the vendor
configuration cannot exceed the container limit.

## Routine management

In the Pterodactyl server page:

- **Console** starts, stops, restarts, and sends console commands.
- **Files** edits `.cache/Server/ProjectZomboid.ini`.
- **Files** edits `.cache/Server/ProjectZomboid_SandboxVars.lua`.
- **Backups** creates, locks, restores, downloads, and deletes backups.
- **Schedules** manages the daily backup schedule.
- **Startup** controls the manual update toggle and server variables.

Before adding or removing Workshop mods, create and verify a manual backup,
stop the server, and follow each mod's compatibility and removal guidance.

## Validation

Run the local checks without installing host packages:

```bash
bash tests/test-static.sh
```

The repository also includes a container workflow:

```bash
docker build -f tests/Dockerfile -t pz-installer-test .
docker run --rm pz-installer-test
```

The container runs Bash syntax checks, ShellCheck, help-path validation, and
public-repository safety assertions. These checks do not provision a server and
do not use cloud credentials.

The GitHub Actions workflow builds and runs the same test container on pushes
and pull requests.

## Scope and limitations

- Fresh Ubuntu 24.04 amd64 hosts only.
- One Panel, one same-host Wings node, and one Project Zomboid server.
- No migration, in-place upgrade, uninstall, or rollback automation.
- No SMTP setup; Panel mail uses its log driver initially.
- No Workshop mods or custom maps are installed automatically.
- No automatic daily game restart is configured.
- No offsite backup destination is configured.
- Final operation still requires an administrator who can maintain Linux,
  Pterodactyl, Docker, DNS, TLS, backups, and game compatibility.

Before changing pinned versions, review upstream release notes, update the
corresponding SHA-256 digest, run all repository checks, and test on a disposable
VPS.

---

## Need a VPS?

> DediRock Promo VPS - New York: https://billing.dedirock.com/aff.php?aff=898&pid=264
>
> DediRock Promo VPS - Los Angeles: https://billing.dedirock.com/aff.php?aff=898&pid=265
>
> GreenCloudVPS: https://greencloudvps.com/billing/aff.php?aff=10195&gid=68

These are referral/affiliate links, which may provide me with a referral benefit if you sign up through them. Pricing and stock can change.
