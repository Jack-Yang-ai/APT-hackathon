-- Versioned read-only recording sources. Phone content/attribution authority is unchanged.
CREATE TABLE recording_memory_sources (
  device_id TEXT NOT NULL,
  record_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision > 0),
  payload TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  text TEXT NOT NULL,
  created TEXT NOT NULL,
  deleted INTEGER NOT NULL CHECK(deleted IN (0, 1)),
  received_at TEXT NOT NULL,
  PRIMARY KEY(device_id, record_id)
);
CREATE TABLE recording_memory_changes (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id TEXT NOT NULL,
  record_id TEXT NOT NULL
);
CREATE TRIGGER recording_memory_insert AFTER INSERT ON recording_memory_sources BEGIN
  INSERT INTO recording_memory_changes(device_id, record_id) VALUES(new.device_id, new.record_id);
END;
CREATE TRIGGER recording_memory_update AFTER UPDATE ON recording_memory_sources BEGIN
  INSERT INTO recording_memory_changes(device_id, record_id) VALUES(new.device_id, new.record_id);
END;
CREATE INDEX recording_memory_live ON recording_memory_sources(deleted, created);
