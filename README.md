# Rauthy for Proxmox LXC

A native [Rauthy](https://github.com/sebadob/rauthy) identity provider in an unprivileged Debian 13 LXC, prepared for Community Scripts / DevScripts submission. Defaults are **4 CPUs, 8 GiB RAM, 25 GiB disk**, allowing Rauthy to compile from official release source. It runs with systemd, uses embedded Hiqlite, and supports the usual in-container `update` command.

This is the testing branch of [mcv19/rauthy-proxmox-community-scripts](https://github.com/mcv19/rauthy-proxmox-community-scripts), a DevScripts fork. The contribution branch `feat/rauthy` contains only the CT script, installer, and JSON metadata. No upstream PR has been opened; real AMD64 Proxmox testing is still required.

## Install on your AMD64 Proxmox host

Run as root on the Proxmox node:

```bash
export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/mcv19/rauthy-proxmox-community-scripts/rauthy-testing"
export var_rauthy_version="0.37.0" # optional; blank/unset selects latest stable
bash -c "$(curl -fsSL "${COMMUNITY_SCRIPTS_URL}/ct/rauthy.sh")"
```

Before creating the LXC, the host script asks for a public DNS hostname, such as `auth.example.com`, and the reverse proxy's source IP/CIDR, such as `192.168.1.20/32`. Comma-separate multiple proxy addresses. Use the source address that Rauthy sees, including any NAT. Whole-Internet trusted proxy ranges are rejected. The public HTTPS port is 443.

You can provide all application settings before running:

```bash
export var_rauthy_hostname="auth.example.com"
export var_rauthy_proxy_cidrs="192.168.1.20/32"
export var_rauthy_admin_email="admin@example.com" # default: admin@localhost
```

Missing required hostname/proxy values cause installation to stop when prompting is unavailable. The community framework saves your source URL for the `update` launcher. For a local checkout, `bash ct/rauthy.sh` uses the sibling installer. Keep the testing fork and branch accessible.

## HTTPS and first login

**The reverse proxy can be configured after installation, but must be ready before first login.** Set DNS and a browser-trusted certificate for your chosen hostname. Forward HTTPS to `http://LXC_IP:8080`, passing the original `Host`, `X-Forwarded-For`, and `X-Forwarded-Proto: https` headers. Limit backend port 8080 to the trusted proxy in your network/Proxmox firewall.

For an existing Nginx HTTPS virtual host:

```nginx
location / {
    proxy_pass http://LXC_IP:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_buffering off;
    proxy_read_timeout 300s;
}
```

The installer records the public origin and trusts only the specified proxies plus loopback. It does not install a proxy, create DNS records, or provision certificates. Browsing directly to the LXC IP does not match Rauthy's authentication origin.

The installer displays the random administrator password. It is also in the root-only `/opt/rauthy_data/config.toml`, under `[bootstrap] password_plain`; `admin_email` gives the initial username. Read it inside the LXC. Open `https://YOUR_HOSTNAME/auth/v1/account`, sign in, and change the password. Then remove `password_plain` from the config. Enroll a passkey and set `[mfa] admin_force_mfa = true` before restarting Rauthy. Public self-registration is disabled.

Configure SMTP in the same config file using the [upstream configuration guide](https://sebadob.github.io/rauthy/config/config.html) for invitations and password-reset email. Bootstrap settings apply only to a new database; edit existing administrator accounts through the UI.

## Native installation and reference scripts

[Vaultwarden's installer](https://github.com/community-scripts/ProxmoxVE/blob/main/install/vaultwarden-install.sh) is the closest Community Scripts reference: a native Rust service built from release source with an embedded database. [Authelia](https://github.com/community-scripts/ProxmoxVE/blob/main/install/authelia-install.sh) supplies the identity-service/public-domain reference.

Rauthy's [Dockerfile](https://github.com/sebadob/rauthy/blob/v0.37.0/Dockerfile), [builder](https://github.com/sebadob/rauthy/blob/v0.37.0/Dockerfile_builder), [Cargo manifest](https://github.com/sebadob/rauthy/blob/v0.37.0/Cargo.toml), and [justfile](https://github.com/sebadob/rauthy/blob/v0.37.0/justfile) establish the build and runtime requirements. The installer uses `fetch_and_deploy_gh_release` in source-tarball mode and `setup_rust` with the release's declared Rust toolchain. It extracts the upstream archived frontend (including WASM), prepares the FIDO metadata when the release includes that tool, and compiles with `cargo --locked`. A Node build is unnecessary when using those archived assets.

No image extraction or container runtime is used in either application script. The service runs as root inside the unprivileged LXC, following DevScripts conventions. Its unit restricts writable paths to `/opt/rauthy_data`. Python is used only for standard-library input/config validation; it is not Rauthy's runtime and creates no virtual environment.

## Updates and recovery

Inside the LXC:

```bash
update
```

To select a release for one invocation:

```bash
var_rauthy_version=0.37.0 update
```

This does not persist a version lock. The updater checks releases with the shared helper and rejects downgrades. It compiles and validates the replacement while the old service continues running. A separate shared-helper build marker prevents failed builds from changing the installed version marker.

After compilation, it stops Rauthy and uses `create_backup` to copy **the old binary, entire config/Hiqlite directory, and installed version marker** into a new root-only `/opt/rauthy.backup-*` directory. It then installs the binary, starts the service, and commits the version marker after local health succeeds. Successful upgrade backups remain available; review disk use and remove old backups after you have verified the upgrade.

A failed start or health check stops the new service and calls `restore_backup`, replacing the full previous state, including WALs, before restarting the old service. The shared restore helper removes its backup directory after restoration. A backup failure restarts the original installation. Do not restore only the old binary over a migrated database.

Automatic upgrades support the supplied single-node Hiqlite layout. HA, external databases/secrets, service overrides, symlinked data, and bind-mounted application/data paths need their own upgrade procedure. This source-build layout replaces the earlier image-extraction prototype; that prototype's `/etc/rauthy` layout requires a fresh test LXC.

## Testing and submission

Follow [the AMD64 Proxmox checklist](docs/rauthy/amd64-proxmox-test.md) before submitting. [Automated checks and limitations](docs/rauthy/testing.md), [test report template](docs/rauthy/test-report-template.md), and [submission process](docs/rauthy/submission.md) are included. ARM64 source builds remain unverified; earlier image-binary tests do not establish support for the new build path.
