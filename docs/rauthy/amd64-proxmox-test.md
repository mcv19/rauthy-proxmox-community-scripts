# Test Rauthy on your AMD64 Proxmox host

This is an experimental testing branch. Your AMD64 host is enough to validate the Proxmox installer and updater. The new source-build path on ARM64 has not been tested; no ARM64 Proxmox/Incus support is claimed.

Use a fresh disposable LXC for these checks. The script creates the LXC through the usual Community Scripts default/advanced menu; don't run the host creation command inside an existing LXC.

## 1. Prepare the public address

Choose a DNS hostname you control, e.g. `auth.example.com`, and the IP of your HTTPS reverse proxy. The proxy can already exist or be configured after the LXC is created, but it is required before browser login and passkeys work. It must present a browser-trusted certificate on public port 443 and forward to `http://LXC_IP:8080`.

No public exposure is necessary: local DNS and a trusted HTTPS certificate on your LAN work too. Enter the source IP/CIDR that the proxy uses when connecting to the LXC. The script does not install a proxy or manage certificates.

The source-build defaults are **4 CPUs, 8 GiB RAM, 25 GiB disk**. Use a fresh LXC for this revision; older image-extraction prototype layouts are not automatically migrated. Compilation downloads Rust crates and may take considerable time. The HTTPS proxy can be configured immediately after installation, before first login.

## 2. Install on the Proxmox host

Open your **Proxmox node's root Shell**, check the architecture, and run the published testing branch:

```bash
dpkg --print-architecture # should print amd64
export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/mcv19/rauthy-proxmox-community-scripts/rauthy-testing"
export var_rauthy_version="0.37.0"
bash -c "$(curl -fsSL "${COMMUNITY_SCRIPTS_URL}/ct/rauthy.sh")"
```

The host script asks for the public hostname and proxy IP/CIDR before LXC creation; these are exported to the installer. For unattended application configuration, provide these too, replacing the examples:

```bash
export var_rauthy_hostname="auth.example.com"
export var_rauthy_proxy_cidrs="192.168.1.20/32"
export var_rauthy_admin_email="admin@example.com"
```

Defaults are Debian 13, 4 CPUs, 8 GiB RAM, 25 GiB disk, and an unprivileged LXC. Use more disk space if you plan to keep many update backups. Record the resulting CTID and LXC IP.

## 3. Check the service inside the LXC

Open the new LXC's console as root:

```bash
dpkg --print-architecture
/opt/rauthy/rauthy --version
systemctl is-active rauthy
curl --fail --silent --show-error \
  -H 'X-Forwarded-For: 127.0.0.1' \
  -H 'X-Forwarded-Proto: https' \
  http://127.0.0.1:8080/auth/v1/health
cat /root/.rauthy
sed -n '/^\[bootstrap\]/,/^\[/p' /opt/rauthy_data/config.toml
```

Expected: `amd64`, `rauthy 0.37.0`, `active`, a successful health response, and version marker `0.37.0`. The initial password is random and retained under `[bootstrap]` in the root-only config. After changing it in the UI, remove `password_plain` from the config. Keep the password and config secrets out of screenshots, issues, and test reports.

## 4. Connect the proxy and sign in

Configure your existing proxy as described in the project README. Verify `https://YOUR_HOSTNAME/auth/v1/account`, sign in, change the password, and enroll a passkey. Then enable `[mfa] admin_force_mfa = true` and restart Rauthy. Configure SMTP separately if you want to test invitation/password-reset email delivery.

## 5. Verify reboot and a no-op update

Reboot the LXC from Proxmox and repeat the health and browser checks. Inside the LXC, inspect the generated update command and run a pinned same-version update:

```bash
cat /usr/bin/update
var_rauthy_version=0.37.0 update
systemctl is-active rauthy
```

The launcher must point to your `mcv19/rauthy-proxmox-community-scripts/rauthy-testing` source, rather than the upstream DevScripts branch. The same-version update should leave the service running without taking an upgrade backup.

## 6. Test a real upgrade in a second disposable LXC

On the Proxmox host, repeat step 2 with `var_rauthy_version=0.36.2` to create a separate upgrade-test LXC. Configure the same type of HTTPS proxy using a **different hostname**, sign in, and create test users/clients. Keep this older release restricted to your test network.

Inside this second LXC:

```bash
sha256sum /opt/rauthy_data/config.toml >/root/rauthy-config-before.sha256
var_rauthy_version=0.37.0 update
/opt/rauthy/rauthy --version
cat /root/.rauthy
sha256sum -c /root/rauthy-config-before.sha256
find /opt -maxdepth 2 -path '/opt/rauthy.backup-*/.manifest'
systemctl is-active rauthy
```

Expected: version `0.37.0`, unchanged config hash, a full backup, healthy service, and the original users/clients still available. For a manual recovery test, restore a Proxmox snapshot of the entire disposable test LXC. Do not mix an old executable with a migrated database.

## 7. Record results before submission

Copy `docs/rauthy/test-report-template.md` to a report and fill in the Proxmox version, architecture, unprivileged/container settings, install/reboot/login/passkey/update results, and any error messages. Do not send secrets. The report must describe what you actually tested; leave untested items unchecked.

The planned upstream contribution is on `feat/rauthy`. The convention alignment and remaining test gates are listed in `docs/rauthy/submission.md`. Record the real AMD64 results before opening the upstream PR.
