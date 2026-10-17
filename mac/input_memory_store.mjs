// The Mac replica and Worker exercise exactly the same SQL, normalization and triggers.
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, mkdirSync, chmodSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

export class InputMemoryReplica {
  constructor(path) {
    this.path = path === ':memory:' ? path : resolve(path);
    if (this.path !== ':memory:') {
      mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
      chmodSync(dirname(this.path), 0o700);
    }
    this.sqlite = new DatabaseSync(this.path);
    try {
      this.sqlite.exec('PRAGMA busy_timeout=3000; PRAGMA foreign_keys=ON;');
      const tables = this.sqlite.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").all();
      const version = this.sqlite.prepare('PRAGMA user_version').get().user_version;
      if (!tables.length && version === 0) {
        this.sqlite.exec('BEGIN IMMEDIATE');
        try {
          this.sqlite.exec(readFileSync(new URL('../worker/migrations/0001_input_memory.sql', import.meta.url), 'utf8'));
          this.sqlite.exec(`CREATE TABLE input_memory_references (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT NOT NULL, record_id TEXT NOT NULL,
            UNIQUE(device_id, record_id),
            FOREIGN KEY(device_id, record_id) REFERENCES input_memory_sources(device_id, record_id));
            CREATE TABLE input_memory_upstreams (
              origin TEXT PRIMARY KEY, cursor INTEGER NOT NULL CHECK(cursor>=0), updated_at TEXT NOT NULL);
            PRAGMA user_version=2; COMMIT;`);
        } catch (error) { this.sqlite.exec('ROLLBACK'); throw error; }
      } else {
        if (![1,2].includes(version) || tables.length !== (version === 1 ? 3 : 4) || !tables.some(t => t.name === 'input_memory_references')) throw new Error('incompatible_input_replica');
        // Never silently open the phone's content library or an unrelated SQLite file.
        for (const [table, expected] of [
          ['input_memory_sources', 'device_id,record_id,revision,payload,fingerprint,text,created,deleted,received_at'],
          ['input_memory_changes', 'seq,device_id,record_id'],
          ['input_memory_references', 'local_id,device_id,record_id'],
        ]) if (this.sqlite.prepare(`PRAGMA table_info(${table})`).all().map(c => c.name).join(',') !== expected) throw new Error('incompatible_input_replica');
        const triggers = this.sqlite.prepare("SELECT name FROM sqlite_master WHERE type='trigger'").all().map(t => t.name);
        if (!['input_memory_insert', 'input_memory_update'].every(t => triggers.includes(t))) throw new Error('missing_input_replica_triggers');
        if (version === 1) {
          this.sqlite.exec('BEGIN IMMEDIATE');
          try { this.sqlite.exec('CREATE TABLE input_memory_upstreams(origin TEXT PRIMARY KEY,cursor INTEGER NOT NULL CHECK(cursor>=0),updated_at TEXT NOT NULL); PRAGMA user_version=2; COMMIT;'); }
          catch (error) { this.sqlite.exec('ROLLBACK'); throw error; }
        } else if (this.sqlite.prepare('PRAGMA table_info(input_memory_upstreams)').all().map(c => c.name).join(',') !== 'origin,cursor,updated_at') throw new Error('incompatible_input_replica');
      }
      this.secureFiles();
      this.sqlite.exec('PRAGMA journal_mode=WAL;');
      this.secureFiles();
    } catch (error) { this.sqlite.close(); throw error; }
    this.db = sqliteD1(this);
  }

  secureFiles() {
    if (this.path === ':memory:') return;
    for (const suffix of ['', '-wal', '-shm']) if (existsSync(this.path + suffix)) chmodSync(this.path + suffix, 0o600);
  }
  transaction(operation) {
    this.sqlite.exec('BEGIN IMMEDIATE');
    let result;
    try { result = operation(this.sqlite); this.sqlite.exec('COMMIT'); }
    catch (error) { this.sqlite.exec('ROLLBACK'); throw error; }
    this.secureFiles(); return result;
  }
  close() { this.sqlite.close(); }
}

// Shared D1 adapter; each source domain keeps a separate SQLite file and schema.
export function sqliteD1(replica) {
    const self = replica;
    return {
      sqlite: self.sqlite,
      prepare(sql) {
        return {
          sql, args: [], bind(...args) { return { ...this, args }; },
          async first() { return self.sqlite.prepare(this.sql).get(...this.args) ?? null; },
          async all() { return { results: self.sqlite.prepare(this.sql).all(...this.args), success: true }; },
          async run() { return { meta: self.sqlite.prepare(this.sql).run(...this.args), success: true }; },
        };
      },
      async batch(statements) {
        self.sqlite.exec('BEGIN IMMEDIATE');
        let results;
        try {
          results = statements.map(s => ({ results: self.sqlite.prepare(s.sql).all(...s.args), success: true }));
          self.sqlite.exec('COMMIT');
        } catch (error) { self.sqlite.exec('ROLLBACK'); throw error; }
        self.secureFiles();
        if (this.afterBatch) { const hook = this.afterBatch; this.afterBatch = null; await hook(); }
        return results;
      },
    };
}
