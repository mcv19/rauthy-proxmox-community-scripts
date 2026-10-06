# Rauthy AMD64 Proxmox test report

- Date:
- Testing branch commit:
- Proxmox VE version (`pveversion`):
- Host architecture (`dpkg --print-architecture`):
- LXC OS/version:
- Unprivileged: yes / no
- CPU/RAM/disk settings:
- Install source: mcv19/rauthy-proxmox-community-scripts, rauthy-testing
- Initial Rauthy version:
- Updated Rauthy version (if tested):
- Proxy software (do not include private credentials):

| Check | Result (pass / fail / untested) | Notes |
| --- | --- | --- |
| LXC creation and native source compilation | untested | |
| Custom hostname/proxy variables reach installer | untested | |
| Service health and generated systemd unit | untested | |
| HTTPS login and initial password change | untested | |
| Passkey enrollment and admin MFA | untested | |
| Reboot starts service | untested | |
| Same-version update does not restart service | untested | |
| 0.36.2 → 0.37.0 upgrade | untested | |
| Users/clients and config/secrets survive update | untested | |
| Full backup and recovery | untested | |
| SMTP invitation/password reset | untested | |

## Errors or deviations

Include relevant redacted messages. Omit passwords, config encryption/Raft keys, API keys, tokens, cookies, and unredacted config files.

## Architecture scope

This report covers real AMD64 Proxmox testing only. The new native source-build path on ARM64 is untested. Earlier arm64/emulated-amd64 image-binary tests apply only to the superseded prototype.
