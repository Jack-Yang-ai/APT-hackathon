"""Adversarial portable-archive tests; fragment schemas are deliberately synthetic.

The real Swift schema and private captured library are separately reconciled.
These fragments test the migration engine, rather than duplicating app DDL.
"""
from __future__ import annotations
import json
import os
import shutil
import sqlite3
import tempfile
import threading
import unittest
from pathlib import Path

from shared.content_migration import ContentStage, MigrationError, export_snapshot, cell, uncell, canonical, digest

LIBRARY = "11111111-1111-4111-8111-111111111111"


class ContentMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "phone.sqlite"
        self.target = self.root / "stage.sqlite"
        with sqlite3.connect(self.source) as db:
            db.executescript("""
                CREATE TABLE sessions(id INTEGER PRIMARY KEY,active_transcript_id INTEGER);
                INSERT INTO sessions VALUES(1,1);
                CREATE TABLE transcripts(id INTEGER PRIMARY KEY,session_id INTEGER,version INTEGER,part INTEGER);
                INSERT INTO transcripts VALUES(1,1,1,0);
                CREATE TABLE transcript_lines(line_id INTEGER PRIMARY KEY,transcript_id INTEGER,text TEXT,redacted INTEGER,is_gap INTEGER);
                INSERT INTO transcript_lines VALUES(10,1,'Synthetic original quote',0,0),(11,1,'Removed private quote',1,0);
                CREATE TABLE judgments(id INTEGER PRIMARY KEY,action TEXT,payload TEXT);
                INSERT INTO judgments VALUES(1,'user-confirm','{"done":true}');
                CREATE TABLE voiceprints(id INTEGER PRIMARY KEY,embedding BLOB);
                INSERT INTO voiceprints VALUES(1,X'112233');
                CREATE TABLE enroll_ledger(instruction_id TEXT PRIMARY KEY,state TEXT);
                INSERT INTO enroll_ledger VALUES('do-not-replay','processed');
            """)

    def tearDown(self):
        self.temp.cleanup()

    def export(self, revision=1):
        directory = self.root / ("export"+str(revision))
        export_snapshot(self.source, directory, LIBRARY, revision)
        return directory

    def test_real_sqlite_reopen_original_ids_and_user_judgments(self):
        directory = self.export()
        before = self.source.read_bytes()
        stage = ContentStage(self.target)
        result = stage.import_snapshot(directory)
        self.assertFalse(result["authority_activated"])
        stage.close()
        restored = ContentStage(self.target, writable=False)
        self.assertEqual(restored.report(LIBRARY)["tables"]["judgments"], 1)
        source = restored.sources(LIBRARY)[0]
        self.assertEqual(source["snapshot"]["source"]["source_id"], "transcript_lines:10")
        self.assertEqual(source["authority"], {"domain":"content","phase":"staging","epoch":0})
        self.assertEqual(source["text"], "Synthetic original quote")
        self.assertEqual(len(restored.sources(LIBRARY)),1)
        restored.close()
        self.assertEqual(self.source.read_bytes(),before)
        self.assertEqual(os.stat(self.target).st_mode & 0o777,0o600)

    def test_voiceprint_data_is_backed_up_but_not_activated_or_exported(self):
        directory = self.export()
        manifest = json.loads((directory/"manifest.json").read_text())
        self.assertNotIn("voiceprints",manifest["tables"])
        self.assertNotIn("enroll_ledger",manifest["tables"])
        self.assertEqual(manifest["excluded"]["voiceprints"],"voiceprint_domain")
        self.assertNotIn("do-not-replay",(directory/"content.ndjson").read_text())
        with sqlite3.connect(directory/"source-backup.sqlite") as db:
            self.assertEqual(db.execute('SELECT embedding FROM voiceprints').fetchone()[0],b'\x11\x22\x33')

    def test_replay_is_idempotent_and_corrupt_replay_is_rejected(self):
        directory=self.export()
        stage=ContentStage(self.target)
        stage.import_snapshot(directory)
        self.assertEqual(stage.import_snapshot(directory)["status"],"already_imported")
        with (directory/"content.ndjson").open('ab') as file:file.write(b'{}\n')
        with self.assertRaises(MigrationError):stage.import_snapshot(directory)
        self.assertEqual(stage.report(LIBRARY)["revision"],1)
        stage.close()

    def test_delete_new_revision_then_old_snapshot_cannot_revive(self):
        old=self.export()
        stage=ContentStage(self.target)
        stage.import_snapshot(old)
        with sqlite3.connect(self.source) as db:db.execute('UPDATE transcript_lines SET redacted=1,text=? WHERE line_id=10',('Removed',))
        fresh=self.export(2)
        stage.import_snapshot(fresh)
        self.assertEqual(stage.sources(LIBRARY),[])
        with self.assertRaises(MigrationError):stage.import_snapshot(old)
        self.assertEqual(stage.report(LIBRARY)["revision"],2)
        stage.close()

    def test_corrupted_new_snapshot_rolls_back_all_rows_and_revision(self):
        old=self.export()
        stage=ContentStage(self.target)
        stage.import_snapshot(old)
        fresh=self.export(2)
        manifest=json.loads((fresh/"manifest.json").read_text())
        manifest['tables']['judgments']['rows']+=1
        manifest['rows']+=1
        (fresh/"manifest.json").write_text(json.dumps(manifest))
        with self.assertRaises(MigrationError):stage.import_snapshot(fresh)
        self.assertEqual(stage.report(LIBRARY)["revision"],1)
        self.assertEqual(stage.sources(LIBRARY)[0]["text"],"Synthetic original quote")
        stage.close()

    def test_tampered_staging_record_is_not_served(self):
        stage=ContentStage(self.target)
        stage.import_snapshot(self.export())
        stage.db.execute("UPDATE content_stage_rows SET values_json='[]' WHERE table_name='transcript_lines'")
        stage.db.commit()
        with self.assertRaises(MigrationError):stage.sources(LIBRARY)
        stage.close()

    def test_self_consistent_omission_still_fails_against_retained_backup(self):
        directory = self.export()
        manifest = json.loads((directory / 'manifest.json').read_text())
        manifest['tables'].pop('judgments')
        lines = [line for line in (directory / 'content.ndjson').read_bytes().splitlines(keepends=True) if json.loads(line)['table'] != 'judgments']
        packed = b''.join(lines)
        import hashlib
        manifest['records_fingerprint'] = hashlib.sha256(packed).hexdigest()
        manifest['rows'] = sum(meta['rows'] for meta in manifest['tables'].values())
        (directory / 'content.ndjson').write_bytes(packed)
        (directory / 'manifest.json').write_bytes(canonical(manifest))
        stage = ContentStage(self.target)
        with self.assertRaisesRegex(MigrationError, 'source_inventory_mismatch'):
            stage.import_snapshot(directory)
        with self.assertRaises(MigrationError):
            stage.report(LIBRARY)
        stage.close()

    def test_interrupted_import_preserves_the_previous_complete_revision(self):
        stage = ContentStage(self.target)
        stage.import_snapshot(self.export())
        fresh = self.export(2)
        stage.close()
        class InterruptedConnection(sqlite3.Connection):
            inserted = 0
            def execute(self, sql, parameters=()):
                if sql.startswith('INSERT INTO content_stage_rows'):
                    self.inserted += 1
                    if self.inserted == 2:
                        raise KeyboardInterrupt('synthetic interruption')
                return super().execute(sql, parameters)
        stage = ContentStage(self.target)
        stage.db.close()
        stage.db = sqlite3.connect(self.target, factory=InterruptedConnection)
        with self.assertRaises(KeyboardInterrupt):
            stage.import_snapshot(fresh)
        self.assertEqual(stage.report(LIBRARY)['revision'], 1)
        self.assertEqual(stage.sources(LIBRARY)[0]['text'], 'Synthetic original quote')
        stage.close()

    def test_concurrent_import_cannot_overwrite_a_newer_deleted_revision(self):
        stage = ContentStage(self.target)
        stage.import_snapshot(self.export())
        stage.close()
        low = self.export(2)
        with sqlite3.connect(self.source) as db:
            db.execute('UPDATE transcript_lines SET redacted=1')
        high = self.export(3)
        observed, newer_done = threading.Event(), threading.Event()
        errors = []
        class PausedCursor:
            def __init__(self, cursor):
                self.cursor = cursor
            def fetchone(self):
                value = self.cursor.fetchone()
                observed.set()
                newer_done.wait(0.5)
                return value
        class PausedConnection(sqlite3.Connection):
            def execute(self, sql, parameters=()):
                cursor = super().execute(sql, parameters)
                return PausedCursor(cursor) if sql.startswith('SELECT revision,') else cursor
        def importing(directory, pause=False):
            local = ContentStage(self.target)
            if pause:
                local.db.close()
                local.db = sqlite3.connect(self.target, factory=PausedConnection)
            try:
                local.import_snapshot(directory)
            except Exception as error:
                errors.append(error)
            finally:
                local.close()
                if not pause:
                    newer_done.set()
        first = threading.Thread(target=importing, args=(low, True))
        second = threading.Thread(target=importing, args=(high,))
        first.start()
        self.assertTrue(observed.wait(2))
        second.start()
        first.join(5)
        second.join(5)
        self.assertFalse(first.is_alive() or second.is_alive())
        self.assertEqual(errors, [])
        stage = ContentStage(self.target, writable=False)
        self.assertEqual(stage.report(LIBRARY)['revision'], 3)
        self.assertEqual(stage.sources(LIBRARY), [])
        stage.close()

    def test_extra_staging_rows_cannot_escape_reconciliation(self):
        stage = ContentStage(self.target)
        stage.import_snapshot(self.export())
        stage.db.execute('INSERT INTO content_stage_rows VALUES(?,?,?,?,?,?)', (LIBRARY, 'unexpected', '[]', digest([]), '[]', 0))
        stage.db.commit()
        with self.assertRaises(MigrationError):
            stage.report(LIBRARY)
        stage.close()

    def test_old_transcript_versions_are_retained_but_only_all_active_parts_are_served(self):
        with sqlite3.connect(self.source) as db:
            db.executescript("""
                INSERT INTO transcripts VALUES(2,1,2,0),(3,1,2,1);
                INSERT INTO transcript_lines VALUES(20,2,'Current first part',0,0),(21,3,'Current last part',0,0);
                UPDATE sessions SET active_transcript_id=3;
            """)
        stage = ContentStage(self.target)
        stage.import_snapshot(self.export())
        self.assertEqual(stage.report(LIBRARY)['tables']['transcript_lines'], 4)
        self.assertEqual({s['text'] for s in stage.sources(LIBRARY)}, {'Current first part', 'Current last part'})
        self.assertEqual(stage.sources(LIBRARY, 'Synthetic original'), [])
        stage.close()

    def test_unknown_source_table_blocks_export_and_retains_backup(self):
        with sqlite3.connect(self.source) as db:db.execute('CREATE TABLE unclassified(id INTEGER PRIMARY KEY)')
        with self.assertRaises(MigrationError):self.export()
        self.assertTrue((self.root/'export1/source-backup.sqlite').is_file())

    def test_sqlite_lookalike_table_cannot_be_silently_omitted(self):
        with sqlite3.connect(self.source) as db:
            db.execute('CREATE TABLE sqlitex_personal(id INTEGER PRIMARY KEY)')
        with self.assertRaisesRegex(MigrationError, 'unclassified_source_table:sqlitex_personal'):
            self.export()
        self.assertTrue((self.root / 'export1/source-backup.sqlite').is_file())

    def test_nullable_primary_keys_require_explicit_identity_before_export(self):
        with sqlite3.connect(self.source) as db:
            db.executescript('DROP TABLE judgments; CREATE TABLE judgments(id TEXT PRIMARY KEY,payload TEXT); INSERT INTO judgments VALUES(NULL,"one"),(NULL,"two");')
        with self.assertRaisesRegex(MigrationError, 'null_primary_key_requires_explicit_identity'):
            self.export()
        self.assertTrue((self.root / 'export1/source-backup.sqlite').is_file())

    def test_unrelated_database_not_modified_and_missing_read_visible(self):
        before=self.source.read_bytes()
        with self.assertRaises(MigrationError):ContentStage(self.source)
        self.assertEqual(self.source.read_bytes(),before)
        with self.assertRaises(MigrationError):ContentStage(self.root/'absent.sqlite',writable=False)
        self.assertFalse((self.root/'absent.sqlite').exists())

    def test_int64_blob_null_and_float_roundtrip_exactly(self):
        for value in (None,2**63-1,-2**63,b'\x00\xff',-0.0,1.23456789,'原话😀'):
            restored=uncell(cell(value))
            self.assertEqual(restored,value)
            self.assertIs(type(restored),type(value))
        for invalid in (["integer","01"],["blob","?"],["real","inf"]):
            with self.assertRaises(MigrationError):uncell(invalid)

    def test_live_wal_backup_includes_committed_rows(self):
        connection=sqlite3.connect(self.source)
        connection.execute('PRAGMA journal_mode=WAL')
        connection.execute("INSERT INTO transcript_lines VALUES(12,1,'Committed WAL quote',0,0)")
        connection.commit()
        directory=self.export()
        stage=ContentStage(self.target)
        stage.import_snapshot(directory)
        self.assertEqual(len(stage.sources(LIBRARY)),2)
        stage.close()
        connection.close()


if __name__=='__main__':unittest.main()
