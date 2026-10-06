#!/usr/bin/env bash
# Copyright (c) 2026 community-scripts contributors
# License: MIT
# Source: https://github.com/sebadob/rauthy

# shellcheck disable=SC1091
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"

rauthy_write_config() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import ipaddress, json, os, pathlib, re, secrets, sys
hostname, proxies, email, config_path, creds_path = sys.argv[1:]
hostname = hostname.strip().lower()
label = r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
if (len(hostname) > 253 or not re.fullmatch(fr'{label}(?:\.{label})+', hostname)
        or hostname.rsplit('.', 1)[1].isdigit()):
    sys.exit('Enter a DNS hostname such as auth.example.com, without a scheme, port, or path.')
try:
    networks = [ipaddress.ip_network(p.strip(), strict=False) for p in proxies.split(',') if p.strip()]
except ValueError:
    sys.exit('Trusted proxies must be comma-separated IP addresses or CIDRs.')
if not networks or any(n.prefixlen == 0 for n in networks):
    sys.exit('Specify your reverse proxy IP/CIDR; trusting the entire Internet is not supported.')
if len(email) > 254 or not re.fullmatch(r"[a-zA-Z0-9.!#$%&*+/=?^_`{|}~-]+@[a-zA-Z0-9.-]+", email):
    sys.exit('Invalid administrator email address.')
trusted = list(dict.fromkeys(['127.0.0.1/32', '::1/128'] + [str(n) for n in networks]))
password = secrets.token_urlsafe(32)
import base64
key = base64.b64encode(secrets.token_bytes(32)).decode()
q = json.dumps  # JSON basic strings and arrays are valid TOML for these inputs.
config = f'''# Rauthy single-node LXC configuration. Keep the encryption and Raft secrets.
[bootstrap]
admin_email = {q(email)}
password_plain = {q(password)}

[cluster]
node_id = 1
nodes = ["1 127.0.0.1:8100 127.0.0.1:8200"]
data_dir = "/var/lib/rauthy/data"
secret_raft = {q(secrets.token_hex(32))}
secret_api = {q(secrets.token_hex(32))}

[database]
hiqlite = true

[encryption]
keys = ["lxc01/{key}"]
key_active = "lxc01"

[server]
listen_address = "0.0.0.0"
port_http = 8080
scheme = "http"
pub_url = {q(hostname)}
proxy_mode = true
trusted_proxies = {q(trusted)}
http_workers = 1

[webauthn]
rp_id = {q(hostname)}
rp_origin = {q('https://' + hostname + ':443')}

[mfa]
# Enroll your admin passkey, then enable this.
admin_force_mfa = false

[user_registration]
enable = false

[logging]
level = "info"
'''
for path, content in [(config_path, config), (creds_path, f'URL: https://{hostname}\nAdmin: {email}\nInitial password: {password}\n')]:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(content)
PY
}

# Keep the image extraction identical to ct/rauthy.sh.
rauthy_stage_binary() (
  set -euo pipefail
  local version="$1" stage="$2" arch digest
  [[ "$version" =~ ^0\.[0-9]+\.[0-9]+$ ]] || {
    echo "Unsupported Rauthy release: $version" >&2
    exit 1
  }
  arch="$(dpkg --print-architecture)"
  case "$arch" in amd64 | arm64) ;; *)
    echo "Unsupported architecture: $arch" >&2
    exit 1
    ;;
  esac
  digest="$(skopeo inspect --override-os linux --override-arch "$arch" --format '{{.Digest}}' "docker://ghcr.io/sebadob/rauthy:${version}")"
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]
  skopeo copy --override-os linux --override-arch "$arch" "docker://ghcr.io/sebadob/rauthy@${digest}" "oci:${stage}/image:rauthy"
  umoci unpack --rootless --image "${stage}/image:rauthy" "${stage}/bundle"
  install -m 0755 "${stage}/bundle/rootfs/app/rauthy" "${stage}/rauthy"
  [[ "$("${stage}/rauthy" --version)" == "rauthy ${version}" ]]
  printf '%s\n' "$digest" >"${stage}/image-digest"
)

rauthy_wait_healthy() {
  local attempt
  for ((attempt = 0; attempt < 60; attempt++)); do
    if systemctl is-active --quiet rauthy && curl -fsS --connect-timeout 1 --max-time 2 \
      -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' \
      http://127.0.0.1:8080/auth/v1/health >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing dependencies"
$STD apt-get install -y ca-certificates curl skopeo umoci python3 libgcc-s1 libstdc++6 util-linux
msg_ok "Installed dependencies"

if [[ -z "${var_rauthy_hostname:-}" ]]; then
  read -r -p "${TAB3}Public HTTPS hostname (e.g. auth.example.com): " var_rauthy_hostname || {
    msg_error "Set var_rauthy_hostname for unattended installation"
    exit 1
  }
fi
if [[ -z "${var_rauthy_proxy_cidrs:-}" ]]; then
  read -r -p "${TAB3}Reverse proxy IP/CIDR (comma-separated if multiple): " var_rauthy_proxy_cidrs || {
    msg_error "Set var_rauthy_proxy_cidrs for unattended installation"
    exit 1
  }
fi

msg_info "Creating Rauthy configuration"
useradd --system --user-group --home-dir /var/lib/rauthy --shell /usr/sbin/nologin rauthy
install -d -m 0755 /opt/rauthy
install -d -m 0750 -o root -g rauthy /etc/rauthy
install -d -m 0700 -o rauthy -g rauthy /var/lib/rauthy
rauthy_write_config "$var_rauthy_hostname" "$var_rauthy_proxy_cidrs" "${var_rauthy_admin_email:-admin@localhost}" /etc/rauthy/config.toml /root/rauthy.creds
chown root:rauthy /etc/rauthy/config.toml
chmod 0640 /etc/rauthy/config.toml
msg_ok "Created Rauthy configuration"

(
  set -Eeuo pipefail
  trap - ERR
  umask 077
  stage="$(mktemp -d /opt/rauthy-stage.XXXXXX)"
  trap 'rm -rf "$stage"' EXIT
  release="${var_rauthy_version:-$(get_latest_github_release "sebadob/rauthy")}"
  release="${release#v}"
  msg_info "Extracting Rauthy ${release} from the official image"
  rauthy_stage_binary "$release" "$stage"
  (cd /var/lib/rauthy && "${stage}/rauthy" validate-config -p /etc/rauthy/config.toml >/dev/null)
  install -m 0755 "${stage}/rauthy" /opt/rauthy/rauthy
  install -m 0600 "${stage}/image-digest" /opt/rauthy/image-digest
  printf '%s\n' "$release" >/opt/rauthy/pending-version
  msg_ok "Installed Rauthy ${release}"
)

msg_info "Creating Rauthy service"
cat <<'EOF' >/etc/systemd/system/rauthy.service
[Unit]
Description=Rauthy Identity Provider
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=rauthy
Group=rauthy
WorkingDirectory=/var/lib/rauthy
Environment=MALLOC_CONF=abort_conf:true,narenas:8,tcache_max:4096,dirty_decay_ms:5000,muzzy_decay_ms:5000
ExecStart=/opt/rauthy/rauthy serve -c /etc/rauthy/config.toml
Restart=on-failure
RestartSec=5
TimeoutStopSec=90
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/rauthy

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --quiet --now rauthy
if ! rauthy_wait_healthy; then
  msg_error "Rauthy did not become healthy. Inspect journalctl -u rauthy"
  exit 1
fi
# Do not retain the plaintext bootstrap password in the service-readable config.
sed -i '/^password_plain = /d' /etc/rauthy/config.toml
mv /opt/rauthy/pending-version /root/.rauthy
chmod 0600 /root/.rauthy
msg_ok "Created healthy Rauthy service"
msg_ok "Initial administrator credentials are stored in /root/rauthy.creds"

motd_ssh
customize
cleanup_lxc
