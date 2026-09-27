#!/usr/bin/env bash

set -Eeuo pipefail

readonly PANEL_VERSION_DEFAULT="v1.15.1"
readonly WINGS_VERSION_DEFAULT="v1.13.3"
readonly EGG_COMMIT_DEFAULT="c637a6d1e0449b167efeff81bb9a0177aa3df6c2"
readonly PANEL_SHA256="62c88c035b3e0f3c3ddd06bc3ef12249d087af0e765f49878b6327a066ed860b"
readonly WINGS_SHA256="010d894a895fe4f914e3f1c1e75fb2fda4ebe50cc249e7e456887ea5b422c8fa"
readonly EGG_SHA256="0326e0d0411b7039bf326fb1438fa29687163af0c2ccb37b7e62adacd677fb45"
readonly STEAMCMD_IMAGE="ghcr.io/ptero-eggs/steamcmd:debian@sha256:c8a93dc0e256d1dba10aed6a0d8d6e739d4f1809f4e3b7428d0c01adc6e6e68b"
readonly INSTALLER_IMAGE="ghcr.io/ptero-eggs/installers:debian@sha256:084e7a28d9902d054b35bcad7c547bcd3b5739040b9e0f5bfe63bb18ce021423"
readonly PANEL_ROOT="/var/www/pterodactyl"
readonly WINGS_ROOT="/etc/pterodactyl"
readonly WINGS_DATA="/var/lib/pterodactyl"
readonly PANEL_CREDENTIAL_FILE="/root/pterodactyl-initial-credentials.txt"
readonly PZ_CREDENTIAL_FILE="/root/project-zomboid-initial-credentials.txt"
readonly PANEL_RECOVERY_FILE="/root/pterodactyl-app-key.txt"

PANEL_DOMAIN=""
LE_EMAIL=""
PUBLIC_IP=""
PANEL_USERNAME=""
FIRST_NAME=""
LAST_NAME=""
PANEL_VERSION="${PANEL_VERSION_DEFAULT}"
WINGS_VERSION="${WINGS_VERSION_DEFAULT}"
EGG_COMMIT="${EGG_COMMIT_DEFAULT}"
TIMEZONE="Asia/Manila"
SERVER_DISPLAY_NAME="Project Zomboid"
PLAYER_LIMIT=8
PUBLIC_SERVER=false
CLOUDFLARE_PROXIED=false
PREFLIGHT_ONLY=false
ASSUME_YES=false
NON_INTERACTIVE=false
TIMEZONE_SET=false
SERVER_NAME_SET=false
PLAYER_LIMIT_SET=false
PUBLIC_SERVER_SET=false
CLOUDFLARE_SET=false
WORK_DIR=""
ADMIN_HELPER=""
DNS_IPV4=""
PUBLIC_INTERFACE=""
declare -a SSH_PORTS=()

usage() {
    cat <<'EOF'
Install Pterodactyl Panel, Wings, and a bounded Project Zomboid server on a
fresh Ubuntu 24.04 amd64 VPS. This installer never reboots the VPS.

Interactive usage:
  sudo ./zomboid.sh

Unattended usage:
  sudo ./zomboid.sh \
    --domain panel.example.com \
    --email admin@example.com \
    --public-ip 203.0.113.10 \
    --username admin \
    --first-name Admin \
    --last-name User \
    --non-interactive [options]

Inputs (prompted when omitted in interactive mode):
  --domain FQDN           Panel and Wings hostname with working public DNS
  --email ADDRESS         Panel administrator and Let's Encrypt email
  --public-ip IPV4        Public IPv4 used by Project Zomboid allocations
  --username NAME         Panel administrator username
  --first-name NAME       Panel administrator first name
  --last-name NAME        Panel administrator last name

Options:
  --timezone ZONE         Panel/game timezone (default: Asia/Manila)
  --server-name NAME      Panel game-server name (default: Project Zomboid)
  --players NUMBER        Initial player limit, 1-10 (default: 8)
  --public-server         Set Public=true instead of the private default
  --cloudflare-proxied    DNS is proxied by Cloudflare; requires Full (strict)
  --preflight-only        Validate the host and DNS, then exit without changes
  --non-interactive       Do not prompt; all required inputs must be supplied
  --yes                   Skip the interactive INSTALL confirmation
  -h, --help              Show this help

Safe baseline:
  - 5,120 MiB game memory, 4 GiB Java heap, no container swap
  - 350% CPU, 30 GB game disk, private, no Workshop mods by default
  - daily 04:00 save-data backup with a seven-backup limit
  - manual game updates through AUTO_UPDATE
  - UFW, HTTPS, loopback-only database services, bounded logs

This is a fresh-host installer. It refuses an existing Panel, Wings, Docker,
MariaDB/MySQL, Redis, NGINX, Docker daemon configuration, or credential files.
For proxied Cloudflare DNS, edge redirects must not block the ACME HTTP path.
EOF
}

log() {
    printf '[%s] %s\n' "$(date -Is)" "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local exit_code=$?
    if [[ -n ${ADMIN_HELPER} && ${ADMIN_HELPER} == "${PANEL_ROOT}"/storage/create-admin.*.php ]]; then
        rm -f -- "${ADMIN_HELPER}"
    fi
    if [[ -n ${WORK_DIR} && -d ${WORK_DIR} && ${WORK_DIR} == /tmp/zomboid-installer.* ]]; then
        rm -rf -- "${WORK_DIR}"
    fi
    if (( exit_code != 0 )); then
        printf 'Installation stopped with an error. Review the last message before retrying.\n' >&2
        if [[ -e ${PANEL_CREDENTIAL_FILE} || -e ${PZ_CREDENTIAL_FILE} || -e ${PANEL_RECOVERY_FILE} ]]; then
            printf 'Generated credentials or recovery material, if any, remain root-only under /root.\n' >&2
        fi
    fi
    exit "${exit_code}"
}

trap cleanup EXIT
trap 'fail "Command failed at line ${LINENO}."' ERR

valid_ipv4() {
    local value=$1
    local octet
    local -a octets

    [[ ${value} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<<"${value}"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        [[ ${octet} =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#${octet} <= 255)) || return 1
    done
}

valid_fqdn() {
    local value=$1
    local label
    local -a labels

    ((${#value} <= 253)) || return 1
    [[ ${value} == *.* && ${value} != .* && ${value} != *. ]] || return 1
    IFS=. read -r -a labels <<<"${value}"
    ((${#labels[@]} >= 2)) || return 1
    for label in "${labels[@]}"; do
        ((${#label} >= 1 && ${#label} <= 63)) || return 1
        [[ ${label} =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

prompt_value() {
    local variable_name=$1
    local prompt_text=$2
    local default_value=${3:-}
    local answer=""

    if [[ -n ${default_value} ]]; then
        read -r -p "${prompt_text} [${default_value}]: " answer
        answer=${answer:-${default_value}}
    else
        while [[ -z ${answer} ]]; do
            read -r -p "${prompt_text}: " answer
        done
    fi
    printf -v "${variable_name}" '%s' "${answer}"
}

prompt_boolean() {
    local variable_name=$1
    local prompt_text=$2
    local default_value=$3
    local suffix='[y/N]'
    local answer=""

    [[ ${default_value} == true ]] && suffix='[Y/n]'
    while true; do
        read -r -p "${prompt_text} ${suffix}: " answer
        answer=${answer:-${default_value}}
        case "${answer,,}" in
            y|yes|true) printf -v "${variable_name}" '%s' true; return 0 ;;
            n|no|false) printf -v "${variable_name}" '%s' false; return 0 ;;
        esac
        printf 'Please answer yes or no.\n' >&2
    done
}

while (($# > 0)); do
    case "$1" in
        --domain)
            (($# >= 2)) || fail '--domain requires a value.'
            PANEL_DOMAIN=$2
            shift 2
            ;;
        --email)
            (($# >= 2)) || fail '--email requires a value.'
            LE_EMAIL=$2
            shift 2
            ;;
        --public-ip)
            (($# >= 2)) || fail '--public-ip requires a value.'
            PUBLIC_IP=$2
            shift 2
            ;;
        --username)
            (($# >= 2)) || fail '--username requires a value.'
            PANEL_USERNAME=$2
            shift 2
            ;;
        --first-name)
            (($# >= 2)) || fail '--first-name requires a value.'
            FIRST_NAME=$2
            shift 2
            ;;
        --last-name)
            (($# >= 2)) || fail '--last-name requires a value.'
            LAST_NAME=$2
            shift 2
            ;;
        --timezone)
            (($# >= 2)) || fail '--timezone requires a value.'
            TIMEZONE=$2
            TIMEZONE_SET=true
            shift 2
            ;;
        --server-name)
            (($# >= 2)) || fail '--server-name requires a value.'
            SERVER_DISPLAY_NAME=$2
            SERVER_NAME_SET=true
            shift 2
            ;;
        --players)
            (($# >= 2)) || fail '--players requires a value.'
            PLAYER_LIMIT=$2
            PLAYER_LIMIT_SET=true
            shift 2
            ;;
        --public-server)
            PUBLIC_SERVER=true
            PUBLIC_SERVER_SET=true
            shift
            ;;
        --cloudflare-proxied)
            CLOUDFLARE_PROXIED=true
            CLOUDFLARE_SET=true
            shift
            ;;
        --preflight-only)
            PREFLIGHT_ONLY=true
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --yes)
            ASSUME_YES=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ ${EUID} -eq 0 ]] || fail 'Run this installer as root with sudo.'

if [[ ${NON_INTERACTIVE} == false ]]; then
    [[ -t 0 ]] || fail 'Interactive mode requires a terminal. Use --non-interactive with all required inputs.'
    detected_ip=""
    if command -v ip >/dev/null 2>&1; then
        detected_ip=$(ip -o -4 address show scope global 2>/dev/null | awk 'NR == 1 {sub(/\/.*/, "", $4); print $4}')
    fi
    [[ -n ${PANEL_DOMAIN} ]] || prompt_value PANEL_DOMAIN 'Panel and Wings domain (for example, panel.example.com)'
    [[ -n ${LE_EMAIL} ]] || prompt_value LE_EMAIL "Administrator and Let's Encrypt email"
    [[ -n ${PUBLIC_IP} ]] || prompt_value PUBLIC_IP 'Public IPv4 address' "${detected_ip}"
    [[ -n ${PANEL_USERNAME} ]] || prompt_value PANEL_USERNAME 'Panel administrator username' 'admin'
    [[ -n ${FIRST_NAME} ]] || prompt_value FIRST_NAME 'Panel administrator first name' 'Admin'
    [[ -n ${LAST_NAME} ]] || prompt_value LAST_NAME 'Panel administrator last name' 'User'
    [[ ${TIMEZONE_SET} == true ]] || prompt_value TIMEZONE 'Timezone' "${TIMEZONE}"
    [[ ${SERVER_NAME_SET} == true ]] || prompt_value SERVER_DISPLAY_NAME 'Project Zomboid server display name' "${SERVER_DISPLAY_NAME}"
    [[ ${PLAYER_LIMIT_SET} == true ]] || prompt_value PLAYER_LIMIT 'Maximum players (1-10)' "${PLAYER_LIMIT}"
    [[ ${PUBLIC_SERVER_SET} == true ]] || prompt_boolean PUBLIC_SERVER 'List this Project Zomboid server publicly?' false
    [[ ${CLOUDFLARE_SET} == true ]] || prompt_boolean CLOUDFLARE_PROXIED 'Is the domain orange-cloud proxied by Cloudflare?' false
fi

[[ -n ${PANEL_DOMAIN} && -n ${LE_EMAIL} && -n ${PUBLIC_IP} ]] || fail 'Domain, email, and public IPv4 are required.'
[[ -n ${PANEL_USERNAME} && -n ${FIRST_NAME} && -n ${LAST_NAME} ]] || fail 'Administrator username, first name, and last name are required.'
valid_fqdn "${PANEL_DOMAIN}" || fail 'Invalid fully qualified domain name.'
[[ ${LE_EMAIL} =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fail 'Invalid email address.'
[[ ${PANEL_USERNAME} =~ ^[A-Za-z0-9_.-]{3,32}$ ]] || fail 'Username must be 3-32 letters, numbers, dots, underscores, or hyphens.'
[[ ! ${FIRST_NAME} =~ [[:cntrl:]] && ${#FIRST_NAME} -le 191 ]] || fail 'Invalid first name.'
[[ ! ${LAST_NAME} =~ [[:cntrl:]] && ${#LAST_NAME} -le 191 ]] || fail 'Invalid last name.'
[[ -n ${SERVER_DISPLAY_NAME} && ! ${SERVER_DISPLAY_NAME} =~ [[:cntrl:]] && ${#SERVER_DISPLAY_NAME} -le 191 ]] || fail 'Invalid server name.'
[[ ${PLAYER_LIMIT} =~ ^[0-9]+$ ]] && ((PLAYER_LIMIT >= 1 && PLAYER_LIMIT <= 10)) || fail 'Player limit must be between 1 and 10.'
valid_ipv4 "${PUBLIC_IP}" || fail 'Invalid public IPv4 address.'
[[ ${TIMEZONE} =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$ && ${TIMEZONE} != *..* ]] || fail 'Invalid timezone name.'
[[ -e /usr/share/zoneinfo/${TIMEZONE} ]] || fail 'The requested timezone does not exist in /usr/share/zoneinfo.'

log 'Running fail-closed preflight checks.'
[[ -r /etc/os-release ]] || fail '/etc/os-release is unavailable.'
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] || fail 'This installer supports only Ubuntu 24.04 LTS.'
[[ $(uname -m) == x86_64 ]] || fail 'This installer currently supports only amd64/x86_64.'
(( $(nproc) >= 4 )) || fail 'At least four vCPUs are required.'

memory_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
(( memory_kib >= 7000000 )) || fail 'At least approximately 8 GB RAM is required.'
disk_available_mib=$(df --output=avail -BM / | tail -1 | tr -dc '0-9')
(( disk_available_mib >= 40000 )) || fail 'At least 40 GB free on / is required.'

for path in \
    "${PANEL_ROOT}" \
    "${WINGS_ROOT}" \
    /etc/docker/daemon.json \
    "${PANEL_CREDENTIAL_FILE}" \
    "${PZ_CREDENTIAL_FILE}" \
    "${PANEL_RECOVERY_FILE}"; do
    [[ ! -e ${path} ]] || fail "Refusing to overwrite existing deployment data: ${path}"
done

for command_name in ss getent awk grep sort paste ip df nproc sha256sum systemctl systemd-detect-virt dpkg-query /usr/sbin/sshd; do
    command -v "${command_name}" >/dev/null || fail "Required preflight command is missing: ${command_name}"
done

existing_failed_units=$(systemctl --failed --no-legend --plain)
if [[ -n ${existing_failed_units} ]]; then
    printf '%s\n' 'Existing failed systemd units:' >&2
    printf '%s\n' "${existing_failed_units}" >&2
    fail 'Resolve existing failed units before installing.'
fi

virtualization=$(systemd-detect-virt 2>/dev/null || true)
case "${virtualization}" in
    openvz|lxc)
        fail "Unsupported virtualization for Docker/Wings: ${virtualization}. Use a KVM VPS or dedicated server."
        ;;
esac

for conflicting_package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "${conflicting_package}" 2>/dev/null | grep -q '^ii'; then
        fail "Conflicting package detected: ${conflicting_package}. This installer will not remove existing packages."
    fi
done

for existing_service in docker mariadb mysql redis-server nginx; do
    if command -v "${existing_service}" >/dev/null; then
        fail "Existing ${existing_service} installation detected; this fresh-host installer will not alter it."
    fi
done

if [[ -d /etc/nginx/sites-enabled ]] && [[ -n $(find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 ! -name default -print -quit) ]]; then
    fail 'Existing non-default NGINX sites were detected.'
fi

mapfile -t SSH_PORTS < <(/usr/sbin/sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -nu)
((${#SSH_PORTS[@]} > 0)) || fail 'Could not determine the active SSH port; refusing to configure UFW.'

preflight_listeners=$(ss -H -lntup 2>/dev/null | awk '{print $5}')
for port in 80 443 2022 8443 16261 16262; do
    if grep -Eq "(^|[.:])${port}$" <<<"${preflight_listeners}"; then
        fail "Required port ${port} is already in use."
    fi
done

DNS_IPV4=$(getent ahostsv4 "${PANEL_DOMAIN}" | awk '{print $1}' | sort -u | paste -sd, -)
[[ -n ${DNS_IPV4} ]] || fail "${PANEL_DOMAIN} has no public IPv4 DNS result."
if [[ ${CLOUDFLARE_PROXIED} == false ]]; then
    [[ ,${DNS_IPV4}, == *",${PUBLIC_IP},"* ]] || fail "DNS for ${PANEL_DOMAIN} does not include ${PUBLIC_IP}."
fi

global_addresses=$(ip -4 address show scope global)
if ! grep -Fq "${PUBLIC_IP}/" <<<"${global_addresses}"; then
    fail "${PUBLIC_IP} is not assigned to a global interface on this VPS."
fi
PUBLIC_INTERFACE=$(ip -o -4 address show scope global | awk -v address="${PUBLIC_IP}" '$4 ~ ("^" address "/") {print $2; exit}')
[[ -n ${PUBLIC_INTERFACE} ]] || fail 'Could not determine the public network interface.'

log "Preflight passed: Ubuntu ${VERSION_ID}, $(nproc) vCPU, $((memory_kib / 1024)) MiB RAM, ${disk_available_mib} MiB free."
log "DNS IPv4 result(s): ${DNS_IPV4}"
if [[ ${CLOUDFLARE_PROXIED} == true ]]; then
    log 'Cloudflare proxy mode selected. Set SSL/TLS encryption to Full (strict) before installation.'
fi
if ((PLAYER_LIMIT > 8)); then
    log 'Warning: more than eight players reduces memory headroom on an 8 GB VPS; monitor actual usage closely.'
fi

if [[ ${PREFLIGHT_ONLY} == true ]]; then
    log 'Preflight-only mode completed; no changes were made.'
    exit 0
fi

printf '\nInstallation target:\n'
printf '  Panel:       https://%s\n' "${PANEL_DOMAIN}"
printf '  Public IPv4: %s\n' "${PUBLIC_IP}"
printf '  Admin:       %s <%s>\n' "${PANEL_USERNAME}" "${LE_EMAIL}"
printf '  Game server: %s (%s players, public=%s)\n' "${SERVER_DISPLAY_NAME}" "${PLAYER_LIMIT}" "${PUBLIC_SERVER}"
printf '  Versions:    Panel %s, Wings %s\n\n' "${PANEL_VERSION}" "${WINGS_VERSION}"

if [[ ${ASSUME_YES} == false ]]; then
    read -r -p 'Type INSTALL to continue: ' confirmation
    [[ ${confirmation} == INSTALL ]] || fail 'Installation cancelled.'
fi

WORK_DIR=$(mktemp -d /tmp/zomboid-installer.XXXXXXXX)
umask 077
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

log 'Installing Ubuntu dependencies.'
apt-get update
apt-get install -y \
    ca-certificates \
    certbot \
    composer \
    cron \
    curl \
    git \
    gnupg \
    iptables \
    logrotate \
    mariadb-server \
    nginx \
    openssl \
    php8.3-bcmath \
    php8.3-cli \
    php8.3-common \
    php8.3-curl \
    php8.3-fpm \
    php8.3-gd \
    php8.3-mbstring \
    php8.3-mysql \
    php8.3-xml \
    php8.3-zip \
    redis-server \
    sudo \
    tar \
    ufw \
    unattended-upgrades \
    unzip

log 'Configuring Docker from the official stable repository.'
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
docker_arch=$(dpkg --print-architecture)
docker_codename=${UBUNTU_CODENAME:-${VERSION_CODENAME}}
{
    printf '%s\n' 'Types: deb'
    printf '%s\n' 'URIs: https://download.docker.com/linux/ubuntu'
    printf 'Suites: %s\n' "${docker_codename}"
    printf '%s\n' 'Components: stable'
    printf 'Architectures: %s\n' "${docker_arch}"
    printf '%s\n' 'Signed-By: /etc/apt/keyrings/docker.asc'
} >/etc/apt/sources.list.d/docker.sources
apt-get update
apt-get install -y containerd.io docker-buildx-plugin docker-ce docker-ce-cli docker-compose-plugin

install -d -m 0755 /etc/docker
install -m 0644 /dev/null /etc/docker/daemon.json
cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

cat >"${WORK_DIR}/pterodactyl-container-firewall" <<EOF
#!/usr/bin/env bash

set -Eeuo pipefail

readonly public_interface='${PUBLIC_INTERFACE}'
readonly public_ip='${PUBLIC_IP}'
readonly managed_chain='PTERODACTYL-FILTER'

/usr/sbin/iptables --wait -N "\${managed_chain}" 2>/dev/null || true
/usr/sbin/iptables --wait -F "\${managed_chain}"
while /usr/sbin/iptables --wait -D DOCKER-USER -j "\${managed_chain}" 2>/dev/null; do :; done
/usr/sbin/iptables --wait -I DOCKER-USER 1 -j "\${managed_chain}"
/usr/sbin/iptables --wait -A "\${managed_chain}" \
    -i "\${public_interface}" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
/usr/sbin/iptables --wait -A "\${managed_chain}" \
    -i "\${public_interface}" -p udp -m conntrack \
    --ctorigdst "\${public_ip}" --ctorigdstport 16261:16262 -j RETURN
/usr/sbin/iptables --wait -A "\${managed_chain}" \
    -i "\${public_interface}" -m conntrack --ctorigdst "\${public_ip}" -j DROP
/usr/sbin/iptables --wait -A "\${managed_chain}" -j RETURN
EOF
install -m 0755 "${WORK_DIR}/pterodactyl-container-firewall" /usr/local/sbin/pterodactyl-container-firewall
install -d -m 0755 /etc/systemd/system/docker.service.d
cat >"${WORK_DIR}/docker-firewall.conf" <<'EOF'
[Service]
ExecStartPost=/usr/local/sbin/pterodactyl-container-firewall
EOF
install -m 0644 "${WORK_DIR}/docker-firewall.conf" /etc/systemd/system/docker.service.d/pterodactyl-firewall.conf

install -m 0644 /dev/null /etc/sysctl.d/99-pterodactyl-memory.conf
printf '%s\n' 'vm.swappiness=10' >/etc/sysctl.d/99-pterodactyl-memory.conf
if [[ $(swapon --noheadings --show=NAME | wc -l) -eq 0 ]]; then
    log 'No swap detected; creating a conservative 2 GiB swapfile.'
    [[ ! -e /swapfile ]] || fail '/swapfile exists but is not active; inspect it manually.'
    fallocate -l 2G /swapfile
    chmod 0600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -Eq '^/swapfile[[:space:]]' /etc/fstab || printf '%s\n' '/swapfile none swap sw 0 0' >>/etc/fstab
fi
sysctl --system >/dev/null

install -m 0644 /dev/null /etc/apt/apt.conf.d/20auto-upgrades
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl daemon-reload
systemctl enable --now docker mariadb redis-server php8.3-fpm cron
systemctl restart docker

install -m 0644 /dev/null /etc/mysql/mariadb.conf.d/99-pterodactyl-bind.cnf
cat >/etc/mysql/mariadb.conf.d/99-pterodactyl-bind.cnf <<'EOF'
[mysqld]
bind-address = 127.0.0.1
EOF
systemctl restart mariadb

log "Downloading official Pterodactyl Panel ${PANEL_VERSION}."
install -d -m 0755 "${PANEL_ROOT}"
curl -fL "https://github.com/pterodactyl/panel/releases/download/${PANEL_VERSION}/panel.tar.gz" -o "${WORK_DIR}/panel.tar.gz"
printf '%s  %s\n' "${PANEL_SHA256}" "${WORK_DIR}/panel.tar.gz" | sha256sum --check --status \
    || fail 'The Panel release archive checksum does not match the pinned official release.'
tar -xzf "${WORK_DIR}/panel.tar.gz" -C "${PANEL_ROOT}"
[[ -f ${PANEL_ROOT}/artisan ]] || fail 'The Panel release archive did not contain artisan.'

cd "${PANEL_ROOT}"
cp .env.example .env
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
php artisan key:generate --force --no-interaction
app_key=$(sed -n 's/^APP_KEY=//p' "${PANEL_ROOT}/.env")
[[ ${app_key} == base64:* ]] || fail 'Panel APP_KEY generation returned an unexpected value.'
printf 'APP_KEY=%s\n' "${app_key}" >"${WORK_DIR}/panel-app-key"
install -m 0600 "${WORK_DIR}/panel-app-key" "${PANEL_RECOVERY_FILE}"
unset app_key

set_env_value() {
    local key=$1
    local value=$2
    if grep -q "^${key}=" "${PANEL_ROOT}/.env"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${PANEL_ROOT}/.env"
    else
        printf '%s=%s\n' "${key}" "${value}" >>"${PANEL_ROOT}/.env"
    fi
}

db_password=$(openssl rand -hex 32)
log 'Creating the loopback-only Panel database and account.'
mariadb --protocol=socket <<SQL
CREATE DATABASE panel CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

set_env_value APP_ENV production
set_env_value APP_DEBUG false
set_env_value APP_TIMEZONE "${TIMEZONE}"
set_env_value APP_URL "https://${PANEL_DOMAIN}"
set_env_value LOG_CHANNEL daily
set_env_value LOG_LEVEL info
set_env_value DB_CONNECTION mysql
set_env_value DB_HOST 127.0.0.1
set_env_value DB_PORT 3306
set_env_value DB_DATABASE panel
set_env_value DB_USERNAME pterodactyl
set_env_value DB_PASSWORD "${db_password}"
set_env_value REDIS_HOST 127.0.0.1
set_env_value REDIS_PASSWORD null
set_env_value REDIS_PORT 6379
set_env_value CACHE_DRIVER redis
set_env_value QUEUE_CONNECTION redis
set_env_value SESSION_DRIVER redis
set_env_value MAIL_MAILER log
set_env_value MAIL_FROM_ADDRESS "no-reply@${PANEL_DOMAIN}"
set_env_value MAIL_FROM_NAME '"Pterodactyl Panel"'
set_env_value APP_BACKUP_DRIVER wings
set_env_value PTERODACTYL_TELEMETRY_ENABLED false
set_env_value RECAPTCHA_ENABLED true

unset db_password
chown -R www-data:www-data "${PANEL_ROOT}"
find "${PANEL_ROOT}/storage" "${PANEL_ROOT}/bootstrap/cache" -type d -exec chmod 0755 {} +
find "${PANEL_ROOT}/storage" "${PANEL_ROOT}/bootstrap/cache" -type f -exec chmod 0644 {} +
chmod 0640 "${PANEL_ROOT}/.env"

log 'Running Panel migrations and production configuration.'
sudo -u www-data php artisan config:clear
sudo -u www-data php artisan migrate --seed --force
sudo -u www-data php artisan p:environment:setup \
    --author="${LE_EMAIL}" \
    --url="https://${PANEL_DOMAIN}" \
    --timezone="${TIMEZONE}" \
    --cache=redis \
    --session=redis \
    --queue=redis \
    --redis-host=127.0.0.1 \
    --redis-pass=null \
    --redis-port=6379 \
    --settings-ui=false \
    --telemetry=false \
    --no-interaction
set_env_value APP_BACKUP_DRIVER wings
set_env_value RECAPTCHA_ENABLED true
chown www-data:www-data "${PANEL_ROOT}/.env"
chmod 0640 "${PANEL_ROOT}/.env"
sudo -u www-data php artisan optimize:clear

panel_password="Pz$(openssl rand -hex 20)A7"
log "Creating Panel administrator ${PANEL_USERNAME}."
ADMIN_HELPER=$(mktemp "${PANEL_ROOT}/storage/create-admin.XXXXXXXX.php")
cat >"${ADMIN_HELPER}" <<'PHP'
<?php

declare(strict_types=1);

use Illuminate\Contracts\Console\Kernel;
use Pterodactyl\Services\Users\UserCreationService;

const PANEL_ROOT = '/var/www/pterodactyl';

require PANEL_ROOT . '/vendor/autoload.php';
$app = require PANEL_ROOT . '/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$values = file('php://stdin', FILE_IGNORE_NEW_LINES);
if ($values === false || count($values) !== 6) {
    throw new RuntimeException('Expected six administrator fields on standard input.');
}

[$email, $username, $firstName, $lastName, $password, $rootAdmin] = $values;
$app->make(UserCreationService::class)->handle([
    'email' => $email,
    'username' => $username,
    'name_first' => $firstName,
    'name_last' => $lastName,
    'password' => $password,
    'root_admin' => $rootAdmin === '1',
]);
PHP
chown www-data:www-data "${ADMIN_HELPER}"
chmod 0600 "${ADMIN_HELPER}"
printf '%s\n' \
    "${LE_EMAIL}" \
    "${PANEL_USERNAME}" \
    "${FIRST_NAME}" \
    "${LAST_NAME}" \
    "${panel_password}" \
    '1' \
    | sudo -u www-data php "${ADMIN_HELPER}"
rm -f -- "${ADMIN_HELPER}"
ADMIN_HELPER=""
{
    printf 'Panel URL: https://%s\n' "${PANEL_DOMAIN}"
    printf 'Email: %s\n' "${LE_EMAIL}"
    printf 'Username: %s\n' "${PANEL_USERNAME}"
    printf 'One-time password: %s\n' "${panel_password}"
} >"${WORK_DIR}/panel-credentials"
install -m 0600 "${WORK_DIR}/panel-credentials" "${PANEL_CREDENTIAL_FILE}"
unset panel_password

cat >"${WORK_DIR}/pteroq.service" <<'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service mariadb.service
Requires=redis-server.service mariadb.service
StartLimitIntervalSec=180
StartLimitBurst=30

[Service]
User=www-data
Group=www-data
Restart=always
RestartSec=5s
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
EOF
install -m 0644 "${WORK_DIR}/pteroq.service" /etc/systemd/system/pteroq.service
printf '%s\n' '* * * * * www-data /usr/bin/php /var/www/pterodactyl/artisan schedule:run >/dev/null 2>&1' >"${WORK_DIR}/pterodactyl-cron"
install -m 0644 "${WORK_DIR}/pterodactyl-cron" /etc/cron.d/pterodactyl

install -d -m 0755 /etc/systemd/journald.conf.d
cat >"${WORK_DIR}/journald.conf" <<'EOF'
[Journal]
SystemMaxUse=256M
RuntimeMaxUse=64M
MaxRetentionSec=14day
Compress=yes
EOF
install -m 0644 "${WORK_DIR}/journald.conf" /etc/systemd/journald.conf.d/pterodactyl-limits.conf

cat >"${WORK_DIR}/wings-logrotate" <<'EOF'
/var/log/pterodactyl/wings.log {
    size 10M
    compress
    delaycompress
    dateext
    maxage 7
    missingok
    notifempty
    postrotate
        /usr/bin/systemctl kill -s HUP wings.service >/dev/null 2>&1 || true
    endscript
}
EOF
install -m 0644 "${WORK_DIR}/wings-logrotate" /etc/logrotate.d/wings
systemctl daemon-reload
systemctl enable --now pteroq
systemctl restart systemd-journald

log 'Creating an NGINX ACME webroot and requesting the certificate.'
install -d -m 0755 /var/www/certbot /etc/nginx/sites-available /etc/nginx/sites-enabled
rm -f /etc/nginx/sites-enabled/default
cat >"${WORK_DIR}/nginx-bootstrap.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PANEL_DOMAIN};
    root /var/www/certbot;

    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 503;
    }
}
EOF
install -m 0644 "${WORK_DIR}/nginx-bootstrap.conf" /etc/nginx/sites-available/pterodactyl.conf
ln -sfn /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t
systemctl enable --now nginx

log 'Applying the least-exposure UFW policy while preserving the configured SSH port.'
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
for ssh_port in "${SSH_PORTS[@]}"; do
    ufw allow "${ssh_port}/tcp" comment 'SSH administration'
done
ufw allow 80/tcp comment 'Panel HTTP and ACME'
ufw allow 443/tcp comment 'Pterodactyl Panel HTTPS'
ufw allow 2022/tcp comment 'Pterodactyl SFTP'
ufw allow 8443/tcp comment 'Pterodactyl Wings HTTPS'
ufw allow 16261/udp comment 'Project Zomboid game and Steam'
ufw allow 16262/udp comment 'Project Zomboid UDP'
ufw --force enable

certbot certonly \
    --webroot \
    --webroot-path /var/www/certbot \
    --non-interactive \
    --agree-tos \
    --no-eff-email \
    --email "${LE_EMAIL}" \
    --domain "${PANEL_DOMAIN}"

cat >"${WORK_DIR}/nginx-pterodactyl.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PANEL_DOMAIN};
    root /var/www/certbot;

    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${PANEL_DOMAIN};
    root /var/www/pterodactyl/public;
    index index.php;
    charset utf-8;
    server_tokens off;

    access_log /var/log/nginx/pterodactyl-access.log;
    error_log /var/log/nginx/pterodactyl-error.log error;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    ssl_certificate /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header X-Robots-Tag none always;
    add_header Content-Security-Policy "frame-ancestors 'self'" always;
    add_header Referrer-Policy same-origin always;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
install -m 0644 "${WORK_DIR}/nginx-pterodactyl.conf" /etc/nginx/sites-available/pterodactyl.conf

cat >"${WORK_DIR}/certbot-hook" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl reload nginx.service
systemctl try-restart wings.service
EOF
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
install -m 0755 "${WORK_DIR}/certbot-hook" /etc/letsencrypt/renewal-hooks/deploy/pterodactyl-services
nginx -t
systemctl reload nginx
systemctl enable --now certbot.timer

log "Downloading official Wings ${WINGS_VERSION}."
install -d -m 0750 "${WINGS_ROOT}"
curl -fL "https://github.com/pterodactyl/wings/releases/download/${WINGS_VERSION}/wings_linux_amd64" -o "${WORK_DIR}/wings"
printf '%s  %s\n' "${WINGS_SHA256}" "${WORK_DIR}/wings" | sha256sum --check --status \
    || fail 'The Wings binary checksum does not match the pinned official release.'
install -m 0755 "${WORK_DIR}/wings" /usr/local/bin/wings

node_name='Project Zomboid Node'
log 'Creating the Panel location and Wings node.'
cd "${PANEL_ROOT}"
sudo -u www-data php artisan p:location:make \
    --short=pz1 \
    --long='Project Zomboid VPS' \
    --no-interaction
location_id=$(mariadb --protocol=socket --batch --skip-column-names panel -e "SELECT id FROM locations WHERE short='pz1' LIMIT 1;")
[[ -n ${location_id} ]] || fail 'Could not determine the new Panel location ID.'

sudo -u www-data php artisan p:node:make \
    --name="${node_name}" \
    --description='Dedicated Project Zomboid node' \
    --locationId="${location_id}" \
    --fqdn="${PANEL_DOMAIN}" \
    --public=0 \
    --scheme=https \
    --proxy=0 \
    --maintenance=0 \
    --maxMemory=6144 \
    --overallocateMemory=0 \
    --maxDisk=45000 \
    --overallocateDisk=0 \
    --uploadSize=100 \
    --daemonListeningPort=8443 \
    --daemonSFTPPort=2022 \
    --daemonBase=/var/lib/pterodactyl/volumes \
    --no-interaction
node_id=$(mariadb --protocol=socket --batch --skip-column-names panel -e "SELECT id FROM nodes WHERE name='Project Zomboid Node' LIMIT 1;")
[[ -n ${node_id} ]] || fail 'Could not determine the new Panel node ID.'

if ! grep -Eq "^[[:space:]]*127\.0\.0\.1[[:space:]]+.*(^|[[:space:]])${PANEL_DOMAIN}([[:space:]]|$)" /etc/hosts; then
    printf '127.0.0.1 %s\n' "${PANEL_DOMAIN}" >>/etc/hosts
fi

# The root shell intentionally owns the mode-0600 redirect target; only the
# configuration-generating PHP process runs as www-data.
# shellcheck disable=SC2024
sudo -u www-data php artisan p:node:configuration "${node_id}" --format=yaml >"${WORK_DIR}/wings-config.yml"
install -m 0600 "${WORK_DIR}/wings-config.yml" "${WINGS_ROOT}/config.yml"

cat >"${WORK_DIR}/wings.service" <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target
PartOf=docker.service
StartLimitIntervalSec=180
StartLimitBurst=30

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
install -m 0644 "${WORK_DIR}/wings.service" /etc/systemd/system/wings.service
systemctl daemon-reload
systemctl enable --now wings

wait_for_wings_api() {
    local _attempt
    local status
    for _attempt in $(seq 1 30); do
        status=$(curl --silent --show-error \
            --resolve "${PANEL_DOMAIN}:8443:127.0.0.1" \
            --output /dev/null \
            --write-out '%{http_code}' \
            "https://${PANEL_DOMAIN}:8443/api/system" 2>/dev/null || true)
        [[ ${status} == 401 ]] && return 0
        sleep 2
    done
    fail 'Wings did not become ready on its authenticated HTTPS endpoint.'
}

wait_for_wings_api

log 'Testing certificate renewal before provisioning the game server.'
certbot renew --dry-run --no-random-sleep-on-renew
systemctl is-active --quiet wings || systemctl start wings
wait_for_wings_api

egg_url="https://raw.githubusercontent.com/pterodactyl/game-eggs/${EGG_COMMIT}/project_zomboid/egg-project-zomboid.json"
log "Downloading the maintained Project Zomboid egg at ${EGG_COMMIT}."
curl -fsSL "${egg_url}" -o "${WORK_DIR}/egg-project-zomboid.json"
printf '%s  %s\n' "${EGG_SHA256}" "${WORK_DIR}/egg-project-zomboid.json" | sha256sum --check --status \
    || fail 'The Project Zomboid egg checksum does not match the pinned reviewed file.'
EGG_PATH="${WORK_DIR}/egg-project-zomboid.json" \
PINNED_RUNTIME_IMAGE="${STEAMCMD_IMAGE}" \
PINNED_INSTALLER_IMAGE="${INSTALLER_IMAGE}" \
php -r '
$path = getenv("EGG_PATH");
$runtime = getenv("PINNED_RUNTIME_IMAGE");
$installer = getenv("PINNED_INSTALLER_IMAGE");
$egg = json_decode(file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
$egg["docker_images"] = [$runtime => $runtime];
$egg["scripts"]["installation"]["container"] = $installer;
file_put_contents($path, json_encode($egg, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL, LOCK_EX);
'

cat >"${WORK_DIR}/provision-project-zomboid.php" <<'PHP'
<?php

declare(strict_types=1);

use Illuminate\Contracts\Console\Kernel;
use Illuminate\Http\UploadedFile;
use Pterodactyl\Helpers\Utilities;
use Pterodactyl\Models\Allocation;
use Pterodactyl\Models\Egg;
use Pterodactyl\Models\Nest;
use Pterodactyl\Models\Node;
use Pterodactyl\Models\Schedule;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\Task;
use Pterodactyl\Models\User;
use Pterodactyl\Services\Eggs\Sharing\EggImporterService;
use Pterodactyl\Services\Servers\ServerCreationService;
use Ramsey\Uuid\Uuid;

const PANEL_ROOT = '/var/www/pterodactyl';

function requiredEnv(string $name): string
{
    $value = getenv($name);
    if ($value === false || $value === '') {
        throw new RuntimeException("Missing required environment variable: {$name}");
    }

    return $value;
}

require PANEL_ROOT . '/vendor/autoload.php';
$app = require PANEL_ROOT . '/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$email = requiredEnv('INSTALL_PANEL_EMAIL');
$nodeName = requiredEnv('INSTALL_NODE_NAME');
$publicIp = requiredEnv('INSTALL_PUBLIC_IP');
$serverName = requiredEnv('INSTALL_SERVER_NAME');
$eggFile = requiredEnv('INSTALL_EGG_FILE');
$stateFile = requiredEnv('INSTALL_STATE_FILE');
$credentialFile = requiredEnv('INSTALL_PZ_CREDENTIAL_FILE');
$runtimeImage = requiredEnv('INSTALL_RUNTIME_IMAGE');

$eggData = json_decode(file_get_contents($eggFile), true, 512, JSON_THROW_ON_ERROR);
if (($eggData['name'] ?? null) !== 'Project Zomboid') {
    throw new RuntimeException('The pinned egg has an unexpected name.');
}
$appId = null;
foreach (($eggData['variables'] ?? []) as $variable) {
    if (($variable['env_variable'] ?? null) === 'SRCDS_APPID') {
        $appId = (string) ($variable['default_value'] ?? '');
    }
}
if ($appId !== '380870') {
    throw new RuntimeException('The pinned egg has an unexpected Steam application ID.');
}

$owner = User::query()->where('email', $email)->firstOrFail();
$node = Node::query()->where('name', $nodeName)->firstOrFail();
if (Server::query()->exists()) {
    throw new RuntimeException('Refusing to provision over an existing Panel server.');
}

$nest = Nest::query()->forceCreate([
    'uuid' => Uuid::uuid4()->toString(),
    'author' => $email,
    'name' => 'Project Zomboid',
    'description' => 'Maintained Project Zomboid dedicated server egg.',
]);
$upload = new UploadedFile($eggFile, 'egg-project-zomboid.json', 'application/json', null, true);
$egg = $app->make(EggImporterService::class)->handle($upload, $nest->id);

$primary = Allocation::query()->forceCreate([
    'node_id' => $node->id,
    'ip' => $publicIp,
    'ip_alias' => null,
    'port' => 16261,
    'notes' => 'Project Zomboid primary game and Steam port',
]);
$steam = Allocation::query()->forceCreate([
    'node_id' => $node->id,
    'ip' => $publicIp,
    'ip_alias' => null,
    'port' => 16262,
    'notes' => 'Project Zomboid UDP port',
]);

$adminPassword = 'PzA7' . bin2hex(random_bytes(13));
$heapGuard = 'sed -E -i \'s/"-Xmx[0-9]+[gGmM]"/"-Xmx4g"/\' ProjectZomboid64.json && '
    . 'grep -q \'"-Xmx4g"\' ProjectZomboid64.json && ';

$server = $app->make(ServerCreationService::class)->handle([
    'name' => $serverName,
    'description' => 'Private stable Project Zomboid server.',
    'owner_id' => $owner->id,
    'node_id' => $node->id,
    'allocation_id' => $primary->id,
    'allocation_additional' => [$steam->id],
    'egg_id' => $egg->id,
    'memory' => 5120,
    'swap' => 0,
    'disk' => 30000,
    'io' => 500,
    'cpu' => 350,
    'threads' => null,
    'oom_disabled' => false,
    'database_limit' => 0,
    'allocation_limit' => 1,
    'backup_limit' => 7,
    'image' => $runtimeImage,
    'startup' => $heapGuard . $egg->startup,
    'environment' => [
        'SERVER_NAME' => 'ProjectZomboid',
        'ADMIN_USER' => 'admin',
        'ADMIN_PASSWORD' => $adminPassword,
        'STEAM_PORT' => '16262',
        'SRCDS_APPID' => '380870',
        'SRCDS_BETAID' => '',
        'AUTO_UPDATE' => '0',
    ],
    'start_on_completion' => false,
]);

$schedule = Schedule::query()->forceCreate([
    'server_id' => $server->id,
    'name' => 'Daily save-data backup',
    'cron_day_of_week' => '*',
    'cron_month' => '*',
    'cron_day_of_month' => '*',
    'cron_hour' => '4',
    'cron_minute' => '0',
    'is_active' => true,
    'is_processing' => false,
    'only_when_online' => false,
    'next_run_at' => Utilities::getScheduleNextRunDate('0', '4', '*', '*', '*'),
]);
Task::query()->forceCreate([
    'schedule_id' => $schedule->id,
    'sequence_id' => 1,
    'action' => Task::ACTION_COMMAND,
    'payload' => 'save',
    'time_offset' => 0,
    'is_queued' => false,
    'continue_on_failure' => false,
]);
Task::query()->forceCreate([
    'schedule_id' => $schedule->id,
    'sequence_id' => 2,
    'action' => Task::ACTION_BACKUP,
    'payload' => implode(PHP_EOL, [
        '*',
        '!.cache/',
        '!.cache/**',
        '.cache/Logs/',
        '.cache/backups/',
        '.cache/server-console.txt',
        '.cache/*.log',
    ]),
    'time_offset' => 30,
    'is_queued' => false,
    'continue_on_failure' => false,
]);

file_put_contents($stateFile, $server->uuid . PHP_EOL, LOCK_EX);
chmod($stateFile, 0600);
file_put_contents($credentialFile, implode(PHP_EOL, [
    'Project Zomboid admin username: admin',
    'Project Zomboid one-time admin password: ' . $adminPassword,
    '',
]), LOCK_EX);
chmod($credentialFile, 0600);
PHP

cat >"${WORK_DIR}/server-ops.php" <<'PHP'
<?php

declare(strict_types=1);

use Illuminate\Contracts\Console\Kernel;
use Pterodactyl\Models\Backup;
use Pterodactyl\Models\Server;
use Pterodactyl\Repositories\Wings\DaemonCommandRepository;
use Pterodactyl\Repositories\Wings\DaemonPowerRepository;
use Pterodactyl\Repositories\Wings\DaemonServerRepository;
use Pterodactyl\Services\Backups\InitiateBackupService;

const PANEL_ROOT = '/var/www/pterodactyl';

require PANEL_ROOT . '/vendor/autoload.php';
$app = require PANEL_ROOT . '/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$uuid = $argv[1] ?? '';
$operation = $argv[2] ?? '';
$server = Server::query()->where('uuid', $uuid)->firstOrFail();

if ($operation === 'installation') {
    if ($server->status === Server::STATUS_INSTALL_FAILED) {
        echo "failed\n";
    } elseif ($server->installed_at !== null) {
        echo "installed\n";
    } else {
        echo "installing\n";
    }
    exit(0);
}

if ($operation === 'state') {
    $details = $app->make(DaemonServerRepository::class)->setServer($server)->getDetails();
    echo ($details['state'] ?? 'unknown') . PHP_EOL;
    exit(0);
}

if (in_array($operation, ['start', 'stop'], true)) {
    $app->make(DaemonPowerRepository::class)->setServer($server)->send($operation);
    echo "accepted\n";
    exit(0);
}

if ($operation === 'save') {
    $app->make(DaemonCommandRepository::class)->setServer($server)->send('save');
    echo "accepted\n";
    exit(0);
}

if ($operation === 'backup') {
    $backup = $app->make(InitiateBackupService::class)
        ->setIgnoredFiles([
            '*',
            '!.cache/',
            '!.cache/**',
            '.cache/Logs/',
            '.cache/backups/',
            '.cache/server-console.txt',
            '.cache/*.log',
        ])
        ->handle($server, 'Initial verified save backup', true);
    echo $backup->uuid . PHP_EOL;
    exit(0);
}

if ($operation === 'backup-status') {
    $backupUuid = $argv[3] ?? '';
    $backup = Backup::query()->where('server_id', $server->id)->where('uuid', $backupUuid)->firstOrFail();
    if ($backup->completed_at === null) {
        echo "pending\n";
    } elseif ($backup->is_successful) {
        echo "successful\n";
    } else {
        echo "failed\n";
    }
    exit(0);
}

fwrite(STDERR, "Unknown operation.\n");
exit(64);
PHP

php -l "${WORK_DIR}/provision-project-zomboid.php"
php -l "${WORK_DIR}/server-ops.php"

log 'Importing the egg and provisioning the bounded game server.'
INSTALL_PANEL_EMAIL="${LE_EMAIL}" \
INSTALL_NODE_NAME="${node_name}" \
INSTALL_PUBLIC_IP="${PUBLIC_IP}" \
INSTALL_SERVER_NAME="${SERVER_DISPLAY_NAME}" \
INSTALL_EGG_FILE="${WORK_DIR}/egg-project-zomboid.json" \
INSTALL_STATE_FILE="${WORK_DIR}/server.uuid" \
INSTALL_PZ_CREDENTIAL_FILE="${PZ_CREDENTIAL_FILE}" \
INSTALL_RUNTIME_IMAGE="${STEAMCMD_IMAGE}" \
php "${WORK_DIR}/provision-project-zomboid.php"

SERVER_UUID=$(tr -d '\r\n' <"${WORK_DIR}/server.uuid")
[[ ${SERVER_UUID} =~ ^[0-9a-f-]{36}$ ]] || fail 'Provisioning returned an invalid server UUID.'
SERVER_ROOT="${WINGS_DATA}/volumes/${SERVER_UUID}"
SERVER_INI="${SERVER_ROOT}/.cache/Server/ProjectZomboid.ini"
JVM_CONFIG="${SERVER_ROOT}/ProjectZomboid64.json"
CONSOLE_LOG="${SERVER_ROOT}/.cache/server-console.txt"

wait_for_installation() {
    local state
    local _attempt
    for _attempt in $(seq 1 180); do
        state=$(php "${WORK_DIR}/server-ops.php" "${SERVER_UUID}" installation)
        case "${state}" in
            installed) return 0 ;;
            failed) fail 'Wings reported a failed game-server installation.' ;;
        esac
        sleep 10
    done
    fail 'Timed out waiting 30 minutes for game-server installation.'
}

wait_for_daemon_state() {
    local expected=$1
    local attempts=$2
    local state
    local _attempt
    for _attempt in $(seq 1 "${attempts}"); do
        state=$(php "${WORK_DIR}/server-ops.php" "${SERVER_UUID}" state 2>/dev/null || true)
        [[ ${state} == "${expected}" ]] && return 0
        sleep 5
    done
    fail "Timed out waiting for game-server state ${expected}."
}

wait_for_start_marker() {
    local previous_count=$1
    local current_count
    local _attempt
    for _attempt in $(seq 1 240); do
        current_count=0
        if [[ -f ${CONSOLE_LOG} ]]; then
            current_count=$(grep -c 'SERVER STARTED' "${CONSOLE_LOG}" || true)
        fi
        ((current_count > previous_count)) && return 0
        sleep 5
    done
    fail 'Timed out waiting 20 minutes for the Project Zomboid startup marker.'
}

wait_for_installation
log 'Initial game installation completed. Starting once to generate configuration.'
first_marker_count=0
[[ -f ${CONSOLE_LOG} ]] && first_marker_count=$(grep -c 'SERVER STARTED' "${CONSOLE_LOG}" || true)
php "${WORK_DIR}/server-ops.php" "${SERVER_UUID}" start >/dev/null
wait_for_start_marker "${first_marker_count}"

log 'Stopping the first start before applying the initial private-server settings.'
php "${WORK_DIR}/server-ops.php" "${SERVER_UUID}" stop >/dev/null
wait_for_daemon_state offline 60
[[ -f ${SERVER_INI} && -f ${JVM_CONFIG} ]] || fail 'Expected Project Zomboid configuration files were not generated.'

replace_pz_setting() {
    local key=$1
    local value=$2
    grep -q "^${key}=" "${SERVER_INI}" || fail "Required Project Zomboid setting is missing: ${key}"
    sed -i -E "s|^${key}=.*$|${key}=${value}|" "${SERVER_INI}"
}

replace_pz_setting MaxPlayers "${PLAYER_LIMIT}"
replace_pz_setting Public "${PUBLIC_SERVER}"
replace_pz_setting Mods ''
replace_pz_setting WorkshopItems ''
replace_pz_setting BackupsOnStart false
sed -E -i 's/"-Xmx[0-9]+[gGmM]"/"-Xmx4g"/' "${JVM_CONFIG}"
grep -q '"-Xmx4g"' "${JVM_CONFIG}" || fail 'Could not enforce the 4 GiB Project Zomboid Java heap.'

game_uid=$(stat -c '%u' "${JVM_CONFIG}")
game_gid=$(stat -c '%g' "${JVM_CONFIG}")
install -d -o "${game_uid}" -g "${game_gid}" -m 0755 "${SERVER_ROOT}/.cache/mods"
cat >"${WORK_DIR}/pteroignore" <<'EOF'
*
!.cache/
!.cache/**
.cache/Logs/
.cache/backups/
.cache/server-console.txt
.cache/*.log
EOF
install -o "${game_uid}" -g "${game_gid}" -m 0644 "${WORK_DIR}/pteroignore" "${SERVER_ROOT}/.pteroignore"
chown "${game_uid}:${game_gid}" "${SERVER_INI}" "${JVM_CONFIG}"
chmod 0644 "${SERVER_INI}" "${JVM_CONFIG}"

cat >"${WORK_DIR}/pz-logrotate" <<EOF
${CONSOLE_LOG} {
    daily
    maxsize 25M
    rotate 7
    compress
    delaycompress
    copytruncate
    missingok
    notifempty
}
EOF
install -m 0644 "${WORK_DIR}/pz-logrotate" /etc/logrotate.d/pterodactyl-pz
cat >"${WORK_DIR}/pz-tmpfiles.conf" <<EOF
# Retain Project Zomboid's dated application logs for 14 days.
e ${SERVER_ROOT}/.cache/Logs - - - 14d
EOF
install -m 0644 "${WORK_DIR}/pz-tmpfiles.conf" /etc/tmpfiles.d/pterodactyl-pz-logs.conf
logrotate --debug /etc/logrotate.d/pterodactyl-pz >/dev/null

log 'Starting the configured Project Zomboid server.'
final_marker_count=$(grep -c 'SERVER STARTED' "${CONSOLE_LOG}" || true)
php "${WORK_DIR}/server-ops.php" "${SERVER_UUID}" start >/dev/null
wait_for_start_marker "${final_marker_count}"
wait_for_daemon_state running 12

log 'Creating and validating the initial save-data backup.'
php "${WORK_DIR}/server-ops.php" "${SERVER_UUID}" save >/dev/null
sleep 30
BACKUP_UUID=$(php "${WORK_DIR}/server-ops.php" "${SERVER_UUID}" backup)
[[ ${BACKUP_UUID} =~ ^[0-9a-f-]{36}$ ]] || fail 'Backup request returned an invalid UUID.'
for _attempt in $(seq 1 60); do
    backup_state=$(php "${WORK_DIR}/server-ops.php" "${SERVER_UUID}" backup-status "${BACKUP_UUID}")
    case "${backup_state}" in
        successful) break ;;
        failed) fail 'The initial Wings backup failed.' ;;
    esac
    sleep 5
done
[[ ${backup_state} == successful ]] || fail 'Timed out waiting for the initial backup.'
BACKUP_FILE="${WINGS_DATA}/backups/${BACKUP_UUID}.tar.gz"
[[ -f ${BACKUP_FILE} ]] || fail 'The successful backup archive is missing from disk.'
gzip -t "${BACKUP_FILE}"
tar -tzf "${BACKUP_FILE}" >"${WORK_DIR}/backup-list.txt"
if grep -Eq '(^|/)(ProjectZomboid64|steamcmd|steamapps)' "${WORK_DIR}/backup-list.txt"; then
    fail 'The save-data backup unexpectedly contains game binaries.'
fi
grep -Eq '^\.cache/Server/ProjectZomboid\.ini$' "${WORK_DIR}/backup-list.txt" || fail 'The backup is missing ProjectZomboid.ini.'
grep -Eq '^\.cache/Server/ProjectZomboid_SandboxVars\.lua$' "${WORK_DIR}/backup-list.txt" || fail 'The backup is missing SandboxVars.'
grep -Eq '(^|/)players\.db$' "${WORK_DIR}/backup-list.txt" || fail 'The backup is missing the player database.'
grep -Eq '^\.cache/Saves/Multiplayer/ProjectZomboid/' "${WORK_DIR}/backup-list.txt" || fail 'The backup is missing world-save data.'

log 'Running final production checks.'
nginx -t
for service in nginx php8.3-fpm mariadb redis-server docker wings pteroq cron certbot.timer apt-daily.timer apt-daily-upgrade.timer; do
    systemctl is-enabled --quiet "${service}" || fail "${service} is not enabled."
    systemctl is-active --quiet "${service}" || fail "${service} is not active."
done
[[ -z $(systemctl --failed --no-legend) ]] || fail 'One or more systemd units are failed.'

panel_http=$(curl --silent --show-error --resolve "${PANEL_DOMAIN}:443:127.0.0.1" --output "${WORK_DIR}/panel-login.html" --write-out '%{http_code}' "https://${PANEL_DOMAIN}/auth/login")
[[ ${panel_http} == 200 ]] || fail "Panel login returned HTTP ${panel_http}."
grep -Eiq 'recaptcha|grecaptcha' "${WORK_DIR}/panel-login.html" || fail 'The Panel login page does not expose a reCAPTCHA marker.'
wings_http=$(curl --silent --show-error --resolve "${PANEL_DOMAIN}:8443:127.0.0.1" --output /dev/null --write-out '%{http_code}' "https://${PANEL_DOMAIN}:8443/api/system")
[[ ${wings_http} == 401 ]] || fail "Wings unauthenticated health probe returned HTTP ${wings_http}, expected 401."

ss -H -lnt | awk '{print $4}' | grep -E '(^|[^0-9])3306$' >"${WORK_DIR}/mariadb-listeners" || true
[[ -s ${WORK_DIR}/mariadb-listeners ]] || fail 'MariaDB is not listening on its loopback port.'
if grep -Evq '^(127\.0\.0\.1|\[::1\]):3306$' "${WORK_DIR}/mariadb-listeners"; then
    fail 'MariaDB appears to be publicly bound.'
fi
ss -H -lnt | awk '{print $4}' | grep -E '(^|[^0-9])6379$' >"${WORK_DIR}/redis-listeners" || true
[[ -s ${WORK_DIR}/redis-listeners ]] || fail 'Redis is not listening on its loopback port.'
if grep -Evq '^(127\.0\.0\.1|\[::1\]):6379$' "${WORK_DIR}/redis-listeners"; then
    fail 'Redis appears to be publicly bound.'
fi

docker inspect "${SERVER_UUID}" --format '{{.State.Running}}' | grep -qx true || fail 'The Project Zomboid container is not running.'
docker inspect "${SERVER_UUID}" --format '{{.Config.Image}}' | grep -Fxq "${STEAMCMD_IMAGE}" \
    || fail 'The Project Zomboid container image is not the pinned reviewed digest.'
docker inspect "${SERVER_UUID}" --format '{{.HostConfig.Privileged}}' | grep -qx false || fail 'The Project Zomboid container is unexpectedly privileged.'
docker inspect "${SERVER_UUID}" --format '{{.HostConfig.ReadonlyRootfs}}' | grep -qx true || fail 'The container root filesystem is unexpectedly writable.'
docker inspect "${SERVER_UUID}" --format '{{.HostConfig.Memory}}' | grep -qx 5637144576 || fail 'The container memory ceiling is unexpected.'
docker inspect "${SERVER_UUID}" --format '{{.HostConfig.CpuQuota}}' | grep -qx 350000 || fail 'The container CPU quota is unexpected.'
grep -q 'SERVER STARTED' "${CONSOLE_LOG}" || fail 'The Project Zomboid startup marker is missing.'
udp_listeners=$(ss -H -lun | awk '{print $4}')
grep -Fxq "${PUBLIC_IP}:16261" <<<"${udp_listeners}" || fail 'UDP port 16261 is not listening on the public IPv4.'
grep -Fxq "${PUBLIC_IP}:16262" <<<"${udp_listeners}" || fail 'UDP port 16262 is not listening on the public IPv4.'
tcp_listeners=$(ss -H -lnt | awk '{print $4}')
grep -Eq '(^|[.:])2022$' <<<"${tcp_listeners}" || fail 'Wings SFTP is not listening on TCP 2022.'
grep -Eq '(^|[.:])8443$' <<<"${tcp_listeners}" || fail 'Wings HTTPS is not listening on TCP 8443.'
ufw_status=$(ufw status)
grep -Eq '^16261/udp[[:space:]]+ALLOW' <<<"${ufw_status}" || fail 'UFW is missing UDP 16261.'
grep -Eq '^16262/udp[[:space:]]+ALLOW' <<<"${ufw_status}" || fail 'UFW is missing UDP 16262.'
/usr/sbin/iptables --wait --check DOCKER-USER -j PTERODACTYL-FILTER \
    || fail 'The Docker ingress filter is not attached to DOCKER-USER.'
/usr/sbin/iptables --wait --check PTERODACTYL-FILTER \
    -i "${PUBLIC_INTERFACE}" -p udp -m conntrack \
    --ctorigdst "${PUBLIC_IP}" --ctorigdstport 16261:16262 -j RETURN \
    || fail 'The Docker ingress filter is missing the Project Zomboid UDP allowance.'
/usr/sbin/iptables --wait --check PTERODACTYL-FILTER \
    -i "${PUBLIC_INTERFACE}" -m conntrack --ctorigdst "${PUBLIC_IP}" -j DROP \
    || fail 'The Docker ingress filter is missing its default public-container drop rule.'

public_endpoint_ip=${DNS_IPV4%%,*}
curl --fail --silent --show-error --location --max-redirs 5 \
    --resolve "${PANEL_DOMAIN}:443:${public_endpoint_ip}" \
    --output /dev/null "https://${PANEL_DOMAIN}/auth/login" \
    || fail 'Public HTTPS failed. For Cloudflare, confirm SSL/TLS mode is Full (strict).'
public_wings_http=$(curl --silent --show-error \
    --resolve "${PANEL_DOMAIN}:8443:${public_endpoint_ip}" \
    --output /dev/null \
    --write-out '%{http_code}' \
    "https://${PANEL_DOMAIN}:8443/api/system")
[[ ${public_wings_http} == 401 ]] || fail "Public Wings probe returned HTTP ${public_wings_http}, expected 401."

chmod 0600 "${PANEL_CREDENTIAL_FILE}" "${PZ_CREDENTIAL_FILE}" "${PANEL_RECOVERY_FILE}" "${WINGS_ROOT}/config.yml"
chmod 0640 "${PANEL_ROOT}/.env"
chown www-data:www-data "${PANEL_ROOT}/.env"

log 'Installation and verification completed successfully. No reboot was performed.'
printf '\nPanel: https://%s\n' "${PANEL_DOMAIN}"
printf 'Project Zomboid: %s:16261 (UDP 16261-16262)\n' "${PUBLIC_IP}"
printf 'Server UUID: %s\n' "${SERVER_UUID}"
printf 'Credentials are stored root-only in:\n  %s\n  %s\n' "${PANEL_CREDENTIAL_FILE}" "${PZ_CREDENTIAL_FILE}"
printf 'Back up the Panel APP_KEY from %s to a password manager, then remove that recovery file.\n' "${PANEL_RECOVERY_FILE}"
printf '\nONE-TIME CREDENTIAL DISPLAY\n'
sed -n '1,20p' "${PANEL_CREDENTIAL_FILE}"
sed -n '1,20p' "${PZ_CREDENTIAL_FILE}"
printf '\nChange the Panel password after first login and then remove both credential files.\n'
