import re
import sqlite3
from pathlib import Path

from flask import current_app, g
import click


SCHEMA_PATH = Path(__file__).with_name("schema.sql")

# Tables whose legacy Stage 1/2 DDL must be REPLACED (constraints differ
# in ways ALTER TABLE cannot express). Only rebuilt when no child rows
# reference them, so existing data is never silently corrupted.
REBUILD_TABLES = ("catalog_products", "probes", "printers", "sale_items")

# Empty legacy tables from the old design that are no longer part of the
# schema (probe/printer "models" now live in catalog_products).
LEGACY_TABLES = ("probe_models", "printer_models", "movement_items")


def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(current_app.config["DATABASE"])
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA foreign_keys = ON")
    return g.db


def close_db(_error=None):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def _existing_columns(db, table):
    rows = db.execute(f"PRAGMA table_info({table})").fetchall()
    return {row["name"]: row for row in rows}


def _existing_tables(db):
    rows = db.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    ).fetchall()
    return {row["name"] for row in rows}


def _table_ddl(db, table):
    row = db.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name = ?", (table,)
    ).fetchone()
    return row["sql"] if row else None


def _has_unique_index(db, table, cols):
    """True if *table* has a unique index covering exactly/at least *cols*."""
    try:
        idx_list = db.execute(f"PRAGMA index_list({table})").fetchall()
    except sqlite3.Error:
        return False
    for idx in idx_list:
        if not idx["unique"]:
            continue
        info = [r["name"] for r in db.execute(f"PRAGMA index_info({idx['name']})")]
        if set(cols).issubset(info):
            return True
    return False


def _schema_create_ddl(table):
    """Return the CREATE TABLE statement for *table* from schema.sql."""
    text = SCHEMA_PATH.read_text(encoding="utf-8")
    marker = f"CREATE TABLE IF NOT EXISTS {table} ("
    start = text.find(marker)
    if start < 0:
        return None
    depth = 0
    for i in range(start + len(marker) - 1, len(text)):
        ch = text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None


def _needs_rebuild(db, table):
    """Decide whether a table's live DDL differs from schema.sql."""
    if table not in _existing_tables(db):
        return False
    cols = _existing_columns(db, table)
    if table == "catalog_products":
        # schema.sql adds brand_id, probe_type, old_source_id, needs_review,
        # review_note and a UNIQUE (name_model, brand_id, category) index.
        wanted = {"brand_id", "probe_type", "old_source_id", "needs_review", "review_note"}
        if not wanted.issubset(cols):
            return True
        return not _has_unique_index(
            db, table, ("name_model", "brand_id", "category")
        )
    if table == "probes":
        # legacy DDL forces serial_number NOT NULL UNIQUE
        serial = cols.get("serial_number")
        if serial and serial["notnull"]:
            return True
        wanted = {"catalog_product_id", "brand_id", "batch_id", "vendor_id",
                  "acquisition_date", "needs_review", "review_note", "old_source_id"}
        return not wanted.issubset(cols)
    if table == "printers":
        # legacy DDL has no internal_id / serial_number columns
        return "internal_id" not in cols
    if table == "sale_items":
        # legacy DDL: CHECK without 'other' + UNIQUE (sale_id, <fk>) triple
        row = db.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name = 'sale_items'"
        ).fetchone()
        ddl = row["sql"] if row and row["sql"] else ""
        if "'other'" not in ddl:
            return True
        return "UNIQUE (sale_id, machine_id)" in ddl
    return False


def _rebuild_table(db, table):
    """Drop and recreate *table* with schema.sql DDL, preserving rows.

    Only columns present in BOTH the old and new definition are copied, so
    obsolete legacy columns (e.g. printer_model_id) are shed. Refuses to run
    if child tables reference live rows.
    """
    ddl = _schema_create_ddl(table)
    if not ddl:
        return False

    # Child-reference safety check
    children = {
        "catalog_products": [("machines", "catalog_product_id"),
                             ("probes", "catalog_product_id"),
                             ("printers", "catalog_product_id"),
                             ("parts", "catalog_product_id")],
        "probes": [("movements", "probe_id"), ("sale_items", "probe_id")],
        "printers": [("movements", "printer_id"), ("sale_items", "printer_id")],
        "sale_items": [],
    }
    for child_table, child_col in children.get(table, []):
        if child_table in _existing_tables(db):
            col_exists = child_col in _existing_columns(db, child_table)
            if col_exists:
                n = db.execute(
                    f"SELECT COUNT(*) FROM {child_table} WHERE {child_col} IS NOT NULL"
                ).fetchone()[0]
                if n:
                    raise RuntimeError(
                        f"Cannot rebuild {table}: {n} rows in {child_table} reference it."
                    )

    rows = db.execute(f"SELECT * FROM {table}").fetchall()
    old_cols = list(rows[0].keys()) if rows else list(_existing_columns(db, table).keys())

    db.execute(f"DROP TABLE {table}")
    db.execute(ddl)

    new_cols = list(_existing_columns(db, table).keys())
    copy_cols = [c for c in old_cols if c in new_cols]
    if rows and copy_cols:
        placeholders = ", ".join("?" for _ in copy_cols)
        collist = ", ".join(copy_cols)
        db.executemany(
            f"INSERT INTO {table} ({collist}) VALUES ({placeholders})",
            [tuple(r[c] for c in copy_cols) for r in rows],
        )
    return True


def _migrate_schema(db):
    """
    Safely bring a Stage 1/2 database up to the Stage 3 schema without
    destroying existing data.
    """
    tables = _existing_tables(db)

    # 1. Rebuild tables whose constraints changed beyond ALTER capability.
    for table in REBUILD_TABLES:
        if _needs_rebuild(db, table):
            _rebuild_table(db, table)

    # 2. Drop empty legacy tables superseded by the unified catalogue.
    for table in LEGACY_TABLES:
        if table in _existing_tables(db):
            n = db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            if n == 0:
                db.execute(f"DROP TABLE {table}")

    tables = _existing_tables(db)

    # 3. Additive column migrations (ALTER TABLE ADD COLUMN only).

    if "batches" in tables:
        existing = _existing_columns(db, "batches")
        if "vendor_id" not in existing:
            db.execute("ALTER TABLE batches ADD COLUMN vendor_id INTEGER REFERENCES vendors(id)")

    if "customers" in tables:
        existing = _existing_columns(db, "customers")
        new_cols = {
            "customer_type": "TEXT NOT NULL DEFAULT 'Customer'",
            "city":          "TEXT",
            "old_source_id": "INTEGER",
        }
        for col, defn in new_cols.items():
            if col not in existing:
                db.execute(f"ALTER TABLE customers ADD COLUMN {col} {defn}")

    if "machines" in tables:
        existing = _existing_columns(db, "machines")
        new_cols = {
            "catalog_product_id":  "INTEGER REFERENCES catalog_products(id)",
            "brand_id":            "INTEGER REFERENCES brands(id)",
            "vendor_id":           "INTEGER REFERENCES vendors(id)",
            "year_of_manufacture": "TEXT",
            "condition":           "TEXT",
            "old_source_id":       "INTEGER",
            "needs_review":        "INTEGER NOT NULL DEFAULT 0",
            "review_note":         "TEXT",
        }
        for col, defn in new_cols.items():
            if col not in existing:
                db.execute(f"ALTER TABLE machines ADD COLUMN {col} {defn}")

    if "probes" in tables:
        existing = _existing_columns(db, "probes")
        new_cols = {
            "catalog_product_id": "INTEGER REFERENCES catalog_products(id)",
            "brand_id":           "INTEGER REFERENCES brands(id)",
            "batch_id":           "INTEGER REFERENCES batches(id)",
            "vendor_id":          "INTEGER REFERENCES vendors(id)",
            "acquisition_date":   "TEXT",
            "needs_review":       "INTEGER NOT NULL DEFAULT 0",
            "review_note":        "TEXT",
            "old_source_id":      "INTEGER",
        }
        for col, defn in new_cols.items():
            if col not in existing:
                db.execute(f"ALTER TABLE probes ADD COLUMN {col} {defn}")

    if "printers" in tables:
        existing = _existing_columns(db, "printers")
        new_cols = {
            "catalog_product_id": "INTEGER REFERENCES catalog_products(id)",
            "brand_id":           "INTEGER REFERENCES brands(id)",
            "batch_id":           "INTEGER REFERENCES batches(id)",
            "vendor_id":          "INTEGER REFERENCES vendors(id)",
            "acquisition_date":   "TEXT",
            "needs_review":       "INTEGER NOT NULL DEFAULT 0",
            "review_note":        "TEXT",
            "old_source_id":      "INTEGER",
        }
        for col, defn in new_cols.items():
            if col not in existing:
                db.execute(f"ALTER TABLE printers ADD COLUMN {col} {defn}")

    if "sales" in tables:
        existing = _existing_columns(db, "sales")
        for col, defn in [("old_source_id", "INTEGER"), ("old_trno", "TEXT")]:
            if col not in existing:
                db.execute(f"ALTER TABLE sales ADD COLUMN {col} {defn}")

    if "sale_items" in tables:
        existing = _existing_columns(db, "sale_items")
        new_cols = {
            "item_description": "TEXT",
            "item_serial":      "TEXT",
            "item_price":       "NUMERIC",
            "is_main_item":     "INTEGER NOT NULL DEFAULT 0",
            "old_source_id":    "INTEGER",
            "old_purchase_id":  "INTEGER",
        }
        for col, defn in new_cols.items():
            if col not in existing:
                db.execute(f"ALTER TABLE sale_items ADD COLUMN {col} {defn}")

    if "imports" in tables:
        existing = _existing_columns(db, "imports")
        new_cols = {
            "records_total":    "INTEGER NOT NULL DEFAULT 0",
            "records_inserted": "INTEGER NOT NULL DEFAULT 0",
            "records_skipped":  "INTEGER NOT NULL DEFAULT 0",
            "records_flagged":  "INTEGER NOT NULL DEFAULT 0",
        }
        for col, defn in new_cols.items():
            if col not in existing:
                db.execute(f"ALTER TABLE imports ADD COLUMN {col} {defn}")

    if "movements" in tables:
        existing = _existing_columns(db, "movements")
        for col, defn in [("probe_id", "INTEGER REFERENCES probes(id)"),
                          ("printer_id", "INTEGER REFERENCES printers(id)"),
                          ("part_id", "INTEGER REFERENCES parts(id)"),
                          ("group_ref", "TEXT"),
                          ("related_group_ref", "TEXT"),
                          ("reference", "TEXT"),
                          ("reversed_by_ref", "TEXT"),
                          ("old_source_id", "INTEGER")]:
            if col not in existing:
                db.execute(f"ALTER TABLE movements ADD COLUMN {col} {defn}")

    if "workshops" in tables:
        existing = _existing_columns(db, "workshops")
        if "city" not in existing:
            db.execute("ALTER TABLE workshops ADD COLUMN city TEXT")

    if "dealers" in tables:
        existing = _existing_columns(db, "dealers")
        if "city" not in existing:
            db.execute("ALTER TABLE dealers ADD COLUMN city TEXT")

    if "parts" in tables:
        existing = _existing_columns(db, "parts")
        for col, defn in [("needs_review", "INTEGER NOT NULL DEFAULT 0"),
                          ("review_note", "TEXT")]:
            if col not in existing:
                db.execute(f"ALTER TABLE parts ADD COLUMN {col} {defn}")

    # 4. Ensure the unique index expected by the catalogue dedup logic.
    db.execute(
        """CREATE UNIQUE INDEX IF NOT EXISTS uq_catalog_name_brand_cat
           ON catalog_products (name_model, brand_id, category)"""
    )


def init_db():
    db = get_db()
    text = SCHEMA_PATH.read_text(encoding="utf-8")
    # Split schema into table DDL and index DDL. Indexes may reference
    # columns that only exist AFTER _migrate_schema adds them to legacy
    # tables, so they must run last.
    index_stmts = re.findall(r"CREATE INDEX[^;]+;", text, flags=re.IGNORECASE)
    tables_only = re.sub(r"CREATE INDEX[^;]+;", "", text, flags=re.IGNORECASE)
    db.executescript(tables_only)
    _migrate_schema(db)
    if index_stmts:
        db.executescript("\n".join(index_stmts))
    db.commit()


def init_app(app):
    app.teardown_appcontext(close_db)
    app.cli.add_command(init_db_command)


@click.command("init-db")
def init_db_command():
    init_db()
    click.echo("Database initialized.")
