from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "xovi" / "appload" / "nyt-crossword"
RUN = ROOT / "scripts" / "nytcrossword-run.sh"


def run_powershell_script(script):
    if os.name == "nt":
        command = ["powershell", "-ExecutionPolicy", "Bypass", "-File", str(script)]
        return subprocess.run(
            command, check=True, cwd=ROOT, capture_output=True, text=True)
    command = ["powershell.exe", "-ExecutionPolicy", "Bypass", "-File",
               subprocess.check_output(["wslpath", "-w", str(script)],
                                       text=True).strip()]
    return subprocess.run(command, check=True, capture_output=True, text=True)


def run_backend(*arguments, config=None):
    env = dict(os.environ)
    if config is not None:
        env["NYTCROSSWORD_CONFIG"] = str(config)
    result = subprocess.run(["sh", str(RUN), *arguments],
                            capture_output=True, text=True, env=env)
    return result.returncode, json.loads(result.stdout)


@unittest.skipIf(os.name == "nt", "the shell backend tests need a POSIX sh (run under WSL)")
class ShellBackendTests(unittest.TestCase):
    def test_version_reports_json(self):
        code, payload = run_backend("version")
        self.assertEqual(code, 0)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["version"], "0.1.0")

    def test_status_is_unconfigured_without_cookie(self):
        with tempfile.TemporaryDirectory() as directory:
            code, payload = run_backend(
                "status", config=Path(directory) / "missing.env")
        self.assertEqual(code, 0)
        self.assertEqual(payload["configured"], False)

    def test_status_is_configured_without_leaking_cookie(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.env"
            config.write_text("# comment\nNYT_S_COOKIE = secret-value\r\n")
            code, payload = run_backend("status", config=config)
        self.assertEqual(code, 0)
        self.assertEqual(payload["configured"], True)
        self.assertNotIn("secret-value", json.dumps(payload))

    def test_unknown_command_fails_with_json(self):
        code, payload = run_backend("bogus")
        self.assertEqual(code, 2)
        self.assertEqual(payload, {
            "ok": False, "error": "unknown_command",
            "message": "Unknown command: bogus"})


class AppLoadAppTests(unittest.TestCase):
    def test_manifest_and_qml_follow_appload_contract(self):
        manifest = json.loads((APP / "manifest.json").read_text())
        qml = (APP / "ui" / "NytCrossword.qml").read_text()
        qrc = (APP / "application.qrc").read_text()
        self.assertEqual(manifest["id"], "nyt-crossword")
        self.assertIs(manifest["loadsBackend"], False)
        self.assertEqual(manifest["entry"], "/ui/NytCrossword.qml")
        self.assertIn("<file>ui/NytCrossword.qml</file>", qrc)
        self.assertIn("signal close", qml)
        self.assertIn("function unloading()", qml)
        self.assertIn("import net.asivery.CommandExecutor 1.0", qml)
        self.assertIn("AsyncCommandExecutor", qml)
        self.assertIn("/home/root/xovi-nytcrossword/scripts/nytcrossword-run.sh", qml)
        self.assertIn('run(["status"], "status")', qml)
        self.assertNotIn("NYT-S=", qml)

    def test_appload_package_contains_only_installable_app_files(self):
        run_powershell_script(ROOT / "scripts" / "package-xovi-appload.ps1")
        package = ROOT / "dist" / "xovi-nytcrossword-appload-app.zip"
        with zipfile.ZipFile(package) as archive:
            self.assertEqual(set(archive.namelist()), {
                "nyt-crossword/manifest.json",
                "nyt-crossword/icon.png",
                "nyt-crossword/resources.rcc",
            })
            self.assertGreater(len(archive.read("nyt-crossword/resources.rcc")), 1000)

    def test_runtime_package_excludes_config_and_state(self):
        run_powershell_script(ROOT / "scripts" / "package-tablet.ps1")
        package = ROOT / "dist" / "xovi-nytcrossword-runtime.zip"
        with zipfile.ZipFile(package) as archive:
            self.assertEqual(set(archive.namelist()), {
                "scripts/nytcrossword-run.sh",
                "scripts/nytcrossword-shell.sh",
                "config.example.env",
            })
            for name in ("scripts/nytcrossword-run.sh", "scripts/nytcrossword-shell.sh"):
                info = archive.getinfo(name)
                self.assertEqual(info.external_attr >> 16, 0o100755)
                self.assertNotIn(b"\r\n", archive.read(name))

    def test_update_script_deploys_runtime_and_app(self):
        content = (ROOT / "scripts" / "update-remarkable.ps1").read_text()
        self.assertIn("package-tablet.ps1", content)
        self.assertIn("package-xovi-appload.ps1", content)
        self.assertIn('cp -R "$stage/appload/nyt-crossword" "$appload/nyt-crossword"', content)
        self.assertNotIn("rm -rf \"$runtime", content)


if __name__ == "__main__":
    unittest.main()
