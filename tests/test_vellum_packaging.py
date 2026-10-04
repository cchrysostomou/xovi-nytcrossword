from pathlib import Path
import os
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / "packaging" / "vellum" / "xovi-nytcrossword" / "VELBUILD.in"


@unittest.skipIf(os.name == "nt", "Vellum recipe checks need POSIX Bash (run under WSL)")
class VellumRecipeTests(unittest.TestCase):
    def create_stage(self, root):
        files = (
            "home/root/xovi/exthome/appload/nyt-crossword/resources.rcc",
            "home/root/xovi/exthome/qt-resource-rebuilder/nytQuickDownload.qmd",
            "home/root/xovi-nytcrossword/tools/bin/qpdf",
            "home/root/.vellum/licenses/xovi-nytcrossword/SOURCES",
        )
        for name in files:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture\n", encoding="utf-8")
        (root / files[2]).chmod(0o755)

    def check_stage(self, root):
        return subprocess.run(
            ["bash", "-c", '. "$1"; srcdir="$2"; check', "check", str(RECIPE), str(root)],
            capture_output=True, text=True,
        )

    def test_recipe_accepts_required_install_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.create_stage(root)
            result = self.check_stage(root)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_recipe_rejects_private_configuration_and_state(self):
        for private in ("config.env", "state"):
            with self.subTest(private=private), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.create_stage(root)
                path = root / "home/root/xovi-nytcrossword" / private
                if private == "state":
                    path.mkdir()
                else:
                    path.write_text("NYT_S_COOKIE=dummy\n", encoding="utf-8")
                self.assertNotEqual(self.check_stage(root).returncode, 0)

    def test_recipe_rejects_missing_resources_or_nonexecutable_merger(self):
        for missing in ("resources", "qmd", "licenses", "merger"):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.create_stage(root)
                paths = {
                    "resources": root / "home/root/xovi/exthome/appload/nyt-crossword/resources.rcc",
                    "qmd": root / "home/root/xovi/exthome/qt-resource-rebuilder/nytQuickDownload.qmd",
                    "licenses": root / "home/root/.vellum/licenses/xovi-nytcrossword/SOURCES",
                    "merger": root / "home/root/xovi-nytcrossword/tools/bin/qpdf",
                }
                if missing == "merger":
                    paths[missing].chmod(0o644)
                else:
                    paths[missing].unlink()
                self.assertNotEqual(self.check_stage(root).returncode, 0)


if __name__ == "__main__":
    unittest.main()
