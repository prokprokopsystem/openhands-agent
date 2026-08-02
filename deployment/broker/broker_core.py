#!/usr/bin/python3
"""OpenHands Broker Core v2, protocol version 1."""

from __future__ import annotations

import json
import os
import re
import selectors
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any


PROTOCOL_VERSION = 1
MAX_REQUEST_BYTES = 16 * 1024
MAX_RESPONSE_BYTES = 64 * 1024
SAFE_ENV = {
    "PATH": "/usr/bin:/bin",
    "HOME": "/nonexistent",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
}
NAME_RE = re.compile(r"^[a-z][a-z0-9_.-]{0,63}$")


class BrokerError(Exception):
    def __init__(self, code: str, message: str, *, status: str = "rejected") -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = status


class DuplicateKeyError(ValueError):
    pass


class NonFiniteNumberError(ValueError):
    pass


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_non_finite(value: str) -> None:
    raise NonFiniteNumberError(f"non-finite JSON number: {value}")


def decode_json_object(raw: bytes, limit: int, label: str) -> dict[str, Any]:
    if not raw:
        raise BrokerError(f"invalid_{label}", f"{label} is empty")
    if len(raw) > limit:
        raise BrokerError(f"{label}_too_large", f"{label} exceeds {limit} bytes")
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise BrokerError(f"invalid_{label}", f"{label} is not valid UTF-8") from exc
    try:
        value = json.loads(
            text,
            object_pairs_hook=_unique_object,
            parse_constant=_reject_non_finite,
        )
    except ValueError as exc:
        raise BrokerError(f"invalid_{label}", f"{label} is not one JSON object") from exc
    if not isinstance(value, dict):
        raise BrokerError(f"invalid_{label}", f"{label} must be a JSON object")
    return value


def compact_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


@dataclass(frozen=True)
class Tool:
    name: str
    target: str
    adapter: str
    operation: str
    risk: str
    params: dict[str, dict[str, Any]]
    timeout_seconds: int
    max_output_bytes: int


class Registry:
    DOCUMENT_FIELDS = {"version", "tools"}
    TOOL_FIELDS = {
        "name",
        "target",
        "adapter",
        "operation",
        "risk",
        "params",
        "timeout_seconds",
        "max_output_bytes",
    }
    PARAM_FIELDS = {"type", "required", "enum", "min", "max", "max_length"}
    PARAM_TYPES = {"string", "integer", "boolean"}

    def __init__(self, tools: dict[str, Tool]) -> None:
        self.tools = tools

    @classmethod
    def load(cls, directory: Path) -> "Registry":
        tools: dict[str, Tool] = {}
        paths = sorted(directory.glob("*.yaml"))
        if not paths:
            raise BrokerError("registry_invalid", "registry contains no YAML files", status="error")
        for path in paths:
            try:
                raw = path.read_bytes()
            except OSError as exc:
                raise BrokerError("registry_invalid", "registry file cannot be read", status="error") from exc
            document = decode_json_object(raw, MAX_REQUEST_BYTES, "registry_document")
            cls._exact_fields(document, cls.DOCUMENT_FIELDS, "registry document")
            if type(document.get("version")) is not int or document["version"] != PROTOCOL_VERSION or not isinstance(document.get("tools"), list):
                raise BrokerError("registry_invalid", "invalid registry version or tools list", status="error")
            for value in document["tools"]:
                tool = cls._parse_tool(value)
                if tool.name in tools:
                    raise BrokerError("registry_invalid", "duplicate tool name", status="error")
                tools[tool.name] = tool
        return cls(tools)

    @staticmethod
    def _exact_fields(value: dict[str, Any], expected: set[str], label: str) -> None:
        if set(value) != expected:
            raise BrokerError("registry_invalid", f"{label} has missing or unknown fields", status="error")

    @classmethod
    def _parse_tool(cls, value: Any) -> Tool:
        if not isinstance(value, dict):
            raise BrokerError("registry_invalid", "tool entry must be an object", status="error")
        cls._exact_fields(value, cls.TOOL_FIELDS, "tool entry")
        for field in ("name", "target", "adapter", "operation"):
            if not isinstance(value[field], str) or not NAME_RE.fullmatch(value[field]):
                raise BrokerError("registry_invalid", f"invalid tool {field}", status="error")
        if not isinstance(value["risk"], str) or value["risk"] not in {"A", "B", "C"}:
            raise BrokerError("registry_invalid", "invalid risk level", status="error")
        if not isinstance(value["timeout_seconds"], int) or isinstance(value["timeout_seconds"], bool) or not 1 <= value["timeout_seconds"] <= 300:
            raise BrokerError("registry_invalid", "invalid tool timeout", status="error")
        if not isinstance(value["max_output_bytes"], int) or isinstance(value["max_output_bytes"], bool) or not 256 <= value["max_output_bytes"] <= MAX_RESPONSE_BYTES:
            raise BrokerError("registry_invalid", "invalid tool output limit", status="error")
        params = value["params"]
        if not isinstance(params, dict):
            raise BrokerError("registry_invalid", "tool params must be an object", status="error")
        for name, spec in params.items():
            if not isinstance(name, str) or not NAME_RE.fullmatch(name) or not isinstance(spec, dict):
                raise BrokerError("registry_invalid", "invalid parameter definition", status="error")
            if not set(spec).issubset(cls.PARAM_FIELDS) or "type" not in spec:
                raise BrokerError("registry_invalid", "invalid parameter fields", status="error")
            if spec["type"] not in cls.PARAM_TYPES or not isinstance(spec.get("required", False), bool):
                raise BrokerError("registry_invalid", "invalid parameter type", status="error")
            cls._validate_param_constraints(spec)
        return Tool(**value)

    @classmethod
    def _validate_param_constraints(cls, spec: dict[str, Any]) -> None:
        kind = spec["type"]
        if "enum" in spec:
            enum = spec["enum"]
            if not isinstance(enum, list) or not enum:
                raise BrokerError("registry_invalid", "parameter enum must be a non-empty list", status="error")
            for value in enum:
                if not cls._matches_type(kind, value):
                    raise BrokerError("registry_invalid", "parameter enum has an invalid value", status="error")
        if "max_length" in spec:
            value = spec["max_length"]
            if kind != "string" or not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise BrokerError("registry_invalid", "invalid max_length constraint", status="error")
        for field in ("min", "max"):
            if field in spec:
                value = spec[field]
                if kind != "integer" or not isinstance(value, int) or isinstance(value, bool):
                    raise BrokerError("registry_invalid", f"invalid {field} constraint", status="error")
        if "min" in spec and "max" in spec and spec["min"] > spec["max"]:
            raise BrokerError("registry_invalid", "parameter min exceeds max", status="error")

    @staticmethod
    def _matches_type(kind: str, value: Any) -> bool:
        return (
            (kind == "string" and isinstance(value, str))
            or (kind == "integer" and isinstance(value, int) and not isinstance(value, bool))
            or (kind == "boolean" and isinstance(value, bool))
        )

    def canonical_params(self, tool: Tool, supplied: dict[str, Any]) -> dict[str, Any]:
        unknown = set(supplied) - set(tool.params)
        if unknown:
            raise BrokerError("invalid_params", "request contains unknown parameters")
        canonical: dict[str, Any] = {}
        for name, spec in tool.params.items():
            if name not in supplied:
                if spec.get("required", False):
                    raise BrokerError("invalid_params", f"required parameter is missing: {name}")
                continue
            value = supplied[name]
            kind = spec["type"]
            if not self._matches_type(kind, value):
                raise BrokerError("invalid_params", f"invalid parameter type: {name}")
            if "enum" in spec and value not in spec["enum"]:
                raise BrokerError("invalid_params", f"parameter is outside enum: {name}")
            if kind == "string" and "max_length" in spec and len(value) > spec["max_length"]:
                raise BrokerError("invalid_params", f"parameter is too long: {name}")
            if kind == "integer" and "min" in spec and value < spec["min"]:
                raise BrokerError("invalid_params", f"parameter is below minimum: {name}")
            if kind == "integer" and "max" in spec and value > spec["max"]:
                raise BrokerError("invalid_params", f"parameter is above maximum: {name}")
            canonical[name] = value
        return canonical


class LoggerAudit:
    def write(self, event: dict[str, Any]) -> None:
        record = compact_json(event).decode("utf-8")
        try:
            completed = subprocess.run(
                ["/usr/bin/logger", "--tag", "openhands-broker", "--", record],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=SAFE_ENV,
                timeout=2,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise BrokerError("audit_unavailable", "mandatory audit is unavailable", status="error") from exc
        if completed.returncode != 0:
            raise BrokerError("audit_unavailable", "mandatory audit is unavailable", status="error")


class AdapterRunner:
    RESPONSE_FIELDS = {"status", "result", "result_code", "verify", "rollback"}
    RESULT_STATUSES = {"not_applicable", "not_run", "passed", "failed", "available", "succeeded"}

    def __init__(self, root: Path) -> None:
        self.executables = {"core": root / "adapters" / "core-adapter"}

    def execute(self, tool: Tool, request: dict[str, Any]) -> dict[str, Any]:
        executable = self.executables.get(tool.adapter)
        if executable is None:
            raise BrokerError("adapter_unavailable", "adapter is not installed", status="error")
        payload = compact_json(request)
        if len(payload) > MAX_REQUEST_BYTES:
            raise BrokerError("adapter_request_too_large", "adapter request exceeds limit", status="error")
        try:
            process = subprocess.Popen(
                [str(executable)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                env=SAFE_ENV,
            )
        except OSError as exc:
            raise BrokerError("adapter_unavailable", "adapter could not start", status="error") from exc
        stdout = self._communicate_bounded(process, payload, tool.timeout_seconds, tool.max_output_bytes)
        response = decode_json_object(stdout, tool.max_output_bytes, "adapter_response")
        if process.returncode != 0:
            raise BrokerError("adapter_failed", "adapter rejected the operation", status="error")
        if set(response) != self.RESPONSE_FIELDS or response.get("status") != "ok":
            raise BrokerError("adapter_failed", "adapter returned an invalid success response", status="error")
        if not isinstance(response["result_code"], str) or not NAME_RE.fullmatch(response["result_code"]):
            raise BrokerError("adapter_failed", "adapter returned an invalid result code", status="error")
        for field in ("verify", "rollback"):
            detail = response[field]
            if not isinstance(detail, dict) or set(detail) != {"status"} or detail["status"] not in self.RESULT_STATUSES:
                raise BrokerError("adapter_failed", f"adapter returned an invalid {field} result", status="error")
        if tool.risk == "A" and (
            response["verify"]["status"] != "not_applicable"
            or response["rollback"]["status"] != "not_applicable"
        ):
            raise BrokerError("adapter_failed", "Level A adapter returned state-change metadata", status="error")
        return response

    @staticmethod
    def _communicate_bounded(
        process: subprocess.Popen[bytes], payload: bytes, timeout_seconds: int, output_limit: int
    ) -> bytes:
        assert process.stdin is not None and process.stdout is not None
        try:
            process.stdin.write(payload)
            process.stdin.close()
        except BrokenPipeError:
            pass
        deadline = time.monotonic() + timeout_seconds
        output = bytearray()
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    process.kill()
                    process.wait()
                    raise BrokerError("adapter_timeout", "adapter timed out", status="error")
                ready = selector.select(remaining)
                if not ready:
                    process.kill()
                    process.wait()
                    raise BrokerError("adapter_timeout", "adapter timed out", status="error")
                chunk = os.read(process.stdout.fileno(), min(4096, output_limit + 1 - len(output)))
                if not chunk:
                    break
                output.extend(chunk)
                if len(output) > output_limit:
                    process.kill()
                    process.wait()
                    raise BrokerError("adapter_output_too_large", "adapter output exceeds limit", status="error")
            remaining = deadline - time.monotonic()
            try:
                process.wait(timeout=max(remaining, 0.001))
            except subprocess.TimeoutExpired as exc:
                process.kill()
                process.wait()
                raise BrokerError("adapter_timeout", "adapter timed out", status="error") from exc
            return bytes(output)
        finally:
            selector.close()
            process.stdout.close()


class BrokerApp:
    REQUEST_FIELDS = {"version", "request_id", "tool", "params", "approval_id"}

    def __init__(self, registry: Registry, audit: Any, runner: Any) -> None:
        self.registry = registry
        self.audit = audit
        self.runner = runner

    def handle(self, raw: bytes) -> dict[str, Any]:
        request = decode_json_object(raw, MAX_REQUEST_BYTES, "request")
        unknown = set(request) - self.REQUEST_FIELDS
        required = {"version", "request_id", "tool", "params"}
        if unknown or not required.issubset(request):
            raise BrokerError("invalid_request", "request has missing or unknown fields")
        if type(request["version"]) is not int or request["version"] != PROTOCOL_VERSION:
            raise BrokerError("unsupported_version", "unsupported protocol version")
        try:
            request_uuid = str(uuid.UUID(request["request_id"]))
        except (ValueError, TypeError, AttributeError) as exc:
            raise BrokerError("invalid_request_id", "request_id must be a canonical UUID") from exc
        if request_uuid != request["request_id"]:
            raise BrokerError("invalid_request_id", "request_id must be a canonical UUID")
        if not isinstance(request["tool"], str) or not isinstance(request["params"], dict):
            raise BrokerError("invalid_request", "tool and params have invalid types")
        tool = self.registry.tools.get(request["tool"])
        if tool is None:
            raise BrokerError("unknown_tool", "tool is not registered")
        approval_id = request.get("approval_id")
        if tool.risk in {"A", "B"} and approval_id is not None:
            raise BrokerError("unexpected_approval", "approval_id is forbidden for this risk level")
        if tool.risk == "B":
            raise BrokerError("level_b_disabled", "Level B is disabled until 4D.6")
        if tool.risk == "C":
            raise BrokerError("level_c_disabled", "Level C is disabled in 4D.1")
        params = self.registry.canonical_params(tool, request["params"])
        descriptor = {
            "protocol_version": PROTOCOL_VERSION,
            "target": tool.target,
            "tool": tool.name,
            "adapter": tool.adapter,
            "operation": tool.operation,
            "canonical_params": params,
        }
        started = time.monotonic()
        audit_base = {
            "request_id": request_uuid,
            "descriptor": descriptor,
            "risk": tool.risk,
        }
        self.audit.write(
            {
                **audit_base,
                "event": "STARTED",
                "status": "started",
                "duration_ms": 0,
                "result_code": "pending",
                "verify_status": "not_run",
                "rollback_status": "not_run",
            }
        )
        adapter_request = {
            "version": PROTOCOL_VERSION,
            "request_id": request_uuid,
            "target": tool.target,
            "operation": tool.operation,
            "params": params,
        }
        try:
            outcome = self.runner.execute(tool, adapter_request)
        except BrokerError as exc:
            self.audit.write(
                {
                    **audit_base,
                    "event": "FAILED",
                    "status": "error",
                    "duration_ms": max(0, round((time.monotonic() - started) * 1000)),
                    "result_code": exc.code,
                    "verify_status": "not_run",
                    "rollback_status": "not_run",
                }
            )
            raise
        self.audit.write(
            {
                **audit_base,
                "event": "SUCCEEDED",
                "status": "ok",
                "duration_ms": max(0, round((time.monotonic() - started) * 1000)),
                "result_code": outcome["result_code"],
                "verify_status": outcome["verify"]["status"],
                "rollback_status": outcome["rollback"]["status"],
            }
        )
        return {
            "version": PROTOCOL_VERSION,
            "request_id": request_uuid,
            "status": "ok",
            "result": outcome["result"],
        }


def error_response(error: BrokerError, request_id: str | None = None) -> dict[str, Any]:
    return {
        "version": PROTOCOL_VERSION,
        "request_id": request_id,
        "status": error.status,
        "error": {"code": error.code, "message": error.message},
    }


def emit(response: dict[str, Any]) -> None:
    raw = compact_json(response)
    if len(raw) > MAX_RESPONSE_BYTES:
        raw = compact_json(error_response(BrokerError("response_too_large", "response exceeds limit", status="error")))
    sys.stdout.buffer.write(raw + b"\n")
    sys.stdout.buffer.flush()


def main() -> int:
    if len(sys.argv) != 1:
        emit(error_response(BrokerError("arguments_forbidden", "broker accepts no command-line arguments")))
        return 2
    root = Path(__file__).resolve().parent
    raw = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    try:
        registry = Registry.load(root / "tools.d")
        response = BrokerApp(registry, LoggerAudit(), AdapterRunner(root)).handle(raw)
    except BrokerError as exc:
        emit(error_response(exc))
        return 2
    except Exception:
        emit(error_response(BrokerError("internal_error", "internal broker error", status="error")))
        return 3
    emit(response)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
