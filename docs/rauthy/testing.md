# Validation and Proxmox acceptance

Validation performed on 2026-10-06:

- Bash syntax checks passed for both contribution scripts and the native integration harness.
- ShellCheck and `shfmt -d -i 2 -ci` passed.
- 15 isolated tests passed, including input/config safety, download/config failures before service stop, backup failure recovery, failed start/readiness restoration of binary and full database, retained encryption/configuration, same-version no-op, downgrade refusal, and rejection of HA or external data symlinks.
- Official **arm64 and amd64** binaries were extracted with `skopeo`/`umoci` and ran on Debian 13 (amd64 under architecture emulation). On both architectures, the actual installer created a dedicated service user, generated config, bootstrapped Hiqlite, and passed readiness. An actual **0.36.2 → 0.37.0** migration passed, retained the config, created a backup, and advertised the configured HTTPS issuer through OIDC discovery.
- The generated service file passed `systemd-analyze verify`.

The Debian integration harness simulates `systemctl` by launching the real service as `rauthy`. It exercises the real upstream binary, database, image extraction, installer, and updater; it does not exercise systemd as PID 1 or enforce the unit's sandbox options. No Proxmox host was connected, so host/container creation, the community engine handoff, the generated `update` launcher, and LXC-specific systemd restrictions remain unverified. Browser login, passkey enrollment, reverse-proxy TLS, and SMTP also need an environment-specific check.

## Repeat isolated checks

Use Linux, Bash, Python 3.11+, ShellCheck, and shfmt:

```bash
bash -n ct/rauthy.sh install/rauthy-install.sh tests/integration-native.sh
shellcheck -e SC1090,SC1091 ct/rauthy.sh install/rauthy-install.sh tests/integration-native.sh
shfmt -d -i 2 -ci ct/rauthy.sh install/rauthy-install.sh tests/integration-native.sh
python3 tests/test_rauthy.py
```

The isolated tests use temporary directories and service/download substitutes. They do not need internet, root, or a running application.

## Repeat real native migration

Run in a disposable container. Do not run the integration harness in an existing application container. The project mount is read-only:

```bash
docker run --rm \
  -v "$PWD:/workspace:ro" \
  debian:13-slim bash -c '
    apt-get update &&
    apt-get install -y ca-certificates curl skopeo umoci python3 procps libgcc-s1 libstdc++6 util-linux &&
    bash /workspace/tests/integration-native.sh
  '
```

Use `--platform linux/amd64` or `--platform linux/arm64` when cross-testing with Docker's architecture emulation. This harness pins its source and target versions to reproduce the migration, independently of the installer’s default latest-stable behavior. It requires registry/network access and downloads official images.

## Required real Proxmox checks

Complete these on a disposable Proxmox LXC before submitting a DevScripts PR:

- [ ] Run `bash ct/rauthy.sh` from a local checkout. Confirm the engine uses this checkout’s installer rather than a missing upstream script.
- [ ] Repeat via an actual GitHub fork/branch and `COMMUNITY_SCRIPTS_URL`. Confirm all custom `var_*` values reach the installer.
- [ ] Confirm default and advanced container creation on Debian 13, including an unprivileged LXC. Check available disk space for data and retained backups.
- [ ] Verify `systemctl is-active rauthy`, the unit’s hardening options, and service startup after an LXC reboot.
- [ ] Forward HTTPS through a real trusted proxy, sign in using `/root/rauthy.creds`, change the password, enroll a passkey, and enable administrator MFA.
- [ ] Configure SMTP and verify an invitation or password-reset email.
- [ ] Run the generated `update` command with no new release. Verify it reports no update without restarting the service.
- [ ] Install a supported older release, add actual test users/OIDC clients, run `update`, and confirm users, signing/encryption secrets, and settings survive.
- [ ] Simulate registry/network failure and confirm the existing service keeps running and the version marker is unchanged.
- [ ] Verify private full-state backups and manual recovery on the disposable LXC. Confirm the restored version and data work together.
- [ ] Test amd64 on your Proxmox host. Record ARM64 host coverage as untested; an ARM64 host is not required for your AMD64 validation.

Metadata in `json/rauthy.json` is a proposal for the current website record, including `app_vars`. Confirm the current maintainer workflow and category/logo choices rather than treating that draft as an automatically validated website submission.
