# Security Policy

## Reporting

Do not open a public issue containing a password, token, private key, Panel
`APP_KEY`, Wings configuration, server UUID, private log, or production address.
Use GitHub's private vulnerability reporting feature when it is enabled for the
repository. Otherwise, contact the repository owner privately without attaching
live credentials.

Revoke or rotate any credential that was exposed before sending a report.

## Installer trust model

This installer runs as root and changes the operating system. Review the exact
commit before execution. Clone the repository rather than piping a network
download directly into a shell.

Release downloads are pinned to specific upstream versions and SHA-256 digests.
The Project Zomboid egg is pinned to a reviewed Git commit and digest. Package
installation still trusts Ubuntu's and Docker's configured APT repositories.
The installer requires Ubuntu 24.04 PHP CLI and FPM packages containing the
php2shell fixes for CVE-2026-109618 and CVE-2026-109619. It also disables
session upload progress in the Panel's PHP-FPM configuration as a defense in
depth. Keep all Ubuntu packages updated after installation.

Generated credentials exist only on the target VPS in mode-0600 files. They are
not accepted as command-line arguments. Remove the initial credential files
after storing recovery material securely and changing the initial passwords.

## Supported security updates

Only the current `main` branch is maintained. Pinned dependency updates require
review of upstream release notes and refreshed digests.
