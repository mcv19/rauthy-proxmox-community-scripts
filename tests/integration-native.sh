#!/usr/bin/env bash
# Run only in a clean disposable Debian 13 container. This simulates systemctl.
set -euo pipefail
[[ -f /.dockerenv && "$(id -u)" == 0 ]] || {
  echo "Disposable container required" >&2
  exit 1
}
[[ ! -e /opt/rauthy && ! -e /opt/rauthy_data ]] || {
  echo "Clean test container required" >&2
  exit 1
}
project="${1:-/workspace}"
core="${2:-/test-core}"
export TEST_CORE="$core" TEST_PROJECT="$project"
mkdir -p /tmp/rauthy-test-bin
cat <<'EOF' >/tmp/rauthy-test-bin/systemctl
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  enable|start)
    pgrep -x rauthy >/dev/null && exit 0
    cd /opt/rauthy_data
    /opt/rauthy/rauthy serve -c /opt/rauthy_data/config.toml >>/tmp/rauthy-test-service.log 2>&1 &
    ;;
  stop)
    pkill -TERM -x rauthy || true
    for ((i=0; i<90; i++)); do
      pgrep -x rauthy >/dev/null || exit 0
      sleep 1
    done
    exit 1
    ;;
  is-active) pgrep -x rauthy >/dev/null ;;
  show)
    [[ "$*" == *EnvironmentFiles* || "$*" == *DropInPaths* ]] && exit 0
    echo 'MALLOC_CONF=abort_conf:true,narenas:8,tcache_max:4096,dirty_decay_ms:5000,muzzy_decay_ms:5000'
    ;;
  *) echo "Unexpected systemctl operation: $*" >&2; exit 1 ;;
esac
EOF
chmod +x /tmp/rauthy-test-bin/systemctl
export PATH="/tmp/rauthy-test-bin:$PATH"
# shellcheck disable=SC2016 # Evaluated in the installer process.
export FUNCTIONS_FILE_PATH='
set -eE
source "$TEST_CORE/core/core.func"
_cs_source_func() { source "$TEST_CORE/$1"; }
source "$TEST_CORE/lib/tools.func"
STD=""; TAB3=""; INFO=""; YW=""; CL=""; NSAPP=rauthy
color() { :; }
verb_ip6() { :; }
catch_errors() { :; }
setting_up_container() { :; }
network_check() { :; }
update_os() { :; }
header_info() { :; }
check_container_storage() { :; }
check_container_resources() { :; }
msg_info() { echo "$*"; }
msg_ok() { echo "$*"; }
msg_warn() { echo "$*"; }
msg_error() { echo "$*" >&2; }
motd_ssh() { :; }
customize() { :; }
cleanup_lxc() { :; }
'
export var_rauthy_hostname=auth.example.com var_rauthy_proxy_cidrs=192.0.2.10/32
export var_rauthy_version="${TEST_INSTALL_VERSION:-v0.37.0}"
cp "$project/install/rauthy-install.sh" /tmp/rauthy-test-installer.sh
bash /tmp/rauthy-test-installer.sh >/tmp/rauthy-test-install.log 2>&1
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
export PATH="/root/.cargo/bin:$PATH"
# Load only the production updater, avoiding Proxmox-specific bootstrapping.
sed -n '/^function update_script()/,/^start$/p' "$project/ct/rauthy.sh" | sed '$d' >/tmp/rauthy-test-update.sh
source /tmp/rauthy-test-update.sh
cp /opt/rauthy_data/config.toml /tmp/rauthy-test-config-before.toml
var_rauthy_version="${TEST_UPDATE_VERSION:-$var_rauthy_version}" update_script >/tmp/rauthy-test-update.log 2>&1
cmp /opt/rauthy_data/config.toml /tmp/rauthy-test-config-before.toml
systemctl is-active --quiet rauthy
/opt/rauthy/rauthy --version
systemd-analyze verify /etc/systemd/system/rauthy.service
curl -fsS -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' \
  http://127.0.0.1:8080/auth/v1/.well-known/openid-configuration >/tmp/rauthy-test-discovery.json
python3 - <<'PY'
import base64, json, pathlib, stat, tomllib
p = pathlib.Path('/opt/rauthy_data/config.toml')
c = tomllib.loads(p.read_text())
assert stat.S_IMODE(p.stat().st_mode) == 0o600
assert len(c['bootstrap']['password_plain']) == 24
assert len(base64.b64decode(c['encryption']['keys'][0].split('/', 1)[1])) == 32
assert c['cluster']['data_dir'] == '/opt/rauthy_data/data'
assert c['webauthn']['rp_origin'] == 'https://auth.example.com:443'
assert not pathlib.Path('/root/rauthy.creds').exists()
discovery = json.loads(pathlib.Path('/tmp/rauthy-test-discovery.json').read_text())
assert discovery['issuer'].startswith('https://auth.example.com/auth/v1')
print('Native source install, update invocation, config permissions, health, HTTPS issuer, and static unit validation passed.')
PY
