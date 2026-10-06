<!-- Draft only: complete real Proxmox testing and resolve convention gaps before submission. -->

## ✍️ Description

Adds a native Rauthy identity-provider LXC with embedded Hiqlite storage and in-container update support. The current prototype extracts the upstream release binary from `ghcr.io/sebadob/rauthy`, runs it with systemd, preserves generated configuration/secrets, takes a full offline state backup before upgrading, and restores the previous binary plus database after failed readiness.

Source research: Rauthy Dockerfile, Docker deployment guide, config generator, CLI/config source, and release metadata. The official image uses a Debian 12 distroless runtime and bundles the Rust executable and frontend at `/app/rauthy`; Debian 13 runs it natively. No external database is needed in this single-instance configuration. Requires an existing HTTPS reverse proxy on port 443.

**Resolve before submission:** review `docs/rauthy/submission.md`. The prototype's custom helper functions, OCI extraction, full-state recovery, service user, credential file, and dependency conventions require revision or explicit upstream acceptance. Do not silently claim full guideline compliance.

## 🔗 Related PR / Issue

None yet.

## ✅ Prerequisites

- [ ] Self-review completed and all remaining convention gaps resolved
- [ ] Tested thoroughly on the real Proxmox host (report pending)
- [ ] No breaking changes to existing scripts
- [ ] No hardcoded secrets or unnecessary privileges

## 🏗️ arm64 Support

- Native arm64 Debian container installation/migration passed.
- Real ARM64 Proxmox/Incus host testing: not performed. Choose the appropriate current upstream template checkbox and explain this scope.

## 🖥️ Tested on

- [ ] Proxmox VE — real AMD64 results pending
- [ ] Incus — not tested

## 🛠️ Type of Change

- [x] New script

## 🔍 Code & Security Review

- [ ] All current AGENTS.md/CODE-AUDIT.md conventions satisfied or explicitly accepted
- [x] CT/install/JSON files present
- [x] No hardcoded credentials
- [x] No Docker daemon or Docker Compose in the LXC
- [x] No application git pull updates

## 🤖 AI Assistance

Codex (GPT-6 family; exact variant and reasoning setting not exposed) authored the prototype, tests, and documentation and performed review and automated validation. An attempted Claude handoff did not run and generated no implementation. Human review and real AMD64 Proxmox testing are pending.

## 📋 Additional Information

Automated checks passed: Bash syntax, ShellCheck, shfmt, 15 isolated input/update/recovery tests, real native installation and 0.36.2 → 0.37.0 database migrations in arm64 and emulated amd64 Debian 13 containers, OIDC HTTPS issuer verification, and static systemd unit validation. The container harness simulates systemctl and does not establish actual LXC/systemd hardening behavior.

Real Proxmox result: TODO — insert your completed AMD64 report.

## 📦 Application Requirements

- [x] At least 6 months old (created 2023-07-01)
- [x] Actively maintained (current release v0.37.0, 2026-10-03)
- [x] 600+ GitHub stars (1,362 on 2026-10-06)
- [ ] Official release tarballs/artifact criterion — source tarball exists; confirm acceptance of OCI-only prebuilt distribution
- [ ] I understand that acceptance is at the maintainers' discretion

## 🌐 Source

- https://github.com/sebadob/rauthy
- https://github.com/sebadob/rauthy/blob/v0.37.0/Dockerfile
- https://sebadob.github.io/rauthy/getting_started/docker.html
- https://github.com/community-scripts/ProxmoxVE/blob/main/install/vaultwarden-install.sh
