from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
ADAPTER = REPO_ROOT / "integrations" / "music-renamer" / "adapter.py"
CORE_SOURCE = Path(os.environ["MUSIC_RENAMER_CORE_SOURCE"]).resolve()
EXPECTED_VERSION = os.environ.get("MUSIC_RENAMER_CORE_VERSION", "0.5.0")


def request(correlation_id: str = "adapter-test") -> dict[str, object]:
    return {
        "protocol_version": 1,
        "correlation_id": correlation_id,
        "operation": "health",
        "config": {
            "template": "{artist} - {title}",
            "warning_acknowledged": False,
            "fixture_path": None,
        },
    }


class AdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(dir=REPO_ROOT / "tests")
        self.manifest = Path(self.temp_dir.name) / "manifest.json"
        self.manifest.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "core_source_path": str(CORE_SOURCE),
                    "core_package_version": EXPECTED_VERSION,
                    "core_git_commit": "test-commit-expectation",
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def invoke(
        self, payload: str, *, executable: Path | None = None
    ) -> subprocess.CompletedProcess[str]:
        args = [str(executable or sys.executable)]
        args.extend([str(ADAPTER), "--manifest", str(self.manifest)])
        return subprocess.run(args, input=payload, text=True, capture_output=True, timeout=10)

    def test_health_checks_core_contract_without_loading_pyside6(self) -> None:
        completed = self.invoke(json.dumps(request()))
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(len(completed.stdout.splitlines()), 1)
        result = json.loads(completed.stdout)
        self.assertEqual(result["adapter_status"], "healthy")
        self.assertEqual(result["core_health"]["package_version"], EXPECTED_VERSION)
        self.assertFalse(result["core_health"]["pyside6_loaded"])
        self.assertIn("RenamePlanner", result["core_health"]["required_api"])
        self.assertNotIn("PySide6", completed.stdout)

    def test_invalid_input_is_structured_and_nonzero(self) -> None:
        completed = self.invoke("not-json")
        self.assertNotEqual(completed.returncode, 0)
        result = json.loads(completed.stdout)
        self.assertEqual(result["error"]["code"], "invalid_request")

    def test_missing_core_is_structured_and_nonzero(self) -> None:
        isolated_root = Path(self.temp_dir.name) / "isolated-python"
        isolated_root.mkdir()
        runtime_root = Path(sys.executable).parent
        runtime_files = [runtime_root / "python.exe", runtime_root / "python312.zip"]
        runtime_files.extend(runtime_root.glob("*.dll"))
        runtime_files.extend(runtime_root.glob("*.pyd"))
        for source in runtime_files:
            shutil.copy2(source, isolated_root / source.name)
        (isolated_root / "python312._pth").write_text(
            "python312.zip\n.\n", encoding="utf-8"
        )
        completed = self.invoke(
            json.dumps(request()), executable=isolated_root / "python.exe"
        )
        self.assertNotEqual(completed.returncode, 0)
        result = json.loads(completed.stdout)
        self.assertEqual(result["error"]["code"], "core_import_failed")

    def test_wrong_source_identity_fails_closed(self) -> None:
        data = json.loads(self.manifest.read_text(encoding="utf-8"))
        data["core_source_path"] = str(Path(self.temp_dir.name) / "other-core")
        self.manifest.write_text(json.dumps(data), encoding="utf-8")
        completed = self.invoke(json.dumps(request()))
        self.assertNotEqual(completed.returncode, 0)
        result = json.loads(completed.stdout)
        self.assertEqual(result["error"]["code"], "core_source_mismatch")


if __name__ == "__main__":
    unittest.main()
