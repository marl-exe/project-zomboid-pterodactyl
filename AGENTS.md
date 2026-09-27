# Repository guidance

- This repository contains a root-level fresh-host installer. Preserve its
  fail-closed preflight and never turn it into an in-place updater.
- Never add real IP addresses, domains, emails, usernames, UUIDs, passwords,
  tokens, private keys, Wings configuration, Panel `.env` files, or logs.
- Keep the default deployment limited to one same-host Panel, Wings node, and
  Project Zomboid server on Ubuntu 24.04 amd64.
- Pin downloaded release artifacts and verify SHA-256 before use.
- Do not pass generated secrets through process arguments.
- Preserve existing SSH ports and do not modify SSH authentication policy.
- Do not disable Docker firewalling. Account for Docker's UFW bypass through a
  verified `DOCKER-USER` policy.
- Never reboot automatically.
- Run `bash tests/test-static.sh`. When Docker is available, also build and run
  `tests/Dockerfile`.
