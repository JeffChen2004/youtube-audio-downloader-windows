"""Phase 1 Music Renamer Core health-check adapter.

The adapter deliberately exposes no rename operation. It reads one JSON request
from stdin, writes one JSON response to stdout, and reserves stderr for human
diagnostics.
"""

from __future__ import annotations

import argparse
import importlib.metadata
import json
from pathlib import Path
import sys
from typing import Any


PROTOCOL_VERSION = 1
MINIMUM_PYTHON = (3, 11)
REQUIRED_CORE_API = (
    "MutagenMetadataReader",
    "RenamePlanner",
    "preflight",
    "RenameExecutor",
    "FilenameTemplate",
    "TemplateContext",
    "TemplateContextResolver",
    "validate_filename_template",
)


class AdapterFailure(Exception):
    def __init__(self, code: str, summary: str) -> None:
        super().__init__(summary)
        self.code = code
        self.summary = summary


def _load_json_object(text: str, *, code: str, label: str) -> dict[str, Any]:
    if text.startswith("\ufeff"):
        text = text[1:]
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        raise AdapterFailure(code, f"{label} is not valid JSON: {exc.msg}") from exc
    if not isinstance(value, dict):
        raise AdapterFailure(code, f"{label} must be a JSON object")
    return value


def _required_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise AdapterFailure("invalid_request", f"{field} must be a non-empty string")
    return value


def _validate_request(request: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    if request.get("protocol_version") != PROTOCOL_VERSION:
        raise AdapterFailure("unsupported_protocol", "protocol_version must be 1")
    correlation_id = _required_string(request.get("correlation_id"), "correlation_id")
    if request.get("operation") != "health":
        raise AdapterFailure("unsupported_operation", "operation must be 'health'")

    config = request.get("config")
    if not isinstance(config, dict):
        raise AdapterFailure("invalid_request", "config must be an object")
    _required_string(config.get("template"), "config.template")
    if not isinstance(config.get("warning_acknowledged"), bool):
        raise AdapterFailure(
            "invalid_request", "config.warning_acknowledged must be a boolean"
        )
    fixture_path = config.get("fixture_path")
    if fixture_path is not None and not isinstance(fixture_path, str):
        raise AdapterFailure("invalid_request", "config.fixture_path must be a string or null")
    return correlation_id, config


def _is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def _health_response(
    correlation_id: str, manifest: dict[str, Any]
) -> dict[str, Any]:
    if sys.version_info < MINIMUM_PYTHON:
        raise AdapterFailure(
            "python_version_incompatible", "Python 3.11 or newer is required"
        )
    if manifest.get("schema_version") != 1:
        raise AdapterFailure("invalid_manifest", "manifest.schema_version must be 1")

    expected_version = _required_string(
        manifest.get("core_package_version"), "manifest.core_package_version"
    )
    source_text = _required_string(
        manifest.get("core_source_path"), "manifest.core_source_path"
    )
    expected_source = Path(source_text).resolve()
    expected_commit = manifest.get("core_git_commit")
    if expected_commit is not None and (
        not isinstance(expected_commit, str) or not expected_commit.strip()
    ):
        raise AdapterFailure(
            "invalid_manifest", "manifest.core_git_commit must be a non-empty string or null"
        )

    try:
        import music_renamer_core as core
    except Exception as exc:
        raise AdapterFailure(
            "core_import_failed", f"music_renamer_core import failed: {type(exc).__name__}: {exc}"
        ) from exc

    try:
        package_version = importlib.metadata.version("music-renamer-core")
    except importlib.metadata.PackageNotFoundError as exc:
        raise AdapterFailure(
            "core_identity_missing", "music-renamer-core distribution metadata was not found"
        ) from exc

    core_file = Path(core.__file__).resolve()
    expected_package_root = (expected_source / "src" / "music_renamer_core").resolve()
    if not _is_within(core_file, expected_package_root):
        raise AdapterFailure(
            "core_source_mismatch",
            "imported music_renamer_core does not come from the expected development source",
        )
    if package_version != expected_version:
        raise AdapterFailure(
            "core_version_mismatch",
            f"expected music-renamer-core {expected_version}, imported {package_version}",
        )

    missing_api = [name for name in REQUIRED_CORE_API if not hasattr(core, name)]
    if missing_api:
        raise AdapterFailure(
            "core_contract_mismatch",
            "required Core API is missing: " + ", ".join(missing_api),
        )
    if "PySide6" in sys.modules or any(
        name.startswith("PySide6.") for name in sys.modules
    ):
        raise AdapterFailure(
            "gui_dependency_leak", "PySide6 was loaded by the Core health check"
        )

    return {
        "protocol_version": PROTOCOL_VERSION,
        "correlation_id": correlation_id,
        "adapter_status": "healthy",
        "runtime_health": {
            "status": "healthy",
            "python_executable": sys.executable,
            "python_version": ".".join(str(part) for part in sys.version_info[:3]),
        },
        "core_health": {
            "status": "healthy",
            "package_name": "music-renamer-core",
            "package_version": package_version,
            "source_path": str(expected_source),
            "import_path": str(core_file),
            "expected_git_commit": expected_commit,
            "required_api": list(REQUIRED_CORE_API),
            "pyside6_loaded": False,
        },
        "error": None,
    }


def _error_response(
    correlation_id: str | None, code: str, summary: str
) -> dict[str, Any]:
    return {
        "protocol_version": PROTOCOL_VERSION,
        "correlation_id": correlation_id,
        "adapter_status": "error",
        "runtime_health": {"status": "unhealthy"},
        "core_health": {"status": "unknown", "pyside6_loaded": "PySide6" in sys.modules},
        "error": {"code": code, "summary": summary},
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    args = parser.parse_args()
    request_text = sys.stdin.read()
    correlation_id: str | None = None
    try:
        request = _load_json_object(
            request_text, code="invalid_request", label="request"
        )
        raw_correlation = request.get("correlation_id")
        if isinstance(raw_correlation, str):
            correlation_id = raw_correlation
        correlation_id, _ = _validate_request(request)
        manifest_path = Path(args.manifest)
        try:
            manifest_text = manifest_path.read_text(encoding="utf-8")
        except OSError as exc:
            raise AdapterFailure(
                "manifest_unavailable", f"runtime manifest could not be read: {exc}"
            ) from exc
        manifest = _load_json_object(
            manifest_text, code="invalid_manifest", label="runtime manifest"
        )
        response = _health_response(correlation_id, manifest)
    except AdapterFailure as exc:
        print(f"Music Renamer adapter: {exc.summary}", file=sys.stderr)
        response = _error_response(correlation_id, exc.code, exc.summary)
        print(json.dumps(response, ensure_ascii=False, separators=(",", ":")))
        return 2
    except Exception as exc:  # fail closed without exposing a traceback on stdout
        summary = f"unexpected adapter failure: {type(exc).__name__}: {exc}"
        print(f"Music Renamer adapter: {summary}", file=sys.stderr)
        response = _error_response(correlation_id, "adapter_internal_error", summary)
        print(json.dumps(response, ensure_ascii=False, separators=(",", ":")))
        return 3

    print(json.dumps(response, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
