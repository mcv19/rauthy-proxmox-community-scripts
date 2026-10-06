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
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-4}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-1}"
export var_rauthy_hostname="${var_rauthy_hostname:-}"
export var_rauthy_proxy_cidrs="${var_rauthy_proxy_cidrs:-}"
export var_rauthy_admin_email="${var_rauthy_admin_email:-admin@localhost}"
export var_rauthy_version="${var_rauthy_version:-}"

header_info "$APP"
variables
color
catch_errors

# These helpers deliberately run without the build framework in isolated tests.
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

rauthy_check_managed_config() {
  python3 - /etc/rauthy/config.toml <<'PY'
import pathlib, sys, tomllib
c = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
for root in ['/etc/rauthy', '/opt/rauthy', '/var/lib/rauthy']:
    directory = pathlib.Path(root)
    if directory.is_symlink() or any(p.is_symlink() for p in directory.rglob('*')):
        sys.exit('Updater requires regular directories and files in the managed Rauthy layout.')
cluster = c.get('cluster', {})
server = c.get('server', {})
if not (c.get('database', {}).get('hiqlite', True)
        and cluster.get('node_id') == 1
        and not cluster.get('node_id_from')
        and cluster.get('nodes') == ['1 127.0.0.1:8100 127.0.0.1:8200']
        and cluster.get('data_dir') == '/var/lib/rauthy/data'
        and not c.get('secrets_file')
        and server.get('scheme') == 'http'
        and server.get('port_http') == 8080):
    sys.exit('Updater supports the supplied single-node Hiqlite layout on HTTP port 8080. '
             'Custom databases, secrets files, or HA layouts need their own backup/upgrade procedure.')
PY
  # Reject runtime overrides that could move the database outside the backup.
  [[ -z "$(systemctl show rauthy -p EnvironmentFiles --value)" ]] || return 1
  [[ -z "$(systemctl show rauthy -p DropInPaths --value)" ]] || return 1
  local environment
  environment="$(systemctl show rauthy -p Environment --value)"
  [[ "$environment" == 'MALLOC_CONF=abort_conf:true,narenas:8,tcache_max:4096,dirty_decay_ms:5000,muzzy_decay_ms:5000' ]] || return 1
  grep -qx 'ExecStart=/opt/rauthy/rauthy serve -c /etc/rauthy/config.toml' /etc/systemd/system/rauthy.service
  grep -qx 'WorkingDirectory=/var/lib/rauthy' /etc/systemd/system/rauthy.service
}

rauthy_apply_update() (
  # Own traps only in this subshell; the caller retains the community handlers.
  set -Eeuo pipefail
  trap - ERR
  umask 077
  local version="${1#v}" current stage="" backup="" stopped=0 saved=0 committed=0
  exec 9>/run/lock/rauthy-update.lock
  flock -n 9 || {
    msg_error "Another Rauthy update is running"
    exit 1
  }
  current="$(cat /root/.rauthy)"
  current="${current#v}"
  [[ "$version" =~ ^0\.[0-9]+\.[0-9]+$ && "$current" =~ ^0\.[0-9]+\.[0-9]+$ ]] || {
    msg_error "Unsupported release version"
    exit 1
  }
  [[ "$version" == "$current" ]] && {
    msg_ok "Rauthy is already at ${version}"
    exit 0
  }
  [[ "$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -n 1)" == "$version" ]] || {
    msg_error "Downgrades require a matching data backup"
    exit 1
  }
  rauthy_check_managed_config

  # shellcheck disable=SC2317 # Invoked by the EXIT trap.
  rauthy_update_cleanup() {
    local rc=$?
    trap - EXIT
    if ((committed == 0 && stopped == 1)); then
      if ((saved == 1)); then
        msg_warn "Update failed; restoring the previous binary, configuration, and database"
        if systemctl stop rauthy; then
          # Replace the full old state, including WALs; copying only SQLite is unsafe.
          if rm -rf /var/lib/rauthy /opt/rauthy /etc/rauthy && tar -C / -xpf "${backup}/snapshot.tar"; then
            if systemctl start rauthy && rauthy_wait_healthy; then
              msg_warn "Previous Rauthy installation restored. Backup: ${backup}"
            else
              msg_error "Restore completed, but the old service is unhealthy. Inspect journalctl -u rauthy"
            fi
          else
            msg_error "Restore failed. Keep ${backup} for manual recovery"
          fi
        else
          msg_error "Could not stop Rauthy for recovery. Keep ${backup} and restore manually"
        fi
      else
        systemctl start rauthy || msg_error "Could not restart the original service"
      fi
      rc=1
    fi
    [[ -z "$stage" ]] || rm -rf "$stage"
    exit "$rc"
  }
  trap rauthy_update_cleanup EXIT

  stage="$(mktemp -d /opt/rauthy-stage.XXXXXX)"
  msg_info "Downloading and validating Rauthy ${version}"
  rauthy_stage_binary "$version" "$stage"
  # Rauthy's validation loads keys but does not open or migrate the database.
  (cd /var/lib/rauthy && "${stage}/rauthy" validate-config -p /etc/rauthy/config.toml >/dev/null)
  msg_ok "Downloaded and validated Rauthy ${version}"

  install -d -m 0700 /var/backups/rauthy
  backup="$(mktemp -d "/var/backups/rauthy/$(date -u +%Y%m%dT%H%M%SZ)-${current}.XXXXXX")"
  msg_info "Stopping Rauthy and backing up its complete state"
  stopped=1
  systemctl stop rauthy
  tar -C / -cpf "${backup}/snapshot.tar" etc/rauthy opt/rauthy var/lib/rauthy root/.rauthy
  saved=1
  printf 'Previous version: %s\nTarget version: %s\n' "$current" "$version" >"${backup}/versions.txt"
  msg_ok "Backup saved to ${backup}"

  install -m 0755 "${stage}/rauthy" /opt/rauthy/rauthy.new
  mv /opt/rauthy/rauthy.new /opt/rauthy/rauthy
  systemctl start rauthy
  rauthy_wait_healthy || {
    msg_error "Updated Rauthy did not become healthy"
    exit 1
  }
  install -m 0600 "${stage}/image-digest" /opt/rauthy/image-digest
  printf '%s\n' "$version" >"${stage}/version"
  install -m 0600 "${stage}/version" /root/.rauthy
  committed=1
  msg_ok "Updated Rauthy to ${version}. Backup: ${backup}"
)

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -x /opt/rauthy/rauthy || ! -f /etc/rauthy/config.toml || ! -f /root/.rauthy ]]; then
    msg_error "No managed Rauthy installation found"
    exit 1
  fi
  ensure_dependencies skopeo umoci python3 curl util-linux
  local rc
  if check_for_gh_release "rauthy" "sebadob/rauthy" "${var_rauthy_version:+v${var_rauthy_version#v}}"; then
    rauthy_apply_update "$CHECK_UPDATE_RELEASE"
  else
    rc=$?
    [[ "$rc" == 1 ]] || {
      msg_error "Release lookup failed (code ${rc})"
      exit 1
    }
  fi
  exit 0
}

start
build_container
description

msg_ok "Completed successfully!"
echo -e "${INFO}${YW}Configure your HTTPS reverse proxy to forward to http://${IP}:8080.${CL}"
echo -e "${INFO}${YW}Use the public hostname entered during installation. Credentials: /root/rauthy.creds inside the LXC.${CL}"
