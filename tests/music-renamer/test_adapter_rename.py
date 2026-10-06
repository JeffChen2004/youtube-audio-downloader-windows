from __future__ import annotations

import base64
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from uuid import uuid4

from mutagen.mp4 import MP4
from mutagen.oggopus import OggOpus

import music_renamer_core as core


REPO_ROOT = Path(__file__).resolve().parents[2]
ADAPTER_PATH = REPO_ROOT / "integrations" / "music-renamer" / "adapter.py"
CORE_SOURCE = Path(os.environ["MUSIC_RENAMER_CORE_SOURCE"]).resolve()
SAMPLE_DIRECTORY = Path(os.environ.get("MUSIC_RENAMER_SAMPLE_DIR", ""))


def _load_adapter_module():
    spec = importlib.util.spec_from_file_location("phase2_adapter", ADAPTER_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ADAPTER = _load_adapter_module()


def _sample(suffix: str) -> Path:
    matches = list(SAMPLE_DIRECTORY.glob(f"*{suffix}")) if SAMPLE_DIRECTORY.is_dir() else []
    if not matches:
        raise unittest.SkipTest(f"A real {suffix} sample is required")
    return matches[0]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _cover(path: Path) -> bytes:
    if path.suffix.lower() == ".opus":
        return base64.b64decode(OggOpus(path).tags["METADATA_BLOCK_PICTURE"][0])
    return bytes(MP4(path).tags["covr"][0])


def _set_title_artist(path: Path, title: str, artist: str) -> None:
    if path.suffix.lower() == ".opus":
        media = OggOpus(path)
        media["TITLE"] = [title]
        media["ARTIST"] = [artist]
    else:
        media = MP4(path)
        media["\xa9nam"] = [title]
        media["\xa9ART"] = [artist]
    media.save()


def _config(template: str = "{artist} - {title}", **updates):
    value = {
        "template": template,
        "warning_acknowledged": False,
        "artist_aliases": [],
        "title_cleanup_rules": [],
        "extraction": {
            "artist_quoted_title": False,
            "title_slash_artist": False,
        },
    }
    value.update(updates)
    return value


class RenameAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(dir=REPO_ROOT / "tests")
        self.root = Path(self.temp_dir.name)
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "core_source_path": str(CORE_SOURCE),
                    "core_package_version": "0.5.0",
                    "core_git_commit": "phase2-test",
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def invoke(self, source: Path, config: dict, correlation_id: str = "phase2-test"):
        request = {
            "protocol_version": 1,
            "correlation_id": correlation_id,
            "operation": "rename",
            "source_path": str(source.resolve()),
            "config": config,
        }
        completed = subprocess.run(
            [sys.executable, str(ADAPTER_PATH), "--manifest", str(self.manifest)],
            input=json.dumps(request), text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(len(completed.stdout.splitlines()), 1, completed.stdout)
        return completed, json.loads(completed.stdout)

    def copy_sample(self, suffix: str, name: str = "source") -> Path:
        destination = self.root / f"{name}{suffix}"
        shutil.copy2(_sample(suffix), destination)
        return destination

    def test_invalid_config_and_template_are_domain_rejections(self) -> None:
        source = self.copy_sample(".opus")
        for config, code in (({"template": "{title}"}, "invalid_config"),
                             (_config("{unknown}"), "unknown_placeholder")):
            with self.subTest(code=code):
                completed, result = self.invoke(source, config)
                self.assertEqual(completed.returncode, 0)
                self.assertEqual(completed.stderr, "")
                self.assertEqual(result["adapter_status"], "completed")
                self.assertEqual(result["classification"], "rejected")
                self.assertIn(code, result["planning"]["issue_codes"])
                self.assertTrue(source.exists())

    def test_unchanged_is_no_op(self) -> None:
        source = self.copy_sample(".opus", "Nocturne No. 2 in E flat Major, Op. 9,2")
        completed, result = self.invoke(source, _config("{title}"), "unchanged-id")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(result["correlation_id"], "unchanged-id")
        self.assertEqual(result["classification"], "unchanged")
        self.assertEqual(result["planning"]["status"], "unchanged")
        self.assertEqual(result["execution"]["outcome"], "no_op")
        self.assertEqual(Path(result["path"]["verified_final_path"]), source)
        self.assertTrue(source.exists())

    def test_simple_opus_and_m4a_rename_preserve_media(self) -> None:
        for suffix in (".opus", ".m4a"):
            with self.subTest(suffix=suffix):
                source = self.copy_sample(suffix, f"source-{suffix[1:]}")
                before_hash = _sha256(source)
                before_metadata = core.MutagenMetadataReader().read(source)
                before_cover = _cover(source)
                completed, result = self.invoke(source, _config("Phase2-{youtube_id}"))
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(completed.stderr, "")
                self.assertEqual(result["classification"], "renamed")
                self.assertEqual(result["execution"]["outcome"], "succeeded")
                destination = Path(result["path"]["verified_final_path"])
                self.assertEqual(destination.name, f"Phase2-bVeOdm-29pU{suffix}")
                self.assertFalse(source.exists())
                self.assertTrue(destination.exists())
                self.assertEqual(_sha256(destination), before_hash)
                self.assertEqual(core.MutagenMetadataReader().read(destination), before_metadata)
                self.assertEqual(_cover(destination), before_cover)

    def test_planning_reject_existing_destination_and_warning_are_nonmutating(self) -> None:
        missing = self.copy_sample(".opus", "missing-field")
        _, missing_result = self.invoke(missing, _config("{performer}"))
        self.assertEqual(missing_result["classification"], "rejected")
        self.assertEqual(missing_result["rejection_reason"], "planning_error")
        self.assertTrue(missing.exists())

        occupied_source = self.copy_sample(".opus", "occupied-source")
        occupied = self.root / "Chopin.opus"
        occupied.write_bytes(b"unrelated")
        _, occupied_result = self.invoke(occupied_source, _config("{album}"))
        self.assertEqual(occupied_result["classification"], "rejected")
        self.assertIn("unrelated_destination_exists", occupied_result["planning"]["issue_codes"])
        self.assertTrue(occupied_source.exists())
        self.assertEqual(occupied.read_bytes(), b"unrelated")

        warning = self.copy_sample(".opus", "warning-source")
        _, warning_result = self.invoke(warning, _config("{title}?"))
        self.assertEqual(warning_result["planning"]["status"], "warning")
        self.assertEqual(warning_result["classification"], "rejected")
        self.assertEqual(warning_result["rejection_reason"], "warning_not_acknowledged")
        self.assertIsNone(warning_result["execution"])
        self.assertTrue(warning.exists())

        acknowledged = self.copy_sample(".opus", "acknowledged-warning")
        _, acknowledged_result = self.invoke(
            acknowledged,
            _config("{title}?", warning_acknowledged=True),
        )
        self.assertEqual(acknowledged_result["classification"], "renamed")
        self.assertEqual(acknowledged_result["execution"]["outcome"], "succeeded")
        self.assertFalse(acknowledged.exists())

    def test_togenashi_config_wiring(self) -> None:
        source = self.copy_sample(".opus", "togenashi-source")
        _set_title_artist(source, "【Official Music Video】トゲナシトゲアリ「偽りの理」", "GIRLS BAND CRY Channel")
        before_hash = _sha256(source)
        config = _config(
            "【{artist}】 {title}",
            artist_aliases=[{"source": "GIRLS BAND CRY Channel", "target": "TOGENASHI TOGEARI"}],
            title_cleanup_rules=[{"kind": "remove_prefix", "text": "【Official Music Video】"}],
            extraction={"artist_quoted_title": True, "title_slash_artist": False},
        )
        _, result = self.invoke(source, config)
        destination = Path(result["path"]["verified_final_path"])
        self.assertEqual(destination.stem, "【TOGENASHI TOGEARI】 偽りの理")
        self.assertEqual(result["planning"]["metadata"]["effective"]["title"], "偽りの理")
        self.assertEqual(result["planning"]["metadata"]["derived"]["title_artist"], "トゲナシトゲアリ")
        self.assertEqual(_sha256(destination), before_hash)

    def test_mygo_and_no_match_extraction(self) -> None:
        mygo = self.copy_sample(".opus", "mygo-source")
        _set_title_artist(mygo, "名無声 ⧸ MyGO!!!!!", "MyGO!!!!!")
        _, result = self.invoke(
            mygo,
            _config("{title} [{title_artist}]", extraction={"artist_quoted_title": False, "title_slash_artist": True}),
        )
        self.assertEqual(Path(result["path"]["verified_final_path"]).stem, "名無声 [MyGO!!!!!]")
        self.assertEqual(result["planning"]["metadata"]["effective"]["title"], "名無声")
        self.assertEqual(result["planning"]["metadata"]["derived"]["title_artist"], "MyGO!!!!!")

        for index, title in enumerate((
            "Ave Mujica - Ether (Official Music Video)",
            "君の神様になりたい。 (Cover)",
            "パメラ covered by 燈",
        )):
            with self.subTest(title=title):
                source = self.copy_sample(".opus", f"no-match-{index}")
                _set_title_artist(source, title, "Channel")
                _, unmatched = self.invoke(
                    source,
                    _config("{title}", extraction={"artist_quoted_title": True, "title_slash_artist": True}),
                )
                self.assertEqual(unmatched["planning"]["metadata"]["effective"]["title"], title)
                self.assertIsNone(unmatched["planning"]["metadata"]["derived"]["title_artist"])
                self.assertEqual(unmatched["planning"]["metadata"]["transformations"], [])

    def test_failure_and_incomplete_recovery_projection(self) -> None:
        now = datetime.now(timezone.utc)
        for outcome, location, expected in (
            (core.TransactionOutcome.FAILED_ROLLED_BACK, core.FinalLocation.SOURCE, "failed"),
            (core.TransactionOutcome.FAILED_ROLLBACK_INCOMPLETE, core.FinalLocation.UNKNOWN, "requires_attention"),
            (core.TransactionOutcome.FAILED_ROLLBACK_INCOMPLETE, core.FinalLocation.MISSING, "requires_attention"),
        ):
            operation = core.RenameOperationResult(
                item_id=uuid4(), source_path=Path("C:/fixture/source.opus"),
                temporary_path=None, destination_path=Path("C:/fixture/target.opus"),
                forward_state=core.ForwardState.FAILED,
                forward_error=core.OperationError("commit_failed", "failed"),
                rollback_state=core.RollbackState.FAILED if location in {core.FinalLocation.UNKNOWN, core.FinalLocation.MISSING} else core.RollbackState.SUCCEEDED,
                rollback_error=core.OperationError("rollback_failed", "failed") if location in {core.FinalLocation.UNKNOWN, core.FinalLocation.MISSING} else None,
                final_location=location, final_path=None if location in {core.FinalLocation.UNKNOWN, core.FinalLocation.MISSING} else Path("C:/fixture/source.opus"),
            )
            execution = core.ExecutionResult(uuid4(), uuid4(), now, now, outcome, (operation,))
            projected = ADAPTER._project_execution(execution)
            self.assertEqual(projected["outcome"], outcome.value)
            classification = ADAPTER._classification(core, execution)
            self.assertEqual(classification, expected)
            response = ADAPTER._domain_response(
                "projection",
                classification=classification,
                original_path="C:/fixture/source.opus",
                planning={"destination_path": "C:/fixture/target.opus"},
                execution_result=projected,
            )
            self.assertEqual(response["classification"], expected)
            if location in {core.FinalLocation.UNKNOWN, core.FinalLocation.MISSING}:
                self.assertIsNone(projected["operations"][0]["final_path"])
                self.assertIsNone(response["path"]["verified_final_path"])


if __name__ == "__main__":
    unittest.main()
