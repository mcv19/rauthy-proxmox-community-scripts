"""Isolated input and update-failure tests; writes only inside temporary directories."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tomllib
import unittest

PROJECT = Path(__file__).resolve().parents[1]
INSTALL = (PROJECT / "install/rauthy-install.sh").read_text()
CT = (PROJECT / "ct/rauthy.sh").read_text()
INPUTS = INSTALL.split('var_rauthy_hostname=$(prompt_input_required', 1)[1].split('# A separate source marker', 1)[0]
INPUTS = 'var_rauthy_hostname=$(prompt_input_required' + INPUTS
CONFIG = INSTALL.split('msg_info "Creating Rauthy configuration"', 1)[1].split('msg_info "Creating Rauthy service"', 1)[0]
UPDATE = 'function update_script()' + CT.split('function update_script()', 1)[1].split('\nstart\n', 1)[0]
HOST_PROMPTS = CT.split('# lxc-attach gives the installer no terminal;', 1)[1].split('\nstart\n', 1)[0]
MALLOC = 'MALLOC_CONF=abort_conf:true,narenas:8,tcache_max:4096,dirty_decay_ms:5000,muzzy_decay_ms:5000'


class ConfigTests(unittest.TestCase):
    def render(self, hostname="auth.example.com", proxies="192.0.2.10", email="admin@example.com"):
        with tempfile.TemporaryDirectory() as folder:
            data = Path(folder) / 'opt/rauthy_data'
            script = r'''
set -e
STD=""
msg_ok() { :; }
prompt_input_required() { echo "${!4}"; }
random_password() { openssl rand -hex 12; }
'''
            script += INPUTS + CONFIG.replace('/opt/rauthy_data', str(data)).replace('$STD /opt/rauthy/rauthy validate-config -p', ':')
            env = dict(os.environ, var_rauthy_hostname=hostname, var_rauthy_proxy_cidrs=proxies, var_rauthy_admin_email=email)
            result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True)
            config = data / 'config.toml'
            return result, tomllib.loads(config.read_text()) if config.exists() else None, (config.stat().st_mode & 0o777) if config.exists() else None

    def test_valid_config_and_permissions(self):
        result, config, mode = self.render(proxies='192.0.2.10,2001:db8::2/128')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(mode, 0o600)
        self.assertEqual(config['server']['trusted_proxies'], ['127.0.0.1/32', '::1/128', '192.0.2.10/32', '2001:db8::2/128'])
        self.assertTrue(config['server']['proxy_mode'])
        self.assertFalse(config['user_registration']['enable'])
        self.assertEqual(len(config['bootstrap']['password_plain']), 24)
        self.assertNotEqual(config['cluster']['secret_raft'], config['cluster']['secret_api'])
        self.assertEqual(len(base64.b64decode(config['encryption']['keys'][0].split('/', 1)[1])), 32)
        self.assertEqual(config['webauthn']['rp_origin'], 'https://auth.example.com:443')

    def test_hostname_injection_and_invalid_addresses(self):
        for hostname in ['', 'localhost', '127.0.0.1', 'https://auth.example.com', 'auth.example.com:443', 'a.example/path', 'a.example"\n[dev]\ndev_mode=true', 'a..example.com', '-auth.example.com']:
            with self.subTest(hostname=hostname):
                result, config, _ = self.render(hostname=hostname)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(config)

    def test_invalid_proxy_and_entire_internet(self):
        for proxy in ['', '0.0.0.0/0', '::/0', '999.0.0.1', '192.0.2.0/99', '192.0.2.1"\nfoo=1', 'example.com']:
            with self.subTest(proxy=proxy):
                result, config, _ = self.render(proxies=proxy)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(config)

    def test_email_injection(self):
        for email in ['admin@example.com\n[dev]', 'admin"@example.com', 'admin\\@example.com']:
            with self.subTest(email=email):
                result, config, _ = self.render(email=email)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(config)

    def test_unique_encryption_and_cluster_secrets(self):
        _, first, _ = self.render()
        _, second, _ = self.render()
        self.assertNotEqual(first['encryption']['keys'], second['encryption']['keys'])
        self.assertNotEqual(first['cluster']['secret_raft'], second['cluster']['secret_raft'])


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path in ['etc/systemd/system', 'opt/rauthy', 'opt/rauthy_data/data', 'root', 'run/lock']:
            (self.root / path).mkdir(parents=True)
        self.version = self.root / 'root/.rauthy'
        self.version.write_text('0.36.2\n')
        self.binary = self.root / 'opt/rauthy/rauthy'
        self.binary.write_text('old-binary\n')
        self.binary.chmod(0o755)
        self.data = self.root / 'opt/rauthy_data/data/db'
        self.data.write_text('original-database\n')
        self.wal = self.root / 'opt/rauthy_data/data/db-wal'
        self.wal.write_text('original-wal\n')
        self.config = self.root / 'opt/rauthy_data/config.toml'
        self.config.write_text('''[cluster]
node_id = 1
nodes = ["1 127.0.0.1:8100 127.0.0.1:8200"]
data_dir = "/opt/rauthy_data/data"
secret_raft = "persistent-secret"
[server]
scheme = "http"
port_http = 8080
'''.replace('/opt/rauthy_data', str(self.root) + '/opt/rauthy_data'))
        self.config.chmod(0o600)
        service = 'ExecStart=/opt/rauthy/rauthy serve -c /opt/rauthy_data/config.toml\nWorkingDirectory=/opt/rauthy_data\n'
        for path in ['/opt/rauthy_data', '/opt/rauthy']:
            # data path and binary path are disjoint after slash-aware matching.
            service = service.replace(path + '/', str(self.root) + path + '/') if path == '/opt/rauthy' else service.replace(path, str(self.root) + path)
        (self.root / 'etc/systemd/system/rauthy.service').write_text(service)
        self.original_config = self.config.read_bytes()

    def run_update(self, fail='', version='0.37.0', lookup=0):
        source = UPDATE
        source = re.sub(r'/(?:opt|root|run/lock|etc/systemd/system)(?=[/"\s])', lambda m: str(self.root) + m.group(), source)
        script = r'''
STD=""
msg_info() { echo "$*"; }
msg_ok() { echo "$*"; }
msg_warn() { echo "$*"; }
msg_error() { echo "$*" >&2; }
header_info() { :; }
check_container_storage() { :; }
check_container_resources() { :; }
ensure_dependencies() { :; }
flock() { [[ "$FAIL" != lock ]]; }
check_for_gh_release() { CHECK_UPDATE_RELEASE="v$VERSION"; return "$LOOKUP"; }
version_gt() { test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }
fetch_and_deploy_gh_release() {
  [[ "$FAIL" != download ]] || return 1
  mkdir -p "$5/target/release" "$5/assets/static_html" "$5/src/bin/src"
  cat > "$5/Cargo.toml" <<'EOF'
rust-version = "1.95.0"
EOF
  touch "$5/src/bin/src/fido_mds_prep.rs"
  marker="$VERSION"
  [[ "$FAIL" != release-marker ]] || marker=0.35.0
  echo "$marker" > "$TEST_ROOT/root/.rauthy-build"
}
setup_rust() { [[ "$FAIL" != toolchain ]]; }
get_parallel_jobs() { echo 1; }
tar() { :; }
cargo() {
  [[ "$FAIL" != build ]] || return 1
  cat > target/release/rauthy <<'EOF'
#!/usr/bin/env bash
[[ "$1" != --version ]] || {
  [[ "$FAIL" != binary-version ]] || { echo 'rauthy 0.35.0'; exit 0; }
  echo "rauthy $VERSION"; exit 0;
}
[[ "$FAIL" != validation ]]
EOF
  chmod 0755 target/release/rauthy
}
findmnt() { [[ "$FAIL" != mount ]] || echo "$TEST_ROOT/opt/rauthy_data/data"; }
systemctl() {
  case "$1" in
    show)
      [[ "$*" != *EnvironmentFiles* && "$*" != *DropInPaths* ]] || { [[ "$FAIL" != override ]] || echo custom.conf; return 0; }
      echo 'MALLOC_CONF=abort_conf:true,narenas:8,tcache_max:4096,dirty_decay_ms:5000,muzzy_decay_ms:5000'
      ;;
    stop) echo stop >> "$TEST_ROOT/service-events" ;;
    start)
      echo start >> "$TEST_ROOT/service-events"
      if [[ "$(cat "$TEST_ROOT/opt/rauthy/rauthy")" != old-binary ]]; then
        echo migrated-database > "$TEST_ROOT/opt/rauthy_data/data/db"
        echo new-wal > "$TEST_ROOT/opt/rauthy_data/data/new-wal"
        [[ "$FAIL" != start ]] || return 1
      fi
      ;;
    is-active) return 0 ;;
  esac
}
curl() { [[ "$FAIL" != health || "$(cat "$TEST_ROOT/opt/rauthy/rauthy")" == old-binary ]]; }
sleep() { :; }
# Backup/service/download boundaries are simulated; the transaction is production code.
create_backup() {
  [[ "$FAIL" != backup ]] || exit 1
  mkdir -p "$BACKUP_DIR/files"
  for path in "$@"; do
    relative="${path#"$TEST_ROOT"}"
    mkdir -p "$BACKUP_DIR/files/$(dirname "$relative")"
    cp -a "$path" "$BACKUP_DIR/files$relative"
    echo "$path" >> "$BACKUP_DIR/.manifest"
  done
}
restore_backup() {
  while IFS= read -r path; do
    relative="${path#"$TEST_ROOT"}"
    rm -rf "$path"
    cp -a "$BACKUP_DIR/files$relative" "$path"
  done < "$BACKUP_DIR/.manifest"
  rm -rf "$BACKUP_DIR"
}
'''
        script += source + '\nupdate_script\n'
        env = dict(os.environ, FAIL=fail, VERSION=version, LOOKUP=str(lookup), TEST_ROOT=str(self.root))
        return subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True)

    def assert_original_state(self):
        self.assertEqual(self.version.read_text(), '0.36.2\n')
        self.assertEqual(self.binary.read_text(), 'old-binary\n')
        self.assertEqual(self.data.read_text(), 'original-database\n')
        self.assertEqual(self.wal.read_text(), 'original-wal\n')
        self.assertEqual(self.config.read_bytes(), self.original_config)
        self.assertFalse((self.wal.parent / 'new-wal').exists())

    def test_failures_before_stopping_preserve_old_installation(self):
        for fail in ['lock', 'download', 'release-marker', 'toolchain', 'build', 'binary-version', 'validation']:
            with self.subTest(fail=fail):
                result = self.run_update(fail)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assert_original_state()
                self.assertFalse((self.root / 'service-events').exists())

    def test_failed_backup_restarts_old_service(self):
        result = self.run_update('backup')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_original_state()
        self.assertEqual((self.root / 'service-events').read_text(), 'stop\nstart\n')

    def test_failed_start_restores_database_binary_and_marker(self):
        result = self.run_update('start')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_original_state()
        self.assertEqual((self.root / 'service-events').read_text(), 'stop\nstart\nstop\nstart\n')

    def test_failed_health_restores_full_state_including_wal(self):
        result = self.run_update('health')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_original_state()

    def test_success_commits_after_readiness_with_offline_backup(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.version.read_text(), '0.37.0\n')
        self.assertEqual(self.data.read_text(), 'migrated-database\n')
        self.assertEqual(self.config.read_bytes(), self.original_config)
        backups = list((self.root / 'opt').glob('rauthy.backup-*'))
        self.assertEqual(len(backups), 1)
        backup = backups[0]
        self.assertEqual(backup.stat().st_mode & 0o777, 0o700)
        self.assertEqual((backup / 'files/opt/rauthy_data/data/db').read_text(), 'original-database\n')
        self.assertEqual((backup / 'files/root/.rauthy').read_text(), '0.36.2\n')
        self.assertEqual((backup / 'files/opt/rauthy_data/config.toml').stat().st_mode & 0o777, 0o600)

    def test_no_update_and_failed_lookup(self):
        for lookup in [1, 22]:
            with self.subTest(lookup=lookup):
                result = self.run_update(lookup=lookup)
                self.assertEqual(result.returncode == 0, lookup == 1, result.stdout + result.stderr)
                self.assert_original_state()
                self.assertFalse((self.root / 'service-events').exists())

    def test_downgrade_rejected(self):
        result = self.run_update(version='0.35.0')
        self.assertNotEqual(result.returncode, 0)
        self.assert_original_state()
        self.assertFalse((self.root / 'service-events').exists())

    def test_custom_layout_and_mounts_rejected_before_mutation(self):
        for fail in ['mount', 'override']:
            with self.subTest(fail=fail):
                result = self.run_update(fail)
                self.assertNotEqual(result.returncode, 0)
                self.assert_original_state()
                self.assertFalse((self.root / 'service-events').exists())
        self.config.write_text(self.config.read_text().replace('node_id = 1', 'node_id = 2'))
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'service-events').exists())

    def test_symlink_state_rejected(self):
        external = self.root / 'external-db'
        external.write_text('external-state\n')
        self.data.unlink()
        self.data.symlink_to(external)
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(external.read_text(), 'external-state\n')
        self.assertFalse((self.root / 'service-events').exists())


class ConventionTests(unittest.TestCase):
    def host_prompt(self, hostname='', proxies=''):
        script = r'''
export var_rauthy_hostname var_rauthy_proxy_cidrs
pveversion() { :; }
msg_error() { echo "$*" >&2; }
prompt_input_required() { echo "${!4}"; }
'''
        script += HOST_PROMPTS.split('\n', 1)[1] + '\nprintenv var_rauthy_hostname\nprintenv var_rauthy_proxy_cidrs\n'
        env = dict(os.environ, var_rauthy_hostname=hostname, var_rauthy_proxy_cidrs=proxies)
        return subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True)

    def test_host_missing_input_aborts_before_container_creation(self):
        result = self.host_prompt()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('before creating the LXC', result.stderr)

    def test_host_provided_values_stay_exported_for_installer(self):
        result = self.host_prompt('auth.example.com', '192.0.2.10/32')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'auth.example.com\n192.0.2.10/32\n')

    def test_required_helpers_and_no_custom_functions(self):
        self.assertEqual(re.findall(r'^(?:function )?(\w+)\(\)', CT, re.M), ['update_script'])
        self.assertEqual(re.findall(r'^(?:function )?(\w+)\(\)', INSTALL, re.M), [])
        for source in [CT, INSTALL]:
            self.assertIn('fetch_and_deploy_gh_release "rauthy-build" "sebadob/rauthy" "tarball"', source)
            self.assertNotRegex(source, r'\b(?:skopeo|umoci|useradd|runuser|apt-get|daemon-reload)\b')
            self.assertNotIn('/root/rauthy.creds', source)
        self.assertIn('check_for_gh_release "rauthy"', CT)
        self.assertIn('create_backup /opt/rauthy /opt/rauthy_data /root/.rauthy', CT)
        self.assertIn('restore_backup', CT)
        self.assertIn('random_password', INSTALL)
        metadata = json.loads((PROJECT / 'json/rauthy.json').read_text())
        self.assertEqual(metadata['install_methods'][0]['resources']['ram'], 8192)
        self.assertEqual(metadata['install_methods'][0]['config_path'], '/opt/rauthy_data/config.toml')
        self.assertNotIn('architectures', metadata)


if __name__ == '__main__':
    unittest.main()
