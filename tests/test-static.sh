#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer="${repo_root}/zomboid.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

printf '%s\n' 'Checking Bash syntax.'
bash -n "${installer}"

if command -v php >/dev/null 2>&1; then
    printf '%s\n' 'Checking embedded PHP syntax.'
    php_check_dir=$(mktemp -d)
    trap 'rm -rf -- "${php_check_dir}"' EXIT
    awk -v output_dir="${php_check_dir}" '
        /^cat .*<<'\''PHP'\''$/ {
            in_php = 1
            count++
            output = sprintf("%s/helper-%d.php", output_dir, count)
            next
        }
        in_php && $0 == "PHP" {
            close(output)
            in_php = 0
            next
        }
        in_php { print > output }
    ' "${installer}"
    php_file_count=$(find "${php_check_dir}" -type f -name 'helper-*.php' | wc -l)
    [[ ${php_file_count} -eq 3 ]] || fail 'Expected three embedded PHP helpers.'
    while IFS= read -r php_file; do
        php -l "${php_file}" >/dev/null
    done < <(find "${php_check_dir}" -type f -name 'helper-*.php' -print | sort)
else
    printf '%s\n' 'PHP is unavailable; container/CI validation will check embedded helpers.'
fi

printf '%s\n' 'Checking the non-mutating help path.'
help_output=$(bash "${installer}" --help)
grep -Fq 'sudo ./zomboid.sh' <<<"${help_output}" || fail 'Help is missing the invocation example.'
grep -Fq -- '--preflight-only' <<<"${help_output}" || fail 'Help is missing preflight-only mode.'
grep -Fq -- '--non-interactive' <<<"${help_output}" || fail 'Help is missing non-interactive mode.'
grep -Fq -- '--twice-daily-restarts' <<<"${help_output}" || fail 'Help is missing the optional restart flag.'
grep -Fq 'TWICE_DAILY_RESTARTS=false' "${installer}" || fail 'Automatic restarts are not disabled by default.'
grep -Fq 'INSTALL_TWICE_DAILY_RESTARTS="${TWICE_DAILY_RESTARTS}"' "${installer}" \
    || fail 'Restart preference is not passed to Pterodactyl provisioning.'

printf '%s\n' 'Checking required safety controls.'
grep -Fq 'Type INSTALL to continue' "${installer}" || fail 'Final confirmation gate is missing.'
grep -Fq 'This installer supports only Ubuntu 24.04 LTS' "${installer}" || fail 'OS gate is missing.'
grep -Fq 'systemd-detect-virt' "${installer}" || fail 'Virtualization gate is missing.'
grep -Fq 'sha256sum --check --status' "${installer}" || fail 'Artifact checksum verification is missing.'
grep -Fq 'PTERODACTYL-FILTER' "${installer}" || fail 'Docker ingress filter is missing.'
grep -Fq 'ufw default deny incoming' "${installer}" || fail 'UFW default-deny policy is missing.'
grep -Fq 'certbot renew --dry-run' "${installer}" || fail 'Certificate-renewal test is missing.'
grep -Fq 'No reboot was performed' "${installer}" || fail 'No-reboot completion statement is missing.'

printf '%s\n' 'Checking optional Pterodactyl restart scheduling.'
grep -Fq "prompt_boolean TWICE_DAILY_RESTARTS 'Enable warned restarts at 00:00 and 12:00 Panel time?' false" "${installer}" \
    || fail 'Interactive restart-schedule prompt is missing or not opt-in.'
grep -Fq "'name' => 'Twice-daily warned restart'" "${installer}" || fail 'Restart schedule is missing.'
grep -Fq "'cron_hour' => '11,23'" "${installer}" || fail 'Restart schedule does not cover both target times.'
grep -Fq "'cron_minute' => '50'" "${installer}" || fail 'Restart warning schedule does not start ten minutes early.'
expected_restart_warnings=$(cat <<'EOF'
        [Task::ACTION_COMMAND, 'servermsg "Server restart in 10 minutes."', 0],
        [Task::ACTION_COMMAND, 'servermsg "Server restart in 5 minutes."', 300],
        [Task::ACTION_COMMAND, 'servermsg "Server restart in 1 minute. Please reach a safe place."', 240],
EOF
)
grep -Fq "${expected_restart_warnings}" "${installer}" \
    || fail 'Restart warning payloads must contain unescaped double quotes and the reviewed timing.'
grep -Fq "[Task::ACTION_COMMAND, 'save', 0]" "${installer}" || fail 'Pre-restart save task is missing.'
grep -Fq "[Task::ACTION_POWER, 'restart', 60]" "${installer}" || fail 'Restart power task is missing or mistimed.'
grep -Fq "'only_when_online' => true" "${installer}" || fail 'Restart schedule must skip offline servers.'
grep -Fq "'name' => 'Daily save-data backup'" "${installer}" || fail 'Daily backup schedule is missing.'
grep -Fq "'cron_hour' => '4'" "${installer}" || fail 'Daily backup schedule is no longer at 04:00.'

printf '%s\n' 'Checking secret-handling invariants.'
if grep -Eq -- '--password=' "${installer}"; then
    fail 'A password is passed through a process argument.'
fi
if grep -Eq 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' "${installer}"; then
    fail 'A remote script is piped directly to a shell.'
fi
if grep -RIEq --exclude-dir=.git 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY' "${repo_root}"; then
    fail 'Private-key material was detected.'
fi
if grep -RIEq --exclude-dir=.git '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35})' "${repo_root}"; then
    fail 'A common live-token shape was detected.'
fi

printf '%s\n' 'Checking pinned digest shape and Project Zomboid password length.'
digest_count=$(grep -Ec '^readonly (PANEL|WINGS|EGG)_SHA256="[0-9a-f]{64}"$' "${installer}")
[[ ${digest_count} -eq 3 ]] || fail 'Expected three pinned 64-character SHA-256 digests.'
image_digest_count=$(grep -Ec '^readonly (STEAMCMD|INSTALLER)_IMAGE="[^"[:space:]]+@sha256:[0-9a-f]{64}"$' "${installer}")
[[ ${image_digest_count} -eq 2 ]] || fail 'Expected two container images pinned by SHA-256 manifest digest.'
grep -Fq "'PzA7' . bin2hex(random_bytes(13))" "${installer}" \
    || fail 'Project Zomboid generated password is not the reviewed 30-character form.'

if command -v shellcheck >/dev/null 2>&1; then
    printf '%s\n' 'Running ShellCheck.'
    shellcheck --severity=warning "${installer}" "${BASH_SOURCE[0]}"
else
    printf '%s\n' 'ShellCheck is unavailable; container/CI validation will run it.'
fi

printf '%s\n' 'All static installer checks passed.'
