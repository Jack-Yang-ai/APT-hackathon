import Foundation
import GRDB











enum AppDatabase {











    static func defaultURL() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        return dir.appendingPathComponent("growth.sqlite")
    }









    static func open(at url: URL? = nil) throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue(path: (url ?? defaultURL()).path)
        try makeMigrator().migrate(dbQueue)
        return dbQueue
    }
















    static let sharedResult: Result<DatabaseQueue, Error> = Result { try open() }

    static var shared: DatabaseQueue? { try? sharedResult.get() }

















    private static let maintainCurrentTriggerSQL = """
CREATE TRIGGER judgments_maintain_current
                AFTER INSERT ON judgments
                FOR EACH ROW
                BEGIN
                  DELETE FROM judgment_current
                   WHERE target_kind = NEW.target_kind AND target_id = NEW.target_id;

                  INSERT INTO judgment_current (target_kind, target_id, judgment_id)
                  SELECT NEW.target_kind, NEW.target_id, root FROM (
                    WITH RECURSIVE
                    scoped(id, action, undoes) AS (
                      SELECT id, action, undoes FROM judgments
                       WHERE target_kind = NEW.target_kind AND target_id = NEW.target_id
                    ),
                    chain(root, node, depth) AS (
                      SELECT id, id, 0 FROM scoped WHERE action <> 'undo'
                      UNION ALL
                      SELECT c.root, u.id, c.depth + 1
                        FROM chain c JOIN scoped u ON u.undoes = c.node
                    )
                    SELECT root, MAX(depth) AS len FROM chain GROUP BY root
                  )
                  WHERE len % 2 = 0
                  ORDER BY root DESC
                  LIMIT 1;
                END
"""

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_frozen_and_attribution") { db in


            try db.execute(sql: """
                CREATE TABLE sessions (
                  id                   INTEGER PRIMARY KEY AUTOINCREMENT,
                  started_at           TEXT    NOT NULL,
                  ended_at             TEXT,
                  day                  TEXT    NOT NULL,
                  source               TEXT    NOT NULL,
                  status               TEXT    NOT NULL,
                  active_transcript_id INTEGER
                )
                """)


            try db.execute(sql: """
                CREATE TABLE transcripts (
                  id            INTEGER PRIMARY KEY AUTOINCREMENT,
                  session_id    INTEGER NOT NULL REFERENCES sessions(id),
                  version       INTEGER NOT NULL,
                  part          INTEGER NOT NULL DEFAULT 1,
                  asr_model     TEXT    NOT NULL,
                  status        TEXT    NOT NULL
                                  CHECK (status IN ('pending','frozen','partial')),
                  created_at    TEXT    NOT NULL,
                  frozen_at     TEXT,
                  UNIQUE(session_id, version, part)
                )
                """)


            try db.execute(sql: """
                CREATE TABLE transcript_lines (
                  line_id       INTEGER PRIMARY KEY AUTOINCREMENT,
                  transcript_id INTEGER NOT NULL REFERENCES transcripts(id),
                  seq           INTEGER NOT NULL,
                  t_start_ms    INTEGER NOT NULL,
                  t_end_ms      INTEGER NOT NULL,
                  text          TEXT    NOT NULL,
                  char_offset   INTEGER NOT NULL,
                  is_gap        INTEGER NOT NULL DEFAULT 0,
                  redacted      INTEGER NOT NULL DEFAULT 0,
                  UNIQUE(transcript_id, seq)
                )
                """)


            try db.execute(sql: """
                CREATE TABLE line_speakers (
                  line_id     INTEGER PRIMARY KEY REFERENCES transcript_lines(line_id),
                  person_id   INTEGER,
                  cluster_tag TEXT,
                  role        TEXT,
                  confidence  REAL,
                  source      TEXT NOT NULL CHECK (source IN
                                ('系统整理','声纹识别','平台标注','系统交叉验证','用户确认')),
                  updated_at  TEXT NOT NULL
                )
                """)


            try db.execute(sql: "CREATE INDEX idx_transcript_lines_transcript_seq ON transcript_lines(transcript_id, seq)")
            try db.execute(sql: "CREATE INDEX idx_transcript_lines_t_start ON transcript_lines(t_start_ms)")
            try db.execute(sql: "CREATE INDEX idx_line_speakers_person ON line_speakers(person_id)")







            try db.execute(sql: """
                CREATE TRIGGER transcript_lines_no_update
                BEFORE UPDATE ON transcript_lines
                FOR EACH ROW
                WHEN NOT (
                      OLD.redacted      = 0
                  AND NEW.redacted      = 1
                  AND NEW.line_id       = OLD.line_id
                  AND NEW.transcript_id = OLD.transcript_id
                  AND NEW.seq           = OLD.seq
                  AND NEW.t_start_ms    = OLD.t_start_ms
                  AND NEW.t_end_ms      = OLD.t_end_ms
                  AND NEW.char_offset   = OLD.char_offset
                  AND NEW.is_gap        = OLD.is_gap
                )
                BEGIN
                  SELECT RAISE(ABORT, 'transcript_lines 已冻结:唯一允许的变更是 redact 通道(text 置墓碑 + redacted 0→1)');
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER transcript_lines_no_delete
                BEFORE DELETE ON transcript_lines
                FOR EACH ROW
                BEGIN
                  SELECT RAISE(ABORT, 'transcript_lines 永不 DELETE:移出记忆走 redact 墓碑通道(§3.1.7)');
                END
                """)





            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcript_lines_fts USING fts5(
                  text,
                  content='transcript_lines',
                  content_rowid='line_id',
                  tokenize='trigram'
                )
                """)


            try db.execute(sql: """
                CREATE TRIGGER transcript_lines_fts_insert
                AFTER INSERT ON transcript_lines
                FOR EACH ROW WHEN NEW.is_gap = 0 AND NEW.redacted = 0
                BEGIN
                  INSERT INTO transcript_lines_fts(rowid, text) VALUES (NEW.line_id, NEW.text);
                END
                """)



            try db.execute(sql: """
                CREATE TRIGGER transcript_lines_fts_redact
                AFTER UPDATE ON transcript_lines
                FOR EACH ROW WHEN OLD.is_gap = 0 AND OLD.redacted = 0
                BEGIN
                  INSERT INTO transcript_lines_fts(transcript_lines_fts, rowid, text)
                    VALUES ('delete', OLD.line_id, OLD.text);
                END
                """)
        }






        migrator.registerMigration("v2_judgments") { db in

            try db.execute(sql: """
                CREATE TABLE judgments (
                  id             INTEGER PRIMARY KEY AUTOINCREMENT,
                  decided_at     TEXT    NOT NULL,
                  actor          TEXT    NOT NULL CHECK (actor IN ('user','system-cascade')),
                  caused_by      INTEGER REFERENCES judgments(id),
                  action         TEXT    NOT NULL,
                  target_kind    TEXT    NOT NULL,
                  target_id      TEXT    NOT NULL,
                  payload        TEXT,
                  basis_line_ids TEXT
                )
                """)

            try db.execute(sql: "CREATE INDEX idx_judgments_target ON judgments(target_kind, target_id, id DESC)")
            try db.execute(sql: "CREATE INDEX idx_judgments_caused ON judgments(caused_by)")


            try db.execute(sql: """
                CREATE TRIGGER judgments_no_update BEFORE UPDATE ON judgments
                BEGIN SELECT RAISE(ABORT, 'judgments is append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER judgments_no_delete BEFORE DELETE ON judgments
                BEGIN SELECT RAISE(ABORT, 'judgments is append-only'); END
                """)


            try db.execute(sql: """
                CREATE TABLE id_remaps (
                  kind             TEXT    NOT NULL,
                  old_id           TEXT    NOT NULL,
                  new_id           TEXT    NOT NULL,
                  recompute_run_id INTEGER NOT NULL
                )
                """)



            try db.execute(sql: """
                CREATE TABLE judgment_current (
                  target_kind TEXT    NOT NULL,
                  target_id   TEXT    NOT NULL,
                  judgment_id INTEGER NOT NULL REFERENCES judgments(id),
                  PRIMARY KEY (target_kind, target_id)
                )
                """)











            try db.execute(sql: """
                CREATE TRIGGER judgments_maintain_current
                AFTER INSERT ON judgments
                FOR EACH ROW
                BEGIN
                  DELETE FROM judgment_current
                   WHERE target_kind = NEW.target_kind AND target_id = NEW.target_id;

                  INSERT INTO judgment_current (target_kind, target_id, judgment_id)
                  SELECT NEW.target_kind, NEW.target_id, j.id
                    FROM judgments j
                   WHERE j.target_kind = NEW.target_kind
                     AND j.target_id   = NEW.target_id
                     AND j.action <> 'undo'
                     AND j.id NOT IN (
                           SELECT u.caused_by FROM judgments u
                            WHERE u.target_kind = NEW.target_kind
                              AND u.target_id   = NEW.target_id
                              AND u.action      = 'undo'
                              AND u.caused_by IS NOT NULL
                         )
                   ORDER BY j.id DESC
                   LIMIT 1;
                END
                """)
        }










        migrator.registerMigration("v3_judgments_undoes") { db in

            try db.execute(sql: "ALTER TABLE judgments ADD COLUMN undoes INTEGER REFERENCES judgments(id)")
            try db.execute(sql: "CREATE INDEX idx_judgments_undoes ON judgments(undoes)")








            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_judgments_undoes_once
                    ON judgments(undoes) WHERE undoes IS NOT NULL
                """)

            try db.execute(sql: "DROP TRIGGER judgments_maintain_current")











            try db.execute(sql: """
                \(maintainCurrentTriggerSQL)
                """)
        }









        migrator.registerMigration("v4_content_and_tasks") { db in









            try db.execute(sql: """
                CREATE TABLE summaries (
                  transcript_id INTEGER PRIMARY KEY REFERENCES transcripts(id),
                  one_liner     TEXT    NOT NULL,
                  created_at    TEXT    NOT NULL
                )
                """)



            for (table, extra) in [
                ("summary_key_points",  "text TEXT NOT NULL"),
                ("summary_commitments", "what TEXT NOT NULL, to_whom_text TEXT"),
                ("summary_stances",     "stance TEXT NOT NULL, premise TEXT, premise_line_id INTEGER REFERENCES transcript_lines(line_id)"),
                ("summary_pendings",    "issue TEXT NOT NULL, parties_text TEXT"),
            ] {
                try db.execute(sql: """
                    CREATE TABLE \(table) (
                      id             INTEGER PRIMARY KEY AUTOINCREMENT,
                      transcript_id  INTEGER NOT NULL REFERENCES transcripts(id),
                      line_id        INTEGER NOT NULL REFERENCES transcript_lines(line_id),
                      seq            INTEGER NOT NULL,
                      \(extra),
                      quote          TEXT    NOT NULL,
                      pending        INTEGER NOT NULL DEFAULT 0,
                      pending_reason TEXT,
                      UNIQUE(transcript_id, seq)
                    )
                    """)
                try db.execute(sql: "CREATE INDEX idx_\(table)_line ON \(table)(line_id)")
            }


            try db.execute(sql: """
                CREATE TABLE summary_topic_keys (
                  id            INTEGER PRIMARY KEY AUTOINCREMENT,
                  transcript_id INTEGER NOT NULL REFERENCES transcripts(id),
                  key           TEXT    NOT NULL,
                  line_ids      TEXT    NOT NULL
                )
                """)











            try db.execute(sql: """
                CREATE TABLE task_state_display (
                  state         TEXT PRIMARY KEY,
                  display_state TEXT NOT NULL
                )
                """)
            for (state, display) in [
                ("waiting_network", "waitingForNetwork"),
                ("uploading",       "uploading"),
                ("queued",          "queued"),
                ("running",         "processing"),
                ("attributing",     "attributionPending"),  // 已出纪要,说话人还在整理
                ("done",            "done"),
                ("retrying",        "failed"),               // 「处理失败,重试中(第 N 次)」
                ("dead",            "failed"),               // §1.3:超上限映射为「失败」
                ("degraded",        "degraded"),
            ] {
                try db.execute(sql: "INSERT INTO task_state_display (state, display_state) VALUES (?, ?)",
                               arguments: [state, display])
            }

            try db.execute(sql: """
                CREATE TABLE tasks (
                  task_id       INTEGER PRIMARY KEY AUTOINCREMENT,
                  kind          TEXT    NOT NULL,
                  session_id    INTEGER REFERENCES sessions(id),
                  attempts      INTEGER NOT NULL DEFAULT 0,
                  next_retry_at TEXT,
                  state         TEXT    NOT NULL REFERENCES task_state_display(state),
                  last_error    TEXT,

                  priority      INTEGER NOT NULL DEFAULT 1 CHECK (priority IN (0, 1)),
                  created_at    TEXT    NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_tasks_pickup ON tasks(state, priority, next_retry_at)")
        }








        migrator.registerMigration("v5_voiceprints") { db in



            try db.execute(sql: """
                CREATE TABLE voiceprints (
                  id             INTEGER PRIMARY KEY AUTOINCREMENT,
                  person_id      INTEGER NOT NULL,
                  embedding      BLOB    NOT NULL,   -- f32 原始字节
                  dim            INTEGER NOT NULL CHECK (dim > 0),
                  source         TEXT    NOT NULL,   -- 这条是哪次确认来的
                  created_at     TEXT    NOT NULL,


                  instruction_id TEXT    NOT NULL UNIQUE
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_voiceprints_person ON voiceprints(person_id)")





            try db.execute(sql: """
                CREATE TABLE enroll_ledger (
                  instruction_id TEXT PRIMARY KEY,
                  state          TEXT NOT NULL CHECK (state IN ('processed', 'revoked')),
                  updated_at     TEXT NOT NULL
                )
                """)
        }








        migrator.registerMigration("v6_mixed_lines") { db in
            try db.execute(sql: """
                CREATE TABLE mixed_lines (
                  line_id     INTEGER PRIMARY KEY REFERENCES transcript_lines(line_id),
                  overlap_ms  INTEGER NOT NULL CHECK (overlap_ms > 0),
                  threshold_ms INTEGER NOT NULL,   -- 用哪个阈值算出来的,便于回溯
                  detected_at TEXT    NOT NULL
                )
                """)
        }














        migrator.registerMigration("v7_voiceprint_model") { db in
            try db.execute(sql: """
                ALTER TABLE voiceprints
                  ADD COLUMN model TEXT NOT NULL DEFAULT 'unknown-pre-v7'
                """)
        }













        migrator.registerMigration("v8_session_identity") { db in
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_sessions_origin ON sessions(source, started_at)
                """)
        }




























        migrator.registerMigration("v9_session_grade") { db in
            try db.execute(sql: """
                ALTER TABLE sessions ADD COLUMN grade TEXT
                  CHECK (grade IS NULL OR grade IN
                         ('full','light','transcript_only','discard'))
                """)
            try db.execute(sql: """
                ALTER TABLE sessions ADD COLUMN grade_source TEXT
                """)
        }














        migrator.registerMigration("v10_word_index") { db in
            try db.execute(sql: """
                CREATE TABLE transcript_line_tokens (
                  line_id INTEGER PRIMARY KEY REFERENCES transcript_lines(line_id),
                  tokens  TEXT NOT NULL
                )
                """)



            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcript_line_tokens_fts USING fts5(
                  tokens,
                  content='transcript_line_tokens',
                  content_rowid='line_id',
                  tokenize='unicode61'
                )
                """)

            try db.execute(sql: """
                CREATE TRIGGER transcript_line_tokens_fts_insert
                AFTER INSERT ON transcript_line_tokens
                FOR EACH ROW
                BEGIN
                  INSERT INTO transcript_line_tokens_fts(rowid, tokens)
                    VALUES (NEW.line_id, NEW.tokens);
                END
                """)


            try db.execute(sql: """
                CREATE TRIGGER transcript_line_tokens_fts_delete
                AFTER DELETE ON transcript_line_tokens
                FOR EACH ROW
                BEGIN
                  INSERT INTO transcript_line_tokens_fts(transcript_line_tokens_fts, rowid, tokens)
                    VALUES ('delete', OLD.line_id, OLD.tokens);
                END
                """)



            try db.execute(sql: """
                CREATE TRIGGER transcript_line_tokens_redact
                AFTER UPDATE ON transcript_lines
                FOR EACH ROW WHEN OLD.redacted = 0 AND NEW.redacted = 1
                BEGIN
                  DELETE FROM transcript_line_tokens WHERE line_id = OLD.line_id;
                END
                """)
        }












        migrator.registerMigration("v11_asr_jobs") { db in
            try db.execute(sql: """
                CREATE TABLE asr_jobs (
                  session_id  INTEGER NOT NULL REFERENCES sessions(id),
                  block_seq   INTEGER NOT NULL,

                  remote_id   TEXT    NOT NULL,
                  state       TEXT    NOT NULL
                                CHECK (state IN ('submitted', 'done', 'failed')),


                  result_json TEXT,
                  last_error  TEXT,
                  created_at  TEXT    NOT NULL,
                  updated_at  TEXT    NOT NULL,
                  PRIMARY KEY (session_id, block_seq)
                )
                """)
            try db.execute(sql:
                "CREATE INDEX idx_asr_jobs_state ON asr_jobs(state, created_at)")
        }




        migrator.registerMigration("v12_background") { db in




            try db.execute(sql: """
                CREATE TABLE upload_jobs (
                  session_id  INTEGER NOT NULL REFERENCES sessions(id),
                  block_seq   INTEGER NOT NULL,
                  r2_key      TEXT    NOT NULL,



                  state       TEXT    NOT NULL CHECK (state IN ('handed','done','failed')),
                  http_status INTEGER,
                  last_error  TEXT,
                  created_at  TEXT    NOT NULL,
                  updated_at  TEXT    NOT NULL,
                  PRIMARY KEY (session_id, block_seq)
                )
                """)
            try db.execute(sql:
                "CREATE INDEX idx_upload_jobs_state ON upload_jobs(state, updated_at)")









            try db.execute(sql: """
                CREATE TABLE processing_events (
                  id      INTEGER PRIMARY KEY AUTOINCREMENT,
                  at      TEXT NOT NULL,



                  trigger TEXT NOT NULL CHECK (trigger IN ('前台','后台唤醒','传输回调')),
                  outcome TEXT NOT NULL,
                  detail  TEXT
                )
                """)
            try db.execute(sql:
                "CREATE INDEX idx_processing_events_at ON processing_events(at DESC)")
        }
















        migrator.registerMigration("v13_judgment_actor_system") { db in

            try db.execute(sql: "DROP TRIGGER judgments_no_update")
            try db.execute(sql: "DROP TRIGGER judgments_no_delete")
            try db.execute(sql: "DROP TRIGGER judgments_maintain_current")

            try db.execute(sql: """
                CREATE TABLE judgments_new (
                  id             INTEGER PRIMARY KEY AUTOINCREMENT,
                  decided_at     TEXT    NOT NULL,
                  actor          TEXT    NOT NULL
                                   CHECK (actor IN ('user','system-cascade','system')),
                  caused_by      INTEGER REFERENCES judgments(id),
                  action         TEXT    NOT NULL,
                  target_kind    TEXT    NOT NULL,
                  target_id      TEXT    NOT NULL,
                  payload        TEXT,
                  basis_line_ids TEXT,
                  undoes         INTEGER REFERENCES judgments(id)
                )
                """)

            try db.execute(sql: """
                INSERT INTO judgments_new
                  (id, decided_at, actor, caused_by, action, target_kind, target_id,
                   payload, basis_line_ids, undoes)
                SELECT id, decided_at, actor, caused_by, action, target_kind, target_id,
                       payload, basis_line_ids, undoes FROM judgments
                """)
            try db.execute(sql: "DROP TABLE judgments")
            try db.execute(sql: "ALTER TABLE judgments_new RENAME TO judgments")

            try db.execute(sql: "CREATE INDEX idx_judgments_target ON judgments(target_kind, target_id, id DESC)")
            try db.execute(sql: "CREATE INDEX idx_judgments_caused ON judgments(caused_by)")
            try db.execute(sql: "CREATE INDEX idx_judgments_undoes ON judgments(undoes)")
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_judgments_undoes_once
                    ON judgments(undoes) WHERE undoes IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE TRIGGER judgments_no_update BEFORE UPDATE ON judgments
                BEGIN SELECT RAISE(ABORT, 'judgments is append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER judgments_no_delete BEFORE DELETE ON judgments
                BEGIN SELECT RAISE(ABORT, 'judgments is append-only'); END
                """)
            try db.execute(sql: maintainCurrentTriggerSQL)
        }




























        migrator.registerMigration("v14_persons") { db in
            try db.execute(sql: """
                CREATE TABLE persons (










                  id         INTEGER PRIMARY KEY AUTOINCREMENT,









                  name       TEXT,
                  source     TEXT    NOT NULL
                               CHECK (source IN ('本人','声纹种子','用户创建','迁移回填')),
                  created_at TEXT    NOT NULL,
                  updated_at TEXT    NOT NULL
                )
                """)




            let now = ISO8601DateFormatter.growth.string(from: Date())
            try db.execute(sql: """
                INSERT INTO persons (id, name, source, created_at, updated_at)
                VALUES (-1, '我', '本人', ?, ?)
                """, arguments: [now, now])




            try db.execute(sql: """
                INSERT INTO persons (id, name, source, created_at, updated_at)
                SELECT id, NULL, '迁移回填', ?, ? FROM (
                    SELECT DISTINCT person_id AS id FROM line_speakers
                     WHERE person_id IS NOT NULL
                    UNION
                    SELECT DISTINCT person_id AS id FROM voiceprints
                ) WHERE id NOT IN (SELECT id FROM persons)
                """, arguments: [now, now])
            let backfilled = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM persons WHERE source = '迁移回填'") ?? 0
            if backfilled > 0 {

                try db.execute(sql: """
                    INSERT INTO processing_events (at, trigger, outcome, detail)
                    VALUES (?, '前台', ?, ?)
                    """, arguments: [now, "迁移 v14 回填了 \(backfilled) 个无主 person_id",
                                     "按现在的写路径这个数应该是 0 —— 非零说明有一条没被登记的写路径"])
            }





            try db.execute(sql: """
                CREATE TABLE line_speakers_new (
                  line_id     INTEGER PRIMARY KEY REFERENCES transcript_lines(line_id),
                  person_id   INTEGER REFERENCES persons(id),
                  cluster_tag TEXT,
                  role        TEXT,
                  confidence  REAL,
                  source      TEXT NOT NULL CHECK (source IN
                                ('系统整理','声纹识别','平台标注','系统交叉验证','用户确认')),
                  updated_at  TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                INSERT INTO line_speakers_new
                  (line_id, person_id, cluster_tag, role, confidence, source, updated_at)
                SELECT line_id, person_id, cluster_tag, role, confidence, source, updated_at
                  FROM line_speakers
                """)
            try db.execute(sql: "DROP TABLE line_speakers")
            try db.execute(sql: "ALTER TABLE line_speakers_new RENAME TO line_speakers")
            try db.execute(sql:
                "CREATE INDEX idx_line_speakers_person ON line_speakers(person_id)")








            try db.execute(sql: """
                CREATE TABLE voiceprints_new (
                  id             INTEGER PRIMARY KEY AUTOINCREMENT,
                  person_id      INTEGER NOT NULL REFERENCES persons(id),
                  embedding      BLOB    NOT NULL,
                  dim            INTEGER NOT NULL CHECK (dim > 0),
                  source         TEXT    NOT NULL,
                  created_at     TEXT    NOT NULL,
                  instruction_id TEXT    NOT NULL UNIQUE,
                  model          TEXT    NOT NULL DEFAULT 'unknown-pre-v7'
                )
                """)
            try db.execute(sql: """
                INSERT INTO voiceprints_new
                  (id, person_id, embedding, dim, source, created_at, instruction_id, model)
                SELECT id, person_id, embedding, dim, source, created_at, instruction_id, model
                  FROM voiceprints
                """)
            try db.execute(sql: "DROP TABLE voiceprints")
            try db.execute(sql: "ALTER TABLE voiceprints_new RENAME TO voiceprints")
            try db.execute(sql: "CREATE INDEX idx_voiceprints_person ON voiceprints(person_id)")
        }





















        migrator.registerMigration("v15_line_block_seq") { db in
            try db.execute(sql: "ALTER TABLE transcript_lines ADD COLUMN block_seq INTEGER")
        }






















        migrator.registerMigration("v16_ask_conversations") { db in
            try db.execute(sql: """
                CREATE TABLE ask_conversations (
                  id         INTEGER PRIMARY KEY AUTOINCREMENT,
                  started_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,


                  title      TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE ask_turns (
                  id              INTEGER PRIMARY KEY AUTOINCREMENT,
                  conversation_id INTEGER NOT NULL REFERENCES ask_conversations(id),
                  seq             INTEGER NOT NULL,
                  asked_at        TEXT    NOT NULL,
                  question        TEXT    NOT NULL,
                  answer          TEXT,
                  status          TEXT    NOT NULL
                                    CHECK (status IN ('提问中','已回答','失败')),


                  error           TEXT,

                  cited_line_ids  TEXT,
                  UNIQUE(conversation_id, seq)
                )
                """)
            try db.execute(sql:
                "CREATE INDEX idx_ask_turns_conv ON ask_turns(conversation_id, seq)")

            try db.execute(sql:
                "CREATE INDEX idx_ask_conversations_updated ON ask_conversations(updated_at DESC)")
        }

















        migrator.registerMigration("v17_kept_intervals") { db in
            try db.execute(sql: "ALTER TABLE upload_jobs ADD COLUMN kept_json TEXT")
        }































        migrator.registerMigration("v18_line_revisions") { db in

            try db.execute(sql: """
                CREATE TABLE transcript_line_revisions (
                  id        INTEGER PRIMARY KEY AUTOINCREMENT,
                  line_id   INTEGER NOT NULL REFERENCES transcript_lines(line_id),
                  before    TEXT    NOT NULL,
                  after     TEXT    NOT NULL,
                  actor     TEXT    NOT NULL,
                  at        TEXT    NOT NULL
                )
                """)
            try db.execute(sql:
                "CREATE INDEX idx_transcript_line_revisions_line ON transcript_line_revisions(line_id)")







            try db.execute(sql: """
                CREATE TRIGGER transcript_line_revisions_no_update
                BEFORE UPDATE ON transcript_line_revisions
                FOR EACH ROW










                WHEN NOT (    NEW.before  = ''
                          AND NEW.after   = ''
                          AND NEW.id      = OLD.id
                          AND NEW.line_id = OLD.line_id
                          AND NEW.actor   = OLD.actor
                          AND NEW.at      = OLD.at )
                BEGIN SELECT RAISE(ABORT, 'transcript_line_revisions 只增不改:唯一例外是移出记忆的墓碑通道(before/after 双双清空,其余列不动)'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER transcript_line_revisions_no_delete
                BEFORE DELETE ON transcript_line_revisions
                BEGIN SELECT RAISE(ABORT, 'transcript_line_revisions is append-only'); END
                """)






            try db.execute(sql: "DROP TRIGGER transcript_lines_no_update")
            try db.execute(sql: """
                CREATE TRIGGER transcript_lines_no_update
                BEFORE UPDATE ON transcript_lines
                FOR EACH ROW
                WHEN NOT (

                    (   OLD.redacted      = 0 AND NEW.redacted = 1
                    AND NEW.line_id       = OLD.line_id
                    AND NEW.transcript_id = OLD.transcript_id
                    AND NEW.seq           = OLD.seq
                    AND NEW.t_start_ms    = OLD.t_start_ms
                    AND NEW.t_end_ms      = OLD.t_end_ms
                    AND NEW.char_offset   = OLD.char_offset
                    AND NEW.is_gap        = OLD.is_gap


                    AND NEW.block_seq     IS OLD.block_seq )
                 OR -- 通道二:行级修订。必须已有一条对得上的修订记录 —— 由 DB 强制留痕。


                    (   OLD.redacted      = 0 AND NEW.redacted = 0 AND OLD.is_gap = 0
                    AND NEW.line_id       = OLD.line_id
                    AND NEW.transcript_id = OLD.transcript_id
                    AND NEW.seq           = OLD.seq
                    AND NEW.t_start_ms    = OLD.t_start_ms
                    AND NEW.t_end_ms      = OLD.t_end_ms
                    AND NEW.is_gap        = OLD.is_gap
                    AND NEW.block_seq     IS OLD.block_seq
                    AND EXISTS (SELECT 1 FROM transcript_line_revisions r
                                 WHERE r.line_id = OLD.line_id
                                   AND r.before  = OLD.text
                                   AND r.after   = NEW.text


                                   AND r.id = (SELECT MAX(id) FROM transcript_line_revisions
                                                WHERE line_id = OLD.line_id)) )
                 OR -- 通道三:后续行的 char_offset 推移。**只准动偏移,文字必须逐字相同。**

                    (   NEW.text          = OLD.text
                    AND NEW.redacted      = OLD.redacted
                    AND NEW.line_id       = OLD.line_id
                    AND NEW.transcript_id = OLD.transcript_id
                    AND NEW.seq           = OLD.seq
                    AND NEW.t_start_ms    = OLD.t_start_ms
                    AND NEW.t_end_ms      = OLD.t_end_ms
                    AND NEW.is_gap        = OLD.is_gap


                    AND NEW.block_seq     IS OLD.block_seq )
                )
                BEGIN
                  SELECT RAISE(ABORT, 'transcript_lines 已冻结:只有三条通道 —— redact 墓碑 / 行级修订(须先写 transcript_line_revisions)/ char_offset 推移(文字不变)');
                END
                """)















            try db.execute(sql: "DROP TRIGGER transcript_lines_fts_redact")
            try db.execute(sql: """
                CREATE TRIGGER transcript_lines_fts_redact
                AFTER UPDATE ON transcript_lines
                FOR EACH ROW WHEN OLD.is_gap = 0 AND OLD.redacted = 0 AND NEW.redacted = 1
                BEGIN
                  INSERT INTO transcript_lines_fts(transcript_lines_fts, rowid, text)
                    VALUES ('delete', OLD.line_id, OLD.text);
                END
                """)
        }


























        migrator.registerMigration("v19_matters") { db in


            try db.execute(sql: """
                CREATE TABLE matter_states (
                  state         TEXT PRIMARY KEY,


                  in_comparison INTEGER NOT NULL CHECK (in_comparison IN (0, 1)),
                  takes_slot    INTEGER NOT NULL CHECK (takes_slot    IN (0, 1)),
                  searchable    INTEGER NOT NULL CHECK (searchable    IN (0, 1))
                )
                """)

            for (st, cmp, slot, search) in [
                ("候选",   0, 0, 1),   // 在候选区可搜
                ("活跃",   1, 1, 1),
                ("沉睡",   0, 0, 1),
                ("已结案", 0, 0, 1),
                ("已拒绝", 0, 0, 1),   // PRD 特意标粗:拒绝过的仍可搜索找回
                ("已合并", 0, 0, 1),   // 搜到跳转到并入的那件
            ] {
                try db.execute(sql: """
                    INSERT INTO matter_states (state, in_comparison, takes_slot, searchable)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [st, cmp, slot, search])
            }






            try db.execute(sql: """
                CREATE TABLE matter_transitions (
                  from_state TEXT NOT NULL REFERENCES matter_states(state),
                  to_state   TEXT NOT NULL REFERENCES matter_states(state),
                  by         TEXT NOT NULL CHECK (by IN ('user', 'system')),
                  PRIMARY KEY (from_state, to_state, by)
                )
                """)
            for (f, t, by) in [
                ("候选", "活跃",   "user"),    // 单独盯着它 / 候选区批量确认
                ("候选", "已拒绝", "user"),    // 不用
                ("候选", "候选",   "user"),    // 说不准 —— 留在候选区
                ("候选", "已拒绝", "system"),  // 30 天未处理,静默
                ("活跃", "沉睡",   "system"),  // 14 天无新材料,静默
                ("活跃", "沉睡",   "user"),    // 手动 / 让位时选中
                ("沉睡", "活跃",   "system"),  // 出现新材料
                ("沉睡", "活跃",   "user"),    // 手动唤醒
                ("活跃", "已结案", "user"),    // PRD:**仅用户**
                ("沉睡", "已结案", "user"),    // 同上
                ("已结案", "活跃", "user"),    // 新材料出现后确认复活
                ("已拒绝", "候选", "user"),    // 候选区历史 / 搜索里找回
                ("已拒绝", "活跃", "user"),    // 同上,直接进活跃(走满员让位)
                ("活跃", "已合并", "user"),
                ("已合并", "活跃", "user"),    // 30 天内拆回
            ] {
                try db.execute(sql: """
                    INSERT INTO matter_transitions (from_state, to_state, by) VALUES (?, ?, ?)
                    """, arguments: [f, t, by])
            }






            try db.execute(sql: """
                CREATE TABLE matters (
                  id          INTEGER PRIMARY KEY AUTOINCREMENT,
                  title       TEXT    NOT NULL,
                  state       TEXT    NOT NULL REFERENCES matter_states(state),
                  created_at  TEXT    NOT NULL,
                  updated_at  TEXT    NOT NULL,

                  merged_into INTEGER REFERENCES matters(id),
                  CHECK ((state = '已合并') = (merged_into IS NOT NULL))
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_matters_state ON matters(state, updated_at DESC)")







            try db.execute(sql: """
                CREATE TRIGGER matters_legal_transition_only
                BEFORE UPDATE OF state ON matters
                FOR EACH ROW
                WHEN NEW.state <> OLD.state
                 AND NOT EXISTS (SELECT 1 FROM matter_transitions
                                  WHERE from_state = OLD.state AND to_state = NEW.state)
                BEGIN
                  SELECT RAISE(ABORT, 'matters:PRD §4.3.4 里没有这条流转');
                END
                """)


            try db.execute(sql: """
                CREATE TABLE matter_open_questions (
                  id         INTEGER PRIMARY KEY AUTOINCREMENT,
                  matter_id  INTEGER NOT NULL REFERENCES matters(id),
                  question   TEXT    NOT NULL,

                  line_id    INTEGER REFERENCES transcript_lines(line_id),
                  opened_at  TEXT    NOT NULL,


                  closed_at  TEXT
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_open_questions_matter ON matter_open_questions(matter_id, closed_at)
                """)


            try db.execute(sql: """
                CREATE TABLE matter_timeline (
                  id        INTEGER PRIMARY KEY AUTOINCREMENT,
                  matter_id INTEGER NOT NULL REFERENCES matters(id),
                  at        TEXT    NOT NULL,
                  summary   TEXT    NOT NULL,

                  session_id INTEGER REFERENCES sessions(id),
                  line_id    INTEGER REFERENCES transcript_lines(line_id)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_timeline_matter ON matter_timeline(matter_id, at DESC)
                """)





            try db.execute(sql: """
                CREATE TABLE matter_nominations (
                  id         INTEGER PRIMARY KEY AUTOINCREMENT,
                  title      TEXT    NOT NULL,


                  score      REAL    NOT NULL,
                  evidence   TEXT    NOT NULL,   -- JSON:证据行号与摘要
                  created_at TEXT    NOT NULL,


                  matter_id  INTEGER REFERENCES matters(id)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_nominations_pending ON matter_nominations(matter_id, score DESC)
                """)


            try db.execute(sql: "ALTER TABLE sessions ADD COLUMN title TEXT")
        }













        migrator.registerMigration("v20_matter_transition_needs_judgment") { db in
            try db.execute(sql: """
                CREATE TRIGGER matters_transition_needs_judgment
                BEFORE UPDATE OF state ON matters
                FOR EACH ROW
                WHEN NEW.state <> OLD.state
                 AND NOT EXISTS (
                       SELECT 1 FROM judgments j
                        WHERE j.target_kind = 'matter'
                          AND j.target_id   = CAST(OLD.id AS TEXT)


                          AND j.action      = 'matter_to_' || NEW.state


                          AND j.id = (SELECT MAX(id) FROM judgments
                                       WHERE target_kind = 'matter'
                                         AND target_id   = CAST(OLD.id AS TEXT))
                     )
                BEGIN
                  SELECT RAISE(ABORT, 'matters:流转必须先写判断记录 —— 直接 UPDATE state 不是合法写路径(M2-B2)');
                END
                """)
        }













        migrator.registerMigration("v21_session_removed_at") { db in
            try db.execute(sql: "ALTER TABLE sessions ADD COLUMN removed_at TEXT")
        }













        migrator.registerMigration("v22_asr_job_lost") { db in

            try db.execute(sql: """
                CREATE TABLE asr_jobs_new (
                  session_id  INTEGER NOT NULL REFERENCES sessions(id),
                  block_seq   INTEGER NOT NULL,
                  remote_id   TEXT    NOT NULL,
                  state       TEXT    NOT NULL
                                CHECK (state IN ('submitted', 'done', 'failed', 'lost')),
                  result_json TEXT,
                  last_error  TEXT,

                  resubmits   INTEGER NOT NULL DEFAULT 0,
                  created_at  TEXT    NOT NULL,
                  updated_at  TEXT    NOT NULL,
                  PRIMARY KEY (session_id, block_seq)
                )
                """)
            try db.execute(sql: """
                INSERT INTO asr_jobs_new
                  (session_id, block_seq, remote_id, state, result_json,
                   last_error, created_at, updated_at)
                SELECT session_id, block_seq, remote_id, state, result_json,
                       last_error, created_at, updated_at FROM asr_jobs
                """)
            try db.execute(sql: "DROP TABLE asr_jobs")
            try db.execute(sql: "ALTER TABLE asr_jobs_new RENAME TO asr_jobs")


            try db.execute(sql:
                "CREATE INDEX idx_asr_jobs_state ON asr_jobs(state, created_at)")
        }








        migrator.registerMigration("v23_progress_landing") { db in




            try db.execute(sql: """
                CREATE TABLE matter_progress_cards (
                  id          INTEGER PRIMARY KEY AUTOINCREMENT,
                  matter_id   INTEGER NOT NULL REFERENCES matters(id),
                  question_id INTEGER REFERENCES matter_open_questions(id),
                  session_id  INTEGER NOT NULL REFERENCES sessions(id),
                  line_id     INTEGER NOT NULL REFERENCES transcript_lines(line_id),
                  quote       TEXT    NOT NULL,
                  kind        TEXT    NOT NULL,
                  summary     TEXT    NOT NULL,
                  created_at  TEXT    NOT NULL,

                  resolved_at TEXT,
                  accepted    INTEGER CHECK (accepted IN (0, 1)),
                  CHECK ((resolved_at IS NULL) = (accepted IS NULL))
                )
                """)




            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_progress_cards_once
                    ON matter_progress_cards(session_id, matter_id, line_id)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_progress_cards_open
                    ON matter_progress_cards(matter_id) WHERE resolved_at IS NULL
                """)






            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_timeline_once
                    ON matter_timeline(matter_id, session_id, line_id)
                 WHERE session_id IS NOT NULL AND line_id IS NOT NULL
                """)
        }

        migrator.registerMigration("v24_anonymous_personas") { db in





            try db.execute(sql: """
                CREATE TABLE persons_new (
                  id         INTEGER PRIMARY KEY AUTOINCREMENT,
                  name       TEXT,
                  source     TEXT    NOT NULL
                               CHECK (source IN ('本人','声纹种子','用户创建','迁移回填','声纹聚类')),
                  created_at TEXT    NOT NULL,
                  updated_at TEXT    NOT NULL
                )
                """)
            try db.execute(sql: """
                INSERT INTO persons_new (id, name, source, created_at, updated_at)
                SELECT id, name, source, created_at, updated_at FROM persons
                """)


            try db.execute(sql: """
                INSERT OR REPLACE INTO sqlite_sequence (name, seq)
                SELECT 'persons_new', COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'persons'),
                                               (SELECT COALESCE(MAX(id), 0) FROM persons))
                """)
            try db.execute(sql: "DROP TABLE persons")
            try db.execute(sql: "ALTER TABLE persons_new RENAME TO persons")




            try db.execute(sql: """
                CREATE TABLE voiceprint_clusters (
                  cluster_key TEXT    PRIMARY KEY,
                  session_id  INTEGER NOT NULL REFERENCES sessions(id),
                  person_id   INTEGER NOT NULL REFERENCES persons(id),
                  created_at  TEXT    NOT NULL
                )
                """)
        }





















        migrator.registerMigration("v25_cloud_purged_at") { db in
            try db.execute(sql: "ALTER TABLE sessions ADD COLUMN cloud_purged_at TEXT")
        }













        migrator.registerMigration("v26_discoveries") { db in









            try db.execute(sql: """
                CREATE TABLE generation_batches (
                  batch_id       TEXT PRIMARY KEY,
                  producer       TEXT NOT NULL CHECK (producer IN ('发现','卡片','观察')),
                  prompt_version TEXT NOT NULL,
                  model_id       TEXT NOT NULL,
                  created_at     TEXT NOT NULL,
                  verdict        TEXT NOT NULL DEFAULT '未判卷'
                                   CHECK (verdict IN ('未判卷','达标','未达标')),
                  verdict_at     TEXT
                )
                """)


            try db.execute(sql: """
                CREATE TABLE discovery_kinds (
                  kind          TEXT PRIMARY KEY,
                  subject       TEXT NOT NULL CHECK (subject IN ('事','人')),
                  evidence_form TEXT NOT NULL CHECK (evidence_form IN ('有原话','没出现'))
                )
                """)
            for k in DiscoveryKind.allCases {
                try db.execute(sql: "INSERT INTO discovery_kinds (kind, subject, evidence_form) VALUES (?, ?, ?)",
                               arguments: [k.rawValue, k.subject.rawValue, k.evidenceForm.rawValue])
            }










            try db.execute(sql: """
                CREATE TABLE discoveries (
                  id              INTEGER PRIMARY KEY AUTOINCREMENT,
                  kind            TEXT    NOT NULL REFERENCES discovery_kinds(kind),
                  object_id       TEXT    NOT NULL,
                  summary         TEXT    NOT NULL,

                  stat_basis      TEXT,
                  batch_id        TEXT    NOT NULL REFERENCES generation_batches(batch_id),
                  created_at      TEXT    NOT NULL,
                  last_touched_at TEXT    NOT NULL,
                  read_at         TEXT,
                  sunk_at         TEXT,
                  withdrawn_at    TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_discoveries_object ON discoveries(kind, object_id)")
            try db.execute(sql: "CREATE INDEX idx_discoveries_batch  ON discoveries(batch_id)")




            for op in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER discoveries_stat_basis_matches_form_\(op.lowercased())
                    BEFORE \(op) ON discoveries
                    BEGIN
                      SELECT RAISE(ABORT, '「没出现」类必须带可复算统计口径,有原话类不许带')
                       WHERE ((SELECT evidence_form FROM discovery_kinds WHERE kind = NEW.kind) = '没出现')
                             <> (NEW.stat_basis IS NOT NULL);
                    END
                    """)
            }



            try db.execute(sql: """
                CREATE TABLE discovery_evidence (
                  id           INTEGER PRIMARY KEY AUTOINCREMENT,
                  discovery_id INTEGER NOT NULL REFERENCES discoveries(id),
                  line_id      INTEGER NOT NULL REFERENCES transcript_lines(line_id),
                  form         TEXT    NOT NULL CHECK (form IN ('quote','anchor')),
                  seq          INTEGER NOT NULL,
                  UNIQUE (discovery_id, seq)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_discovery_evidence_line ON discovery_evidence(line_id)")
        }








        migrator.registerMigration("v27_cards") { db in
            try db.execute(sql: """
                CREATE TABLE card_kinds (
                  kind     TEXT    PRIMARY KEY,
                  priority INTEGER NOT NULL UNIQUE
                )
                """)
            for k in CardTrigger.Kind.allCases {
                try db.execute(sql: "INSERT INTO card_kinds (kind, priority) VALUES (?, ?)",
                               arguments: [k.rawValue, k.priority])
            }













            try db.execute(sql: """
                CREATE TABLE cards (
                  id           INTEGER PRIMARY KEY AUTOINCREMENT,
                  kind         TEXT    NOT NULL REFERENCES card_kinds(kind),
                  object_kind  TEXT    NOT NULL CHECK (object_kind IN ('事','人')),
                  object_id    TEXT    NOT NULL,
                  session_id   INTEGER REFERENCES sessions(id),

                  body         TEXT    NOT NULL,
                  quote        TEXT,
                  line_id      INTEGER REFERENCES transcript_lines(line_id),
                  batch_id     TEXT    REFERENCES generation_batches(batch_id),
                  created_at   TEXT    NOT NULL,

                  pushed_at    TEXT,

                  withdrawn_at TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_cards_merge ON cards(object_kind, object_id, session_id)")
            try db.execute(sql: "CREATE INDEX idx_cards_line  ON cards(line_id)")
        }








        migrator.registerMigration("v28_observations") { db in



            try db.execute(sql: """
                CREATE TABLE person_observations (
                  id               INTEGER PRIMARY KEY AUTOINCREMENT,
                  person_id        INTEGER NOT NULL REFERENCES persons(id),
                  statement        TEXT    NOT NULL,


                  occurrence_count INTEGER NOT NULL,

                  stat_basis       TEXT,
                  batch_id         TEXT    NOT NULL REFERENCES generation_batches(batch_id),
                  created_at       TEXT    NOT NULL,

                  withdrawn_at     TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_observations_person ON person_observations(person_id)")

            try db.execute(sql: """
                CREATE TABLE observation_evidence (
                  id             INTEGER PRIMARY KEY AUTOINCREMENT,
                  observation_id INTEGER NOT NULL REFERENCES person_observations(id),
                  line_id        INTEGER NOT NULL REFERENCES transcript_lines(line_id),
                  seq            INTEGER NOT NULL,
                  UNIQUE (observation_id, seq)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_observation_evidence_line ON observation_evidence(line_id)")







            try db.execute(sql: """
                CREATE TABLE person_brief (
                  person_id           INTEGER PRIMARY KEY REFERENCES persons(id),
                  last_met_session_id INTEGER REFERENCES sessions(id),
                  last_topic          TEXT,
                  last_topic_line_id  INTEGER REFERENCES transcript_lines(line_id),
                  updated_at          TEXT    NOT NULL
                )
                """)
        }












        migrator.registerMigration("v29_self_stances_and_principles") { db in


            try db.execute(sql: "CREATE TABLE stance_directions (direction TEXT PRIMARY KEY)")
            for d in CardTrigger.Direction.allCases {
                try db.execute(sql: "INSERT INTO stance_directions (direction) VALUES (?)",
                               arguments: [d.rawValue])
            }

            try db.execute(sql: """
                CREATE TABLE self_stances (
                  id              INTEGER PRIMARY KEY AUTOINCREMENT,
                  topic_key       TEXT    NOT NULL,
                  direction       TEXT    NOT NULL REFERENCES stance_directions(direction),
                  text            TEXT    NOT NULL,

                  premise         TEXT,
                  premise_line_id INTEGER REFERENCES transcript_lines(line_id),
                  created_at      TEXT    NOT NULL,

                  withdrawn_at    TEXT,
                  UNIQUE (topic_key, direction)
                )
                """)




            try db.execute(sql: """
                CREATE TABLE self_stance_evidence (
                  id        INTEGER PRIMARY KEY AUTOINCREMENT,
                  stance_id INTEGER NOT NULL REFERENCES self_stances(id),
                  line_id   INTEGER NOT NULL REFERENCES transcript_lines(line_id),
                  matter_id INTEGER REFERENCES matters(id),
                  said_at   TEXT    NOT NULL,
                  UNIQUE (stance_id, line_id)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_self_stance_evidence_line ON self_stance_evidence(line_id)")






            try db.execute(sql: """
                CREATE TABLE self_principles (
                  id               INTEGER PRIMARY KEY AUTOINCREMENT,
                  text             TEXT    NOT NULL,
                  source_kind      TEXT    NOT NULL
                                     CHECK (source_kind IN ('系统提炼','你自己写的')),

                  stance_id        INTEGER REFERENCES self_stances(id),
                  meets_predictive INTEGER NOT NULL DEFAULT 0 CHECK (meets_predictive IN (0, 1)),
                  meets_exclusive  INTEGER NOT NULL DEFAULT 0 CHECK (meets_exclusive  IN (0, 1)),
                  created_at       TEXT    NOT NULL,

                  demoted_at       TEXT
                )
                """)

            try db.execute(sql: """
                CREATE TRIGGER self_principles_system_needs_a_stance
                BEFORE INSERT ON self_principles
                BEGIN
                  SELECT RAISE(ABORT, '系统提炼的原则必须挂在一条立场上,否则降级无处可降')
                   WHERE NEW.source_kind = '系统提炼' AND NEW.stance_id IS NULL;
                END
                """)
        }















        migrator.registerMigration("v30_speaker_clips") { db in
            try db.execute(sql: """
                CREATE TABLE speaker_clips (
                  id           INTEGER PRIMARY KEY AUTOINCREMENT,



                  cluster_key  TEXT    NOT NULL REFERENCES voiceprint_clusters(cluster_key),

                  session_id   INTEGER NOT NULL REFERENCES sessions(id),
                  r2_key       TEXT    NOT NULL UNIQUE,
                  duration_ms  INTEGER NOT NULL,



                  speech_ratio REAL    NOT NULL CHECK (speech_ratio BETWEEN 0 AND 1),
                  created_at   TEXT    NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_speaker_clips_cluster ON speaker_clips(cluster_key)")
            try db.execute(sql: "CREATE INDEX idx_speaker_clips_session ON speaker_clips(session_id)")



            try db.execute(sql: """
                CREATE TRIGGER speaker_clips_key_must_be_under_clip_prefix
                BEFORE INSERT ON speaker_clips
                BEGIN
                  SELECT RAISE(ABORT, '片段的键不在 clips/ 底下 —— 它会跟着 7 天保留期一起没')
                   WHERE NEW.r2_key NOT LIKE 'clips/%';
                END
                """)
        }













        migrator.registerMigration("v31_cluster_candidate") { db in


            try db.execute(sql: "ALTER TABLE voiceprint_clusters ADD COLUMN candidate_person_id INTEGER REFERENCES persons(id)")

            try db.execute(sql: "ALTER TABLE voiceprint_clusters ADD COLUMN candidate_votes INTEGER")
            try db.execute(sql: "ALTER TABLE voiceprint_clusters ADD COLUMN candidate_of INTEGER")
        }









        migrator.registerMigration("v32_observation_kind") { db in
            try db.execute(sql: """
                CREATE TABLE observation_kinds (
                  kind         TEXT    PRIMARY KEY,
                  band         INTEGER NOT NULL,
                  is_blindspot INTEGER NOT NULL CHECK (is_blindspot IN (0, 1))
                )
                """)
            for k in ObservationKind.allCases {
                try db.execute(sql: """
                    INSERT INTO observation_kinds (kind, band, is_blindspot) VALUES (?, ?, ?)
                    """, arguments: [k.rawValue, k.band.rawValue, k.isBlindSpot ? 1 : 0])
            }



            try db.execute(sql: "ALTER TABLE person_observations ADD COLUMN kind TEXT REFERENCES observation_kinds(kind)")
        }





        migrator.registerMigration("v33_card_budget") { db in
            try db.execute(sql: """
                CREATE TABLE card_budget (
                  id            INTEGER PRIMARY KEY CHECK (id = 1),
                  value         INTEGER NOT NULL,


                  raised_streak INTEGER NOT NULL DEFAULT 0,


                  paused_since  TEXT,
                  updated_at    TEXT    NOT NULL
                )
                """)


            try db.execute(sql: """
                INSERT INTO card_budget (id, value, raised_streak, updated_at)
                VALUES (1, ?, 0, ?)
                """, arguments: [CardBudget.initialValue,
                                 ISO8601DateFormatter.growth.string(from: Date())])






            try db.execute(sql: """
                CREATE TABLE card_drops (
                  id         INTEGER PRIMARY KEY AUTOINCREMENT,
                  day        TEXT    NOT NULL,
                  reason     TEXT    NOT NULL,
                  topic_key  TEXT,
                  created_at TEXT    NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_card_drops_day ON card_drops(day, reason)")
        }















        migrator.registerMigration("v34_voiceprint_gated_out") { db in
            try db.execute(sql: "ALTER TABLE sessions ADD COLUMN voiceprint_gated_out INTEGER")
        }








        migrator.registerMigration("v35_cards_quote_frozen") { db in
            try db.execute(sql: """
                CREATE TRIGGER cards_quote_frozen BEFORE UPDATE ON cards
                WHEN NEW.quote IS NOT OLD.quote
                BEGIN SELECT RAISE(ABORT, 'cards.quote 是冻结层的复制品,不许改'); END
                """)
        }













        migrator.registerMigration("v36_reclaim_upstream_diarization") { db in
            let now = ISO8601DateFormatter.growth.string(from: Date())
            _ = try applyUpstreamDiarizationRepair(now: now, in: db)




            try db.execute(sql: """
                DELETE FROM voiceprints
                 WHERE person_id IN (
                   SELECT p.id FROM persons p
                    WHERE p.name IS NULL AND p.source = '声纹聚类'
                      AND NOT EXISTS (SELECT 1 FROM line_speakers ls WHERE ls.person_id = p.id))
                """)
            try db.execute(sql: """
                DELETE FROM voiceprint_clusters
                 WHERE person_id IN (
                   SELECT p.id FROM persons p
                    WHERE p.name IS NULL AND p.source = '声纹聚类'
                      AND NOT EXISTS (SELECT 1 FROM line_speakers ls WHERE ls.person_id = p.id))
                """)
            try db.execute(sql: """
                DELETE FROM persons
                 WHERE name IS NULL AND source = '声纹聚类'
                   AND NOT EXISTS (SELECT 1 FROM line_speakers ls WHERE ls.person_id = persons.id)
                """)














        }










        migrator.registerMigration("v37_reclaim_upstream_diarization_again") { db in
            let now = ISO8601DateFormatter.growth.string(from: Date())
            _ = try applyUpstreamDiarizationRepair(now: now, in: db)
            for table in ["voiceprints", "voiceprint_clusters"] {
                try db.execute(sql: """
                    DELETE FROM \(table)
                     WHERE person_id IN (
                       SELECT p.id FROM persons p
                        WHERE p.name IS NULL AND p.source = '声纹聚类'
                          AND NOT EXISTS (SELECT 1 FROM line_speakers ls WHERE ls.person_id = p.id))
                    """)
            }
            try db.execute(sql: """
                DELETE FROM persons
                 WHERE name IS NULL AND source = '声纹聚类'
                   AND NOT EXISTS (SELECT 1 FROM line_speakers ls WHERE ls.person_id = persons.id)
                """)
        }






















        migrator.registerMigration("v38_purge_poisoned_anonymous_vectors") { db in
            try db.execute(sql: """
                DELETE FROM voiceprints
                 WHERE source = '\(PersonStore.Source.clustered.rawValue)'
                """)
        }















        migrator.registerMigration("v39_cascade_confirmed_upstream_speakers") { db in
            let now = ISO8601DateFormatter.growth.string(from: Date())
            for (person, line) in try ConfirmCascade.retroactivePlan(in: db) {
                try db.execute(sql: """
                    UPDATE line_speakers
                       SET person_id = ?, source = ?, confidence = 0, updated_at = ?
                     WHERE line_id = ?
                    """, arguments: [person, AttributionSource.crossValidated.rawValue, now, line])
            }
        }



























        migrator.registerMigration("v40_repair_rejected_templates") { _ in

        }








        migrator.registerMigration("v41_speaker_skips") { db in
            try db.execute(sql: """
                CREATE TABLE speaker_skips (
                  who        TEXT PRIMARY KEY,
                  created_at TEXT NOT NULL
                )
                """)
        }






























        migrator.registerMigration("v42_repair_mislabeled_templates") { _ in

        }













        migrator.registerMigration("v43_repair_mislabeled_templates_secondary") { _ in

        }














        migrator.registerMigration("v44_repair_contaminated_templates") { _ in

        }
















        migrator.registerMigration("v45_speaker_reviews") { db in
            try db.execute(sql: """
                CREATE TABLE speaker_reviews (
                  line_id     INTEGER PRIMARY KEY REFERENCES transcript_lines(line_id),
                  person_id   INTEGER NOT NULL REFERENCES persons(id),
                  score       REAL    NOT NULL,
                  cluster_key TEXT    NOT NULL,
                  state       TEXT    NOT NULL
                                CHECK (state IN ('待复查','是本人','不是本人')),
                  created_at  TEXT    NOT NULL,
                  updated_at  TEXT    NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_speaker_reviews_state ON speaker_reviews(state)
                """)
        }





        migrator.registerMigration("v46_summary_events") { db in
            try db.execute(sql: """
                CREATE TABLE summary_events (
                  id            INTEGER PRIMARY KEY AUTOINCREMENT,
                  transcript_id INTEGER NOT NULL REFERENCES transcripts(id),
                  seq           INTEGER NOT NULL,
                  title         TEXT    NOT NULL,
                  summary       TEXT    NOT NULL,
                  first_line_id INTEGER REFERENCES transcript_lines(line_id),
                  last_line_id  INTEGER REFERENCES transcript_lines(line_id),
                  UNIQUE(transcript_id, seq)
                )
                """)
        }


        migrator.registerMigration("v47_summary_event_ranges") { db in
            try db.execute(sql: """
                CREATE TABLE summary_events_v47 (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  transcript_id INTEGER NOT NULL REFERENCES transcripts(id),
                  seq INTEGER NOT NULL, title TEXT NOT NULL, summary TEXT NOT NULL,
                  first_line_id INTEGER REFERENCES transcript_lines(line_id),
                  last_line_id INTEGER REFERENCES transcript_lines(line_id),
                  UNIQUE(transcript_id, seq),
                  CHECK ((first_line_id IS NULL) = (last_line_id IS NULL)),
                  CHECK (first_line_id IS NULL OR first_line_id <= last_line_id)
                );
                WITH checked AS (
                  SELECT e.*, (first_line_id <= last_line_id
                    AND EXISTS (SELECT 1 FROM transcript_lines WHERE line_id = e.first_line_id AND transcript_id = e.transcript_id)
                    AND EXISTS (SELECT 1 FROM transcript_lines WHERE line_id = e.last_line_id AND transcript_id = e.transcript_id)) AS valid
                    FROM summary_events e
                )
                INSERT INTO summary_events_v47 (id, transcript_id, seq, title, summary, first_line_id, last_line_id)
                  SELECT id, transcript_id, seq, title, summary,
                         CASE WHEN valid THEN first_line_id END, CASE WHEN valid THEN last_line_id END FROM checked;
                DROP TABLE summary_events;
                ALTER TABLE summary_events_v47 RENAME TO summary_events;
                """)
        }
        migrator.registerMigration("v48_self_review_mode") { db in
            try db.execute(sql: """
                ALTER TABLE speaker_reviews ADD COLUMN mode TEXT NOT NULL DEFAULT 'line'
                  CHECK (mode IN ('line', 'cluster'))
                """)
        }

        migrator.registerMigration("v49_continuous_ingestion") { db in
            try db.execute(sql: """
                CREATE TABLE stream_sessions (
                  session_id INTEGER PRIMARY KEY REFERENCES sessions(id),
                  created_at TEXT NOT NULL,
                  finished_at TEXT
                );
                CREATE TABLE stream_blocks (
                  session_id INTEGER NOT NULL REFERENCES stream_sessions(session_id),
                  block_seq INTEGER NOT NULL CHECK(block_seq >= 0),
                  transcript_id INTEGER NOT NULL UNIQUE REFERENCES transcripts(id),
                  offset_ms INTEGER NOT NULL CHECK(offset_ms >= 0),
                  duration_ms INTEGER NOT NULL CHECK(duration_ms >= 0),
                  PRIMARY KEY(session_id, block_seq)
                );
                ALTER TABLE summary_events ADD COLUMN continuation_id INTEGER REFERENCES summary_events(id);
                ALTER TABLE ask_conversations ADD COLUMN context_session_id INTEGER REFERENCES sessions(id);
                ALTER TABLE ask_conversations ADD COLUMN context_event_id INTEGER REFERENCES summary_events(id);
                ALTER TABLE ask_conversations ADD COLUMN is_main INTEGER NOT NULL DEFAULT 0 CHECK(is_main IN (0,1));
                ALTER TABLE ask_conversations ADD COLUMN archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1));
                CREATE UNIQUE INDEX ask_unique_main ON ask_conversations(is_main) WHERE is_main = 1;
                ALTER TABLE ask_turns ADD COLUMN sources_tracked INTEGER NOT NULL DEFAULT 0 CHECK(sources_tracked IN (0,1));
                CREATE TABLE ask_turn_sources (
                  turn_id INTEGER NOT NULL REFERENCES ask_turns(id) ON DELETE CASCADE,
                  line_id INTEGER NOT NULL REFERENCES transcript_lines(line_id),
                  text TEXT NOT NULL,
                  PRIMARY KEY(turn_id, line_id)
                );
                CREATE INDEX ask_sources_line ON ask_turn_sources(line_id);
                """)
        }

        migrator.registerMigration("v50_input_memory_sources") { db in
            try db.execute(sql: """
                CREATE TABLE input_memory_sources (
                  local_id INTEGER PRIMARY KEY AUTOINCREMENT,
                  device_id TEXT NOT NULL,
                  record_id TEXT NOT NULL,
                  revision INTEGER NOT NULL CHECK(revision > 0),
                  content_hash TEXT NOT NULL,
                  record_json TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  deleted INTEGER NOT NULL CHECK(deleted IN (0,1)),
                  UNIQUE(device_id, record_id)
                );
                CREATE INDEX input_memory_recent ON input_memory_sources(deleted, updated_at DESC);
                CREATE TABLE input_memory_sync (
                  singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                  cursor INTEGER NOT NULL DEFAULT 0 CHECK(cursor >= 0),
                  last_success_at TEXT,
                  last_error TEXT
                );
                INSERT INTO input_memory_sync(singleton) VALUES(1);
                ALTER TABLE ask_turns ADD COLUMN cited_input_ids TEXT NOT NULL DEFAULT '[]';
                CREATE TABLE ask_turn_input_sources (
                  turn_id INTEGER NOT NULL REFERENCES ask_turns(id) ON DELETE CASCADE,
                  local_id INTEGER NOT NULL REFERENCES input_memory_sources(local_id),
                  revision INTEGER NOT NULL,
                  content_hash TEXT NOT NULL,
                  record_json TEXT NOT NULL,
                  PRIMARY KEY(turn_id, local_id)
                );
                CREATE INDEX ask_input_sources_id ON ask_turn_input_sources(local_id);
                """)
        }

        migrator.registerMigration("v51_personal_actions_and_chat_drafts") { db in
            try db.execute(sql: """
                ALTER TABLE ask_turn_sources ADD COLUMN speaker_id INTEGER;
                ALTER TABLE ask_turn_sources ADD COLUMN attribution TEXT;
                ALTER TABLE ask_turn_sources ADD COLUMN attribution_tracked INTEGER NOT NULL DEFAULT 0 CHECK(attribution_tracked IN (0,1));
                CREATE TABLE personal_actions (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                  status TEXT NOT NULL CHECK(status IN ('next','confirm','followup','doing','done','cancelled')),
                  resume_status TEXT NOT NULL DEFAULT 'next' CHECK(resume_status IN ('next','confirm','followup','doing')),
                  deadline TEXT,
                  conditions TEXT NOT NULL DEFAULT '',
                  next_step TEXT NOT NULL DEFAULT '',
                  collaborators TEXT NOT NULL DEFAULT '',
                  source_key TEXT UNIQUE,
                  source_kind TEXT CHECK(source_kind IN ('commitment','pending')),
                  source_line_id INTEGER,
                  source_seq INTEGER,
                  source_version INTEGER,
                  source_fingerprint TEXT,
                  source_reviewed INTEGER NOT NULL DEFAULT 0 CHECK(source_reviewed IN (0,1)),
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE ask_drafts (
                  key TEXT PRIMARY KEY,
                  text TEXT NOT NULL,
                  revision INTEGER NOT NULL,
                  context_session_id INTEGER,
                  context_event_id INTEGER
                );
                """)
        }

        migrator.registerMigration("v52_source_revision_snapshots") { db in
            try db.execute(sql: """
                ALTER TABLE ask_turn_sources ADD COLUMN source_revision INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE summaries ADD COLUMN source_revision INTEGER NOT NULL DEFAULT 0;
                """)
        }

        migrator.registerMigration("v53_personal_action_admission") { db in
            try db.execute(sql: """
                ALTER TABLE personal_actions ADD COLUMN deadline_text TEXT NOT NULL DEFAULT '';
                ALTER TABLE personal_actions ADD COLUMN admission_reviewed INTEGER NOT NULL DEFAULT 0 CHECK(admission_reviewed IN (0,1));
                ALTER TABLE tasks ADD COLUMN action_request_token TEXT NOT NULL DEFAULT '';
                CREATE TABLE action_assessments (
                  transcript_id INTEGER PRIMARY KEY REFERENCES transcripts(id),
                  protocol TEXT NOT NULL, snapshot TEXT NOT NULL, source_revision INTEGER NOT NULL, created_at TEXT NOT NULL,
                  scope TEXT NOT NULL DEFAULT 'transcript' CHECK(scope IN ('transcript','session'))
                );
                CREATE TABLE action_candidates (
                  transcript_id INTEGER NOT NULL REFERENCES transcripts(id), line_id INTEGER NOT NULL REFERENCES transcript_lines(line_id),
                  seq INTEGER NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('accepted','request','follow_up')),
                  title TEXT NOT NULL CHECK(length(trim(title))>0), quote TEXT NOT NULL, evidence TEXT NOT NULL,
                  condition_text TEXT NOT NULL, deadline_text TEXT NOT NULL, collaborators_text TEXT NOT NULL,
                  PRIMARY KEY(transcript_id,line_id,seq)
                );
                """)
        }

        migrator.registerMigration("v54_action_removal") { db in
            try db.execute(sql: """
                ALTER TABLE personal_actions ADD COLUMN removed_at TEXT;
                CREATE TABLE action_dismissals (
                  source_key TEXT PRIMARY KEY,
                  source_line_id INTEGER NOT NULL REFERENCES transcript_lines(line_id),
                  removed_at TEXT NOT NULL
                );
                """)
        }

        migrator.registerMigration("v55_recording_memory_outbox") { db in
            try db.execute(sql: """
                CREATE TABLE recording_memory_identity(singleton INTEGER PRIMARY KEY CHECK(singleton=1),device_id TEXT NOT NULL);
                CREATE TABLE recording_memory_outbox(id TEXT PRIMARY KEY,session_id INTEGER NOT NULL,transcript_id INTEGER NOT NULL,revision INTEGER NOT NULL CHECK(revision>0),record_json TEXT NOT NULL);
                CREATE TABLE recording_memory_receipts(destination TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL CHECK(revision>0),PRIMARY KEY(destination,id));
                CREATE TRIGGER recording_projection_line_changed AFTER UPDATE OF text,redacted ON transcript_lines
                WHEN NEW.redacted=1 OR NEW.text!=OLD.text BEGIN
                  UPDATE recording_memory_outbox SET revision=revision+1,
                    record_json=json_set(record_json,'$.revision',revision+1,'$.text','','$.title','已移出记忆','$.deleted',json('true'),
                      '$.updated',MAX(json_extract(record_json,'$.created'),strftime('%Y-%m-%dT%H:%M:%SZ','now')))
                    WHERE transcript_id=NEW.transcript_id AND json_extract(record_json,'$.deleted')=0;
                END;
                CREATE TRIGGER recording_projection_session_removed AFTER UPDATE OF removed_at ON sessions
                WHEN NEW.removed_at IS NOT NULL BEGIN
                  UPDATE recording_memory_outbox SET revision=revision+1,
                    record_json=json_set(record_json,'$.revision',revision+1,'$.text','','$.title','已移出记忆','$.deleted',json('true'),
                      '$.updated',MAX(json_extract(record_json,'$.created'),strftime('%Y-%m-%dT%H:%M:%SZ','now')))
                    WHERE session_id=NEW.id AND json_extract(record_json,'$.deleted')=0;
                END;
                """)
            try db.execute(sql: "INSERT INTO recording_memory_identity(singleton,device_id) VALUES(1,?)", arguments: [UUID().uuidString.lowercased()])
        }
        migrator.registerMigration("v56_empty_export_recovery") { db in



            try db.execute(sql: """
                CREATE TABLE upload_empty_export_recovery AS
                  SELECT j.* FROM upload_jobs j JOIN sessions s ON s.id=j.session_id
                   WHERE s.source='watch' AND s.removed_at IS NULL
                     AND j.state='failed' AND j.http_status=-1
                     AND (j.last_error LIKE '音频转 wav 失败:%解出来一个采样点都没有'
                       OR j.last_error LIKE '音频转 wav 失败:这个文件读不出来:%Code=-11847%')
                     AND NOT EXISTS(SELECT 1 FROM asr_jobs a WHERE a.session_id=j.session_id AND a.block_seq=j.block_seq)
                     AND NOT EXISTS(SELECT 1 FROM stream_blocks b WHERE b.session_id=j.session_id AND b.block_seq=j.block_seq)
                     AND NOT EXISTS(SELECT 1 FROM transcripts t WHERE t.session_id=j.session_id AND t.version<>1)
                     AND NOT EXISTS(SELECT 1 FROM transcripts t WHERE t.session_id=j.session_id
                       AND NOT EXISTS(SELECT 1 FROM stream_sessions x WHERE x.session_id=j.session_id));
                UPDATE tasks SET state='queued', next_retry_at=NULL,
                  last_error='空裁剪导出恢复：原失败记录已保留，复用已有转写，仅补未提交音频'
                  WHERE kind IN ('upload_audio','transcribe')
                    AND session_id IN (SELECT session_id FROM upload_empty_export_recovery);
                DELETE FROM upload_jobs WHERE (session_id,block_seq) IN
                  (SELECT session_id,block_seq FROM upload_empty_export_recovery);
                """)
        }
        return migrator
    }












    @discardableResult
    static func applyUpstreamDiarizationRepair(
        now: String, in db: Database) throws -> UpstreamDiarizationRepair.Plan {
        let plan = try UpstreamDiarizationRepair.plan(in: db)
        for (_, items) in plan.repaired.sorted(by: { $0.key < $1.key }) {
            for item in items {
                try db.execute(sql: """
                    UPDATE line_speakers
                       SET person_id = NULL, cluster_tag = ?, confidence = NULL,
                           source = ?, updated_at = ?
                     WHERE line_id = ?
                    """, arguments: [item.clusterTag,
                                     AttributionSource.systemOrganized.rawValue,
                                     now, item.lineID])
            }


            let ids = try String(data: JSONSerialization.data(
                withJSONObject: items.map(\.lineID)), encoding: .utf8) ?? "[]"
            try db.execute(sql: """
                INSERT INTO judgments (decided_at, actor, action, target_kind, target_id,
                                       payload, basis_line_ids)
                VALUES (?, 'system', 'assign_speaker', 'line', ?, ?, ?)
                """, arguments: [now, ids,
                                 #"{"source":"系统整理","why":"M2-认9 上游分人回填"}"#, ids])
        }
        return plan
    }


    static func open(atPath path: String) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: path)
        try makeMigrator().migrate(queue)
        return queue
    }
}
