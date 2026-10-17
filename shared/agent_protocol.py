"""The common Agent wire contract; no authority is granted by a valid payload."""
from __future__ import annotations

import json
import math
import re
import unicodedata
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).with_suffix("")
SCHEMA = json.loads((ROOT / "schema.json").read_text())
DEFINITIONS = SCHEMA["$defs"]


class ProtocolError(ValueError):
    pass


def validate(name: str, value: object) -> object:
    if name not in DEFINITIONS:
        raise ProtocolError("unknown_contract")
    _check(DEFINITIONS[name], value, "$")
    _semantics(name, value)
    return value


def decode(name: str, raw: bytes | str) -> object:
    """Strict UTF-8 wire boundary; duplicate normalized keys are ambiguous."""
    try:
        data = raw.encode("utf-8") if isinstance(raw, str) else raw
        if len(data) > 1_048_576:
            raise ProtocolError("payload_too_large")
        def unique(pairs):
            seen, result = set(), {}
            for key, value in pairs:
                normalized = unicodedata.normalize("NFC", key)
                if normalized in seen:
                    raise ProtocolError("duplicate_json_key")
                seen.add(normalized)
                result[key] = value
            return result
        def constant(_):
            raise ProtocolError("invalid_json_number")
        value = json.loads(data.decode("utf-8"), object_pairs_hook=unique, parse_constant=constant)
        _json(value, "$", 0)
        return validate(name, value)
    except (UnicodeError, json.JSONDecodeError, RecursionError):
        raise ProtocolError("invalid_json_encoding") from None


def _string(value: str, path: str) -> None:
    if any(0xD800 <= ord(char) <= 0xDFFF for char in value):
        raise ProtocolError(f"{path}:invalid_unicode")


def _check(schema: dict, value: object, path: str) -> None:
    if "$ref" in schema:
        _check(DEFINITIONS[schema["$ref"].removeprefix("#/$defs/")], value, path)
        return
    if "anyOf" in schema:
        for option in schema["anyOf"]:
            try:
                _check(option, value, path)
                return
            except ProtocolError:
                pass
        raise ProtocolError(f"{path}:type")
    if "const" in schema and value != schema["const"]:
        raise ProtocolError(f"{path}:const")
    if "enum" in schema and value not in schema["enum"]:
        raise ProtocolError(f"{path}:enum")
    kind = schema.get("type")
    if kind == "null" and value is not None:
        raise ProtocolError(f"{path}:null")
    if kind == "boolean" and type(value) is not bool:
        raise ProtocolError(f"{path}:boolean")
    if kind == "integer":
        if type(value) not in (int, float) or not schema.get("minimum", -math.inf) <= value <= schema.get("maximum", math.inf) or type(value) is float and (not math.isfinite(value) or not value.is_integer()):
            raise ProtocolError(f"{path}:integer")
    if kind == "string":
        if not isinstance(value, str) or not schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", math.inf):
            raise ProtocolError(f"{path}:string")
        _string(value, path)
        if "pattern" in schema and not re.fullmatch(schema["pattern"], value):
            raise ProtocolError(f"{path}:pattern")
        if schema.get("format") == "date-time":
            try:
                if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)", value):
                    raise ValueError()
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    raise ValueError()
            except ValueError:
                raise ProtocolError(f"{path}:date-time") from None
    if kind == "array":
        if not isinstance(value, list) or len(value) > schema.get("maxItems", math.inf):
            raise ProtocolError(f"{path}:array")
        for index, item in enumerate(value):
            _check(schema["items"], item, f"{path}[{index}]")
    if kind == "object":
        if not isinstance(value, dict) or any(not isinstance(k, str) for k in value):
            raise ProtocolError(f"{path}:object")
        properties = schema.get("properties", {})
        if any(key not in value for key in schema.get("required", [])):
            raise ProtocolError(f"{path}:required")
        if schema.get("additionalProperties") is False and set(value) - set(properties):
            raise ProtocolError(f"{path}:unknown_field")
        for key, item in value.items():
            _string(key, path)
            if key in properties:
                _check(properties[key], item, f"{path}.{key}")
            else:
                _json(item, f"{path}.{key}")


def _json(value: object, path: str, depth: int = 0) -> None:
    if depth > 64:
        raise ProtocolError("json_depth_exceeded")
    if type(value) is str:
        _string(value, path)
        return
    if value is None or type(value) is bool:
        return
    if type(value) in (int, float):
        if type(value) is int and abs(value) > 9007199254740991 or type(value) is float and (not math.isfinite(value) or value.is_integer() and abs(value) > 9007199254740991):
            raise ProtocolError(f"{path}:unsafe_number")
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _json(item, f"{path}[{index}]", depth + 1)
        return
    if isinstance(value, dict) and all(isinstance(k, str) for k in value):
        for key, item in value.items():
            _string(key, path)
            _json(item, f"{path}.{key}", depth + 1)
        return
    raise ProtocolError(f"{path}:invalid_json")


def _semantics(name: str, value: object) -> None:
    if not isinstance(value, dict):
        return
    authority = value if name == "Authority" else value.get("authority")
    if authority is not None:
        if (authority["phase"] == "backend") != (authority["epoch"] > 0):
            raise ProtocolError("authority_epoch_mismatch")
    if name == "SourceSnapshot" and value["deleted"] and (value["text"] or value["attributes"]):
        raise ProtocolError("tombstone_contains_content")
    if name in ("ExecutionRequest", "ExecutionReceipt", "CommandEnvelope", "CommandReceipt", "ContentReadRequest", "ContentQueryRequest", "ContentValidateRequest", "CommandReceiptReadRequest") and authority["phase"] != "backend":
        raise ProtocolError("backend_authority_required")
    target = value if name == "CommandTarget" else value.get("target")
    if target is not None:
        if target["kind"] == "source":
            if target["source"] is None or target["entity_id"] is not None:
                raise ProtocolError("invalid_command_target")
        elif target["source"] is not None or target["entity_id"] is None:
            raise ProtocolError("invalid_command_target")
    if name == "CommandReceipt":
        if value["state"] == "accepted" and (value["applied_revision"] is None or value["error"] is not None):
            raise ProtocolError("accepted_revision_required")
        if value["state"] != "accepted" and value["error"] is None:
            raise ProtocolError("command_error_required")
    if name == "ExecutionReceipt":
        state, error = value["state"], value["error"]
        if state in ("failed", "unknown") and error is None:
            raise ProtocolError("execution_error_required")
        if state == "unknown" and error["retryable"]:
            raise ProtocolError("unknown_result_cannot_auto_retry")
        if state == "succeeded" and (error is not None or value["result"] is None and value["operation_id"] is None):
            raise ProtocolError("success_requires_receipt")


def canonical(value: object) -> bytes:
    """UTF-8 canonical bytes for the portable archive, distinct from M6 hashes."""
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
