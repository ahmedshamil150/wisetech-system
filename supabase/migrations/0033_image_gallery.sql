-- 0033_image_gallery.sql
-- Additive-only: new tables and nullable columns. No existing data touched.

-- Image groups: one group = one machine + its printer + its probes,
-- identified by a short code like 1U, 2U, 3U...
CREATE TABLE IF NOT EXISTS image_groups (
    id BIGSERIAL PRIMARY KEY,
    group_code TEXT UNIQUE NOT NULL,
    batch_id BIGINT REFERENCES batches(id),
    batch_name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Item images: one row per uploaded photo, linked to a group.
CREATE TABLE IF NOT EXISTS item_images (
    id BIGSERIAL PRIMARY KEY,
    group_id BIGINT NOT NULL REFERENCES image_groups(id) ON DELETE CASCADE,
    item_type TEXT NOT NULL CHECK (item_type IN ('machine','printer','probe')),
    item_serial TEXT,
    item_model TEXT,
    r2_key TEXT NOT NULL,
    r2_url TEXT NOT NULL,
    uploaded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Nullable link columns so existing records are unaffected.
ALTER TABLE machines ADD COLUMN IF NOT EXISTS image_group_code TEXT;
ALTER TABLE probes ADD COLUMN IF NOT EXISTS image_group_code TEXT;
ALTER TABLE printers ADD COLUMN IF NOT EXISTS image_group_code TEXT;

-- Indexes for gallery lookups.
CREATE INDEX IF NOT EXISTS idx_image_groups_batch ON image_groups(batch_id);
CREATE INDEX IF NOT EXISTS idx_item_images_group ON item_images(group_id);
CREATE INDEX IF NOT EXISTS idx_machines_image_group ON machines(image_group_code);
CREATE INDEX IF NOT EXISTS idx_probes_image_group ON probes(image_group_code);
CREATE INDEX IF NOT EXISTS idx_printers_image_group ON printers(image_group_code);
