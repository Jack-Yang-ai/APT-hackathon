"""C0 text migration: consistent private backup, portable export and staged import.

Imports are read-only candidates. This module cannot activate a content writer or
execute processing queues. Phone capture is outside this offline tool.
"""
from __future__ import annotations

import base64
import hashlib
import json
import math
import os
import re
import sqlite3
import time
import uuid
from contextlib import closing, contextmanager
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

from shared.agent_protocol import canonical, validate

# Unknown tables block export. New app migrations must be classified explicitly.
CONTENT_TABLES = frozenset("""
ask_conversations ask_turn_input_sources ask_turn_sources ask_turns asr_jobs
card_budget card_drops card_kinds cards discoveries discovery_evidence discovery_kinds
generation_batches grdb_migrations id_remaps input_memory_sources input_memory_sync
judgment_current judgments line_speakers matter_nominations matter_open_questions
matter_progress_cards matter_states matter_timeline matter_transitions matters mixed_lines
observation_evidence observation_kinds person_brief person_observations persons
processing_events self_principles self_stance_evidence self_stances sessions speaker_reviews
speaker_skips stance_directions stream_blocks stream_sessions summaries summary_commitments
summary_events summary_key_points summary_pendings summary_stances summary_topic_keys
task_state_display tasks transcript_line_revisions transcript_line_tokens transcript_lines
transcripts upload_jobs personal_actions ask_drafts
""".split())
VOICEPRINT_TABLES = frozenset(("voiceprints", "enroll_ledger", "voiceprint_clusters", "speaker_clips"))
DERIVED_TABLES = frozenset(
    name + suffix for name in ("transcript_lines_fts", "transcript_line_tokens_fts")
    for suffix in ("", "_config", "_data", "_docsize", "_idx")
)
MAX_LINE_BYTES = 16 * 1024 * 1024


class MigrationError(ValueError):
    pass


def digest(value: object) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def producer_semantics(record: dict) -> str:
    """Producer meaning before tombstone projection; transport seq is excluded."""
    normalized = {key: value for key, value in record.items() if key != "event_seq"}
    normalized["device_id"] = normalized["device_id"].lower()
    normalized["id"] = normalized["id"].lower()
    normalized["revision"] = int(validate("Revision", normalized["revision"]))
    return digest(normalized)


def iphone_input_record(raw: dict) -> dict:
    """Check the producer's original bytes; Swift JSON escaping is significant."""
    if not {'device_id', 'record_id', 'revision', 'content_hash', 'record_json', 'deleted', 'updated_at'} <= raw.keys():
        raise MigrationError('input_producer_columns_missing')
    try:
        packed = raw['record_json']
        if not isinstance(packed, str) or hashlib.sha256(packed.encode('utf-8')).hexdigest() != raw['content_hash']:
            raise ValueError()
        record = json.loads(packed)
        if not isinstance(record, dict):
            raise ValueError()
        device, identity = record['device_id'], record['id']
        if not isinstance(device, str) or str(uuid.UUID(device)) != device.lower() or not isinstance(identity, str) or not identity.startswith('local_input_') or str(uuid.UUID(identity[12:])) != identity[12:].lower():
            raise ValueError()
        validate('Revision', record['revision'])
        if (device.lower(), identity.lower(), record['revision'], record['updated']) != (raw['device_id'], raw['record_id'], raw['revision'], raw['updated_at']):
            raise ValueError()
        if type(record['deleted']) is not bool or type(record['partial']) is not bool or int(record['deleted']) != raw['deleted']:
            raise ValueError()
        text, app = record['text'], record['app']
        if not isinstance(text, str) or len(text.encode('utf-16-le')) > 16384 or not isinstance(app, str) or not app.strip() or len(app.encode('utf-16-le')) > 512:
            raise ValueError()
        for field in ['pasted', 'voiced']:
            spans = record[field]
            if not isinstance(spans, list) or len(spans) > 128 or any(not isinstance(v, str) or not v or v not in text for v in spans):
                raise ValueError()
        if record['deleted'] and (text or record['pasted'] or record['voiced']) or not record['deleted'] and not text.strip():
            raise ValueError()
        dates = []
        for field in ['created', 'updated']:
            value = record[field]
            if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)', value):
                raise ValueError()
            dates.append(datetime.fromisoformat(value.replace('Z', '+00:00')))
        if dates[0] > dates[1]:
            raise ValueError()
        return record
    except (KeyError, TypeError, ValueError, UnicodeError):
        raise MigrationError('input_producer_metadata_mismatch') from None


def read_db(path: Path) -> sqlite3.Connection:
    if not path.is_file():
        raise MigrationError("source_database_missing")
    return sqlite3.connect("file:" + quote(str(path.resolve())) + "?mode=ro", uri=True, timeout=5)


def private_file(path: Path) -> None:
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)


def backup_sqlite(source: Path, target: Path, seconds: float = 30) -> None:
    """SQLite backup incorporates a live source WAL; no immutable=1 shortcut."""
    private_file(target)
    deadline = time.monotonic() + seconds
    def progress(status, remaining, total):
        if time.monotonic() > deadline:
            raise MigrationError("backup_deadline_exceeded")
    with closing(read_db(source)) as original, closing(sqlite3.connect(target)) as backup:
        original.backup(backup, pages=256, progress=progress, sleep=0.05)
        # A portable archive is a single closed file. SQLite backup can retain
        # the source WAL mode; normalize only the new copy before hashing it.
        if backup.execute("PRAGMA journal_mode=DELETE").fetchone()[0] != "delete":
            raise MigrationError("backup_journal_not_closed")
        if backup.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise MigrationError("backup_integrity_failed")


def cell(value: object) -> list:
    if value is None:
        return ["null", None]
    if type(value) is int:
        return ["integer", str(value)]  # Preserve the full SQLite int64 across JS.
    if type(value) is float and math.isfinite(value):
        return ["real", value.hex()]
    if isinstance(value, str):
        return ["text", value]
    if isinstance(value, bytes):
        return ["blob", base64.b64encode(value).decode("ascii")]
    raise MigrationError("unsupported_sqlite_value")


def uncell(value: object) -> object:
    if not isinstance(value, list) or len(value) != 2:
        raise MigrationError("invalid_cell")
    kind, raw = value
    if kind == "null" and raw is None:
        return None
    if kind == "integer" and isinstance(raw, str):
        try:
            number = int(raw)
            if str(number) == raw and -(2**63) <= number < 2**63:
                return number
        except ValueError:
            pass
    if kind == "real" and isinstance(raw, str):
        try:
            number = float.fromhex(raw)
            if math.isfinite(number) and number.hex() == raw:
                return number
        except ValueError:
            pass
    if kind == "text" and isinstance(raw, str):
        return raw
    if kind == "blob" and isinstance(raw, str):
        try:
            decoded = base64.b64decode(raw, validate=True)
            if base64.b64encode(decoded).decode("ascii") == raw:
                return decoded
        except ValueError:
            pass
    raise MigrationError("invalid_cell")


def quoted(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def inventory(db: sqlite3.Connection) -> tuple[list, dict, dict]:
    schema_rows = db.execute("SELECT name, sql FROM sqlite_master WHERE type='table' AND substr(name,1,7) <> 'sqlite_' ORDER BY name").fetchall()
    tables, excluded = {}, {}
    for table, _ in schema_rows:
        if table in VOICEPRINT_TABLES or table in DERIVED_TABLES:
            excluded[table] = "voiceprint_domain" if table in VOICEPRINT_TABLES else "derived_search_index"
            continue
        if table not in CONTENT_TABLES:
            raise MigrationError("unclassified_source_table:" + table)
        columns = db.execute("PRAGMA table_info(" + quoted(table) + ")").fetchall()
        primary = [c[1] for c in sorted(columns, key=lambda c: c[5]) if c[5]]
        tables[table] = {"columns": [c[1] for c in columns], "primary_key": primary, "rowid_identity": not primary}
    return schema_rows, tables, excluded


def archive_table(db: sqlite3.Connection, table: str, metadata: dict):
    names, primary = metadata["columns"], metadata["primary_key"]
    selector = ",".join(map(quoted, names)) + (",rowid" if not primary else "")
    ordering = ",".join(map(quoted, primary)) if primary else "rowid"
    for raw in db.execute(f"SELECT {selector} FROM {quoted(table)} ORDER BY {ordering}"):
        if any(raw[names.index(name)] is None for name in primary):
            raise MigrationError("null_primary_key_requires_explicit_identity")
        values = [cell(v) for v in raw[:len(names)]]
        key = [[name, cell(raw[names.index(name)])] for name in primary] if primary else [["rowid", cell(raw[-1])]]
        payload = {"table": table, "key": key, "values": values}
        encoded = canonical({**payload, "fingerprint": digest(payload)}) + b"\n"
        if len(encoded) > MAX_LINE_BYTES:
            raise MigrationError("source_row_exceeds_archive_budget")
        yield encoded


def export_snapshot(source: Path, directory: Path, library_id: str, revision: int) -> dict:
    validate("SourceRef", {"namespace": "ios_content", "library_id": library_id, "source_id": "snapshot"})
    validate("Revision", revision)
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    backup = directory / "source-backup.sqlite"
    backup_sqlite(source, backup)
    manifest = {
        "schema": "apt.content-export/1", "namespace": "ios_content", "library_id": library_id,
        "revision": revision, "migration_id": str(uuid.uuid4()),
        "captured_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "phase": "staging", "tables": {}, "excluded": {},
    }
    records = directory / "content.ndjson"
    private_file(records)
    whole = hashlib.sha256()
    with closing(read_db(backup)) as db, records.open("wb") as stream:
        schema_rows, tables, manifest["excluded"] = inventory(db)
        manifest["source_schema_fingerprint"] = digest(schema_rows)
        manifest["foreign_key_errors"] = len(db.execute("PRAGMA foreign_key_check").fetchall())
        if manifest["foreign_key_errors"]:
            raise MigrationError("source_foreign_keys_invalid_backup_retained")
        for table, structure in tables.items():
            metadata = {**structure, "rows": 0}
            table_digest = hashlib.sha256()
            for encoded in archive_table(db, table, metadata):
                stream.write(encoded)
                table_digest.update(encoded)
                whole.update(encoded)
                metadata["rows"] += 1
            metadata["fingerprint"] = table_digest.hexdigest()
            manifest["tables"][table] = metadata
    manifest["records_fingerprint"] = whole.hexdigest()
    manifest["rows"] = sum(v["rows"] for v in manifest["tables"].values())
    manifest["source_backup_fingerprint"] = file_digest(backup)
    target = directory / "manifest.json"
    private_file(target)
    target.write_bytes(canonical(manifest) + b"\n")
    return summary(manifest)


def file_digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def summary(manifest: dict) -> dict:
    return {key: manifest[key] for key in ("schema", "library_id", "revision", "migration_id", "phase", "rows")}


def verify_export(directory: Path) -> dict:
    with (directory / "manifest.json").open("rb") as stream:
        packed = stream.read(1024 * 1024 + 1)
    if len(packed) > 1024 * 1024:
        raise MigrationError("manifest_budget_exceeded")
    manifest = json.loads(packed)
    fields = {"schema", "namespace", "library_id", "revision", "migration_id", "captured_at", "phase", "tables", "excluded", "source_schema_fingerprint", "foreign_key_errors", "records_fingerprint", "rows", "source_backup_fingerprint"}
    if not isinstance(manifest, dict) or set(manifest) != fields or manifest["schema"] != "apt.content-export/1" or manifest["phase"] != "staging" or manifest["namespace"] != "ios_content" or type(manifest["foreign_key_errors"]) is not int or manifest["foreign_key_errors"] != 0:
        raise MigrationError("invalid_export_manifest")
    validate("ID", manifest["migration_id"])
    validate("Revision", manifest["revision"])
    for field in ("records_fingerprint", "source_schema_fingerprint", "source_backup_fingerprint"):
        validate("Hash", manifest[field])
    validate("SourceSnapshot", {"schema": "apt.source-snapshot/1", "snapshot": {"source": {"namespace": "ios_content", "library_id": manifest["library_id"], "source_id": "snapshot"}, "revision": manifest["revision"], "fingerprint": manifest["records_fingerprint"]}, "authority": {"domain": "content", "phase": "staging", "epoch": 0}, "captured_at": manifest["captured_at"], "semantics": "derived", "deleted": False, "text": "", "attributes": {}})
    tables = manifest["tables"]
    if not isinstance(tables, dict) or not tables or set(tables) - CONTENT_TABLES:
        raise MigrationError("invalid_export_tables")
    for meta in tables.values():
        if not isinstance(meta, dict) or set(meta) != {"columns", "primary_key", "rowid_identity", "rows", "fingerprint"} or not isinstance(meta["columns"], list) or not meta["columns"] or not all(isinstance(c, str) and c for c in meta["columns"]) or len(set(meta["columns"])) != len(meta["columns"]):
            raise MigrationError("invalid_table_metadata")
        if type(meta["rows"]) is not int or meta["rows"] < 0 or type(meta["rowid_identity"]) is not bool or not isinstance(meta["primary_key"], list) or not all(isinstance(c, str) for c in meta["primary_key"]) or len(set(meta["primary_key"])) != len(meta["primary_key"]) or not set(meta["primary_key"]).issubset(meta["columns"]) or meta["rowid_identity"] != (not meta["primary_key"]):
            raise MigrationError("invalid_table_identity")
        validate("Hash", meta["fingerprint"])
    if type(manifest["rows"]) is not int or manifest["rows"] != sum(v["rows"] for v in tables.values()):
        raise MigrationError("manifest_row_count_mismatch")
    if file_digest(directory / "content.ndjson") != manifest["records_fingerprint"]:
        raise MigrationError("archive_fingerprint_mismatch")
    backup = directory / "source-backup.sqlite"
    if any(Path(str(backup) + suffix).exists() for suffix in ("-wal", "-journal")) or file_digest(backup) != manifest["source_backup_fingerprint"]:
        raise MigrationError("source_backup_changed")
    # Verify completeness against the retained SQLite, not only against a
    # self-consistent manifest that might have accidentally omitted a table.
    with closing(read_db(backup)) as db:
        if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok" or db.execute("PRAGMA foreign_key_check").fetchall():
            raise MigrationError("source_backup_invalid")
        schema, actual, excluded = inventory(db)
        if digest(schema) != manifest["source_schema_fingerprint"] or set(actual) != set(tables) or excluded != manifest["excluded"]:
            raise MigrationError("source_inventory_mismatch")
        whole = hashlib.sha256()
        for name, structure in actual.items():
            if any(tables[name][field] != value for field, value in structure.items()):
                raise MigrationError("source_columns_mismatch")
            count, mark = 0, hashlib.sha256()
            for encoded in archive_table(db, name, structure):
                count += 1
                mark.update(encoded)
                whole.update(encoded)
            if count != tables[name]["rows"] or mark.hexdigest() != tables[name]["fingerprint"]:
                raise MigrationError("source_rows_mismatch")
        if whole.hexdigest() != manifest["records_fingerprint"]:
            raise MigrationError("source_archive_mismatch")
    return manifest


class ContentStage:
    def __init__(self, path: Path, *, writable: bool = True):
        self.path = path
        self.writable = writable
        if not writable and not path.is_file():
            raise MigrationError("staged_database_missing")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if not path.exists():
            private_file(path)
        self.db = sqlite3.connect(path, timeout=5) if writable else read_db(path)
        self.db.execute("PRAGMA foreign_keys=ON")
        tables = {r[0] for r in self.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if tables and tables != {"content_stage_libraries", "content_stage_rows"}:
            self.db.close()
            raise MigrationError("not_a_content_staging_database")
        if tables:
            expected = {
                "content_stage_libraries": ["library_id", "revision", "manifest_fingerprint", "manifest_json"],
                "content_stage_rows": ["library_id", "table_name", "row_key", "fingerprint", "values_json", "record_seq"],
            }
            if any([r[1] for r in self.db.execute("PRAGMA table_info(" + name + ")")] != fields for name, fields in expected.items()):
                self.db.close()
                raise MigrationError("incompatible_content_staging_schema")
        elif not writable:
            self.db.close()
            raise MigrationError("not_a_content_staging_database")
        if writable:
            path.chmod(0o600)
            self.db.executescript("""
            CREATE TABLE IF NOT EXISTS content_stage_libraries (
              library_id TEXT PRIMARY KEY, revision INTEGER NOT NULL,
              manifest_fingerprint TEXT NOT NULL, manifest_json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS content_stage_rows (
              library_id TEXT NOT NULL REFERENCES content_stage_libraries(library_id),
              table_name TEXT NOT NULL, row_key TEXT NOT NULL, fingerprint TEXT NOT NULL,
              values_json TEXT NOT NULL, record_seq INTEGER NOT NULL,
              PRIMARY KEY(library_id, table_name, row_key),
              UNIQUE(library_id, table_name, record_seq));
            """)

    def close(self):
        self.db.close()

    @contextmanager
    def reading(self):
        owns_transaction = not self.db.in_transaction
        if owns_transaction:
            self.db.execute("BEGIN")
        try:
            yield
        finally:
            if owns_transaction:
                self.db.rollback()

    def import_snapshot(self, directory: Path) -> dict:
        if not self.writable:
            raise MigrationError("staged_database_read_only")
        manifest = verify_export(directory)
        tables = manifest["tables"]
        library = manifest["library_id"]
        mark = digest(manifest)
        counts = {name: 0 for name in tables}
        hashes = {name: hashlib.sha256() for name in tables}
        whole = hashlib.sha256()
        self.db.execute("BEGIN IMMEDIATE")
        try:
            previous = self.db.execute("SELECT revision, manifest_fingerprint FROM content_stage_libraries WHERE library_id=?", (library,)).fetchone()
            if previous and manifest["revision"] <= previous[0]:
                if manifest["revision"] == previous[0] and mark == previous[1]:
                    self.report(library)
                    self.db.rollback()
                    return {**summary(manifest), "status": "already_imported", "authority_activated": False}
                raise MigrationError("stale_or_conflicting_library_revision")
            self.db.execute("INSERT INTO content_stage_libraries VALUES (?,?,?,?) ON CONFLICT(library_id) DO UPDATE SET revision=excluded.revision,manifest_fingerprint=excluded.manifest_fingerprint,manifest_json=excluded.manifest_json", (library, manifest["revision"], mark, canonical(manifest).decode()))
            self.db.execute("DELETE FROM content_stage_rows WHERE library_id=?", (library,))
            with (directory / "content.ndjson").open("rb") as stream:
                while encoded := stream.readline(MAX_LINE_BYTES + 1):
                    if len(encoded) > MAX_LINE_BYTES or not encoded.endswith(b"\n"):
                        raise MigrationError("invalid_archive_line")
                    record = json.loads(encoded)
                    if set(record) != {"table", "key", "values", "fingerprint"} or record["table"] not in tables:
                        raise MigrationError("invalid_export_record")
                    name = record["table"]
                    meta = tables[name]
                    if not isinstance(record["values"], list) or len(record["values"]) != len(meta["columns"]):
                        raise MigrationError("invalid_record_columns")
                    for value in record["values"]:
                        uncell(value)
                    key = record["key"]
                    expected = [[column, record["values"][meta["columns"].index(column)]] for column in meta["primary_key"]]
                    if meta["rowid_identity"]:
                        if not isinstance(key, list) or len(key) != 1 or not isinstance(key[0], list) or len(key[0]) != 2 or key[0][0] != "rowid" or type(uncell(key[0][1])) is not int:
                            raise MigrationError("invalid_rowid")
                    elif key != expected:
                        raise MigrationError("record_identity_mismatch")
                    payload = {k: record[k] for k in ("table", "key", "values")}
                    if digest(payload) != record["fingerprint"]:
                        raise MigrationError("record_fingerprint_mismatch")
                    if counts[name] >= meta["rows"]:
                        raise MigrationError("unexpected_archive_rows")
                    self.db.execute("INSERT INTO content_stage_rows VALUES (?,?,?,?,?,?)", (library, name, canonical(key).decode(), record["fingerprint"], canonical(record["values"]).decode(), counts[name]))
                    counts[name] += 1
                    hashes[name].update(encoded)
                    whole.update(encoded)
            if whole.hexdigest() != manifest["records_fingerprint"] or any(counts[n] != tables[n]["rows"] or hashes[n].hexdigest() != tables[n]["fingerprint"] for n in tables):
                raise MigrationError("archive_reconciliation_failed")
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise
        return {**summary(manifest), "status": "staged", "authority_activated": False}

    def report(self, library: str) -> dict:
        with self.reading():
            return self._report(library)

    def _report(self, library: str) -> dict:
        row = self.db.execute("SELECT manifest_json,manifest_fingerprint FROM content_stage_libraries WHERE library_id=?", (library,)).fetchone()
        if row is None:
            raise MigrationError("library_unavailable")
        manifest = json.loads(row[0])
        if digest(manifest) != row[1]:
            raise MigrationError("staged_manifest_changed")
        counts = dict(self.db.execute("SELECT table_name,COUNT(*) FROM content_stage_rows WHERE library_id=? GROUP BY table_name", (library,)))
        if set(counts) - set(manifest["tables"]) or any(counts.get(name, 0) != meta["rows"] for name, meta in manifest["tables"].items()):
            raise MigrationError("staged_row_count_mismatch")
        whole = hashlib.sha256()
        for name, metadata in sorted(manifest["tables"].items()):
            table_hash = hashlib.sha256()
            rows = self.db.execute("SELECT row_key,values_json,fingerprint FROM content_stage_rows WHERE library_id=? AND table_name=? ORDER BY record_seq", (library, name))
            for key, values, fingerprint in rows:
                payload = {"table": name, "key": json.loads(key), "values": json.loads(values)}
                if digest(payload) != fingerprint:
                    raise MigrationError("staged_record_changed")
                encoded = canonical({**payload, "fingerprint": fingerprint}) + b"\n"
                table_hash.update(encoded)
                whole.update(encoded)
            if table_hash.hexdigest() != metadata["fingerprint"]:
                raise MigrationError("staged_table_changed")
        if whole.hexdigest() != manifest["records_fingerprint"]:
            raise MigrationError("staged_archive_changed")
        return {**summary(manifest), "tables": {name: counts.get(name, 0) for name in manifest["tables"]}, "excluded": manifest["excluded"], "authority_activated": False}

    def sources(self, library: str, query: str = "", limit: int = 12) -> list[dict]:
        with self.reading():
            return self._sources(library, query, limit)

    def _sources(self, library: str, query: str, limit: int) -> list[dict]:
        if type(limit) is not int or not 1 <= limit <= 30:
            raise MigrationError("invalid_source_limit")
        found = []
        for snapshot in self._source_snapshots(library):
            if query.casefold() not in snapshot["text"].casefold():
                continue
            found.append(snapshot)
            if len(found) >= limit:
                break
        return found

    def source_snapshots(self, library: str, *, include_deleted: bool = False):
        """Complete migration inventory, including tombstones when requested."""
        with self.reading():
            yield from self._source_snapshots(library, include_deleted=include_deleted)

    def source_inventory(self, library: str):
        """Private import evidence; never attach producer metadata to a tombstone."""
        with self.reading():
            yield from self._source_snapshots(library, include_deleted=True, with_provenance=True)

    def _source_snapshots(self, library: str, *, include_deleted: bool = False, with_provenance: bool = False):
        self.report(library)
        manifest = json.loads(self.db.execute("SELECT manifest_json FROM content_stage_libraries WHERE library_id=?", (library,)).fetchone()[0])
        def records(table: str):
            meta = manifest["tables"].get(table)
            if meta is None:
                raise MigrationError("source_identity_table_missing")
            rows = self.db.execute("SELECT values_json FROM content_stage_rows WHERE library_id=? AND table_name=? ORDER BY record_seq", (library, table))
            for packed, in rows:
                yield dict(zip(meta["columns"], map(uncell, json.loads(packed))))
        transcripts, active = {}, set()
        if "transcript_lines" in manifest["tables"]:
            required = {"transcript_lines": {"line_id", "transcript_id", "text", "redacted", "is_gap"}, "transcripts": {"id", "session_id", "version"}, "sessions": {"id", "active_transcript_id"}}
            if any(not fields.issubset(manifest["tables"].get(table, {}).get("columns", [])) for table, fields in required.items()):
                raise MigrationError("source_identity_columns_missing")
            transcripts = {r["id"]: r for r in records("transcripts")}
            for session in records("sessions"):
                active_id = session["active_transcript_id"]
                if active_id is None:
                    continue
                current = transcripts.get(active_id)
                if current is None or current["session_id"] != session["id"]:
                    raise MigrationError("active_transcript_identity_invalid")
                active.add((current["session_id"], current["version"]))
        for table in ("transcript_lines", "input_memory_sources"):
            meta = manifest["tables"].get(table)
            if meta is None:
                continue
            rows = self.db.execute("SELECT values_json FROM content_stage_rows WHERE library_id=? AND table_name=? ORDER BY row_key", (library, table))
            for packed, in rows:
                producer = None
                raw = dict(zip(meta["columns"], map(uncell, json.loads(packed))))
                if table == "transcript_lines":
                    transcript = transcripts.get(raw["transcript_id"])
                    if transcript is None:
                        raise MigrationError("transcript_identity_invalid")
                    if (transcript["session_id"], transcript["version"]) not in active:
                        continue
                    deleted = bool(raw.get("redacted") or raw.get("is_gap"))
                    if deleted and not include_deleted:
                        continue
                    text = raw["text"]
                    source = {"namespace": "ios_content", "library_id": library, "source_id": "transcript_lines:" + str(raw["line_id"])}
                    revision, fingerprint = manifest["revision"], digest(json.loads(packed))
                    semantics = "recording"
                    attributes = {k: str(v) if isinstance(v, int) else v for k, v in raw.items() if k != "text" and not isinstance(v, bytes)}
                else:
                    record = iphone_input_record(raw)
                    deleted = bool(raw["deleted"])
                    if deleted and not include_deleted:
                        continue
                    producer = producer_semantics(record)
                    text = record["text"]
                    source = {"namespace": "input_memory", "library_id": record["device_id"].lower(), "source_id": record["id"].lower()}
                    revision, fingerprint = record["revision"], raw["content_hash"]
                    semantics = "input_draft"
                    attributes = {k: v for k, v in record.items() if k != "text"}
                snapshot = {"schema": "apt.source-snapshot/1", "snapshot": {"source": source, "revision": revision, "fingerprint": fingerprint}, "authority": {"domain": "content", "phase": "staging", "epoch": 0}, "captured_at": manifest["captured_at"], "semantics": semantics, "deleted": deleted, "text": "" if deleted else text, "attributes": {} if deleted else attributes}
                validate("SourceSnapshot", snapshot)
                yield (snapshot, producer) if with_provenance else snapshot
