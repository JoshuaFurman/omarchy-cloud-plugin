#!/usr/bin/env python3

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
MOUNT = REPO / "bin" / "omarchy-cloud-mount"
BOOKMARK = REPO / "bin" / "omarchy-cloud-bookmark"
UNINSTALL = REPO / "bin" / "omarchy-cloud-uninstall"


class ShellHelperTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.home = self.root / "home"
        self.config = self.root / "config"
        self.fake_bin = self.root / "fake-bin"
        self.home.mkdir()
        self.config.mkdir()
        self.fake_bin.mkdir()
        self.env = os.environ.copy()
        self.env.update(
            {
                "HOME": str(self.home),
                "XDG_CONFIG_HOME": str(self.config),
                "XDG_CACHE_HOME": str(self.root / "cache"),
                "PATH": f"{self.fake_bin}{os.pathsep}{self.env['PATH']}",
                "TERM": "dumb",
            }
        )

    def tearDown(self):
        self.tempdir.cleanup()

    def executable(self, name, source):
        path = self.fake_bin / name
        path.write_text(source, encoding="utf-8")
        path.chmod(0o755)
        return path

    def managed_remote(self, name="gdrive"):
        path = self.config / "omarchy-cloud" / "remotes" / f"{name}.conf"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("label='Test remote'\nextra_flags=''\n", encoding="utf-8")
        return path

    def run_script(self, script, *args, env=None):
        return subprocess.run(
            [str(script), *args],
            check=False,
            capture_output=True,
            text=True,
            env=env or self.env,
            timeout=10,
        )

    def test_forget_refuses_an_unmanaged_rclone_remote(self):
        rclone_log = self.root / "rclone.log"
        env = self.env | {"TEST_LOG": str(rclone_log)}
        self.executable(
            "rclone",
            "#!/bin/bash\nprintf '%s\\n' \"$*\" >>\"$TEST_LOG\"\n",
        )

        result = self.run_script(MOUNT, "forget", "unrelated", "--yes", env=env)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ownership record", result.stderr)
        self.assertFalse(rclone_log.exists(), "rclone must not be called")

    def test_failed_systemd_stop_keeps_credentials_and_metadata(self):
        metadata = self.managed_remote()
        unit = self.config / "systemd" / "user" / "omarchy-cloud-mount@.service"
        unit.parent.mkdir(parents=True)
        unit.write_text(
            "# Managed by furmware.cloud; do not edit.\n[Service]\n",
            encoding="utf-8",
        )
        rclone_log = self.root / "rclone.log"
        env = self.env | {"TEST_LOG": str(rclone_log)}
        self.executable(
            "systemctl",
            """#!/bin/bash
case "$2" in
  show-environment) exit 0 ;;
  disable) exit 1 ;;
  show)
    printf 'ActiveState=active\\nUnitFileState=enabled\\n'
    exit 0
    ;;
esac
exit 1
""",
        )
        self.executable(
            "rclone",
            "#!/bin/bash\nprintf '%s\\n' \"$*\" >>\"$TEST_LOG\"\n",
        )

        result = self.run_script(MOUNT, "forget", "gdrive", "--yes", env=env)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not verify", result.stderr)
        self.assertTrue(metadata.exists())
        self.assertFalse(rclone_log.exists(), "credentials must not be touched")

    def test_uninstall_keeps_unit_and_metadata_when_stop_fails(self):
        metadata = self.managed_remote()
        unit = self.config / "systemd" / "user" / "omarchy-cloud-mount@.service"
        unit.parent.mkdir(parents=True)
        unit.write_text(
            "# Managed by furmware.cloud; do not edit.\n[Service]\n",
            encoding="utf-8",
        )
        self.executable(
            "systemctl",
            """#!/bin/bash
case "$2" in
  show-environment) exit 0 ;;
  list-units|list-unit-files)
    printf 'omarchy-cloud-mount@gdrive.service enabled\\n'
    exit 0
    ;;
  disable) exit 1 ;;
  show)
    printf 'ActiveState=active\\nUnitFileState=enabled\\n'
    exit 0
    ;;
esac
exit 1
""",
        )

        result = self.run_script(UNINSTALL)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not verify", result.stderr)
        self.assertTrue(metadata.exists())
        self.assertTrue(unit.exists())

    def test_mount_uses_the_config_path_reported_by_rclone(self):
        self.managed_remote()
        rclone_log = self.root / "rclone.log"
        custom_config = self.root / "custom-rclone.conf"
        env = self.env | {
            "TEST_LOG": str(rclone_log),
            "TEST_RCLONE_CONFIG": str(custom_config),
        }
        self.executable(
            "rclone",
            """#!/bin/bash
if [[ "$1" == "config" && "$2" == "file" ]]; then
  printf 'Configuration file is stored at:\\n%s\\n' "$TEST_RCLONE_CONFIG"
  exit 0
fi
printf '%s\\n' "$@" >"$TEST_LOG"
""",
        )
        self.executable("mountpoint", "#!/bin/bash\nexit 1\n")
        self.executable("fusermount3", "#!/bin/bash\nexit 0\n")

        result = self.run_script(MOUNT, "run", "gdrive", env=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = rclone_log.read_text(encoding="utf-8").splitlines()
        config_index = arguments.index("--config")
        self.assertEqual(arguments[config_index + 1], str(custom_config))
        self.assertNotIn(str(self.home / ".config/rclone/rclone.conf"), arguments)

    def test_bookmark_percent_encodes_utf8_bytes(self):
        result = self.run_script(BOOKMARK, "add", "/tmp/Café Cloud", "Café")

        self.assertEqual(result.returncode, 0, result.stderr)
        bookmarks = self.config / "gtk-3.0" / "bookmarks"
        self.assertEqual(
            bookmarks.read_text(encoding="utf-8"),
            "file:///tmp/Caf%C3%A9%20Cloud Café\n",
        )

    def test_custom_backend_runs_the_full_rclone_question_flow(self):
        wizard_bin = self.root / "wizard-bin"
        wizard_bin.mkdir()
        for name in (
            "omarchy-cloud-connect",
            "omarchy-cloud-ui.sh",
            "omarchy-cloud-rclone-config.sh",
        ):
            shutil.copy2(REPO / "bin" / name, wizard_bin / name)

        event_log = self.root / "events.log"
        env = self.env | {"TEST_LOG": str(event_log)}
        self.executable(
            "gum",
            """#!/bin/bash
case "$1" in
  choose) printf '%s\\n' 'Something else (guided by rclone)' ;;
  input)
    if [[ "$*" == *"backend name"* ]]; then printf '%s\\n' 'sftp'
    else printf '%s\\n' 'sftp-test'
    fi
    ;;
  confirm) exit 0 ;;
  style|spin) exit 0 ;;
esac
""",
        )
        self.executable(
            "rclone",
            """#!/bin/bash
if [[ "$1" == "listremotes" ]]; then exit 0; fi
if [[ "$1" == "config" && "$2" == "create" ]]; then
  printf 'rclone %s\\n' "$*" >>"$TEST_LOG"
  exit 0
fi
if [[ "$1" == "lsd" ]]; then exit 0; fi
exit 1
""",
        )
        (wizard_bin / "omarchy-cloud-mount").write_text(
            "#!/bin/bash\nprintf 'mount %s\\n' \"$*\" >>\"$TEST_LOG\"\n",
            encoding="utf-8",
        )
        (wizard_bin / "omarchy-cloud-mount").chmod(0o755)
        (wizard_bin / "omarchy-cloud-bookmark").write_text(
            "#!/bin/bash\nexit 0\n", encoding="utf-8"
        )
        (wizard_bin / "omarchy-cloud-bookmark").chmod(0o755)
        self.executable("mountpoint", "#!/bin/bash\nexit 0\n")

        result = self.run_script(wizard_bin / "omarchy-cloud-connect", env=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        events = event_log.read_text(encoding="utf-8")
        self.assertIn(
            "rclone config create sftp-test sftp --all --no-output", events
        )
        self.assertTrue(
            (self.config / "omarchy-cloud/remotes/sftp-test.conf").is_file()
        )

    def test_google_credential_migration_stops_then_reconnects(self):
        self.managed_remote()
        wizard_bin = self.root / "settings-bin"
        wizard_bin.mkdir()
        for name in ("omarchy-cloud-configure", "omarchy-cloud-ui.sh"):
            shutil.copy2(REPO / "bin" / name, wizard_bin / name)

        event_log = self.root / "events.log"
        choose_count = self.root / "choose-count"
        env = self.env | {
            "TEST_LOG": str(event_log),
            "CHOOSE_COUNT": str(choose_count),
        }
        self.executable(
            "gum",
            """#!/bin/bash
case "$1" in
  choose)
    count=0
    [[ -f "$CHOOSE_COUNT" ]] && count="$(<"$CHOOSE_COUNT")"
    count=$((count + 1))
    printf '%s' "$count" >"$CHOOSE_COUNT"
    if ((count == 1)); then printf '%s\\n' 'Google credentials — rclone shared'
    else printf '%s\\n' 'Close'
    fi
    ;;
  input)
    if [[ "$*" == *"client ID"* ]]; then printf '%s\\n' 'client-id'
    else printf '%s\\n' 'client-secret'
    fi
    ;;
  confirm) exit 0 ;;
  style|spin) exit 0 ;;
esac
""",
        )
        self.executable(
            "rclone",
            """#!/bin/bash
if [[ "$1" == "config" && "$2" == "show" ]]; then
  printf 'type = drive\\n'
  exit 0
fi
printf 'rclone %s\\n' "$*" >>"$TEST_LOG"
exit 0
""",
        )
        (wizard_bin / "omarchy-cloud-mount").write_text(
            """#!/bin/bash
printf 'mount %s\\n' "$*" >>"$TEST_LOG"
case "$1" in
  is-active|is-enabled) exit 0 ;;
esac
exit 0
""",
            encoding="utf-8",
        )
        (wizard_bin / "omarchy-cloud-mount").chmod(0o755)

        result = self.run_script(
            wizard_bin / "omarchy-cloud-configure", "gdrive", env=env
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        events = event_log.read_text(encoding="utf-8")
        self.assertIn("mount stop gdrive", events)
        self.assertIn(
            "rclone config update gdrive client_id=client-id "
            "client_secret=client-secret config_refresh_token=false --no-output",
            events,
        )
        self.assertIn("rclone config reconnect gdrive:", events)
        self.assertIn("mount start gdrive", events)

    def test_reconnect_stops_and_recovers_an_enabled_failed_unit(self):
        self.managed_remote()
        wizard_bin = self.root / "reconnect-bin"
        wizard_bin.mkdir()
        for name in (
            "omarchy-cloud-reconnect",
            "omarchy-cloud-ui.sh",
            "omarchy-cloud-rclone-config.sh",
        ):
            shutil.copy2(REPO / "bin" / name, wizard_bin / name)

        event_log = self.root / "events.log"
        env = self.env | {"TEST_LOG": str(event_log)}
        self.executable(
            "gum",
            "#!/bin/bash\ncase \"$1\" in style|spin) exit 0 ;; esac\n",
        )
        self.executable(
            "rclone",
            """#!/bin/bash
if [[ "$1" == "config" && "$2" == "show" ]]; then
  printf 'type = drive\\n'
  exit 0
fi
printf 'rclone %s\\n' "$*" >>"$TEST_LOG"
exit 0
""",
        )
        (wizard_bin / "omarchy-cloud-mount").write_text(
            """#!/bin/bash
printf 'mount %s\\n' "$*" >>"$TEST_LOG"
case "$1" in
  is-active) exit 1 ;;
  is-enabled) exit 0 ;;
esac
exit 0
""",
            encoding="utf-8",
        )
        (wizard_bin / "omarchy-cloud-mount").chmod(0o755)

        result = self.run_script(
            wizard_bin / "omarchy-cloud-reconnect", "gdrive", env=env
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        events = event_log.read_text(encoding="utf-8")
        self.assertIn("mount stop gdrive", events)
        self.assertIn("rclone config reconnect gdrive:", events)
        self.assertIn("mount start gdrive", events)


if __name__ == "__main__":
    unittest.main()
