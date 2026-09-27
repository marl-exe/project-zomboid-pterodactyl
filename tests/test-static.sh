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

printf '%s\n' 'Checking the non-mutating help path.'
help_output=$(bash "${installer}" --help)
grep -Fq 'sudo ./zomboid.sh' <<<"${help_output}" || fail 'Help is missing the invocation example.'
grep -Fq -- '--preflight-only' <<<"${help_output}" || fail 'Help is missing preflight-only mode.'
grep -Fq -- '--non-interactive' <<<"${help_output}" || fail 'Help is missing non-interactive mode.'

printf '%s\n' 'Checking required safety controls.'
grep -Fq 'Type INSTALL to continue' "${installer}" || fail 'Final confirmation gate is missing.'
grep -Fq 'This installer supports only Ubuntu 24.04 LTS' "${installer}" || fail 'OS gate is missing.'
grep -Fq 'systemd-detect-virt' "${installer}" || fail 'Virtualization gate is missing.'
grep -Fq 'sha256sum --check --status' "${installer}" || fail 'Artifact checksum verification is missing.'
grep -Fq 'PTERODACTYL-FILTER' "${installer}" || fail 'Docker ingress filter is missing.'
grep -Fq 'ufw default deny incoming' "${installer}" || fail 'UFW default-deny policy is missing.'
grep -Fq 'certbot renew --dry-run' "${installer}" || fail 'Certificate-renewal test is missing.'
grep -Fq 'No reboot was performed' "${installer}" || fail 'No-reboot completion statement is missing.'

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
