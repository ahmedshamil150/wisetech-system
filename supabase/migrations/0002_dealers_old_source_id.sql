-- dealers (and workshops) are the only reference tables without a legacy
-- id column, so a re-run of scripts/import_legacy.py can be made idempotent.
ALTER TABLE dealers ADD COLUMN IF NOT EXISTS old_source_id BIGINT;
ALTER TABLE workshops ADD COLUMN IF NOT EXISTS old_source_id BIGINT;

CREATE INDEX IF NOT EXISTS idx_dealers_old ON dealers(old_source_id);
CREATE INDEX IF NOT EXISTS idx_workshops_old ON workshops(old_source_id);
