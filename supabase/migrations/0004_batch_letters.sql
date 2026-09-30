-- ============================================================
-- 0004: batch letters + human friendly item ids
--
--   * every batch gets a letter: BATCH-3 (14-09-2026) = T,
--     BATCH-PARTS (all spare parts) = A, next batch created
--     in the app will be U, then V, ...
--   * a machine is numbered <n><letter>: 1T, 2T ... 98T
--   * every probe and printer of a machine carries the SAME id
--     as its machine (so you type 2T to send machine 2T with
--     its probes and printer)
-- ============================================================

ALTER TABLE batches ADD COLUMN IF NOT EXISTS letter TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS batches_letter_key ON batches (letter);

UPDATE batches SET letter = 'T' WHERE code = 'BATCH-3';
UPDATE batches SET letter = 'A' WHERE code = 'BATCH-PARTS';

-- the batch seeded for "items added from the app" was never used:
-- a batch is only created from the app, when stock actually arrives
DELETE FROM batches WHERE code = 'BATCH-4';

-- probes / printers of the same machine now share one id
ALTER TABLE probes  DROP CONSTRAINT IF EXISTS probes_internal_id_key;
ALTER TABLE printers DROP CONSTRAINT IF EXISTS printers_internal_id_key;

-- machines: 1T .. 98T, in the order the legacy system listed them
WITH ranked AS (
    SELECT id, row_number() OVER (ORDER BY machine_id) || 'T' AS new_code
    FROM machines
)
UPDATE machines m SET machine_id = r.new_code
FROM ranked r WHERE m.id = r.id;

-- probes and printers take over their machine's id
UPDATE probes p SET internal_id = m.machine_id
FROM machines m WHERE p.assigned_machine_id = m.id;

UPDATE printers p SET internal_id = m.machine_id
FROM machines m WHERE p.assigned_machine_id = m.id;

-- ============================================================
-- id helpers
-- ============================================================
DROP FUNCTION IF EXISTS next_machine_code();

CREATE OR REPLACE FUNCTION next_machine_code(p_letter TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_max INT;
BEGIN
    IF p_letter IS NULL OR p_letter !~ '^[A-Z]$' THEN
        RAISE EXCEPTION 'bad batch letter: %', p_letter;
    END IF;

    SELECT COALESCE(MAX((regexp_match(machine_id, '^([0-9]+)'))[1]::INT), 0)
      INTO v_max
      FROM machines
     WHERE machine_id ~ ('^[0-9]+' || p_letter || '$');

    RETURN (v_max + 1) || p_letter;
END;
$$;

-- next free letter for a new batch: A, ... T (used), so U
CREATE OR REPLACE FUNCTION next_batch_letter()
RETURNS TEXT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT CASE
               WHEN max(letter) IS NULL THEN 'A'
               ELSE chr(ascii(max(letter)::text) + 1)
           END
      FROM batches
     WHERE letter IS NOT NULL AND letter ~ '^[A-Z]$';
$$;

GRANT EXECUTE ON FUNCTION next_machine_code(text) TO authenticated;
GRANT EXECUTE ON FUNCTION next_batch_letter() TO authenticated;
