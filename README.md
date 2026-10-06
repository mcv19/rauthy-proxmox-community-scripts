# Rauthy for Proxmox LXC

Community Scripts contribution for a native [Rauthy](https://github.com/sebadob/rauthy) service in an unprivileged Debian 13 LXC. Defaults: 2 CPUs, 1 GiB RAM, 4 GiB disk. Single instance, embedded Hiqlite database, systemd startup, and the usual in-container `update` command.

Rauthy's official Docker image supplies the release binary and embedded frontend. `skopeo` and `umoci` extract it without a Docker daemon. Rauthy then runs directly as a dedicated `rauthy` user. The installer generates independent encryption and Raft secrets, prompts for a public hostname and trusted reverse proxy, and stores random administrator credentials in `/root/rauthy.creds` inside the LXC.

## Reference projects

[Vaultwarden's container script](https://github.com/community-scripts/ProxmoxVE/blob/main/ct/vaultwarden.sh) and [installer](https://github.com/community-scripts/ProxmoxVE/blob/main/install/vaultwarden-install.sh) are the closest mature reference: a Rust application, a single service, and an embedded persistent database. [Authelia](https://github.com/community-scripts/ProxmoxVE/blob/main/ct/authelia.sh) provides the identity-service and public-domain pattern. Rauthy's [Dockerfile](https://github.com/sebadob/rauthy/blob/v0.37.0/Dockerfile) and [Docker deployment guide](https://sebadob.github.io/rauthy/getting_started/docker.html) define the actual binary, working-directory, and configuration requirements. Unlike Vaultwarden's Debian installer, this script reuses the prebuilt upstream binary instead of compiling Rust and the frontend.

## Run on Proxmox

This is the personal `rauthy-testing` branch of [mcv19/rauthy-proxmox-community-scripts](https://github.com/mcv19/rauthy-proxmox-community-scripts), a DevScripts fork. These files have not been submitted upstream. Clone/copy this project onto a Proxmox host and run the local script as root:

```bash
bash ct/rauthy.sh
```

The community core resolves the sibling `install/` directory for a local checkout. Its shared engine is downloaded from `community-scripts/core` unless `COMMUNITY_SCRIPTS_CORE_DIR` is provided. The normal default/advanced LXC settings apply.

The published testing branch belongs to your DevScripts fork. Run this on the Proxmox host:

```bash
export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/mcv19/rauthy-proxmox-community-scripts/rauthy-testing"
bash -c "$(curl -fsSL "${COMMUNITY_SCRIPTS_URL}/ct/rauthy.sh")"
```

That source URL is saved by the community framework for the LXC's `update` command. Keep the fork/branch accessible. The default DevScripts URL is for eventual upstream inclusion; there is currently no upstream Rauthy script to fetch.

The installer asks for:

- **Public hostname:** e.g. `auth.example.com`, without `https://`, a port, or a path. The public HTTPS port is 443.
- **Reverse proxy IP/CIDR:** e.g. `192.168.1.20/32`. Comma-separate multiple proxies. Use the source address that Rauthy sees, including NAT where applicable. Whole-Internet proxy ranges are rejected.

Provide these variables before running to bypass the application prompts:

```bash
export var_rauthy_hostname="auth.example.com"
export var_rauthy_proxy_cidrs="192.168.1.20/32"
export var_rauthy_admin_email="admin@example.com" # optional; default admin@localhost
export var_rauthy_version="0.37.0"                # optional; default latest stable
bash ct/rauthy.sh
```

`var_rauthy_version` chooses an explicit version for that invocation. It is not a persistent version lock: subsequent `update` calls follow stable upstream releases unless the variable is supplied again.

## HTTPS and first login

Use an existing reverse proxy with a browser-trusted TLS certificate. Point the public hostname to that proxy and forward it to `http://LXC_IP:8080`. Pass the original `Host`, `X-Forwarded-For`, and `X-Forwarded-Proto: https` headers. Rauthy accepts requests from the configured proxy addresses and loopback. Restrict backend port 8080 to your proxy in your network/Proxmox firewall.

For example, inside your existing Nginx HTTPS virtual host:

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

The installer configures Rauthy's public origin; it does not provision DNS, a reverse proxy, or certificates. Direct browsing to the LXC IP does not match the configured authentication origin.

Inside the LXC:

```bash
cat /root/rauthy.creds
systemctl status rauthy
journalctl -u rauthy -n 100 --no-pager
```

Open `https://YOUR_HOSTNAME/auth/v1/account`, sign in, and change the initial password. Enroll an administrator passkey, then set `[mfa] admin_force_mfa = true` in `/etc/rauthy/config.toml` and restart Rauthy. MFA enforcement is initially disabled so the first administrator can enroll. Public self-registration is disabled.

Configure SMTP in `/etc/rauthy/config.toml` using the [upstream email configuration](https://sebadob.github.io/rauthy/config/config.html). Email delivery is needed for account invitations and password-reset email flows. The `[bootstrap]` email only applies to a new database; change existing accounts through the UI.

## Updates and backups

Inside the LXC:

```bash
update
```

Or choose a specific release for one update:

```bash
var_rauthy_version=0.37.0 update
```

Updates resolve a stable release once, pin the image by digest, extract and validate the new binary, and validate your config before stopping the service. With Rauthy stopped, the updater archives the complete configuration, binary/digest, database directory including WALs, and version marker to `/var/backups/rauthy/TIMESTAMP-VERSION.RANDOM/snapshot.tar`. It starts the new version and checks `/auth/v1/health` before recording success. A failed update after the backup triggers restoration of the previous binary **and complete data**. Download/config errors leave the original service running. A lock prevents concurrent updates.

Backups are private to root and retained. Plan disk space for the staged image plus a full data backup on every update. Copy important backups off the LXC and use Proxmox backups as well. Review [Rauthy release notes](https://github.com/sebadob/rauthy/releases) before upgrading: application behavior and configuration requirements can change even when automatic migrations succeed.

Automatic updates support this installer’s single-node Hiqlite layout, HTTP backend on 8080, and managed systemd service. HA, external Postgres, external secrets files, runtime environment overrides, and alternate data layouts require their own upgrade procedure. Downgrades are refused; use a matching pre-upgrade data backup. A future 1.x release requires a script review before this updater accepts it.

For manual recovery, substitute the **actual** backup directory. Stop the service first. Restore the entire archive together; restoring only the old binary can leave an incompatible migrated database:

```bash
backup="/var/backups/rauthy/ACTUAL_BACKUP_DIRECTORY"
test -f "$backup/snapshot.tar" || exit 1
tar -tf "$backup/snapshot.tar" >/dev/null || exit 1
systemctl stop rauthy || exit 1
# Preserve the failed state before replacing it.
recovery="$(mktemp -d /var/backups/rauthy/manual-recovery.XXXXXX)"
tar -C / -cpf "$recovery/failed-state.tar" etc/rauthy opt/rauthy var/lib/rauthy root/.rauthy || exit 1
rm -rf /etc/rauthy /opt/rauthy /var/lib/rauthy
tar -C / -xpf "$backup/snapshot.tar" || exit 1
systemctl start rauthy
journalctl -u rauthy -n 100 --no-pager
```

Protect `/etc/rauthy/config.toml`: its encryption keys are needed to read encrypted database secrets. Updates preserve these keys. Do not replace them with new random values when restoring.

## Files and contribution

| File/location | Purpose |
| --- | --- |
| `ct/rauthy.sh` | Proxmox creation and in-LXC update flow |
| `install/rauthy-install.sh` | Native installation and generated service/config |
| `/opt/rauthy/rauthy` | Upstream release binary |
| `/opt/rauthy/image-digest` | Image digest used for the installed binary |
| `/etc/rauthy/config.toml` | Configuration and persistent encryption/Raft secrets |
| `/var/lib/rauthy` | Service working directory and complete persistent state |
| `/root/.rauthy` | Community framework version marker |
| `/root/rauthy.creds` | Initial credentials, readable only by root |

New scripts must first be submitted to [DevScripts](https://github.com/community-scripts/DevScripts), per the current [ProxmoxVE contribution guide](https://github.com/community-scripts/ProxmoxVE/blob/main/CONTRIBUTING.md). Add `ct/rauthy.sh` and `install/rauthy-install.sh` to a DevScripts fork, complete the real Proxmox checklist in [docs/rauthy/testing.md](docs/rauthy/testing.md), and open a PR there. The website metadata and `app_vars` proposal are in [json/rauthy.json](json/rauthy.json); confirm the maintainers' current metadata process when submitting.

Start with the [AMD64 Proxmox test guide](docs/rauthy/amd64-proxmox-test.md). The [submission checklist](docs/rauthy/submission.md) records the remaining DevScripts convention gaps; this branch is for testing and is not ready for upstream acceptance yet.

Tests and their limits are described in [docs/rauthy/testing.md](docs/rauthy/testing.md). Native Linux validation does not establish that Proxmox container creation or systemd hardening works in a real LXC.
