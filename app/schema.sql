PRAGMA foreign_keys = ON;

-- ============================================================
-- BRANDS
-- ============================================================
CREATE TABLE IF NOT EXISTS brands (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL UNIQUE COLLATE NOCASE,
    notes       TEXT,
    is_active   INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
    old_source_id INTEGER,          -- original id from old brands table
    created_at  TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- VENDORS / SUPPLIERS
-- ============================================================
CREATE TABLE IF NOT EXISTS vendors (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL COLLATE NOCASE,
    phone       TEXT,
    address     TEXT,
    city        TEXT,
    notes       TEXT,
    is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    old_source_id INTEGER,          -- original id from old vendors table
    created_at  TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- PRODUCT CATALOGUE  (one unified list: machines, probes, printers, parts, accessories)
-- ============================================================
CREATE TABLE IF NOT EXISTS catalog_products (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name_model      TEXT    NOT NULL COLLATE NOCASE,
    category        TEXT    NOT NULL CHECK (category IN (
                        'Machine','Probe','Printer','Accessory','Part','Other'
                    )),
    brand_id        INTEGER REFERENCES brands(id),
    probe_type      TEXT,   -- Convex | Micro Convex | Linear | Sector | TVS | Endorectal |
                            -- 4D Convex | 3D Convex | Pediatric Sector | Neonatal Cardiac |
                            -- Micro Linear | Other  (NULL for non-probe categories)
    description     TEXT,
    source_info     TEXT,   -- e.g. "Old catalogue ID 134"
    old_source_id   INTEGER,          -- original id from old catalogue table
    needs_review    INTEGER NOT NULL DEFAULT 0 CHECK (needs_review IN (0, 1)),
    review_note     TEXT,   -- reason why flagged for review
    is_archived     INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    created_at      TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (name_model, brand_id, category)
);

-- ============================================================
-- BATCHES
-- ============================================================
CREATE TABLE IF NOT EXISTS batches (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    code                TEXT    NOT NULL UNIQUE COLLATE NOCASE,
    arrival_date        TEXT    NOT NULL,
    vendor_id           INTEGER REFERENCES vendors(id),   -- NEW: FK to vendors
    supplier_source     TEXT,   -- kept for free-text fallback / legacy data
    container_reference TEXT,
    notes               TEXT,
    is_archived         INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    created_at          TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- CUSTOMERS  (end-customers AND dealers — distinguished by customer_type)
-- ============================================================
CREATE TABLE IF NOT EXISTS customers (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT    NOT NULL,
    company_name    TEXT,
    phone           TEXT,
    email           TEXT,
    address         TEXT,
    city            TEXT,
    customer_type   TEXT    NOT NULL DEFAULT 'Customer'
                    CHECK (customer_type IN ('Customer','Dealer','Other')),
    notes           TEXT,
    is_archived     INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    old_source_id   INTEGER,
    created_at      TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- WORKSHOPS
-- ============================================================
CREATE TABLE IF NOT EXISTS workshops (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL,
    contact     TEXT,
    phone       TEXT,
    address     TEXT,
    city        TEXT,
    notes       TEXT,
    is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    created_at  TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- DEALERS  (external dealers the company sends machines to)
-- ============================================================
CREATE TABLE IF NOT EXISTS dealers (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL,
    contact     TEXT,
    phone       TEXT,
    address     TEXT,
    city        TEXT,
    notes       TEXT,
    is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    created_at  TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- MACHINES  (physical machine units)
-- ============================================================
CREATE TABLE IF NOT EXISTS machines (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    machine_id          TEXT    NOT NULL UNIQUE COLLATE NOCASE,   -- e.g. 1T, 16T
    batch_id            INTEGER NOT NULL REFERENCES batches(id),
    catalog_product_id  INTEGER REFERENCES catalog_products(id),  -- NEW: FK to catalogue
    brand_id            INTEGER REFERENCES brands(id),             -- NEW: direct brand FK
    model               TEXT    NOT NULL,                          -- kept as free text fallback
    serial_number       TEXT,
    year_of_manufacture TEXT,
    vendor_id           INTEGER REFERENCES vendors(id),            -- NEW: vendor override
    acquisition_date    TEXT,
    status              TEXT    NOT NULL DEFAULT 'In Stock'
                        CHECK (status IN ('In Stock','With Workshop','With Dealer','Sold','Archived')),
    current_location    TEXT    NOT NULL DEFAULT 'Company',
    condition           TEXT    CHECK (condition IN ('Good','Used','Faulty','Unknown',NULL)),
    notes               TEXT,
    is_archived         INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    old_source_id       INTEGER,   -- original purchases.id from old system
    created_at          TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- PHYSICAL PROBES  (individual probe units, not models)
-- ============================================================
CREATE TABLE IF NOT EXISTS probes (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    internal_id         TEXT    UNIQUE COLLATE NOCASE,   -- PRB-00001
    catalog_product_id  INTEGER REFERENCES catalog_products(id),
    model               TEXT,           -- free-text fallback / display
    brand_id            INTEGER REFERENCES brands(id),
    serial_number       TEXT    COLLATE NOCASE,
    batch_id            INTEGER REFERENCES batches(id),
    vendor_id           INTEGER REFERENCES vendors(id),
    acquisition_date    TEXT,
    status              TEXT    NOT NULL DEFAULT 'Available'
                        CHECK (status IN ('Available','With Machine','With Workshop','With Dealer','Sold','Archived')),
    current_location    TEXT    NOT NULL DEFAULT 'Company',
    assigned_machine_id INTEGER REFERENCES machines(id),   -- current assignment (snapshot)
    condition           TEXT    CHECK (condition IN ('Good','Used','Needs Inspection','Damaged','Under Repair',NULL)),
    condition_notes     TEXT,
    notes               TEXT,
    needs_review        INTEGER NOT NULL DEFAULT 0 CHECK (needs_review IN (0, 1)),
    review_note         TEXT,
    is_archived         INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    old_source_id       INTEGER,
    created_at          TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- PHYSICAL PRINTERS  (quantity-based, serial optional)
-- ============================================================
CREATE TABLE IF NOT EXISTS printers (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    internal_id         TEXT    UNIQUE COLLATE NOCASE,   -- PRT-00001
    catalog_product_id  INTEGER REFERENCES catalog_products(id),
    name_model          TEXT,           -- free-text fallback / display
    brand_id            INTEGER REFERENCES brands(id),
    serial_number       TEXT    COLLATE NOCASE,
    quantity            INTEGER NOT NULL DEFAULT 1 CHECK (quantity >= 0),
    batch_id            INTEGER REFERENCES batches(id),
    vendor_id           INTEGER REFERENCES vendors(id),
    acquisition_date    TEXT,
    status              TEXT    NOT NULL DEFAULT 'Available'
                        CHECK (status IN ('Available','With Machine','With Workshop','With Dealer','Sold','Archived')),
    current_location    TEXT    NOT NULL DEFAULT 'Company',
    assigned_machine_id INTEGER REFERENCES machines(id),
    condition           TEXT    CHECK (condition IN ('Good','Used','Needs Inspection','Damaged','Under Repair',NULL)),
    condition_notes     TEXT,
    notes               TEXT,
    is_archived         INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    old_source_id       INTEGER,
    created_at          TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- PHYSICAL PARTS / SPARE PARTS  (quantity-based stock)
-- ============================================================
CREATE TABLE IF NOT EXISTS parts (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    internal_id         TEXT    UNIQUE COLLATE NOCASE,   -- PRT-00001 style, generated
    catalog_product_id  INTEGER REFERENCES catalog_products(id),
    name_model          TEXT,           -- free-text fallback / display
    brand_id            INTEGER REFERENCES brands(id),
    serial_number       TEXT    COLLATE NOCASE,
    quantity            INTEGER NOT NULL DEFAULT 1 CHECK (quantity >= 0),
    batch_id            INTEGER REFERENCES batches(id),
    vendor_id           INTEGER REFERENCES vendors(id),
    acquisition_date    TEXT,
    status              TEXT    NOT NULL DEFAULT 'Available'
                        CHECK (status IN ('Available','With Machine','With Workshop','With Dealer','Sold','Archived')),
    current_location    TEXT    NOT NULL DEFAULT 'Company',
    assigned_machine_id INTEGER REFERENCES machines(id),
    condition           TEXT    CHECK (condition IN ('Good','Used','Needs Inspection','Damaged','Under Repair',NULL)),
    condition_notes     TEXT,
    notes               TEXT,
    needs_review        INTEGER NOT NULL DEFAULT 0 CHECK (needs_review IN (0, 1)),
    review_note         TEXT,
    is_archived         INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    old_source_id       INTEGER,
    created_at          TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- SALES
-- ============================================================
CREATE TABLE IF NOT EXISTS sales (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id         INTEGER REFERENCES customers(id),
    sale_date           TEXT    NOT NULL,
    sale_price          NUMERIC,
    invoice_reference   TEXT,
    notes               TEXT,
    old_source_id       INTEGER,   -- original sale_inv.id
    old_trno            TEXT,      -- original transaction number
    created_at          TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- SALE ITEMS
-- ============================================================
CREATE TABLE IF NOT EXISTS sale_items (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    sale_id         INTEGER NOT NULL REFERENCES sales(id),
    item_type       TEXT    NOT NULL CHECK (item_type IN ('machine','probe','printer','other')),
    machine_id      INTEGER REFERENCES machines(id),
    probe_id        INTEGER REFERENCES probes(id),
    printer_id      INTEGER REFERENCES printers(id),
    item_description TEXT,  -- fallback text description when FK not available
    item_serial     TEXT,
    item_price      NUMERIC,
    is_main_item    INTEGER NOT NULL DEFAULT 0 CHECK (is_main_item IN (0, 1)),
    old_source_id   INTEGER   -- original sale_temp_inv.id
);

-- ============================================================
-- MOVEMENTS  (every location/status change is logged)
-- ============================================================
CREATE TABLE IF NOT EXISTS movements (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    movement_type   TEXT    NOT NULL,
    movement_date   TEXT    NOT NULL,
    machine_id      INTEGER REFERENCES machines(id),
    probe_id        INTEGER REFERENCES probes(id),
    printer_id      INTEGER REFERENCES printers(id),
    part_id         INTEGER REFERENCES parts(id),
    workshop_id     INTEGER REFERENCES workshops(id),
    dealer_id       INTEGER REFERENCES dealers(id),
    customer_id     INTEGER REFERENCES customers(id),
    from_location   TEXT,
    to_location     TEXT,
    reason          TEXT,
    condition_notes TEXT,
    notes           TEXT,
    group_ref         TEXT,   -- links every row created by one action (a set move)
    related_group_ref TEXT,   -- on a return: the outbound group being returned
    reference         TEXT,   -- human movement number MOV-00001 (shared by one action)
    reversed_by_ref   TEXT,   -- group_ref of the reversal that corrected this movement
    old_source_id   INTEGER,  -- original events.id from old system
    created_at      TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- REPAIR JOBS  (customer-owned equipment — NEVER company inventory)
-- ============================================================
CREATE TABLE IF NOT EXISTS repair_jobs (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    job_number              TEXT    NOT NULL UNIQUE COLLATE NOCASE,
    customer_id             INTEGER REFERENCES customers(id),
    customer_contact        TEXT,
    received_at             TEXT    NOT NULL,
    delivered_by            TEXT,
    problem_description     TEXT    NOT NULL,
    accessories_received    TEXT,
    condition_on_arrival    TEXT,
    estimated_cost          NUMERIC,
    final_cost              NUMERIC,
    repair_notes            TEXT,
    status                  TEXT    NOT NULL DEFAULT 'Received'
                            CHECK (status IN ('Received','In Progress','Awaiting Parts','Ready','Returned','Cancelled')),
    returned_at             TEXT,
    collected_by            TEXT,
    return_notes            TEXT,
    created_at              TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- REPAIR ITEMS
-- ============================================================
CREATE TABLE IF NOT EXISTS repair_items (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    repair_job_id   INTEGER NOT NULL REFERENCES repair_jobs(id),
    equipment_type  TEXT    NOT NULL CHECK (equipment_type IN ('machine','probe','printer','other')),
    name_model      TEXT    NOT NULL,
    serial_number   TEXT,
    quantity        INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
    notes           TEXT
);

-- ============================================================
-- APP SETTINGS  (smart defaults: remember last used values)
-- ============================================================
CREATE TABLE IF NOT EXISTS app_settings (
    key        TEXT    PRIMARY KEY,
    value      TEXT,
    updated_at TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- IMPORT AUDIT LOG
-- ============================================================
CREATE TABLE IF NOT EXISTS imports (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    batch_code      TEXT    NOT NULL UNIQUE COLLATE NOCASE,
    source_filename TEXT,
    source_type     TEXT    DEFAULT 'SQL',
    imported_at     TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    imported_by     TEXT,
    records_total   INTEGER NOT NULL DEFAULT 0,
    records_inserted INTEGER NOT NULL DEFAULT 0,
    records_skipped INTEGER NOT NULL DEFAULT 0,
    records_flagged INTEGER NOT NULL DEFAULT 0,
    notes           TEXT
);

-- ============================================================
-- INDEXES
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_machines_status         ON machines(status);
CREATE INDEX IF NOT EXISTS idx_machines_batch          ON machines(batch_id);
CREATE INDEX IF NOT EXISTS idx_machines_catalog        ON machines(catalog_product_id);
CREATE INDEX IF NOT EXISTS idx_probes_status           ON probes(status);
CREATE INDEX IF NOT EXISTS idx_probes_catalog          ON probes(catalog_product_id);
CREATE INDEX IF NOT EXISTS idx_printers_status         ON printers(status);
CREATE INDEX IF NOT EXISTS idx_parts_status            ON parts(status);
CREATE INDEX IF NOT EXISTS idx_parts_catalog           ON parts(catalog_product_id);
CREATE INDEX IF NOT EXISTS idx_movements_date          ON movements(movement_date);
CREATE INDEX IF NOT EXISTS idx_movements_machine       ON movements(machine_id);
CREATE INDEX IF NOT EXISTS idx_movements_probe         ON movements(probe_id);
CREATE INDEX IF NOT EXISTS idx_movements_group         ON movements(group_ref);
CREATE INDEX IF NOT EXISTS idx_movements_reference     ON movements(reference);
CREATE INDEX IF NOT EXISTS idx_movements_printer       ON movements(printer_id);
CREATE INDEX IF NOT EXISTS idx_workshops_name          ON workshops(name);
CREATE INDEX IF NOT EXISTS idx_dealers_name            ON dealers(name);
CREATE INDEX IF NOT EXISTS idx_machines_old            ON machines(old_source_id);
CREATE INDEX IF NOT EXISTS idx_probes_old              ON probes(old_source_id);
CREATE INDEX IF NOT EXISTS idx_printers_old            ON printers(old_source_id);
CREATE INDEX IF NOT EXISTS idx_parts_old               ON parts(old_source_id);
CREATE INDEX IF NOT EXISTS idx_repair_jobs_status      ON repair_jobs(status);
CREATE INDEX IF NOT EXISTS idx_catalog_name            ON catalog_products(name_model);
CREATE INDEX IF NOT EXISTS idx_catalog_brand           ON catalog_products(brand_id);
CREATE INDEX IF NOT EXISTS idx_catalog_category        ON catalog_products(category);
CREATE INDEX IF NOT EXISTS idx_brands_name             ON brands(name);
CREATE INDEX IF NOT EXISTS idx_vendors_name            ON vendors(name);
CREATE INDEX IF NOT EXISTS idx_customers_name          ON customers(name);
CREATE INDEX IF NOT EXISTS idx_sales_date              ON sales(sale_date);
CREATE INDEX IF NOT EXISTS idx_sales_customer          ON sales(customer_id);
