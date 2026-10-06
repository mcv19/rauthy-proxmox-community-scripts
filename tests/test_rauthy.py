"""Isolated behavior tests. Nothing here starts systemd or writes outside a temp dir."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
INSTALL = (PROJECT / "install/rauthy-install.sh").read_text()
CT = (PROJECT / "ct/rauthy.sh").read_text()
CONFIG_FUNCTION = INSTALL.split("rauthy_write_config()", 1)[1].split("# Keep the image", 1)[0]
CONFIG_FUNCTION = "rauthy_write_config()" + CONFIG_FUNCTION
UPDATE_FUNCTIONS = "rauthy_stage_binary()" + CT.split("rauthy_stage_binary()", 1)[1].split("function update_script()", 1)[0]


class ConfigTests(unittest.TestCase):
    def render(self, hostname="auth.example.com", proxies="192.0.2.10", email="admin@example.com"):
        with tempfile.TemporaryDirectory() as folder:
            config, creds = Path(folder) / "config.toml", Path(folder) / "creds"
            result = subprocess.run(
                ["bash", "-c", CONFIG_FUNCTION + '\nrauthy_write_config "$@"', "test", hostname, proxies, email, str(config), str(creds)],
                capture_output=True, text=True,
            )
            return result, config.read_text() if config.exists() else "", creds.read_text() if creds.exists() else ""

    def test_valid_ipv4_ipv6_and_secure_bootstrap(self):
        import tomllib
        result, content, creds = self.render(proxies="192.0.2.10,2001:db8::2/128")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = tomllib.loads(content)
        self.assertEqual(config["server"]["trusted_proxies"], ["127.0.0.1/32", "::1/128", "192.0.2.10/32", "2001:db8::2/128"])
        self.assertTrue(config["server"]["proxy_mode"])
        self.assertFalse(config["user_registration"]["enable"])
        self.assertIn(config["bootstrap"]["password_plain"], creds)
        self.assertNotEqual(config["cluster"]["secret_raft"], config["cluster"]["secret_api"])
        self.assertGreaterEqual(len(config["bootstrap"]["password_plain"]), 32)
        self.assertEqual(config["webauthn"]["rp_origin"], "https://auth.example.com:443")

    def test_invalid_hostnames_do_not_create_credentials(self):
        for hostname in ["", "localhost", "127.0.0.1", "https://auth.example.com", "auth.example.com:443", "a.example/path", 'a.example"\n[dev]\ndev_mode=true', "a..example.com", "-auth.example.com"]:
            with self.subTest(hostname=hostname):
                result, config, creds = self.render(hostname=hostname)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((config, creds), ("", ""))

    def test_invalid_proxy_ranges_do_not_create_credentials(self):
        for proxy in ["", "0.0.0.0/0", "::/0", "999.0.0.1", "192.0.2.0/99", '192.0.2.1"\nfoo=1', "example.com"]:
            with self.subTest(proxy=proxy):
                result, config, creds = self.render(proxies=proxy)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((config, creds), ("", ""))

    def test_invalid_email(self):
        result, _, creds = self.render(email="admin@example.com\n[dev]")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(creds, "")

    def test_secrets_are_unique(self):
        _, first, _ = self.render()
        _, second, _ = self.render()
        self.assertNotEqual(first, second)


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path in ["etc/rauthy", "etc/systemd/system", "opt/rauthy", "var/lib/rauthy/data", "root", "run/lock"]:
            (self.root / path).mkdir(parents=True)
        self.version = self.root / "root/.rauthy"
        self.version.write_text("0.36.2\n")
        self.binary = self.root / "opt/rauthy/rauthy"
        self.binary.write_text("old-binary\n")
        self.digest = self.root / "opt/rauthy/image-digest"
        self.digest.write_text("old-digest\n")
        self.data = self.root / "var/lib/rauthy/data/db"
        self.data.write_text("original-database\n")
        self.config = self.root / "etc/rauthy/config.toml"
        self.config.write_text('''[cluster]
node_id = 1
nodes = ["1 127.0.0.1:8100 127.0.0.1:8200"]
data_dir = "/var/lib/rauthy/data"
secret_raft = "persistent-secret"
[server]
scheme = "http"
port_http = 8080
'''.replace('/var/lib/rauthy', str(self.root) + '/var/lib/rauthy'))
        service = "ExecStart=/opt/rauthy/rauthy serve -c /etc/rauthy/config.toml\nWorkingDirectory=/var/lib/rauthy\n"
        for path in ['/opt/rauthy', '/etc/rauthy', '/var/lib/rauthy']:
            service = service.replace(path, str(self.root) + path)
        (self.root / "etc/systemd/system/rauthy.service").write_text(service)
        self.original_config = self.config.read_bytes()

    def run_update(self, fail="", version="0.37.0"):
        # Rebase production paths, leaving TAR member names relative to the fake root.
        source = UPDATE_FUNCTIONS.replace("tar -C / ", 'tar -C "$TEST_ROOT" ')
        for path in ["/run/lock", "/var/backups/rauthy", "/var/lib/rauthy", "/etc/systemd/system/rauthy.service", "/etc/rauthy", "/opt/rauthy", "/root/.rauthy"]:
            source = source.replace(path, str(self.root) + path)
        source += r'''
msg_info() { echo "$*"; }
msg_ok() { echo "$*"; }
msg_warn() { echo "$*"; }
msg_error() { echo "$*" >&2; }
rauthy_stage_binary() {
  [[ "$FAIL" != download ]] || return 1
  cat >"$2/rauthy" <<'BINARY'
#!/usr/bin/env bash
[[ "$FAIL" != validation ]]
BINARY
  chmod 0755 "$2/rauthy"
  echo 'new-digest' >"$2/image-digest"
}
systemctl() {
  if [[ "$1" == show ]]; then
    [[ "$*" != *EnvironmentFiles* ]] || return 0
    [[ "$*" != *DropInPaths* ]] || return 0
    echo 'MALLOC_CONF=abort_conf:true,narenas:8,tcache_max:4096,dirty_decay_ms:5000,muzzy_decay_ms:5000'
    return 0
  fi
  echo "$1" >>"$TEST_ROOT/actions"
  if [[ "$1" == start ]] && ! grep -q old-binary "$TEST_ROOT/opt/rauthy/rauthy"; then
    echo 'migrated-database' >"$TEST_ROOT/var/lib/rauthy/data/db"
    echo 'new WAL' >"$TEST_ROOT/var/lib/rauthy/data/new-wal"
    [[ "$FAIL" != start ]] || return 1
  fi
  return 0
}
rauthy_wait_healthy() {
  [[ "$FAIL" != health ]] || grep -q old-binary "$TEST_ROOT/opt/rauthy/rauthy"
}
tar() {
  if [[ "$FAIL" == backup && "$*" == *-cpf* ]]; then return 1; fi
  command tar "$@"
}
rauthy_apply_update "$TARGET_VERSION"
'''
        return subprocess.run(["bash", "-c", source], env={**os.environ, "TEST_ROOT": str(self.root), "FAIL": fail, "TARGET_VERSION": version}, capture_output=True, text=True)

    def assert_original(self):
        self.assertEqual(self.binary.read_text(), "old-binary\n")
        self.assertEqual(self.data.read_text(), "original-database\n")
        self.assertEqual(self.version.read_text(), "0.36.2\n")
        self.assertEqual(self.digest.read_text(), "old-digest\n")
        self.assertEqual(self.config.read_bytes(), self.original_config)
        self.assertFalse((self.root / "var/lib/rauthy/data/new-wal").exists())
        self.assertEqual(list((self.root / "opt").glob("rauthy-stage.*")), [])

    def test_download_failure_never_stops_service(self):
        result = self.run_update("download")
        self.assertNotEqual(result.returncode, 0)
        self.assert_original()
        self.assertFalse((self.root / "actions").exists())

    def test_config_validation_failure_never_stops_service(self):
        result = self.run_update("validation")
        self.assertNotEqual(result.returncode, 0)
        self.assert_original()
        self.assertFalse((self.root / "actions").exists())

    def test_backup_failure_restarts_original(self):
        result = self.run_update("backup")
        self.assertNotEqual(result.returncode, 0)
        self.assert_original()
        self.assertEqual((self.root / "actions").read_text().splitlines(), ["stop", "start"])

    def test_start_failure_restores_database_and_binary(self):
        result = self.run_update("start")
        self.assertNotEqual(result.returncode, 0)
        self.assert_original()
        self.assertIn("Previous Rauthy installation restored", result.stdout)

    def test_health_failure_restores_full_database_and_binary(self):
        result = self.run_update("health")
        self.assertNotEqual(result.returncode, 0)
        self.assert_original()
        self.assertIn("Previous Rauthy installation restored", result.stdout)

    def test_success_retains_secrets_and_consistent_backup(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.version.read_text(), "0.37.0\n")
        self.assertEqual(self.digest.read_text(), "new-digest\n")
        self.assertEqual(self.config.read_bytes(), self.original_config)
        self.assertEqual(self.data.read_text(), "migrated-database\n")
        backup = next((self.root / "var/backups/rauthy").glob("*/snapshot.tar"))
        result = subprocess.run(["tar", "-xOf", str(backup), "var/lib/rauthy/data/db"], capture_output=True, text=True)
        self.assertEqual(result.stdout, "original-database\n")

    def test_same_version_has_no_service_or_data_changes(self):
        result = self.run_update(version="0.36.2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_original()
        self.assertFalse((self.root / "actions").exists())

    def test_downgrade_refused_before_service_changes(self):
        result = self.run_update(version="0.36.1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_original()
        self.assertFalse((self.root / "actions").exists())

    def test_ha_configuration_refused(self):
        self.config.write_text(self.config.read_text().replace("node_id = 1", "node_id = 2"))
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "actions").exists())

    def test_external_data_symlink_refused_before_stopping(self):
        outside = self.root / "external-db"
        outside.write_text("must not change")
        self.data.unlink()
        self.data.symlink_to(outside)
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(outside.read_text(), "must not change")
        self.assertFalse((self.root / "actions").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
