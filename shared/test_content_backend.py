"""Text-authority attacks against real temporary SQLite and HTTP boundaries."""
from __future__ import annotations

import copy
import hashlib
import json
import sqlite3
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from mac.content_server import ContentHTTPServer
from shared.agent_protocol import canonical
from shared.content_backend import ContentBackend, ContentError, prepare
from shared.content_migration import export_snapshot, file_digest, MigrationError

OWNER = "11111111-1111-4111-8111-111111111111"
LIBRARY = "22222222-2222-4222-8222-222222222222"
DEVICE = "33333333-3333-4333-8333-333333333333"
INPUT = "local_input_44444444-4444-4444-8444-444444444444"


def input_record(revision=1, text="Synthetic draft copied phrase original words", deleted=False):
    return {"device_id": DEVICE, "id": INPUT, "revision": revision, "created": "2026-10-14T01:00:00.000Z", "updated": "2026-10-14T02:00:00.000Z", "app": "fixture", "text": "" if deleted else text, "pasted": ["copied phrase"] if not deleted and "copied phrase" in text else [], "voiced": ["original words"] if not deleted and "original words" in text else [], "partial": False, "deleted": deleted}


class ContentBackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "legacy.sqlite"
        record = input_record()
        with sqlite3.connect(self.source) as db:
            db.executescript("""
              CREATE TABLE sessions(id INTEGER PRIMARY KEY,active_transcript_id INTEGER);
              INSERT INTO sessions VALUES(1,1);
              CREATE TABLE transcripts(id INTEGER PRIMARY KEY,session_id INTEGER,version INTEGER,part INTEGER);
              INSERT INTO transcripts VALUES(1,1,1,0);
              CREATE TABLE transcript_lines(line_id INTEGER PRIMARY KEY,transcript_id INTEGER,text TEXT,redacted INTEGER,is_gap INTEGER);
              INSERT INTO transcript_lines VALUES(10,1,'Frozen quote',0,0),(11,1,'Removed',1,0);
              CREATE TABLE input_memory_sources(local_id INTEGER PRIMARY KEY,device_id TEXT,record_id TEXT,revision INTEGER,content_hash TEXT,record_json TEXT,deleted INTEGER,updated_at TEXT);
              CREATE TABLE judgments(id INTEGER PRIMARY KEY,payload TEXT);
              INSERT INTO judgments VALUES(1,'preserve user judgment');
              CREATE TABLE voiceprints(id INTEGER PRIMARY KEY,embedding BLOB);
              INSERT INTO voiceprints VALUES(1,X'112233');
            """)
            packed = canonical(record)
            db.execute("INSERT INTO input_memory_sources VALUES(1,?,?,1,?,?,0,?)", (DEVICE, INPUT, hashlib.sha256(packed).hexdigest(), packed.decode(), record['updated']))
        self.export = self.root / "export"
        export_snapshot(self.source, self.export, LIBRARY, 1)
        self.directory = self.root / "backend"
        prepare(self.directory, self.export, OWNER)
        self.backend = ContentBackend(self.directory)
        self.backend.transition(OWNER, str(uuid.uuid4()), "activate", 0)
        self.authority = self.backend.authority()["authority"]
        self.input_source = {"namespace": "input_memory", "library_id": DEVICE, "source_id": INPUT}
        self.source_ref = {"namespace": "manual_text", "library_id": LIBRARY, "source_id": "synthetic-note"}

    def tearDown(self):
        self.backend.close()
        self.temp.cleanup()

    def request(self, operation="create", revision=0, *, source=None, text="Synthetic new text", request_id=None, authority=None):
        payload = {"reason": "Synthetic user instruction"}
        if operation != "delete":
            payload["text"] = text
        if operation == "create":
            payload["captured_at"] = "2026-10-14T03:00:00Z"
        return {"schema": "apt.command/1", "request_id": request_id or str(uuid.uuid4()), "authority": authority or self.authority, "target": {"kind": "source", "source": source or self.source_ref, "entity_id": None}, "expected_revision": revision, "operation": operation, "payload": payload}

    def read(self, source=None, deleted=False):
        return self.backend.read(OWNER, {"schema": "apt.content-read/1", "authority": self.backend.authority()["authority"], "source": source or self.source_ref, "include_deleted": deleted})

    def validate_refs(self, refs):
        return self.backend.validate_sources(OWNER, {"schema": "apt.content-validate/1", "authority": self.backend.authority()["authority"], "snapshots": refs})

    def test_prepared_fences_writes_and_preserves_original_data_and_voice_recovery(self):
        other = self.root / "prepared"
        status = prepare(other, self.export, OWNER)
        self.assertEqual(status["status"], "prepared")
        self.assertEqual(status["authority"]["epoch"], 0)
        pending = ContentBackend(other)
        with self.assertRaisesRegex(ContentError, "content_writer_unavailable"):
            pending.command(OWNER, self.request())
        pending.close()
        with sqlite3.connect(other / "legacy-recovery.sqlite") as db:
            self.assertEqual(db.execute('SELECT embedding FROM voiceprints').fetchone()[0], b'\x11\x22\x33')
            self.assertEqual(db.execute('SELECT payload FROM judgments').fetchone()[0], 'preserve user judgment')
        before = file_digest(self.source)
        self.backend.command(OWNER, self.request())
        self.assertEqual(file_digest(self.source), before)
        with self.assertRaises(FileExistsError):
            prepare(other, self.export, OWNER)

    def test_iphone_input_redundant_identity_and_raw_hash_must_match_before_prepare(self):
        mutations = {'device_id': LIBRARY, 'record_id': 'local_input_' + LIBRARY,
                     'revision': 2, 'content_hash': '0' * 64, 'deleted': 1,
                     'updated_at': '2026-10-14T03:00:00.000Z'}
        for column, value in mutations.items():
            with self.subTest(column=column):
                source = self.root / ('bad-' + column + '.sqlite')
                source.write_bytes(self.source.read_bytes())
                with sqlite3.connect(source) as db:
                    db.execute('UPDATE input_memory_sources SET ' + column + '=?', (value,))
                archive = self.root / ('export-' + column)
                export_snapshot(source, archive, LIBRARY, 1)
                before = file_digest(source)
                with self.assertRaisesRegex(MigrationError, 'input_producer_'):
                    prepare(self.root / ('prepared-' + column), archive, OWNER)
                self.assertEqual(file_digest(source), before)

    def test_iphone_input_missing_identity_column_is_not_a_legacy_alias(self):
        with sqlite3.connect(self.source) as db:
            db.execute('ALTER TABLE input_memory_sources DROP COLUMN device_id')
        archive = self.root / 'missing-identity-export'
        export_snapshot(self.source, archive, LIBRARY, 2)
        with self.assertRaisesRegex(MigrationError, 'input_producer_columns_missing'):
            prepare(self.root / 'missing-identity-backend', archive, OWNER)

    def test_iphone_hash_covers_original_utf8_including_swift_slash_escape(self):
        record = input_record(text='合成链接 https://example.test/a 😀')
        packed = canonical(record).decode().replace('/', '\\/')
        with sqlite3.connect(self.source) as db:
            db.execute('UPDATE input_memory_sources SET record_json=?,content_hash=?',
                       (packed, hashlib.sha256(packed.encode()).hexdigest()))
        archive = self.root / 'slash-export'
        export_snapshot(self.source, archive, LIBRARY, 2)
        directory = self.root / 'slash-backend'
        prepare(directory, archive, OWNER)
        backend = ContentBackend(directory)
        try:
            backend.transition(OWNER, str(uuid.uuid4()), 'activate', 0)
            value = backend.read(OWNER, {'schema': 'apt.content-read/1', 'authority': backend.authority()['authority'], 'source': self.input_source, 'include_deleted': False})
            self.assertEqual(value['text'], record['text'])
        finally:
            backend.close()

    def test_transition_replay_and_monotone_epochs_survive_restart(self):
        key = str(uuid.uuid4())
        first = self.backend.transition(OWNER, key, "suspend", 1)
        self.assertEqual(first["authority"]["epoch"], 2)
        self.assertEqual(self.backend.transition(OWNER, key, "suspend", 1), first)
        with self.assertRaisesRegex(ContentError, "transition_id_reused"):
            self.backend.transition(OWNER, key, "resume", 2)
        paused = self.backend.command(OWNER, self.request())
        self.assertEqual(paused["state"], "unavailable")
        self.backend.transition(OWNER, str(uuid.uuid4()), "resume", 2)
        self.backend.close()
        self.backend = ContentBackend(self.directory)
        self.assertEqual(self.backend.authority()["authority"]["epoch"], 3)
        stale = self.backend.command(OWNER, self.request())
        self.assertEqual(stale["state"], "stale")
        self.assertEqual(stale["authority"]["epoch"], 3)
        self.assertEqual(self.backend.command(OWNER, self.request(authority=stale["authority"]))["state"], "accepted")

    def test_actor_is_checked_before_any_command_or_transition(self):
        with self.assertRaisesRegex(ContentError, "content_owner_mismatch"):
            self.backend.command(DEVICE, self.request())
        with self.assertRaisesRegex(ContentError, "content_owner_mismatch"):
            self.backend.transition(DEVICE, str(uuid.uuid4()), "suspend", 1)
        self.assertEqual(self.backend.authority()["status"], "active")

    def test_damaged_baseline_cannot_prevent_durable_suspension(self):
        baseline = self.directory / "base-content.sqlite"
        baseline.chmod(0o600)
        with baseline.open("ab") as out:
            out.write(b"synthetic recovery corruption")
        receipt = self.backend.transition(OWNER, str(uuid.uuid4()), "suspend", 1)
        self.assertEqual((receipt["status"], receipt["authority"]["epoch"]), ("suspended", 2))
        self.assertEqual(self.backend.command(OWNER, self.request())["state"], "unavailable")
        with self.assertRaisesRegex(ContentError, "immutable_content_baseline_changed"):
            self.backend.transition(OWNER, str(uuid.uuid4()), "resume", 2)
        self.backend.close()
        self.backend = ContentBackend(self.directory)
        self.assertEqual((self.backend.authority()["status"], self.backend.authority()["authority"]["epoch"]), ("suspended", 2))

    def test_exact_replay_returns_original_receipt_and_id_reuse_is_rejected(self):
        command = self.request()
        receipt = self.backend.command(OWNER, command)
        count = self.backend.authority()["watermark"]
        self.assertEqual(self.backend.command(OWNER, command), receipt)
        self.assertEqual(self.backend.authority()["watermark"], count)
        changed = copy.deepcopy(command)
        changed["payload"]["text"] = "Different instruction"
        with self.assertRaisesRegex(ContentError, "command_id_reused"):
            self.backend.command(OWNER, changed)
        self.assertEqual(self.read()["text"], "Synthetic new text")

    def test_correction_invalidates_the_original_dependency_and_keeps_feedback(self):
        original = self.read(self.input_source)
        receipt = self.backend.command(OWNER, self.request("correct", 1, source=self.input_source, text="Corrected synthetic draft"))
        self.assertEqual(receipt["applied_revision"], 2)
        self.assertFalse(self.validate_refs([original["snapshot"]])["current"])
        self.assertEqual(self.read(self.input_source)["text"], "Corrected synthetic draft")
        row = self.backend.db.execute("SELECT payload_json FROM content_events WHERE request_id=?", (receipt["request_id"],)).fetchone()
        self.assertEqual(json.loads(row[0])["reason"], "Synthetic user instruction")

    def test_delete_cannot_revive_by_old_commands_or_an_implicit_update(self):
        create = self.request()
        self.backend.command(OWNER, create)
        original = self.read()["snapshot"]
        delete = self.request("delete", 1)
        self.backend.command(OWNER, delete)
        tombstone = self.read(deleted=True)
        self.assertEqual((tombstone["text"], tombstone["attributes"]), ("", {}))
        self.assertEqual(self.validate_refs([original])["sources"][0]["state"], "deleted")
        with self.assertRaisesRegex(ContentError, "source_deleted"):
            self.read()
        self.backend.command(OWNER, create)
        self.backend.command(OWNER, delete)
        self.assertTrue(self.read(deleted=True)["deleted"])
        update = self.backend.command(OWNER, self.request("update", 2))
        self.assertEqual(update["state"], "conflict")
        restored = self.backend.command(OWNER, self.request("restore", 2, text="Explicitly restored text"))
        self.assertEqual(restored["applied_revision"], 3)
        self.assertEqual(self.read()["text"], "Explicitly restored text")

    def test_frozen_and_attribution_commands_require_their_dedicated_bridge(self):
        frozen = {"namespace": "ios_content", "library_id": LIBRARY, "source_id": "transcript_lines:10"}
        reply = self.backend.command(OWNER, self.request("delete", 1, source=frozen))
        self.assertEqual(reply["error"]["code"], "frozen_content_domain_bridge_required")
        command = self.request()
        command["target"] = {"kind": "attribution", "source": None, "entity_id": LIBRARY}
        reply = self.backend.command(OWNER, command)
        self.assertEqual(reply["state"], "rejected")
        self.assertEqual(reply["error"]["code"], "dedicated_domain_command_required")

    def test_two_writers_on_the_same_revision_have_only_one_winner(self):
        self.backend.command(OWNER, self.request())
        ready = threading.Barrier(2)
        receipts, errors = [], []
        def updating(text):
            local = ContentBackend(self.directory)
            try:
                ready.wait(timeout=3)
                receipts.append(local.command(OWNER, self.request("update", 1, text=text)))
            except Exception as error:
                errors.append(error)
            finally:
                local.close()
        threads = [threading.Thread(target=updating, args=(text,)) for text in ("First correction", "Second correction")]
        for thread in threads: thread.start()
        for thread in threads: thread.join(5)
        self.assertFalse(any(t.is_alive() for t in threads))
        self.assertEqual(errors, [])
        self.assertEqual(sorted(r["state"] for r in receipts), ["accepted", "conflict"])
        self.assertEqual(self.read()["snapshot"]["revision"], 2)

    def test_write_failure_rolls_back_source_event_and_receipt_then_retry_is_safe(self):
        self.backend.command(OWNER, self.request())
        command = self.request("update", 1, text="After retry")
        before = self.backend.authority()["watermark"]
        self.backend.db.close()
        class FailedConnection(sqlite3.Connection):
            def execute(self, sql, parameters=()):
                if sql.startswith('INSERT INTO content_sources'):
                    raise sqlite3.OperationalError('synthetic disk full')
                return super().execute(sql, parameters)
        self.backend.db = sqlite3.connect(self.directory / "content.sqlite", factory=FailedConnection)
        self.backend.db.row_factory = sqlite3.Row
        with self.assertRaises(sqlite3.OperationalError):
            self.backend.command(OWNER, command)
        self.assertEqual(self.backend.authority()["watermark"], before)
        self.assertEqual(self.read()["snapshot"]["revision"], 1)
        self.backend.close()
        self.backend = ContentBackend(self.directory)
        self.assertEqual(self.backend.command(OWNER, command)["applied_revision"], 2)
        self.assertEqual(self.backend.command(OWNER, command)["applied_revision"], 2)

    def test_tampered_source_and_changed_baseline_fail_visibly(self):
        self.backend.command(OWNER, self.request())
        row = self.backend.db.execute("SELECT source_key,snapshot_json FROM content_sources WHERE source_key LIKE '%synthetic-note%'").fetchone()
        value = json.loads(row['snapshot_json'])
        value['text'] = 'Tampered'
        self.backend.db.execute('UPDATE content_sources SET snapshot_json=? WHERE source_key=?', (canonical(value).decode(), row['source_key']))
        self.backend.db.commit()
        with self.assertRaisesRegex(ContentError, 'stored_source_changed'):
            self.read()
        archive = self.directory / 'base-content.sqlite'
        archive.chmod(0o600)
        with archive.open('ab') as stream: stream.write(b'corrupt')
        with self.assertRaisesRegex(ContentError, 'immutable_content_baseline_changed'):
            self.backend.verify_baseline()

    def test_checkpoint_contains_new_text_commands_and_tombstones(self):
        self.backend.command(OWNER, self.request())
        self.backend.command(OWNER, self.request('delete', 1))
        target = self.root / 'after-cutover.sqlite'
        receipt = self.backend.checkpoint(target)
        self.assertEqual(receipt['authority_epoch'], 1)
        with sqlite3.connect(target) as db:
            values = [json.loads(r[0]) for r in db.execute('SELECT snapshot_json FROM content_sources')]
            self.assertTrue(any(v['snapshot']['source'] == self.source_ref and v['deleted'] for v in values))
            self.assertEqual(db.execute('SELECT COUNT(*) FROM content_commands').fetchone()[0], 2)
        with self.assertRaises(FileExistsError):
            self.backend.checkpoint(target)

    def test_unavailable_integrity_failure_is_not_cached_as_a_user_rejection(self):
        self.backend.command(OWNER, self.request())
        command = self.request('correct', 1)
        row = self.backend.db.execute("SELECT source_key,snapshot_json FROM content_sources WHERE source_key LIKE '%synthetic-note%'").fetchone()
        damaged = json.loads(row['snapshot_json'])
        damaged['text'] = 'Bad checksum'
        self.backend.db.execute('UPDATE content_sources SET snapshot_json=? WHERE source_key=?', (canonical(damaged).decode(), row['source_key']))
        self.backend.db.commit()
        reply = self.backend.command(OWNER, command)
        self.assertEqual(reply['state'], 'unavailable')
        self.assertIsNone(reply['applied_revision'])
        self.assertIsNone(self.backend.db.execute('SELECT 1 FROM content_commands WHERE request_id=?', (command['request_id'],)).fetchone())
        self.backend.db.execute('UPDATE content_sources SET snapshot_json=? WHERE source_key=?', (row['snapshot_json'], row['source_key']))
        self.backend.db.commit()
        self.assertEqual(self.backend.command(OWNER, command)['state'], 'accepted')

    def make_mac(self, record):
        path = self.root / 'mac.sqlite'
        packed = json.dumps(record, ensure_ascii=False, separators=(',', ':'))
        with sqlite3.connect(path) as db:
            db.execute('CREATE TABLE input_memory_sources(device_id TEXT,record_id TEXT,revision INTEGER,payload TEXT,fingerprint TEXT,text TEXT,created TEXT,deleted INTEGER,received_at TEXT)')
            db.execute('INSERT INTO input_memory_sources VALUES(?,?,?,?,?,?,?,?,?)', (DEVICE, INPUT, record['revision'], packed, hashlib.sha256(packed.encode()).hexdigest(), record['text'], record['created'], int(record['deleted']), record['updated']))
        return path

    def test_newer_mac_input_tombstone_wins_over_phone_replica_and_provenance_remains(self):
        path = self.make_mac(input_record(2, deleted=True))
        directory = self.root / 'merged'
        prepare(directory, self.export, OWNER, mac_input=path)
        backend = ContentBackend(directory)
        try:
            backend.transition(OWNER, str(uuid.uuid4()), 'activate', 0)
            request = {'schema':'apt.content-read/1','authority':backend.authority()['authority'],'source':self.input_source,'include_deleted':True}
            value = backend.read(OWNER, request)
            self.assertTrue(value['deleted'])
            self.assertEqual(value['snapshot']['revision'], 1, 'Formal and producer revisions have separate spaces')
            origins = json.loads(backend.db.execute("SELECT provenance_json FROM content_sources WHERE source_key LIKE '%input_memory%'").fetchone()[0])
            self.assertEqual([o['snapshot']['revision'] for o in origins], [1, 2])
        finally: backend.close()

    def test_same_mac_producer_version_with_conflicting_text_is_rejected(self):
        path = self.make_mac(input_record(1, text='Conflicting draft'))
        with self.assertRaisesRegex(ContentError, 'same_producer_version_has_different_content'):
            prepare(self.root / 'conflict', self.export, OWNER, mac_input=path)

    def test_correction_and_restore_keep_only_markers_present_in_current_text(self):
        self.backend.command(OWNER, self.request('correct', 1, source=self.input_source, text='Entirely revised draft'))
        value = self.read(self.input_source)
        self.assertEqual((value['attributes']['pasted'], value['attributes']['voiced']), ([], []))
        self.assertTrue(value['attributes']['partial'])
        bad = self.request('correct', 2, source=self.input_source, text=17)
        self.assertEqual(self.backend.command(OWNER, bad)['state'], 'rejected')
        self.backend.command(OWNER, self.request('delete', 2, source=self.input_source))
        self.backend.command(OWNER, self.request('restore', 3, source=self.input_source, text='Another revised draft'))
        restored = self.read(self.input_source)
        self.assertEqual((restored['attributes']['pasted'], restored['attributes']['voiced']), ([], []))
        self.assertEqual(restored['attributes']['apt_text_origin'], 'user_correction')

    def test_same_deleted_producer_version_still_compares_private_metadata(self):
        record = input_record(deleted=True)
        with sqlite3.connect(self.source) as db:
            packed = canonical(record)
            db.execute('UPDATE input_memory_sources SET record_json=?,content_hash=?,deleted=1', (packed.decode(), hashlib.sha256(packed).hexdigest()))
        fresh = self.root / 'deleted-export'
        export_snapshot(self.source, fresh, LIBRARY, 2)
        changed = copy.deepcopy(record)
        changed['app'] = 'Different producer app'
        changed['updated'] = '2026-10-14T02:01:00.000Z'
        mac = self.make_mac(changed)
        with self.assertRaisesRegex(ContentError, 'same_producer_version_has_different_content'):
            prepare(self.root / 'deleted-conflict', fresh, OWNER, mac_input=mac)

    def test_integer_wire_alias_replay_and_receipt_lookup_after_epoch_change(self):
        command = self.request()
        first = self.backend.command(OWNER, command)
        alias = copy.deepcopy(command)
        alias['expected_revision'] = 0.0
        alias['authority']['epoch'] = 1.0
        self.assertEqual(self.backend.command(OWNER, alias), first)
        self.backend.transition(OWNER, str(uuid.uuid4()), 'suspend', 1)
        request = {'schema':'apt.command-receipt-read/1','authority':self.backend.authority()['authority'],'request_id':command['request_id']}
        self.assertEqual(self.backend.receipt(OWNER, request), first)
        self.backend.transition(OWNER, str(uuid.uuid4()), 'resume', 2)
        self.assertEqual(self.backend.command(OWNER, command)['state'], 'stale')
        request['authority'] = self.backend.authority()['authority']
        self.assertEqual(self.backend.receipt(OWNER, request), first)
        self.assertEqual(self.read()['snapshot']['revision'], 1)

    def test_http_auth_and_raw_protocol_are_checked_before_writes(self):
        server = ContentHTTPServer(self.directory, OWNER, 't' * 48, 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        origin = 'http://127.0.0.1:' + str(server.server_address[1])
        def post(path, raw, token='t' * 48):
            request = urllib.request.Request(origin + path, data=raw, headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
            try:
                with urllib.request.urlopen(request, timeout=3) as response: return response.status, json.load(response)
            except urllib.error.HTTPError as response: return response.code, json.load(response)
        try:
            command = self.request()
            self.assertEqual(post('/content/commands', canonical(command), 'wrong')[0], 401)
            duplicate = canonical(command)[:-1] + b',"operation":"delete"}'
            self.assertEqual(post('/content/commands', duplicate)[0], 400)
            status, receipt = post('/content/commands', canonical(command))
            self.assertEqual((status, receipt['state']), (200, 'accepted'))
            self.assertEqual(post('/content/commands', canonical(command))[1], receipt)
            self.assertEqual(post('/content/activate', b'{}')[0], 404)
            malformed = self.request('update', 1)
            malformed['actor_id'] = DEVICE
            self.assertEqual(post('/content/commands', canonical(malformed))[0], 400)
            validate = {'schema':'apt.content-validate/1','authority':self.authority,'snapshots':[self.read()['snapshot']]}
            self.assertTrue(post('/content/validate', canonical(validate))[1]['current'])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(3)


if __name__ == '__main__': unittest.main()
