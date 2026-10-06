#!/usr/bin/env bash
# Copyright (c) 2026 community-scripts contributors
# License: MIT
# Source: https://github.com/sebadob/rauthy

# shellcheck disable=SC1091
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Rauthy build dependencies"
$STD apt install -y build-essential clang pkg-config libpam0g-dev libudev-dev python3
msg_ok "Installed Rauthy build dependencies"
ensure_dependencies openssl

var_rauthy_hostname=$(prompt_input_required "Rauthy public HTTPS hostname (e.g. auth.example.com)" "" 120 "var_rauthy_hostname")
var_rauthy_proxy_cidrs=$(prompt_input_required "Rauthy reverse proxy IP/CIDR (comma-separated)" "" 120 "var_rauthy_proxy_cidrs")
var_rauthy_admin_email="${var_rauthy_admin_email:-admin@localhost}"
# Validate before interpolation; only IP networks and safe TOML basic strings survive.
TRUSTED_PROXIES=$(
  python3 - "$var_rauthy_hostname" "$var_rauthy_proxy_cidrs" "$var_rauthy_admin_email" <<'PY'
import ipaddress, json, re, sys
hostname, proxies, email = sys.argv[1:]
label = r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
if (len(hostname) > 253 or not re.fullmatch(fr'{label}(?:\.{label})+', hostname)
        or hostname.rsplit('.', 1)[1].isdigit()):
    sys.exit('Rauthy requires a DNS hostname without a scheme, port, or path.')
try:
    networks = [ipaddress.ip_network(p.strip(), strict=False) for p in proxies.split(',') if p.strip()]
except ValueError:
    sys.exit('Rauthy trusted proxies must be IP addresses or CIDRs.')
if not networks or any(n.prefixlen == 0 for n in networks):
    sys.exit('Rauthy requires specific trusted proxy addresses; /0 is not allowed.')
if len(email) > 254 or not re.fullmatch(r'[a-zA-Z0-9.!#$%&*+/=?^_`{|}~-]+@[a-zA-Z0-9.-]+', email):
    sys.exit('Rauthy administrator email is invalid.')
print(json.dumps(list(dict.fromkeys(['127.0.0.1/32', '::1/128'] + [str(n) for n in networks]))))
PY
)

# A separate source marker keeps a failed build from advertising an installed update.
CLEAN_INSTALL=1 fetch_and_deploy_gh_release "rauthy-build" "sebadob/rauthy" "tarball" "${var_rauthy_version:-latest}" "/opt/rauthy-build"
cd /opt/rauthy-build || exit 1
RUST_TOOLCHAIN="$(sed -n 's/^rust-version = "\([^"]*\)"/\1/p' Cargo.toml)" setup_rust

msg_info "Building Rauthy from release source"
# Upstream ships the archived frontend, including WASM; no Node build is needed.
mkdir -p static
$STD tar -xf assets/static_html/static_v1.tar.gz
$STD tar -xf assets/static_html/templates_html.tar.gz
CARGO_BUILD_JOBS="$(get_parallel_jobs)"
export CARGO_BUILD_JOBS
export CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_DEV_INCREMENTAL=false
export CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
if [[ -f src/bin/src/fido_mds_prep.rs && ! -s assets/fido_mds/dataset.bin ]]; then
  $STD cargo run --locked --bin fido-mds-prep
fi
$STD cargo build --locked --release --bin rauthy
[[ "$(target/release/rauthy --version)" == "rauthy $(cat /root/.rauthy-build)" ]] || exit 1
install -d -m 0755 /opt/rauthy
install -m 0755 target/release/rauthy /opt/rauthy/rauthy
msg_ok "Built Rauthy from release source"

msg_info "Creating Rauthy configuration"
umask 077
install -d -m 0700 /opt/rauthy_data
RAUTHY_ADMIN_PASSWORD=$(random_password)
cat <<EOF >/opt/rauthy_data/config.toml
# Keep this configuration and its encryption and cluster secrets across upgrades.
[bootstrap]
admin_email = "$var_rauthy_admin_email"
password_plain = "$RAUTHY_ADMIN_PASSWORD"

[cluster]
node_id = 1
nodes = ["1 127.0.0.1:8100 127.0.0.1:8200"]
data_dir = "/opt/rauthy_data/data"
secret_raft = "$(openssl rand -hex 32)"
secret_api = "$(openssl rand -hex 32)"

[database]
hiqlite = true

[encryption]
keys = ["lxc01/$(openssl rand -base64 32)"]
key_active = "lxc01"

[server]
listen_address = "0.0.0.0"
port_http = 8080
scheme = "http"
pub_url = "$var_rauthy_hostname"
proxy_mode = true
trusted_proxies = $TRUSTED_PROXIES
http_workers = 1

[webauthn]
rp_id = "$var_rauthy_hostname"
rp_origin = "https://$var_rauthy_hostname:443"

[mfa]
# Enroll your admin passkey, then enable enforcement.
admin_force_mfa = false

[user_registration]
enable = false

[logging]
level = "info"
EOF
chmod 0600 /opt/rauthy_data/config.toml
cd /opt/rauthy_data || exit 1
$STD /opt/rauthy/rauthy validate-config -p /opt/rauthy_data/config.toml
msg_ok "Created Rauthy configuration"

msg_info "Creating Rauthy service"
cat <<'EOF' >/etc/systemd/system/rauthy.service
[Unit]
Description=Rauthy Identity Provider
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/rauthy_data
Environment=MALLOC_CONF=abort_conf:true,narenas:8,tcache_max:4096,dirty_decay_ms:5000,muzzy_decay_ms:5000
ExecStart=/opt/rauthy/rauthy serve -c /opt/rauthy_data/config.toml
Restart=on-failure
RestartSec=5
TimeoutStopSec=90
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/rauthy_data

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 /etc/systemd/system/rauthy.service
systemctl enable --quiet --now rauthy
for ((attempt = 0; attempt < 60; attempt++)); do
  if systemctl is-active --quiet rauthy && curl -fsS --connect-timeout 1 --max-time 2 \
    -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' \
    http://127.0.0.1:8080/auth/v1/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ((attempt == 60)); then
  msg_error "Rauthy did not become healthy. Inspect journalctl -u rauthy"
  exit 1
fi
mv /root/.rauthy-build /root/.rauthy
chmod 0600 /root/.rauthy
cd /root || exit 1
rm -rf /opt/rauthy-build
msg_ok "Created healthy Rauthy service"
echo -e "${INFO}${YW}Rauthy administrator: $var_rauthy_admin_email${CL}"
echo -e "${INFO}${YW}Rauthy initial password: $RAUTHY_ADMIN_PASSWORD${CL}"
echo -e "${INFO}${YW}Rauthy configuration: /opt/rauthy_data/config.toml (root-only). Change the password after signing in, then remove bootstrap.password_plain.${CL}"

motd_ssh
customize
cleanup_lxc
