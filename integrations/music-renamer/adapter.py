"""Music Renamer Core process adapter for health and single-file rename operations."""

from __future__ import annotations

import argparse
from dataclasses import asdict
import importlib.metadata
import importlib.util
import json
from pathlib import Path
import sys
from typing import Any

_safety_spec = importlib.util.spec_from_file_location('renamer_cancellation', Path(__file__).with_name('cancellation.py'))
_safety = importlib.util.module_from_spec(_safety_spec)
_safety_bytecode = sys.dont_write_bytecode
try:
    sys.dont_write_bytecode = True
    _safety_spec.loader.exec_module(_safety)
finally:
    sys.dont_write_bytecode = _safety_bytecode


PROTOCOL_VERSION = 1
MINIMUM_PYTHON = (3, 11)
REQUIRED_CORE_API = (
    "ArtistAliasNormalizer", "ArtistAliasRule", "ArtistAliasRuleSetError",
    "FinalLocation", "FilenameTemplate", "JapaneseQuotedTitleRule",
    "MetadataNormalizationPipeline", "MutagenMetadataReader", "RenameExecutor",
    "RenamePlanner", "RenameStatus", "RuleBasedTemplateContextResolver",
    "TitleCleanupNormalizer", "TitleCleanupRule", "TitleCleanupRuleKind",
    "TitleCleanupRuleSetError", "TitleSlashArtistRule", "TransactionOutcome",
    "preflight", "validate_filename_template",
)


class AdapterFailure(Exception):
    def __init__(self, code: str, summary: str) -> None:
        super().__init__(summary)
        self.code = code
        self.summary = summary


class DomainRejection(Exception):
    def __init__(self, issues: list[dict[str, Any]]) -> None:
        super().__init__("; ".join(str(issue["message"]) for issue in issues))
        self.issues = issues


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


def _required_string(value: Any, field: str, *, domain: bool = False) -> str:
    if not isinstance(value, str) or not value.strip():
        message = f"{field} must be a non-empty string"
        if domain:
            raise DomainRejection([{"code": "invalid_config", "message": message}])
        raise AdapterFailure("invalid_request", message)
    return value


def _validate_request(request: dict[str, Any]) -> tuple[str, str]:
    if request.get("protocol_version") != PROTOCOL_VERSION:
        raise AdapterFailure("unsupported_protocol", "protocol_version must be 1")
    correlation_id = _required_string(request.get("correlation_id"), "correlation_id")
    operation = request.get("operation")
    if operation not in {"health", "rename"}:
        raise AdapterFailure("unsupported_operation", "operation must be 'health' or 'rename'")
    return correlation_id, operation


def _validate_health_config(request: dict[str, Any]) -> None:
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
        raise AdapterFailure(
            "invalid_request", "config.fixture_path must be a string or null"
        )


def _is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def _load_core(manifest: dict[str, Any]) -> tuple[Any, dict[str, Any]]:
    if sys.version_info < MINIMUM_PYTHON:
        raise AdapterFailure("python_version_incompatible", "Python 3.11 or newer is required")
    if manifest.get("schema_version") != 1:
        raise AdapterFailure("invalid_manifest", "manifest.schema_version must be 1")
    expected_version = _required_string(manifest.get("core_package_version"), "manifest.core_package_version")
    source_text = _required_string(manifest.get("core_source_path"), "manifest.core_source_path")
    expected_source = Path(source_text).resolve()
    expected_commit = manifest.get("core_git_commit")
    if expected_commit is not None and (not isinstance(expected_commit, str) or not expected_commit.strip()):
        raise AdapterFailure("invalid_manifest", "manifest.core_git_commit must be a non-empty string or null")
    try:
        import music_renamer_core as core
    except Exception as exc:
        raise AdapterFailure("core_import_failed", f"music_renamer_core import failed: {type(exc).__name__}: {exc}") from exc
    try:
        package_version = importlib.metadata.version("music-renamer-core")
    except importlib.metadata.PackageNotFoundError as exc:
        raise AdapterFailure("core_identity_missing", "music-renamer-core distribution metadata was not found") from exc
    core_file = Path(core.__file__).resolve()
    expected_package_root = (expected_source / "src" / "music_renamer_core").resolve()
    if not _is_within(core_file, expected_package_root):
        raise AdapterFailure("core_source_mismatch", "imported music_renamer_core does not come from the expected development source")
    if package_version != expected_version:
        raise AdapterFailure("core_version_mismatch", f"expected music-renamer-core {expected_version}, imported {package_version}")
    missing_api = [name for name in REQUIRED_CORE_API if not hasattr(core, name)]
    if missing_api:
        raise AdapterFailure("core_contract_mismatch", "required Core API is missing: " + ", ".join(missing_api))
    if "PySide6" in sys.modules or any(name.startswith("PySide6.") for name in sys.modules):
        raise AdapterFailure("gui_dependency_leak", "PySide6 was loaded by the Core health check")
    return core, {
        "package_name": "music-renamer-core", "package_version": package_version,
        "source_path": str(expected_source), "import_path": str(core_file),
        "expected_git_commit": expected_commit, "required_api": list(REQUIRED_CORE_API),
        "pyside6_loaded": False,
    }


def _health_response(correlation_id: str, identity: dict[str, Any]) -> dict[str, Any]:
    return {
        "protocol_version": PROTOCOL_VERSION, "correlation_id": correlation_id,
        "operation": "health", "adapter_status": "healthy",
        "runtime_health": {"status": "healthy", "python_executable": sys.executable,
                           "python_version": ".".join(str(part) for part in sys.version_info[:3])},
        "core_health": {"status": "healthy", **identity}, "error": None,
    }


def _domain_issue(code: str, message: str, **extra: Any) -> dict[str, Any]:
    return {"code": code, "message": message, **extra}


def _require_list(value: Any, field: str) -> list[Any]:
    if not isinstance(value, list):
        raise DomainRejection([_domain_issue("invalid_config", f"{field} must be an array")])
    return value


def _require_keys(value: dict[str, Any], field: str, expected: set[str]) -> None:
    unknown = sorted(set(value) - expected)
    missing = sorted(expected - set(value))
    if unknown or missing:
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if unknown:
            details.append("unknown " + ", ".join(unknown))
        raise DomainRejection(
            [_domain_issue("invalid_config", f"{field} has " + "; ".join(details))]
        )


def _translate_config(core: Any, request: dict[str, Any]) -> tuple[Any, Any, str, bool]:
    config = request.get("config")
    if not isinstance(config, dict):
        raise DomainRejection([_domain_issue("invalid_config", "config must be an object")])
    _require_keys(
        config,
        "config",
        {"template", "warning_acknowledged", "artist_aliases", "title_cleanup_rules", "extraction"},
    )
    template_text = _required_string(config.get("template"), "config.template", domain=True)
    template_validation = core.validate_filename_template(template_text)
    if not template_validation.is_valid:
        raise DomainRejection([_domain_issue(issue.code, issue.message) for issue in template_validation.issues])
    warning_acknowledged = config.get("warning_acknowledged")
    if not isinstance(warning_acknowledged, bool):
        raise DomainRejection([_domain_issue("invalid_config", "config.warning_acknowledged must be a boolean")])

    aliases: list[Any] = []
    for index, item in enumerate(_require_list(config.get("artist_aliases"), "config.artist_aliases")):
        if not isinstance(item, dict):
            raise DomainRejection([_domain_issue("invalid_config", f"artist_aliases[{index}] must be an object")])
        _require_keys(item, f"artist_aliases[{index}]", {"source", "target"})
        source = _required_string(item.get("source"), f"artist_aliases[{index}].source", domain=True)
        target = _required_string(item.get("target"), f"artist_aliases[{index}].target", domain=True)
        aliases.append(core.ArtistAliasRule(source, target))

    cleanup_rules: list[Any] = []
    for index, item in enumerate(_require_list(config.get("title_cleanup_rules"), "config.title_cleanup_rules")):
        if not isinstance(item, dict):
            raise DomainRejection([_domain_issue("invalid_config", f"title_cleanup_rules[{index}] must be an object")])
        _require_keys(item, f"title_cleanup_rules[{index}]", {"kind", "text"})
        try:
            kind = core.TitleCleanupRuleKind(item.get("kind"))
        except (TypeError, ValueError) as exc:
            raise DomainRejection([_domain_issue("invalid_config", f"title_cleanup_rules[{index}].kind is invalid")]) from exc
        text = _required_string(item.get("text"), f"title_cleanup_rules[{index}].text", domain=True)
        cleanup_rules.append(core.TitleCleanupRule(kind, text))

    extraction = config.get("extraction")
    if not isinstance(extraction, dict):
        raise DomainRejection([_domain_issue("invalid_config", "config.extraction must be an object")])
    _require_keys(extraction, "config.extraction", {"artist_quoted_title", "title_slash_artist"})
    for name in ("artist_quoted_title", "title_slash_artist"):
        if not isinstance(extraction.get(name), bool):
            raise DomainRejection([_domain_issue("invalid_config", f"config.extraction.{name} must be a boolean")])
    try:
        normalizer = core.MetadataNormalizationPipeline((
            core.ArtistAliasNormalizer(tuple(aliases)),
            core.TitleCleanupNormalizer(tuple(cleanup_rules)),
        ))
    except core.ArtistAliasRuleSetError as exc:
        raise DomainRejection([_domain_issue(issue.code, issue.message, rule_index=issue.rule_index) for issue in exc.issues]) from exc
    except core.TitleCleanupRuleSetError as exc:
        raise DomainRejection([_domain_issue(issue.code, issue.message, rule_index=issue.rule_index) for issue in exc.issues]) from exc
    extraction_rules: list[Any] = []
    if extraction["artist_quoted_title"]:
        extraction_rules.append(core.JapaneseQuotedTitleRule("artist_quoted_title"))
    if extraction["title_slash_artist"]:
        extraction_rules.append(core.TitleSlashArtistRule("title_slash_artist"))
    resolver = core.RuleBasedTemplateContextResolver(tuple(extraction_rules))
    return normalizer, resolver, template_text, warning_acknowledged


def _validate_source(request: dict[str, Any]) -> Path:
    source_text = _required_string(request.get("source_path"), "source_path", domain=True)
    source = Path(source_text)
    if not source.is_absolute():
        raise DomainRejection([_domain_issue("source_not_absolute", "source_path must be absolute")])
    if not source.exists():
        raise DomainRejection([_domain_issue("source_missing", "source_path does not exist")])
    if not source.is_file():
        raise DomainRejection([_domain_issue("source_not_file", "source_path is not a file")])
    if source.suffix.lower() not in {".opus", ".m4a"}:
        raise DomainRejection([_domain_issue("unsupported_extension", "source_path must end in .opus or .m4a")])
    return source.absolute()


def _project_issue(issue: Any) -> dict[str, Any]:
    return {"code": issue.code, "message": issue.message,
            "path": str(issue.path) if issue.path is not None else None,
            "item_id": str(issue.item_id) if issue.item_id is not None else None}


def _project_operation_error(error: Any) -> dict[str, Any] | None:
    if error is None:
        return None
    return {"code": error.code, "message": error.message, "exception_type": error.exception_type,
            "errno": error.errno, "winerror": error.winerror,
            "path": str(error.path) if error.path is not None else None}


def _project_plan_item(item: Any) -> dict[str, Any]:
    context = item.context_resolution.context if item.context_resolution is not None else None
    return {
        "status": item.status.value,
        "destination_path": str(item.destination_path) if item.destination_path is not None else None,
        "issue_codes": [issue.code for issue in item.issues],
        "issues": [_project_issue(issue) for issue in item.issues],
        "warnings": list(item.warnings), "errors": list(item.errors),
        "metadata": {
            "raw": asdict(item.metadata) if item.metadata is not None else None,
            "effective": asdict(item.effective_metadata) if item.effective_metadata is not None else None,
            "derived": asdict(context.derived) if context is not None else None,
            "transformations": [asdict(value) for value in item.transformations],
        },
    }


def _project_preflight(result: Any) -> dict[str, Any]:
    return {"is_valid": result.is_valid, "issues": [_project_issue(issue) for issue in result.issues]}


def _project_execution(result: Any) -> dict[str, Any]:
    operations = [{
        "item_id": str(operation.item_id),
        "source_path": str(operation.source_path),
        "temporary_path": str(operation.temporary_path) if operation.temporary_path is not None else None,
        "destination_path": str(operation.destination_path) if operation.destination_path is not None else None,
        "forward_state": operation.forward_state.value,
        "forward_error": _project_operation_error(operation.forward_error),
        "rollback_state": operation.rollback_state.value,
        "rollback_error": _project_operation_error(operation.rollback_error),
        "final_location": operation.final_location.value,
        "final_path": str(operation.final_path) if operation.final_path is not None else None,
    } for operation in result.operations]
    return {"transaction_id": str(result.transaction_id), "plan_id": str(result.plan_id),
            "outcome": result.outcome.value,
            "preflight_issues": [_project_issue(issue) for issue in result.preflight_issues],
            "operations": operations}


def _classification(core: Any, execution: Any) -> str:
    if execution.outcome is core.TransactionOutcome.FAILED_ROLLBACK_INCOMPLETE:
        return "requires_attention"
    if any(operation.final_location in {core.FinalLocation.MISSING, core.FinalLocation.UNKNOWN} for operation in execution.operations):
        return "requires_attention"
    if execution.outcome is core.TransactionOutcome.SUCCEEDED:
        return "renamed"
    if execution.outcome is core.TransactionOutcome.NO_OP:
        return "unchanged"
    if execution.outcome is core.TransactionOutcome.PREFLIGHT_REJECTED:
        return "rejected"
    return "failed"


def _domain_response(correlation_id: str, *, classification: str,
                     original_path: str | None, planning: dict[str, Any],
                     preflight_result: dict[str, Any] | None = None,
                     execution_result: dict[str, Any] | None = None,
                     rejection_reason: str | None = None) -> dict[str, Any]:
    operation = execution_result["operations"][0] if execution_result is not None and execution_result["operations"] else None
    return {
        "protocol_version": PROTOCOL_VERSION, "correlation_id": correlation_id,
        "operation": "rename", "adapter_status": "completed", "classification": classification,
        "path": {"original_path": original_path, "destination_path": planning.get("destination_path"),
                 "verified_final_path": operation["final_path"] if operation is not None else None,
                 "final_location": operation["final_location"] if operation is not None else None},
        "planning": planning, "preflight": preflight_result, "execution": execution_result,
        "rejection_reason": rejection_reason, "error": None,
    }


def _rejected_response(correlation_id: str, original_path: str | None,
                       issues: list[dict[str, Any]]) -> dict[str, Any]:
    return _domain_response(
        correlation_id, classification="rejected", original_path=original_path,
        planning={"status": "error", "destination_path": None,
                  "issue_codes": [str(issue["code"]) for issue in issues], "issues": issues,
                  "warnings": [], "errors": [str(issue["message"]) for issue in issues],
                  "metadata": {"raw": None, "effective": None, "derived": None, "transformations": []}},
        rejection_reason=str(issues[0]["code"]) if issues else "rejected",
    )


def _rename_response(correlation_id: str, request: dict[str, Any], core: Any,
                     safety=None) -> dict[str, Any]:
    source_text = request.get("source_path")
    original_path = source_text if isinstance(source_text, str) else None
    try:
        normalizer, resolver, template, warning_acknowledged = _translate_config(core, request)
        source = _validate_source(request)
    except DomainRejection as exc:
        return _rejected_response(correlation_id, original_path, exc.issues)
    plan = core.RenamePlanner(template=template, reader=core.MutagenMetadataReader(),
                              normalizer=normalizer, context_resolver=resolver).plan([source])
    item = plan.items[0]
    planning = _project_plan_item(item)
    preflight_result = core.preflight(plan)
    projected_preflight = _project_preflight(preflight_result)
    if item.status is core.RenameStatus.ERROR:
        return _domain_response(correlation_id, classification="rejected", original_path=str(source),
                                planning=planning, preflight_result=projected_preflight,
                                rejection_reason="planning_error")
    if not preflight_result.is_valid:
        return _domain_response(correlation_id, classification="rejected", original_path=str(source),
                                planning=planning, preflight_result=projected_preflight,
                                rejection_reason="preflight_rejected")
    if item.status is core.RenameStatus.WARNING and not warning_acknowledged:
        return _domain_response(correlation_id, classification="rejected", original_path=str(source),
                                planning=planning, preflight_result=projected_preflight,
                                rejection_reason="warning_not_acknowledged")
    # Acquire BEFORE inspecting stop signals. Parent timeout acquires the same
    # mutex before killing, eliminating a check-then-execute race. Keep ownership
    # through final JSON flushing (main), not merely until execute returns.
    if safety is not None:
        safety['gate'].__enter__()
        if _safety.requested(safety['cancel'], safety['job_cancel']):
            response = _rejected_response(correlation_id, str(source), [_domain_issue('operation_cancelled', 'Cancelled before execution')])
            response['classification'] = 'cancelled'
            response['cancellation'] = {'cancel_requested': True, 'mutation_started': False}
            return response
        safety['mutation_started'] = True
    execution = core.RenameExecutor().execute(plan, allow_warnings=warning_acknowledged)
    projected_execution = _project_execution(execution)
    response = _domain_response(correlation_id, classification=_classification(core, execution),
                            original_path=str(source), planning=planning,
                            preflight_result=projected_preflight,
                            execution_result=projected_execution)
    if safety is not None:
        response['cancellation'] = {'cancel_requested': _safety.requested(safety['cancel'], safety['job_cancel']), 'mutation_started': True}
    return response


def _error_response(correlation_id: str | None, operation: str | None,
                    code: str, summary: str) -> dict[str, Any]:
    return {
        "protocol_version": PROTOCOL_VERSION, "correlation_id": correlation_id,
        "operation": operation, "adapter_status": "error",
        "runtime_health": {"status": "unhealthy"},
        "core_health": {"status": "unknown", "pyside6_loaded": "PySide6" in sys.modules},
        "error": {"code": code, "summary": summary},
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument('--mutation-gate', default='')
    parser.add_argument('--cancel-file', default='')
    parser.add_argument('--job-cancel-file', default='')
    args = parser.parse_args()
    correlation_id: str | None = None
    operation: str | None = None
    try:
        safety = {'gate': _safety.Gate(args.mutation_gate), 'cancel': args.cancel_file,
                  'job_cancel': args.job_cancel_file, 'mutation_started': False}
        request = _load_json_object(sys.stdin.read(), code="invalid_request", label="request")
        if isinstance(request.get("correlation_id"), str):
            correlation_id = request["correlation_id"]
        if isinstance(request.get("operation"), str):
            operation = request["operation"]
        correlation_id, operation = _validate_request(request)
        if operation == "health":
            _validate_health_config(request)
        try:
            manifest_text = Path(args.manifest).read_text(encoding="utf-8")
        except OSError as exc:
            raise AdapterFailure("manifest_unavailable", f"runtime manifest could not be read: {exc}") from exc
        manifest = _load_json_object(manifest_text, code="invalid_manifest", label="runtime manifest")
        core, identity = _load_core(manifest)
        response = (_health_response(correlation_id, identity) if operation == "health"
                    else _rename_response(correlation_id, request, core, safety))
    except AdapterFailure as exc:
        print(f"Music Renamer adapter: {exc.summary}", file=sys.stderr)
        print(json.dumps(_error_response(correlation_id, operation, exc.code, exc.summary), ensure_ascii=False, separators=(",", ":")))
        return 2
    except Exception as exc:
        summary = f"unexpected adapter failure: {type(exc).__name__}: {exc}"
        print(f"Music Renamer adapter: {summary}", file=sys.stderr)
        print(json.dumps(_error_response(correlation_id, operation, "adapter_internal_error", summary), ensure_ascii=False, separators=(",", ":")))
        return 3
    print(json.dumps(response, ensure_ascii=False, separators=(",", ":")), flush=True)
    # OS releases the mutation mutex at normal process exit, after stdout flush.
    # A parent never kills between the truthful result and process exit.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
