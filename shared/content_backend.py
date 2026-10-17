"""Private Mac text authority. Legacy archives are immutable recovery evidence.

Only source commands are implemented here. Attribution and voiceprint writes
require their dedicated semantics and cannot pass through arbitrary payloads.
"""
from __future__ import annotations

import copy
import hashlib
import json
import sqlite3
from contextlib import closing, contextmanager
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

from shared.agent_protocol import canonical, decode, validate
from shared.content_migration import ContentStage, backup_sqlite, digest, file_digest, private_file, producer_semantics, read_db, verify_export

MAX_REVISION = 9_007_199_254_740_991
TABLES = {"content_meta", "content_sources", "content_events", "content_commands", "content_transitions"}
FIELDS = {
    "content_meta": ["singleton", "owner_id", "status", "epoch", "library_id", "baseline_json"],
    "content_sources": ["source_key", "snapshot_json", "provenance_json", "updated_seq"],
    "content_events": ["seq", "kind", "source_key", "request_id", "actor_id", "created_at", "payload_json"],
    "content_commands": ["request_id", "actor_id", "fingerprint", "epoch", "receipt_json"],
    "content_transitions": ["request_id", "actor_id", "fingerprint", "receipt_json"],
}
DDL = """
CREATE TABLE content_meta (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1), owner_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('prepared','active','suspended')),
  epoch INTEGER NOT NULL, library_id TEXT NOT NULL, baseline_json TEXT NOT NULL);
CREATE TABLE content_events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, source_key TEXT,
  request_id TEXT, actor_id TEXT NOT NULL, created_at TEXT NOT NULL, payload_json TEXT NOT NULL);
CREATE TABLE content_sources (
  source_key TEXT PRIMARY KEY, snapshot_json TEXT NOT NULL, provenance_json TEXT NOT NULL,
  updated_seq INTEGER NOT NULL REFERENCES content_events(seq));
CREATE TABLE content_commands (
  request_id TEXT PRIMARY KEY, actor_id TEXT NOT NULL, fingerprint TEXT NOT NULL,
  epoch INTEGER NOT NULL, receipt_json TEXT NOT NULL);
CREATE TABLE content_transitions (
  request_id TEXT PRIMARY KEY, actor_id TEXT NOT NULL, fingerprint TEXT NOT NULL,
  receipt_json TEXT NOT NULL);
PRAGMA user_version=1;
"""


class ContentError(ValueError):
    def __init__(self, code: str, status: int = 400):
        self.code, self.status = code, status
        super().__init__(code)


def now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def source_key(source: dict) -> str:
    return canonical(validate("SourceRef", source)).decode()


def content_fingerprint(snapshot: dict) -> str:
    return digest({key: snapshot[key] for key in ("semantics", "captured_at", "deleted", "text", "attributes")} | {"source": snapshot["snapshot"]["source"]})


def canonical_source(original: dict, revision: int, epoch: int) -> dict:
    value = copy.deepcopy(original)
    value["authority"] = {"domain": "content", "phase": "backend", "epoch": epoch}
    value["snapshot"]["revision"] = revision
    value["snapshot"]["fingerprint"] = content_fingerprint(value)
    decode("SourceSnapshot", canonical(value))
    return value


def mac_input_snapshots(path: Path):
    """Read a closed online backup of M6, preserving its producer hash as evidence."""
    with closing(read_db(path)) as db:
        db.row_factory = sqlite3.Row
        expected = ["device_id", "record_id", "revision", "payload", "fingerprint", "text", "created", "deleted", "received_at"]
        if [r[1] for r in db.execute("PRAGMA table_info(input_memory_sources)")] != expected or db.execute("PRAGMA integrity_check").fetchone()[0] != "ok" or db.execute("PRAGMA foreign_key_check").fetchall():
            raise ContentError("incompatible_mac_input_backup")
        for row in db.execute("SELECT * FROM input_memory_sources ORDER BY device_id,record_id"):
            if hashlib.sha256(row["payload"].encode()).hexdigest() != row["fingerprint"]:
                raise ContentError("mac_input_producer_fingerprint_changed")
            record = json.loads(row["payload"])
            if record["device_id"].lower() != row["device_id"] or record["id"].lower() != row["record_id"] or record["revision"] != row["revision"] or type(record["deleted"]) is not bool or int(record["deleted"]) != row["deleted"] or record["text"] != row["text"]:
                raise ContentError("mac_input_producer_identity_mismatch")
            deleted = record["deleted"]
            value = {"schema": "apt.source-snapshot/1", "snapshot": {"source": {"namespace": "input_memory", "library_id": record["device_id"].lower(), "source_id": record["id"].lower()}, "revision": record["revision"], "fingerprint": row["fingerprint"]}, "authority": {"domain": "content", "phase": "staging", "epoch": 0}, "captured_at": record["updated"], "semantics": "input_draft", "deleted": deleted, "text": "" if deleted else record["text"], "attributes": {} if deleted else {k: v for k, v in record.items() if k not in ("text", "event_seq")}}
            validate("SourceSnapshot", value)
            yield value, producer_semantics(record)


def prepare(directory: Path, export: Path, owner_id: str, *, mac_input: Path | None = None) -> dict:
    validate("ID", owner_id)
    manifest = verify_export(export)
    directory.mkdir(parents=True, mode=0o700, exist_ok=False)
    baseline = {"schema": "apt.content-baseline/1", "files": {}, "migration": manifest, "coverage": ["captured_ios_text"], "client_sync": "not_connected"}
    archive = directory / "base-content.sqlite"
    stage = ContentStage(archive)
    try:
        stage.import_snapshot(export)
        selected = {}
        for original, producer in stage.source_inventory(manifest["library_id"]):
            key = source_key(original["snapshot"]["source"])
            selected[key] = (original, [{"kind": "ios_backup", "snapshot": original["snapshot"], "producer_semantics": producer}])
        if mac_input is not None:
            local = directory / "mac-input.sqlite"
            backup_sqlite(mac_input, local)
            for original, producer in mac_input_snapshots(local):
                key = source_key(original["snapshot"]["source"])
                provenance = {"kind": "mac_input_replica", "snapshot": original["snapshot"], "producer_semantics": producer}
                previous = selected.get(key)
                if previous:
                    old, origins = previous
                    if old["snapshot"]["revision"] == original["snapshot"]["revision"]:
                        if origins[0]["producer_semantics"] != producer:
                            raise ContentError("same_producer_version_has_different_content")
                    selected[key] = (original if original["snapshot"]["revision"] >= old["snapshot"]["revision"] else old, [*origins, provenance])
                else:
                    selected[key] = (original, [provenance])
            baseline["coverage"].append("captured_mac_input")
            baseline["files"][local.name] = file_digest(local)
            local.chmod(0o400)
        if len(selected) > 100_000:
            raise ContentError("bootstrap_source_budget_exceeded")
        baseline["archive_rows"] = manifest["rows"]
        baseline["sources"] = len(selected)
    finally:
        stage.close()
    baseline["files"][archive.name] = file_digest(archive)
    archive.chmod(0o400)
    recovery = directory / "legacy-recovery.sqlite"
    backup_sqlite(export / "source-backup.sqlite", recovery)
    baseline["files"][recovery.name] = file_digest(recovery)
    recovery.chmod(0o400)
    path = directory / "content.sqlite"
    private_file(path)
    with closing(sqlite3.connect(path)) as db:
        db.execute("PRAGMA foreign_keys=ON")
        db.executescript(DDL)
        db.execute("BEGIN IMMEDIATE")
        try:
            db.execute("INSERT INTO content_meta VALUES(1,?,'prepared',0,?,?)", (owner_id, manifest["library_id"], canonical(baseline).decode()))
            for key, (original, origins) in selected.items():
                value = canonical_source(original, 1, 1)
                packed = canonical(value).decode()
                event = db.execute("INSERT INTO content_events(kind,source_key,actor_id,created_at,payload_json) VALUES('migration',?,?,?,?)", (key, owner_id, now(), packed)).lastrowid
                db.execute("INSERT INTO content_sources VALUES(?,?,?,?)", (key, packed, canonical(origins).decode(), event))
            db.commit()
        except BaseException:
            db.rollback()
            raise
    backend = ContentBackend(directory)
    try:
        backend.verify_baseline()
        return backend.authority()
    finally:
        backend.close()


class ContentBackend:
    def __init__(self, directory: Path):
        self.directory = directory
        path = directory / "content.sqlite"
        if not path.is_file():
            raise ContentError("content_database_missing", 503)
        self.db = sqlite3.connect("file:" + quote(str(path.resolve())) + "?mode=rw", uri=True, timeout=5)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        tables = {r[0] for r in self.db.execute("SELECT name FROM sqlite_master WHERE type='table' AND substr(name,1,7)<>'sqlite_'")}
        if tables != TABLES or self.db.execute("PRAGMA user_version").fetchone()[0] != 1 or self.db.execute("SELECT 1 FROM sqlite_master WHERE type IN ('trigger','view') LIMIT 1").fetchone() or any([r[1] for r in self.db.execute("PRAGMA table_info(" + table + ")")] != fields for table, fields in FIELDS.items()):
            self.close()
            raise ContentError("incompatible_content_database", 503)
        try:
            self.meta()
        except BaseException:
            self.close()
            raise
        path.chmod(0o600)

    def close(self):
        self.db.close()

    def meta(self):
        row = self.db.execute("SELECT * FROM content_meta WHERE singleton=1").fetchone()
        if row is None:
            raise ContentError("content_not_prepared", 503)
        try:
            validate("ID", row["owner_id"])
            validate("ID", row["library_id"])
            if type(row["epoch"]) is not int or not 0 <= row["epoch"] <= MAX_REVISION or row["status"] not in ("prepared", "active", "suspended") or (row["status"] == "prepared") != (row["epoch"] == 0):
                raise ValueError()
        except ValueError:
            raise ContentError("invalid_stored_content_authority", 503) from None
        return row

    @contextmanager
    def transaction(self, *, writing: bool = False):
        if self.db.in_transaction:
            raise ContentError("nested_content_transaction")
        self.db.execute("BEGIN IMMEDIATE" if writing else "BEGIN")
        try:
            yield
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise

    def verify_baseline(self):
        baseline = json.loads(self.meta()["baseline_json"])
        for name, fingerprint in baseline["files"].items():
            if name not in ("base-content.sqlite", "legacy-recovery.sqlite", "mac-input.sqlite") or file_digest(self.directory / name) != fingerprint:
                raise ContentError("immutable_content_baseline_changed", 503)
        archive = ContentStage(self.directory / "base-content.sqlite", writable=False)
        try:
            if archive.report(self.meta()["library_id"])["rows"] != baseline["archive_rows"]:
                raise ContentError("content_baseline_rows_changed", 503)
        finally:
            archive.close()

    def authority(self):
        row = self.meta()
        authority = {"domain": "content", "phase": "backend" if row["epoch"] else "staging", "epoch": row["epoch"]}
        baseline = json.loads(row["baseline_json"])
        return {"schema": "apt.content-authority/1", "authority": authority, "writer": "mac_content_backend", "status": row["status"], "owner_id": row["owner_id"], "library_id": row["library_id"], "watermark": self.db.execute("SELECT COALESCE(MAX(seq),0) FROM content_events").fetchone()[0], "sources": self.db.execute("SELECT COUNT(*) FROM content_sources").fetchone()[0], "coverage": baseline["coverage"], "client_sync": baseline["client_sync"], "supported_commands": {"manual_text": ["create", "update", "correct", "delete", "restore"], "input_memory": ["update", "correct", "delete", "restore"], "ios_content": []}, "frozen_content_bridge": "not_connected"}

    def check_actor(self, actor: str):
        if actor != self.meta()["owner_id"]:
            raise ContentError("content_owner_mismatch", 403)

    def check_authority(self, authority: dict):
        validate("Authority", authority)
        row = self.meta()
        if row["status"] != "active":
            raise ContentError("content_writer_unavailable", 503)
        if authority != {"domain": "content", "phase": "backend", "epoch": row["epoch"]}:
            raise ContentError("stale_content_authority", 409)

    def transition(self, actor: str, request_id: str, operation: str, expected_epoch: int):
        validate("ID", request_id)
        if type(expected_epoch) is not int or expected_epoch < 0:
            raise ContentError("invalid_expected_epoch")
        with self.transaction(writing=True):
            self.check_actor(actor)
            fingerprint = digest({"actor": actor, "operation": operation, "expected_epoch": expected_epoch})
            previous = self.db.execute("SELECT fingerprint,receipt_json FROM content_transitions WHERE request_id=?", (request_id,)).fetchone()
            if previous:
                if previous["fingerprint"] != fingerprint:
                    raise ContentError("transition_id_reused", 409)
                return json.loads(previous["receipt_json"])
            row = self.meta()
            allowed = {"activate": ("prepared", "active"), "suspend": ("active", "suspended"), "resume": ("suspended", "active")}
            if operation not in allowed or row["status"] != allowed[operation][0] or row["epoch"] != expected_epoch or row["epoch"] >= MAX_REVISION:
                raise ContentError("stale_or_invalid_content_transition", 409)
            if operation in ("activate", "resume"):
                self.verify_baseline()
            # Suspension is the fault fence: a damaged recovery baseline must
            # never prevent an authenticated owner from durably stopping writes.
            epoch, status = row["epoch"] + 1, allowed[operation][1]
            self.db.execute("UPDATE content_meta SET status=?,epoch=? WHERE singleton=1", (status, epoch))
            receipt = {"schema": "apt.content-transition/1", "request_id": request_id, "writer": "mac_content_backend", "status": status, "authority": {"domain": "content", "phase": "backend", "epoch": epoch}, "previous_epoch": expected_epoch, "accepted_at": now(), "client_sync": "not_connected"}
            self.db.execute("INSERT INTO content_transitions VALUES(?,?,?,?)", (request_id, actor, fingerprint, canonical(receipt).decode()))
            self.db.execute("INSERT INTO content_events(kind,request_id,actor_id,created_at,payload_json) VALUES('authority',?,?,?,?)", (request_id, actor, now(), canonical(receipt).decode()))
            return receipt

    def load(self, source: dict):
        row = self.db.execute("SELECT * FROM content_sources WHERE source_key=?", (source_key(source),)).fetchone()
        if row is None:
            raise ContentError("source_unavailable", 404)
        try:
            value = decode("SourceSnapshot", row["snapshot_json"])
        except ValueError:
            raise ContentError("stored_source_changed", 503) from None
        if value["snapshot"]["source"] != source or content_fingerprint(value) != value["snapshot"]["fingerprint"]:
            raise ContentError("stored_source_changed", 503)
        value["authority"] = {"domain": "content", "phase": "backend", "epoch": self.meta()["epoch"]}
        return value

    def read(self, actor: str, request: dict):
        validate("ContentReadRequest", request)
        with self.transaction():
            self.check_actor(actor)
            self.check_authority(request["authority"])
            value = self.load(request["source"])
            if value["deleted"] and not request["include_deleted"]:
                raise ContentError("source_deleted", 410)
            return value

    def query(self, actor: str, request: dict):
        validate("ContentQueryRequest", request)
        with self.transaction():
            self.check_actor(actor)
            self.check_authority(request["authority"])
            found = []
            for row in self.db.execute("SELECT source_key FROM content_sources ORDER BY updated_seq DESC"):
                source = json.loads(row["source_key"])
                if request["namespace"] is not None and source["namespace"] != request["namespace"]:
                    continue
                value = self.load(source)
                if value["deleted"] or request["query"].casefold() not in value["text"].casefold():
                    continue
                found.append(value)
                if len(found) == request["limit"]:
                    break
            state = self.authority()
            return {"schema": "apt.content-query-result/1", "authority": state["authority"], "watermark": state["watermark"], "coverage": state["coverage"], "client_sync": state["client_sync"], "complete": False, "sources": found}

    def validate_sources(self, actor: str, request: dict):
        validate("ContentValidateRequest", request)
        with self.transaction():
            self.check_actor(actor)
            self.check_authority(request["authority"])
            checked = []
            for reference in request["snapshots"]:
                try:
                    current = self.load(reference["source"])
                    state = "deleted" if current["deleted"] else "current" if current["snapshot"] == reference else "stale"
                except ContentError as error:
                    if error.code != "source_unavailable":
                        raise
                    state = "unavailable"
                checked.append({"snapshot": reference, "state": state})
            return {"schema": "apt.content-validation/1", "authority": self.authority()["authority"], "current": all(c["state"] == "current" for c in checked), "sources": checked}

    def command(self, actor: str, command: dict):
        validate("CommandEnvelope", command)
        command = copy.deepcopy(command)
        command["expected_revision"] = int(command["expected_revision"])
        command["authority"]["epoch"] = int(command["authority"]["epoch"])
        with self.transaction(writing=True):
            self.check_actor(actor)
            try:
                self.check_authority(command["authority"])
            except ContentError as error:
                if self.meta()["epoch"] == 0:
                    raise
                receipt = {"schema": "apt.command-receipt/1", "request_id": command["request_id"], "authority": self.authority()["authority"], "target": command["target"], "state": "stale" if error.code == "stale_content_authority" else "unavailable", "applied_revision": None, "error": {"code": error.code, "message": error.code, "retryable": False}}
                return validate("CommandReceipt", receipt)
            fingerprint = digest({"actor": actor, "command": command})
            previous = self.db.execute("SELECT fingerprint,receipt_json FROM content_commands WHERE request_id=?", (command["request_id"],)).fetchone()
            if previous:
                if previous["fingerprint"] != fingerprint:
                    raise ContentError("command_id_reused", 409)
                return json.loads(previous["receipt_json"])
            authority = self.authority()["authority"]
            receipt = {"schema": "apt.command-receipt/1", "request_id": command["request_id"], "authority": authority, "target": command["target"], "state": "accepted", "applied_revision": None, "error": None}
            try:
                value, origins = self.source_command(command)
                event = self.db.execute("INSERT INTO content_events(kind,source_key,request_id,actor_id,created_at,payload_json) VALUES('source',?,?,?,?,?)", (source_key(value["snapshot"]["source"]), command["request_id"], actor, now(), canonical({"snapshot": value, "operation": command["operation"], "reason": command["payload"].get("reason")}).decode())).lastrowid
                self.db.execute("INSERT INTO content_sources VALUES(?,?,?,?) ON CONFLICT(source_key) DO UPDATE SET snapshot_json=excluded.snapshot_json,updated_seq=excluded.updated_seq", (source_key(value["snapshot"]["source"]), canonical(value).decode(), canonical(origins).decode(), event))
                receipt["applied_revision"] = value["snapshot"]["revision"]
            except ContentError as error:
                receipt["state"] = "unavailable" if error.status >= 500 else "conflict" if error.status == 409 else "rejected"
                receipt["error"] = {"code": error.code, "message": error.code, "retryable": False}
            validate("CommandReceipt", receipt)
            if receipt["state"] == "unavailable":
                # source_command validates before any mutation. Integrity or
                # read failures are visible but are not a permanent denial;
                # after repair the same request can be explicitly retried.
                return receipt
            self.db.execute("INSERT INTO content_commands VALUES(?,?,?,?,?)", (command["request_id"], actor, fingerprint, authority["epoch"], canonical(receipt).decode()))
            return receipt

    def source_command(self, command: dict):
        if command["target"]["kind"] != "source":
            raise ContentError("dedicated_domain_command_required")
        source, operation, payload = command["target"]["source"], command["operation"], command["payload"]
        if source["namespace"] == "ios_content":
            # Frozen text mutation has established revisions/redaction/derived
            # invalidation and attribution/voiceprint consequences. Preserve
            # that domain until its dedicated bridge is connected.
            raise ContentError("frozen_content_domain_bridge_required", 409)
        if source["namespace"] not in ("manual_text", "input_memory"):
            raise ContentError("source_namespace_not_migrated")
        if operation not in ("create", "update", "correct", "delete", "restore"):
            raise ContentError("unsupported_source_operation")
        if operation != "delete" and not isinstance(payload.get("text"), str):
            raise ContentError("invalid_source_payload")
        row = self.db.execute("SELECT snapshot_json,provenance_json FROM content_sources WHERE source_key=?", (source_key(source),)).fetchone()
        if row:
            current = self.load(source)
            revision, origins = current["snapshot"]["revision"], json.loads(row["provenance_json"])
        else:
            current, revision, origins = None, 0, []
        if command["expected_revision"] != revision or revision >= MAX_REVISION:
            raise ContentError("stale_source_revision", 409)
        if operation == "create":
            if current is not None:
                raise ContentError("source_already_exists", 409)
            if source["namespace"] != "manual_text" or set(payload) != {"text", "captured_at", "reason"}:
                raise ContentError("manual_text_create_required")
            value = {"schema": "apt.source-snapshot/1", "snapshot": {"source": source, "revision": 1, "fingerprint": "0" * 64}, "authority": command["authority"], "semantics": "imported_text", "captured_at": payload["captured_at"], "deleted": False, "text": payload["text"], "attributes": {}}
        else:
            if current is None:
                raise ContentError("source_unavailable", 404)
            if (operation == "restore") != current["deleted"]:
                raise ContentError("explicit_source_restore_required", 409)
            if set(payload) != ({"reason"} if operation == "delete" else {"text", "reason"}):
                raise ContentError("invalid_source_payload")
            value = copy.deepcopy(current)
            if operation == "delete":
                value.update(deleted=True, text="", attributes={})
            else:
                value.update(deleted=False, text=payload["text"])
                if operation == "restore":
                    previous = self.db.execute("SELECT payload_json FROM content_events WHERE source_key=? AND kind IN ('migration','source') ORDER BY seq DESC", (source_key(source),))
                    for event in previous:
                        candidate = json.loads(event[0])
                        if candidate.get("schema") != "apt.source-snapshot/1":
                            candidate = candidate["snapshot"]
                        if not candidate["deleted"]:
                            value["attributes"] = candidate["attributes"]
                            break
                if source["namespace"] == "input_memory":
                    for field in ("pasted", "voiced"):
                        marks = value["attributes"].get(field, [])
                        if not isinstance(marks, list) or any(not isinstance(mark, str) for mark in marks):
                            raise ContentError("invalid_input_provenance")
                        value["attributes"][field] = [mark for mark in marks if mark and mark in value["text"]]
                    value["attributes"]["partial"] = True
                    value["attributes"]["apt_text_origin"] = "user_correction"
                    value["attributes"]["apt_updated_at"] = now()
        reason = payload.get("reason")
        if not isinstance(reason, str) or not reason.strip() or len(reason) > 1024 or not isinstance(value["text"], str) or not value["deleted"] and not value["text"].strip():
            raise ContentError("invalid_source_payload")
        try:
            return canonical_source(value, revision + 1, command["authority"]["epoch"]), origins
        except ValueError:
            raise ContentError("invalid_source_payload") from None

    def checkpoint(self, target: Path):
        """A new recovery copy includes all later commands, revisions and deletions."""
        if self.db.in_transaction:
            raise ContentError("checkpoint_requires_closed_transaction")
        backup_sqlite(self.directory / "content.sqlite", target)
        with closing(read_db(target)) as copy_db:
            epoch = copy_db.execute("SELECT epoch FROM content_meta").fetchone()[0]
            watermark = copy_db.execute("SELECT COALESCE(MAX(seq),0) FROM content_events").fetchone()[0]
        return {"schema": "apt.content-checkpoint/1", "authority_epoch": epoch, "watermark": watermark, "fingerprint": file_digest(target)}

    def receipt(self, actor: str, request: dict):
        validate("CommandReceiptReadRequest", request)
        with self.transaction():
            self.check_actor(actor)
            if request["authority"] != {"domain": "content", "phase": "backend", "epoch": self.meta()["epoch"]}:
                raise ContentError("stale_content_authority", 409)
            row = self.db.execute("SELECT receipt_json FROM content_commands WHERE request_id=? AND actor_id=?", (request["request_id"], actor)).fetchone()
            if row is None:
                raise ContentError("command_receipt_unavailable", 404)
            return decode("CommandReceipt", row["receipt_json"])
