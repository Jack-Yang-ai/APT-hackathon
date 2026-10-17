-- Ownership of the read-only projection only. Formal phone content is unchanged.
CREATE TABLE recording_memory_owners (
  device_id TEXT NOT NULL,
  recording_id TEXT NOT NULL,
  generation TEXT NOT NULL,
  control_version INTEGER NOT NULL CHECK(control_version >= 0),
  state TEXT NOT NULL CHECK(state IN ('active','revoked')),
  handoff_id TEXT NOT NULL,
  snapshot_digest TEXT NOT NULL,
  sources_digest TEXT NOT NULL,
  mutation_id TEXT,
  apply_nonce TEXT,
  publication_version INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(device_id,recording_id)
);
CREATE TABLE recording_memory_records (
  device_id TEXT NOT NULL,
  record_id TEXT NOT NULL,
  recording_id TEXT NOT NULL,
  PRIMARY KEY(device_id,record_id)
);
CREATE INDEX recording_memory_record_owner ON recording_memory_records(device_id,recording_id);
INSERT INTO recording_memory_records(device_id,record_id,recording_id)
SELECT device_id,record_id,json_extract(text,'$.recording_id') FROM recording_memory_sources
WHERE CASE WHEN json_valid(text) THEN json_extract(text,'$.schema')='apt.recording-source/1'
  AND json_extract(text,'$.platform')='stepx' AND length(json_extract(text,'$.recording_id'))=36 ELSE 0 END;
