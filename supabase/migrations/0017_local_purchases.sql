-- ============================================================
-- 0017: local purchases — machines bought from local people.
--
--   * sometimes a used machine is bought from an individual,
--     not from a container vendor; it still enters stock as
--     'In Stock' and can be sold like any other machine
--   * purchase_price keeps what we paid (NULL for stock that
--     arrived in a container, where the cost is per batch)
--   * a standing batch BATCH-LOCAL (letter L -> ids 1L, 2L ...)
--     groups every local purchase together
-- ============================================================

ALTER TABLE machines ADD COLUMN IF NOT EXISTS purchase_price NUMERIC(12,2);

INSERT INTO batches (code, letter, arrival_date, supplier_source, notes, is_archived)
SELECT 'BATCH-LOCAL', 'L', 'Unknown', 'Local purchase',
       'Machines bought from local people', 0
WHERE NOT EXISTS (SELECT 1 FROM batches WHERE code = 'BATCH-LOCAL');
