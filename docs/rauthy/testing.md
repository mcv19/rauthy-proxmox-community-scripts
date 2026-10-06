# Rauthy validation

## Current source-build revision

- Bash syntax, ShellCheck, and `shfmt -d -i 2 -ci` pass.
- Seventeen isolated tests pass. They cover valid/random config and permissions, rejected hostname/email/proxy injection, download/toolchain/build/config failures before service downtime, backup failures, failed starts/readiness, complete binary/database/WAL/version rollback, successful commit with retained offline backup, no-op/failed release lookup, downgrade rejection, unsupported layouts/mounts/overrides, symlink rejection, host input collection/export before container creation, and contribution conventions.
- The actual shared `create_backup`/`restore_backup` helpers passed a disposable full-state fixture check: executable, config permissions, database, WAL, and version restored; a new WAL was removed rather than merged. This fixture is not a real Rauthy migration.
- The real v0.37.0 source installer passed on emulated AMD64 Debian 13 under Docker Desktop, limited to 4 CPUs and 7 GiB memory. Official source deployment, Rust 1.95.0, FIDO preparation, release compilation, config validation, native service startup, local health, OIDC HTTPS issuer, root-only config permissions, static systemd unit validation, and same-version update all passed. The tested installer snapshot exactly matched the current file.
- Compilation on this emulated setup took about 16 minutes for the initial FIDO tool build and 26 minutes for the release executable. A test-harness file-edit race and a metadata download retry were corrected; the final run completed successfully using the already-prepared staged metadata. The harness now snapshots the installer before execution.
- Real Proxmox creation, framework handoff, systemd as PID 1, reboot, browser login/passkey enrollment, reverse-proxy TLS, and SMTP remain untested. ARM64 source compilation remains untested.

The source-build integration harness loads actual Community Scripts release/runtime/backup helpers and compiles actual Rauthy source. The default no-op check does not exercise backup/restore; those boundaries are mocked in the isolated failure tests. Only the Proxmox lifecycle and `systemctl` are simulated. It tests local health, OIDC HTTPS issuer, generated config permissions, version marker, and static unit validation; it cannot enforce the unit's sandbox or establish LXC behavior.

The interactive host prompt was also exercised through a pseudo-terminal using the actual core prompt helper and a simulated Proxmox host command. Both chosen values remained exported. Core helpers used for this run: `79f6520ec8c5b4374c5c04736fb69b5ee601ea9b`.

## Run isolated checks

Use Linux, Bash, Python 3.11+, ShellCheck, and shfmt:

```bash
bash -n ct/rauthy.sh install/rauthy-install.sh tests/integration-native.sh
shellcheck -e SC1090,SC1091 ct/rauthy.sh install/rauthy-install.sh tests/integration-native.sh
shfmt -d -i 2 -ci ct/rauthy.sh install/rauthy-install.sh tests/integration-native.sh
python3 tests/test_rauthy.py
```

The isolated update tests mock external boundaries (downloads, compilers, backup storage, service control). The updater logic and input/config snippets come from the production scripts. No service is started and no system directory is written.

## Disposable Debian source-build test

Docker is used only as a local disposable test environment; the application scripts do not use it. Run this with sufficient free disk and memory on a machine with Docker. The workspace is mounted read-only. This test creates a new disposable container and compiles Rauthy; it must not be run on your host filesystem.

```bash
core_dir=$(mktemp -d)
gh api repos/community-scripts/core/tarball/main > "$core_dir/core.tar.gz"
mkdir "$core_dir/core"
tar -xzf "$core_dir/core.tar.gz" -C "$core_dir/core" --strip-components=1

docker run --rm --init --platform linux/amd64 --memory 7g --cpus 4 \
  -v "$PWD:/workspace:ro" -v "$core_dir/core:/test-core:ro" \
  debian:13-slim bash -c '
    apt-get update &&
    apt-get install -y curl ca-certificates jq git systemd procps &&
    bash /workspace/tests/integration-native.sh
  '
```

The default harness installs v0.37.0 and invokes a same-version no-op update. To test a real migration, add these Docker options before the image name:

```bash
-e TEST_INSTALL_VERSION=v0.36.2 -e TEST_UPDATE_VERSION=v0.37.0
```

The helper source is fetched at execution time; record its revision alongside test results. For reproducible runs, substitute an explicit core commit for `main` in the API command. A source-build migration compiles two releases, so it requires more time than the default test.

## Superseded prototype results

Before the source-build revision, the OCI-extraction prototype passed native ARM64 and emulated AMD64 Debian installs and 0.36.2 → 0.37.0 migrations, using the official image binary, a dedicated service user, and a custom offline archive. Those results apply only to that earlier implementation. They do not validate this revision's source compilation, layout, or shared-helper recovery.

## Proxmox acceptance

Follow `amd64-proxmox-test.md`, record results in `test-report-template.md`, and complete the gates in `submission.md`. Metadata is a proposal for the current website record; the resource defaults, exported `app_vars`, and config path must stay synchronized with the scripts.
