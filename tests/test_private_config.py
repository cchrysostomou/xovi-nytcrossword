from contextlib import redirect_stderr
from datetime import datetime
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("nytcrwd", ROOT / "scripts" / "nytcrwd.py")
assert SPEC is not None and SPEC.loader is not None
downloader = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(downloader)


class PrivateConfigTests(unittest.TestCase):
    def load_settings(self, text):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.env"
            config.write_text(text, encoding="utf-8")
            return downloader.load_access_config(config)

    def test_session_cookie_and_generic_defaults(self):
        self.assertEqual(self.load_settings("NYT_S_COOKIE=fake-session==\n"), {
            "cookie": "NYT-S=fake-session==",
            "rmapi_path": "rmapi",
            "rmapi_folder": "/Crosswords",
        })

    def test_full_header_and_personal_settings_are_read_as_data(self):
        settings = self.load_settings(
            "# ignored comment\r\nNYT_S_COOKIE=unused\r\n"
            "NYT_COOKIE = NYT-S=fake-session==; example=value\r\n"
            "RMAPI_PATH=C:\\Tools\\rmapi.exe\r\n"
            "RMAPI_FOLDER=/A folder with spaces\r\n"
        )
        self.assertEqual(settings["cookie"], "NYT-S=fake-session==; example=value")
        self.assertEqual(settings["rmapi_path"], r"C:\Tools\rmapi.exe")
        self.assertEqual(settings["rmapi_folder"], "/A folder with spaces")

    def test_duplicate_settings_use_last_value(self):
        settings = self.load_settings("NYT_S_COOKIE=first\nNYT_S_COOKIE=last\n")
        self.assertEqual(settings["cookie"], "NYT-S=last")

    def test_missing_cookie_is_an_explicit_error(self):
        with self.assertRaisesRegex(ValueError, "Set NYT_S_COOKIE or NYT_COOKIE"):
            self.load_settings("NYT_S_COOKIE=\nNYT_COOKIE=\n")

    def test_malformed_config_error_does_not_echo_secret(self):
        with self.assertRaises(ValueError) as caught:
            self.load_settings("NYT_S_COOKIE=fake-session\ninvalid-secret-line\n")
        self.assertEqual(str(caught.exception), "Invalid configuration entry on line 2.")

    def test_missing_file_raises(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(FileNotFoundError):
                downloader.load_access_config(Path(directory) / "missing.env")

    def test_upload_arguments_are_not_shell_commands(self):
        with patch.object(downloader.subprocess, "run") as run:
            downloader._save_rmapi(
                datetime(2026, 1, 1), Path("crossword.pdf"),
                prefix_path="/Folder with spaces", rmapi_path="custom-rmapi",
            )
        self.assertEqual(run.call_args_list[0].args[0], [
            "custom-rmapi", "mkdir", "/Folder with spaces/2026 CW",
        ])
        self.assertEqual(run.call_args_list[1].args[0], [
            "custom-rmapi", "put", "crossword.pdf",
            "/Folder with spaces/2026 CW/", "--content-only",
        ])
        self.assertTrue(all(call.kwargs["check"] for call in run.call_args_list))

    def test_main_uses_explicit_config_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.env"
            config.write_text(
                "NYT_S_COOKIE=fake-session\nRMAPI_FOLDER=/Example\n",
                encoding="utf-8",
            )
            with (
                patch("sys.argv", ["nytcrwd.py", "3", "--config", str(config)]),
                patch.object(downloader, "download_and_merge_crosswords",
                             return_value=([], Path("merged.pdf"))) as download,
                patch.object(downloader, "_save_rmapi") as upload,
            ):
                downloader.main()
        self.assertEqual(download.call_args.args, (3, "NYT-S=fake-session"))
        self.assertEqual(upload.call_args.kwargs, {
            "prefix_path": "/Example", "rmapi_path": "rmapi",
        })

    def test_command_line_credentials_are_rejected(self):
        output = io.StringIO()
        with patch("sys.argv", ["nytcrwd.py", "7", "fake-session"]):
            with redirect_stderr(output):
                with self.assertRaises(SystemExit) as caught:
                    downloader.main()
        self.assertEqual(caught.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
