#!/usr/bin/env bash
# Run ONLY inside an empty disposable Debian 13 Docker container, as root.
# Service control is simulated because this container has no systemd PID 1.
set -euo pipefail
[[ -f /.dockerenv && "$(id -u)" == 0 ]] || {
  echo "Disposable Docker container required" >&2
  exit 1
}
[[ ! -e /opt/rauthy && ! -e /etc/rauthy ]] || {
  echo "Clean test container required" >&2
  exit 1
}
project="${1:-/workspace}"
mkdir -p /tmp/rauthy-test-bin
cat <<'EOF' >/tmp/rauthy-test-bin/systemctl
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  daemon-reload) exit 0 ;;
  enable|start)
    cd /var/lib/rauthy
    runuser -u rauthy -- /opt/rauthy/rauthy serve -c /etc/rauthy/config.toml >>/tmp/rauthy-test-service.log 2>&1 &
    echo "$!" >/tmp/rauthy-test-service.pid
    ;;
  stop)
    pkill -TERM -u rauthy -x rauthy || true
    for ((i=0; i<90; i++)); do
      pgrep -u rauthy -x rauthy >/dev/null || exit 0
      sleep 1
    done
    exit 1
    ;;
  is-active) pgrep -u rauthy -x rauthy >/dev/null ;;
  show)
    [[ "$*" == *EnvironmentFiles* ]] && exit 0
    [[ "$*" == *DropInPaths* ]] && exit 0
    echo 'MALLOC_CONF=abort_conf:true,narenas:8,tcache_max:4096,dirty_decay_ms:5000,muzzy_decay_ms:5000'
    ;;
  *) echo "Unexpected systemctl operation" >&2; exit 1 ;;
esac
EOF
chmod +x /tmp/rauthy-test-bin/systemctl
export PATH="/tmp/rauthy-test-bin:$PATH"
export FUNCTIONS_FILE_PATH='
set -eE
STD=""
TAB3=""
color() { :; }
verb_ip6() { :; }
catch_errors() { :; }
setting_up_container() { :; }
network_check() { :; }
update_os() { :; }
msg_info() { echo "$*"; }
msg_ok() { echo "$*"; }
msg_warn() { echo "$*"; }
msg_error() { echo "$*" >&2; }
motd_ssh() { :; }
customize() { :; }
cleanup_lxc() { :; }
'
export var_rauthy_hostname=auth.example.com var_rauthy_proxy_cidrs=192.0.2.10/32 var_rauthy_version=0.36.2
bash "${project}/install/rauthy-install.sh"
cp /etc/rauthy/config.toml /tmp/rauthy-test-config-before.toml
# Load production update functions without calling the Proxmox framework.
sed -n '/^rauthy_stage_binary()/,/^function update_script()/p' "${project}/ct/rauthy.sh" | sed '$d' >/tmp/rauthy-test-update-functions.sh
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
source /tmp/rauthy-test-update-functions.sh
rauthy_apply_update 0.37.0
cmp /etc/rauthy/config.toml /tmp/rauthy-test-config-before.toml
[[ "$(cat /root/.rauthy)" == 0.37.0 ]]
rauthy_wait_healthy
curl -fsS -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' \
  http://127.0.0.1:8080/auth/v1/.well-known/openid-configuration >/tmp/rauthy-test-discovery.json
python3 - <<'PY'
import json, os, pathlib, tomllib
c = tomllib.loads(pathlib.Path('/etc/rauthy/config.toml').read_text())
assert 'password_plain' not in c['bootstrap']
assert os.stat('/root/rauthy.creds').st_mode & 0o777 == 0o600
discovery = json.loads(pathlib.Path('/tmp/rauthy-test-discovery.json').read_text())
assert discovery['issuer'].startswith('https://auth.example.com/auth/v1')
assert list(pathlib.Path('/var/backups/rauthy').glob('*/snapshot.tar'))
print('Real native install, 0.36.2 -> 0.37.0 migration, readiness, and HTTPS issuer passed.')
PY
