#!/usr/bin/env bash
_CS_DEFAULT_URL="https://raw.githubusercontent.com/community-scripts/DevScripts/main"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
# shellcheck disable=SC1090
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2026 community-scripts contributors
# License: MIT
# Source: https://github.com/sebadob/rauthy

APP="Rauthy"
var_tags="${var_tags:-identity;authentication;sso}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-25}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
#var_arm64="${var_arm64:-no}" # No standalone assets; ARM64 source build is unverified.
var_unprivileged="${var_unprivileged:-1}"
export var_rauthy_hostname="${var_rauthy_hostname:-}"
export var_rauthy_proxy_cidrs="${var_rauthy_proxy_cidrs:-}"
export var_rauthy_admin_email="${var_rauthy_admin_email:-admin@localhost}"
export var_rauthy_version="${var_rauthy_version:+v${var_rauthy_version#v}}"

header_info "$APP"
variables
color
catch_errors

# shellcheck disable=SC2034 # Transaction state is read by the EXIT trap.
function update_script() (
  set -Eeuo pipefail
  trap - ERR EXIT
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -x /opt/rauthy/rauthy || ! -f /opt/rauthy_data/config.toml || ! -f /root/.rauthy ]]; then
    msg_error "No managed Rauthy installation found; reinstall older experimental layouts"
    exit 1
  fi
  ensure_dependencies python3 build-essential clang pkg-config libpam0g-dev libudev-dev util-linux
  rc=0 current="" backup="" stopped=0 saved=0 committed=0 attempt=0
  exec 9>/run/lock/rauthy-update.lock
  flock -n 9 || {
    msg_error "Another Rauthy update is running"
    exit 1
  }
  if check_for_gh_release "rauthy" "sebadob/rauthy" "${var_rauthy_version:-}" "User-selected release"; then
    current="$(cat /root/.rauthy)"
    if ! version_gt "${CHECK_UPDATE_RELEASE#v}" "${current#v}"; then
      msg_error "Rauthy downgrades require a matching database backup"
      exit 1
    fi
  else
    rc=$?
    [[ "$rc" == 1 ]] && exit 0
    msg_error "Rauthy release lookup failed (code ${rc})"
    exit 1
  fi

  # Full-state rollback is only valid for this managed single-node layout.
  python3 - /opt/rauthy_data/config.toml <<'PY'
import pathlib, sys, tomllib
c = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
if pathlib.Path('/root/.rauthy').is_symlink():
    sys.exit('Rauthy updater requires a regular installed-version marker.')
for root in ['/opt/rauthy', '/opt/rauthy_data']:
    directory = pathlib.Path(root)
    if directory.is_symlink() or any(p.is_symlink() for p in directory.rglob('*')):
        sys.exit('Rauthy updater requires regular directories and files.')
cluster = c.get('cluster', {})
server = c.get('server', {})
if not (c.get('database', {}).get('hiqlite', True)
        and cluster.get('node_id') == 1
        and not cluster.get('node_id_from')
        and cluster.get('nodes') == ['1 127.0.0.1:8100 127.0.0.1:8200']
        and cluster.get('data_dir') == '/opt/rauthy_data/data'
        and not c.get('secrets_file')
        and server.get('scheme') == 'http'
        and server.get('port_http') == 8080):
    sys.exit('Rauthy custom databases, secrets files, and HA layouts require manual upgrades.')
PY
  if [[ -n "$(systemctl show rauthy -p EnvironmentFiles --value)" ||
  -n "$(systemctl show rauthy -p DropInPaths --value)" ||
  "$(systemctl show rauthy -p Environment --value)" != 'MALLOC_CONF=abort_conf:true,narenas:8,tcache_max:4096,dirty_decay_ms:5000,muzzy_decay_ms:5000' ]] ||
    ! grep -qx 'ExecStart=/opt/rauthy/rauthy serve -c /opt/rauthy_data/config.toml' /etc/systemd/system/rauthy.service ||
    ! grep -qx 'WorkingDirectory=/opt/rauthy_data' /etc/systemd/system/rauthy.service; then
    msg_error "Rauthy service overrides require a separate backup and upgrade procedure"
    exit 1
  fi
  if findmnt -rn -o TARGET | grep -Eq '^/opt/rauthy(_data)?(/|$)'; then
    msg_error "Rauthy bind-mounted installations require a separate backup procedure"
    exit 1
  fi

  CLEAN_INSTALL=1 fetch_and_deploy_gh_release "rauthy-build" "sebadob/rauthy" "tarball" "$CHECK_UPDATE_RELEASE" "/opt/rauthy-build"
  [[ "$(cat /root/.rauthy-build)" == "${CHECK_UPDATE_RELEASE#v}" ]] || exit 1
  cd /opt/rauthy-build
  RUST_TOOLCHAIN="$(sed -n 's/^rust-version = "\([^"]*\)"/\1/p' Cargo.toml)" setup_rust
  msg_info "Building Rauthy update from release source"
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
  $STD target/release/rauthy validate-config -p /opt/rauthy_data/config.toml
  msg_ok "Built and validated Rauthy update"

  umask 077
  backup="$(mktemp -d /opt/rauthy.backup-XXXXXX)"
  export BACKUP_DIR="$backup"
  # Keep recovery inside this subshell so the engine retains its own traps.
  trap '
    rc=$?
    trap - EXIT
    if ((committed == 0 && stopped == 1)); then
      if ((saved == 1)); then
        msg_warn "Rauthy update failed; restoring the previous binary, configuration, and database"
        systemctl stop rauthy || { msg_error "Rauthy recovery could not stop the service. Backup: $backup"; exit 1; }
        restore_backup
      fi
      systemctl start rauthy || { msg_error "Rauthy recovery could not start the previous service. Backup: $backup"; exit 1; }
      for ((attempt = 0; attempt < 60; attempt++)); do
        if systemctl is-active --quiet rauthy && curl -fsS --connect-timeout 1 --max-time 2 \
          -H "X-Forwarded-For: 127.0.0.1" -H "X-Forwarded-Proto: https" \
          http://127.0.0.1:8080/auth/v1/health >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done
      if ((attempt == 60)); then
        msg_error "Previous Rauthy state restored, but service is unhealthy. Inspect journalctl -u rauthy"
      else
        msg_warn "Restored healthy previous Rauthy installation"
      fi
      rc=1
    fi
    exit "$rc"
  ' EXIT
  msg_info "Stopping Rauthy for an offline backup"
  stopped=1
  systemctl stop rauthy
  msg_ok "Stopped Rauthy for an offline backup"
  create_backup /opt/rauthy /opt/rauthy_data /root/.rauthy
  saved=1

  msg_info "Installing Rauthy update"
  install -m 0755 target/release/rauthy /opt/rauthy/rauthy.new
  mv /opt/rauthy/rauthy.new /opt/rauthy/rauthy
  systemctl start rauthy
  for ((attempt = 0; attempt < 60; attempt++)); do
    if systemctl is-active --quiet rauthy && curl -fsS --connect-timeout 1 --max-time 2 \
      -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' \
      http://127.0.0.1:8080/auth/v1/health >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if ((attempt == 60)); then
    msg_error "Rauthy update did not become healthy"
    exit 1
  fi
  mv /root/.rauthy-build /root/.rauthy
  chmod 0600 /root/.rauthy
  committed=1
  msg_ok "Updated Rauthy. Previous binary and complete data backup: $backup"
  cd /root
  rm -rf /opt/rauthy-build
  exit 0
)

# lxc-attach gives the installer no terminal; collect required values on the host.
if command -v pveversion >/dev/null 2>&1; then
  var_rauthy_hostname=$(prompt_input_required "Rauthy public HTTPS hostname (e.g. auth.example.com)" "" 120 "var_rauthy_hostname")
  var_rauthy_proxy_cidrs=$(prompt_input_required "Rauthy reverse proxy IP/CIDR (comma-separated)" "" 120 "var_rauthy_proxy_cidrs")
  if [[ -z "$var_rauthy_hostname" || -z "$var_rauthy_proxy_cidrs" ]]; then
    msg_error "Rauthy requires var_rauthy_hostname and var_rauthy_proxy_cidrs before creating the LXC"
    exit 1
  fi
fi

start
build_container
description

msg_ok "Completed successfully!"
echo -e "${INFO}${YW}Configure your HTTPS reverse proxy to forward to http://${IP}:8080.${CL}"
echo -e "${INFO}${YW}Rauthy account URL after proxy setup: https://${var_rauthy_hostname}/auth/v1/account${CL}"
echo -e "${INFO}${YW}Rauthy credentials and configuration: /opt/rauthy_data/config.toml inside the LXC.${CL}"
