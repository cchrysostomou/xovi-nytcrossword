from pathlib import Path
import json
import os
import re
import subprocess
import tempfile
import threading
import time
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


def run_backend(*arguments, config=None, extra_env=None):
    env = dict(os.environ)
    env["NYTCROSSWORD_CONFIG"] = str(
        config if config is not None else ROOT / "tests" / "missing-config.env")
    if extra_env is not None:
        env.update(extra_env)
    result = subprocess.run(["sh", str(RUN), *arguments],
                            capture_output=True, text=True, env=env)
    return result.returncode, json.loads(result.stdout)


@unittest.skipIf(os.name == "nt", "the shell backend tests need a POSIX sh (run under WSL)")
class ShellBackendTests(unittest.TestCase):
    def create_inventory_library(self, root):
        library = root / "library"
        library.mkdir()
        records = {
            "base": {"type": "CollectionType", "visibleName": "Crosswords", "parent": ""},
            "year": {"type": "CollectionType", "visibleName": "2026", "parent": "base"},
            "month": {"type": "CollectionType", "visibleName": "10_October", "parent": "year"},
            "existing": {"type": "DocumentType", "parent": "month",
                         "visibleName": "NYT Crosswords 2026-10-01 to 2026-10-02"},
            "trashed": {"type": "DocumentType", "parent": "trash",
                        "visibleName": "NYT Crosswords 2026-10-03 to 2026-10-04"},
        }
        for uuid, record in records.items():
            (library / f"{uuid}.metadata").write_text(json.dumps(record))
        (library / "existing.pdf").write_bytes(b"%PDF-1.4\n")
        (library / "trashed.pdf").write_bytes(b"%PDF-1.4\n")
        return library

    def test_view_reports_existing_pdfs_and_missing_dates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = self.create_inventory_library(root)
            env = {"NYTCROSSWORD_LIBRARY_DIR": str(library),
                   "NYTCROSSWORD_STATE_DIR": str(root / "state")}
            code, payload = run_backend(
                "view", "2026-10-01", "2026-10-04",
                "Oct0126,Oct0226,Oct0326,Oct0426", extra_env=env)
            self.assertEqual(code, 0)
            self.assertEqual(payload["present_count"], 2)
            self.assertEqual(payload["missing_count"], 2)
            self.assertEqual(payload["dates"][0]["files"][0]["uuid"], "existing")
            self.assertEqual(payload["groups"][0]["start_date"], "2026-10-03")
            (library / "existing.pdf").unlink()
            code, payload = run_backend(
                "view", "2026-10-01", "2026-10-02",
                "Oct0126,Oct0226", extra_env=env)
            self.assertEqual(payload["missing_count"], 2)

    def test_import_missing_does_nothing_when_all_present(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = self.create_inventory_library(root)
            code, payload = run_backend(
                "import-missing", "2026-10-01", "2026-10-02",
                "Oct0126,Oct0226", extra_env={
                    "NYTCROSSWORD_LIBRARY_DIR": str(library),
                    "NYTCROSSWORD_STATE_DIR": str(root / "state"),
                })
            self.assertEqual(code, 0)
            self.assertEqual(payload["count"], 0)
            self.assertEqual(payload["documents"], [])

    def test_settings_save_preserves_cookie_and_other_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config.env"
            state = root / "state"
            state.mkdir()
            config.write_text(
                "NYT_S_COOKIE=private-value\nMB_IN_PATH=/run/custom\n"
                "CROSSWORD_FOLDER=/Old\n", encoding="utf-8")
            draft = state / "settings-draft.env"
            draft.write_text(
                "NYT_S_COOKIE=\nCROSSWORD_FOLDER=/Puzzles\n"
                "BROKER_TIMEOUT_S=15\n", encoding="utf-8")
            code, payload = run_backend(
                "settings-apply", config=config,
                extra_env={"NYTCROSSWORD_STATE_DIR": str(state)})
            self.assertEqual(code, 0)
            self.assertTrue(payload["configured"])
            self.assertEqual(payload["folder"], "/Puzzles")
            self.assertNotIn("private-value", json.dumps(payload))
            self.assertIn("NYT_S_COOKIE=private-value", config.read_text())
            self.assertIn("MB_IN_PATH=/run/custom", config.read_text())
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            self.assertFalse(draft.exists())
            draft.write_text(
                "NYT_S_COOKIE=replacement\nCROSSWORD_FOLDER=/Puzzles\n"
                "BROKER_TIMEOUT_S=15\n", encoding="utf-8")
            code, payload = run_backend(
                "settings-apply", config=config,
                extra_env={"NYTCROSSWORD_STATE_DIR": str(state)})
            self.assertEqual(code, 0)
            self.assertNotIn("replacement", json.dumps(payload))
            self.assertIn("NYT_S_COOKIE=replacement", config.read_text())
            self.assertNotIn("private-value", config.read_text())

    def test_invalid_settings_do_not_change_saved_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config.env"
            config.write_text("NYT_S_COOKIE=unchanged\n", encoding="utf-8")
            state = root / "state"
            state.mkdir()
            draft = state / "settings-draft.env"
            draft.write_text(
                "CROSSWORD_FOLDER=/Crosswords\nBROKER_TIMEOUT_S=301\n",
                encoding="utf-8")
            code, payload = run_backend(
                "settings-apply", config=config,
                extra_env={"NYTCROSSWORD_STATE_DIR": str(state)})
            self.assertNotEqual(code, 0)
            self.assertEqual(payload["error"], "invalid_config")
            self.assertEqual(config.read_text(), "NYT_S_COOKIE=unchanged\n")
            self.assertFalse(draft.exists())

    def test_version_reports_json(self):
        code, payload = run_backend("version")
        self.assertEqual(code, 0)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["version"], "0.2.0")

    def test_status_is_unconfigured_without_cookie(self):
        with tempfile.TemporaryDirectory() as directory:
            code, payload = run_backend(
                "status", config=Path(directory) / "missing.env")
        self.assertEqual(code, 0)
        self.assertEqual(payload["configured"], False)
        self.assertIn("curl_available", payload)
        self.assertIn("merger_available", payload)
        self.assertIn("broker_ready", payload)

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

    def test_preview_reports_validated_range(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.env"
            config.write_text("CROSSWORD_FOLDER=/Puzzles\n", encoding="utf-8")
            code, payload = run_backend(
                "preview", "2026-10-01", "2026-10-04",
                "Oct0126,Oct0226,Oct0326,Oct0426", config=config)
        self.assertEqual(code, 0)
        self.assertEqual(payload, {
            "ok": True,
            "start_date": "2026-10-01",
            "end_date": "2026-10-04",
            "count": 4,
            "destination": "/Puzzles/2026/10_October",
            "merge_required": True,
            "groups": [{
                "start_date": "2026-10-01", "end_date": "2026-10-04",
                "count": 4, "destination": "/Puzzles/2026/10_October",
            }],
        })

    def test_preview_rejects_future_range(self):
        code, payload = run_backend(
            "preview", "2999-01-01", "2999-01-01", "Jan0129")
        self.assertEqual(code, 2)
        self.assertEqual(payload["error"], "invalid_range")

    def test_preview_rejects_duplicate_puzzle(self):
        code, payload = run_backend(
            "preview", "2026-10-01", "2026-10-02", "Oct0126,Oct0126")
        self.assertEqual(code, 2)
        self.assertEqual(payload["error"], "invalid_range")

    def test_preview_rejects_ids_that_do_not_match_range(self):
        code, payload = run_backend(
            "preview", "2026-10-01", "2026-10-02", "Oct0226,Oct0326")
        self.assertEqual(code, 2)
        self.assertEqual(payload["error"], "invalid_range")

    def test_import_downloads_merges_and_uses_broker(self):
        self.check_monthly_import(False)

    def test_import_merges_each_month_separately(self):
        self.check_monthly_import(True)

    def test_import_missing_downloads_only_uncovered_date(self):
        self.check_monthly_import(False, True)

    def check_monthly_import(self, cross_month, missing_mode=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config.env"
            state = root / "state"
            mb_in = root / "xovi-mb"
            mb_out = root / "xovi-mb-out"
            os.mkfifo(mb_in)
            os.mkfifo(mb_out)
            config.write_text(
                "NYT_S_COOKIE=fake-session\n"
                "CROSSWORD_FOLDER=/Crosswords\n"
                f"MB_IN_PATH={mb_in}\n"
                f"MB_OUT_PATH={mb_out}\n",
                encoding="utf-8",
            )

            fake_curl = root / "curl"
            fake_curl.write_text(
                "#!/bin/sh\n"
                "output=\n"
                "while [ \"$#\" -gt 0 ]; do\n"
                "  if [ \"$1\" = --output ]; then output=$2; shift 2; else shift; fi\n"
                "done\n"
                f'printf "%s\\n" "$output" >>"{root / "downloads"}"\n'
                "printf '%%PDF-1.4\\nfake puzzle\\n' >\"$output\"\n"
                "printf 200\n",
                encoding="utf-8",
            )
            fake_qpdf = root / "qpdf"
            fake_qpdf.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = --check ]; then exit 0; fi\n"
                f'printf "%s\\n" "$*" >>"{root / "merges"}"\n'
                "for argument in \"$@\"; do output=$argument; done\n"
                "printf '%%PDF-1.4\\nmerged puzzles\\n' >\"$output\"\n",
                encoding="utf-8",
            )
            fake_curl.chmod(0o755)
            fake_qpdf.chmod(0o755)

            requests = []

            def broker():
                replies = [
                    "11111111-1111-1111-1111-111111111111",
                    "22222222-2222-2222-2222-222222222222",
                ]
                if cross_month:
                    replies += replies
                for reply in replies:
                    with mb_in.open(encoding="utf-8") as incoming:
                        requests.append(incoming.readline().strip())
                    with mb_out.open("w", encoding="utf-8") as outgoing:
                        outgoing.write(reply)

            worker = threading.Thread(target=broker, daemon=True)
            worker.start()
            extra_env = {
                "NYTCROSSWORD_STATE_DIR": str(state),
                "NYTCROSSWORD_CURL": str(fake_curl),
                "NYTCROSSWORD_QPDF": str(fake_qpdf),
            }
            if missing_mode:
                library = self.create_inventory_library(root)
                record = library / "existing.metadata"
                data = json.loads(record.read_text())
                data["visibleName"] = "NYT Crosswords 2026-10-01 to 2026-10-01"
                record.write_text(json.dumps(data))
                extra_env["NYTCROSSWORD_LIBRARY_DIR"] = str(library)
            code, payload = run_backend(
                "import-missing" if missing_mode else "import",
                "2026-09-29" if cross_month else "2026-10-01",
                "2026-10-02",
                "Sep2926,Sep3026,Oct0126,Oct0226" if cross_month else "Oct0126,Oct0226",
                config=config,
                extra_env=extra_env,
            )
            worker.join(timeout=5)
            merges = (root / "merges").read_text().splitlines() if (root / "merges").exists() else []
            downloads = (root / "downloads").read_text().splitlines()
            marker_exists = (state / "import-uncertain").exists()

        self.assertFalse(worker.is_alive())
        self.assertEqual(code, 0)
        self.assertEqual(payload["count"], 1 if missing_mode else (4 if cross_month else 2))
        self.assertEqual(
            payload["document_uuid"],
            "22222222-2222-2222-2222-222222222222")
        self.assertEqual(requests[0], ">eensureFolder:/Crosswords/2026/" +
                         ("09_September" if cross_month else "10_October"))
        self.assertTrue(requests[1].startswith(">eimportDocument:"))
        self.assertIn(
            ",11111111-1111-1111-1111-111111111111", requests[1])
        self.assertFalse(marker_exists)
        self.assertEqual(len(payload["documents"]), 2 if cross_month else 1)
        if missing_mode:
            self.assertEqual(len(downloads), 1)
            self.assertTrue(downloads[0].endswith("Oct0226.pdf"))
            self.assertEqual(merges, [])
        if cross_month:
            self.assertEqual(requests[2], ">eensureFolder:/Crosswords/2026/10_October")
            self.assertEqual(len(merges), 2)
            self.assertIn("Sep2926.pdf", merges[0])
            self.assertNotIn("Oct0126.pdf", merges[0])
            self.assertIn("Oct0126.pdf", merges[1])
            self.assertNotIn("Sep3026.pdf", merges[1])

    def test_preview_splits_range_at_month_boundary(self):
        code, payload = run_backend(
            "preview", "2026-09-30", "2026-10-01", "Sep3026,Oct0126")
        self.assertEqual(code, 0)
        self.assertFalse(payload["merge_required"])
        self.assertEqual(payload["groups"], [
            {"start_date": "2026-09-30", "end_date": "2026-09-30",
             "count": 1, "destination": "/Crosswords/2026/09_September"},
            {"start_date": "2026-10-01", "end_date": "2026-10-01",
             "count": 1, "destination": "/Crosswords/2026/10_October"},
        ])

    def test_preview_rejects_missing_middle_dates(self):
        code, payload = run_backend(
            "preview", "2026-09-29", "2026-10-02",
            "Sep2926,Oct0226")
        self.assertNotEqual(code, 0)
        self.assertEqual(payload["error"], "invalid_range")

    def test_broker_timeout_bounds_fifo_open_and_blocks_retry(self):
        self.check_broker_timeout(False)

    def test_broker_timeout_bounds_reply_wait_and_blocks_retry(self):
        self.check_broker_timeout(True)

    def check_broker_timeout(self, consume_request):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mb_in = root / "in"
            mb_out = root / "out"
            os.mkfifo(mb_in)
            os.mkfifo(mb_out)
            config = root / "config.env"
            config.write_text(
                f"MB_IN_PATH={mb_in}\nMB_OUT_PATH={mb_out}\n"
                "BROKER_TIMEOUT_S=1\n", encoding="utf-8")
            work = root / "work"
            work.mkdir()
            env = dict(os.environ, NYTCROSSWORD_CONFIG=str(config))
            # Source the backend in version mode, then exercise the broker directly.
            command = [
                "bash", "-c",
                'source "$1" version; WORK=$2; broker_call ensureFolder /Test',
                "test", str(ROOT / "scripts" / "nytcrossword-shell.sh"), str(work),
            ]
            if consume_request:
                def consume():
                    with mb_in.open(encoding="utf-8") as incoming:
                        incoming.read()
                consumer = threading.Thread(target=consume, daemon=True)
                consumer.start()
            start = time.monotonic()
            result = subprocess.run(
                command, env=env, capture_output=True, text=True, timeout=5)
            elapsed = time.monotonic() - start
            payload = json.loads(result.stdout.splitlines()[-1])
            self.assertEqual(result.returncode, 1)
            self.assertEqual(payload["error"], "broker_timeout")
            self.assertLess(elapsed, 4)
            self.assertTrue(Path(str(mb_in) + ".nytcrossword-pending").exists())
            self.assertFalse(work.exists())
            if consume_request:
                consumer.join(timeout=2)
                self.assertFalse(consumer.is_alive())
            work.mkdir()
            result = subprocess.run(
                command, env=env, capture_output=True, text=True, timeout=5)
            payload = json.loads(result.stdout.splitlines()[-1])
            self.assertEqual(payload["error"], "broker_recovery_required")


class AppLoadAppTests(unittest.TestCase):
    def test_settings_and_main_page_are_root_siblings(self):
        qml = (APP / "ui" / "NytCrossword.qml").read_text()
        tokens = re.finditer(
            r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|'
            r'//[^\n]*|/\*[\s\S]*?\*/|'
            r'\bid\s*:\s*(mainPage|settingsPage)\b|[{}]', qml)
        stack = []
        parents = {}
        for token in tokens:
            value = token.group()
            if value == "{":
                stack.append(token.start())
            elif value == "}":
                stack.pop()
            elif token.group(1):
                self.assertEqual(len(stack), 2, value)
                parents[token.group(1)] = stack[-2]
        self.assertEqual(set(parents), {"mainPage", "settingsPage"})
        self.assertEqual(parents["mainPage"], parents["settingsPage"])
        self.assertEqual(stack, [])

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
        self.assertIn('"view"', qml)
        self.assertIn('"import"', qml)
        self.assertIn("function puzzleIds()", qml)
        self.assertIn("function selectPreset(preset)", qml)
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
                "scripts/nytcrossword-inventory.jq",
                "config.example.env",
            })
            for name in ("scripts/nytcrossword-run.sh", "scripts/nytcrossword-shell.sh"):
                info = archive.getinfo(name)
                self.assertEqual(info.external_attr >> 16, 0o100755)
                self.assertNotIn(b"\r\n", archive.read(name))

    def test_runtime_launcher_detects_app_local_qpdf(self):
        launcher = (ROOT / "scripts" / "nytcrossword-run.sh").read_text()
        self.assertIn(
            'NYTCROSSWORD_QPDF="${NYTCROSSWORD_QPDF:-$ROOT_DIR/tools/bin/qpdf}"',
            launcher,
        )

    def test_update_script_deploys_runtime_and_app(self):
        content = (ROOT / "scripts" / "update-remarkable.ps1").read_text()
        self.assertIn("package-tablet.ps1", content)
        self.assertIn("package-xovi-appload.ps1", content)
        self.assertIn('cp -R "$stage/appload/nyt-crossword" "$appload/nyt-crossword"', content)
        self.assertNotIn("rm -rf \"$runtime", content)


if __name__ == "__main__":
    unittest.main()
