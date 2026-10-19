-- ============================================================
-- 0018: REVIEW KIND on probes
--
--   needs_review was a single boolean shown as a green dot. Now that
--   boxed probes are audited against the old stock we need to tell the
--   two reasons apart:
--     'sold'  -> the serial also shows up in the old sales (green dot)
--     'serial'-> the serial could not be found in the old stock (red)
--   NULL keeps whatever was flagged before this column existed.
-- ============================================================

ALTER TABLE probes ADD COLUMN IF NOT EXISTS review_kind TEXT;
