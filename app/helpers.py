import json
from datetime import date

from sqlite3 import IntegrityError


# ── Smart defaults ────────────────────────────────────────────────────────────

SETTING_KEYS = (
    "last_vendor_id",
    "last_batch_id",
    "last_arrival_date",
    "last_brand_id",
    "last_model",
    "last_printer_catalog_id",
    "last_probe_models",
)


def get_settings(db):
    rows = db.execute("SELECT key, value FROM app_settings").fetchall()
    return {r["key"]: r["value"] for r in rows}


def set_settings(db, values):
    for key, value in values.items():
        if value is None:
            continue
        db.execute(
            """INSERT INTO app_settings (key, value, updated_at)
               VALUES (?, ?, CURRENT_TIMESTAMP)
               ON CONFLICT(key) DO UPDATE SET value = excluded.value,
                                              updated_at = CURRENT_TIMESTAMP""",
            (key, str(value)),
        )


def recent_probe_models(db, limit=8):
    rows = db.execute(
        """SELECT model, MAX(created_at) AS last_used FROM probes
           WHERE model IS NOT NULL AND model != '' AND is_archived = 0
           GROUP BY model COLLATE NOCASE ORDER BY last_used DESC LIMIT ?""",
        (limit,),
    ).fetchall()
    return [r["model"] for r in rows]


def last_probe_models(settings):
    try:
        value = json.loads(settings.get("last_probe_models") or "[]")
    except ValueError:
        return []
    return [m for m in value if isinstance(m, str) and m][:8]


# ── Find or create helpers ────────────────────────────────────────────────────

def find_or_create_vendor(db, name, phone=None):
    name = (name or "").strip()
    if not name:
        return None
    row = db.execute(
        "SELECT id FROM vendors WHERE name = ? COLLATE NOCASE AND is_archived = 0 LIMIT 1",
        (name,),
    ).fetchone()
    if row:
        return row["id"]
    cur = db.execute(
        "INSERT INTO vendors (name, phone) VALUES (?, ?)", (name, (phone or "").strip() or None)
    )
    return cur.lastrowid


def find_or_create_brand(db, name):
    name = (name or "").strip()
    if not name:
        return None
    row = db.execute(
        "SELECT id FROM brands WHERE name = ? COLLATE NOCASE", (name,)
    ).fetchone()
    if row:
        return row["id"]
    try:
        cur = db.execute("INSERT INTO brands (name) VALUES (?)", (name,))
    except IntegrityError:
        row = db.execute(
            "SELECT id FROM brands WHERE name = ? COLLATE NOCASE", (name,)
        ).fetchone()
        return row["id"]
    return cur.lastrowid


def find_or_create_batch(db, code, arrival_date=None, vendor_id=None, notes=None):
    code = (code or "").strip()
    if not code:
        return None
    row = db.execute(
        "SELECT * FROM batches WHERE code = ? COLLATE NOCASE", (code,)
    ).fetchone()
    if row:
        if not row["vendor_id"] and vendor_id:
            db.execute("UPDATE batches SET vendor_id = ? WHERE id = ?", (vendor_id, row["id"]))
        return row["id"]
    cur = db.execute(
        """INSERT INTO batches (code, arrival_date, vendor_id, notes)
           VALUES (?, ?, ?, ?)""",
        (code, arrival_date or date.today().isoformat(), vendor_id, notes),
    )
    return cur.lastrowid


def find_or_create_catalog(db, name_model, category, brand_id=None):
    name_model = (name_model or "").strip()
    if not name_model:
        return None
    row = db.execute(
        """SELECT id FROM catalog_products
           WHERE name_model = ? COLLATE NOCASE AND category = ?
             AND (brand_id IS ? OR brand_id = ?) AND is_archived = 0
           LIMIT 1""",
        (name_model, category, brand_id, brand_id),
    ).fetchone()
    if row:
        return row["id"]
    cur = db.execute(
        "INSERT INTO catalog_products (name_model, category, brand_id) VALUES (?, ?, ?)",
        (name_model, category, brand_id),
    )
    return cur.lastrowid


def find_or_create_customer(db, name):
    name = (name or "").strip()
    if not name:
        return None
    row = db.execute(
        "SELECT id FROM customers WHERE name = ? COLLATE NOCASE AND is_archived = 0 LIMIT 1",
        (name,),
    ).fetchone()
    if row:
        return row["id"]
    cur = db.execute(
        "INSERT INTO customers (name, customer_type) VALUES (?, 'Customer')", (name,)
    )
    return cur.lastrowid


def find_or_create_workshop(db, name):
    name = (name or "").strip()
    if not name:
        return None
    row = db.execute(
        "SELECT id FROM workshops WHERE name = ? COLLATE NOCASE AND is_archived = 0 LIMIT 1",
        (name,),
    ).fetchone()
    if row:
        return row["id"]
    cur = db.execute("INSERT INTO workshops (name) VALUES (?)", (name,))
    return cur.lastrowid


def find_or_create_dealer(db, name):
    name = (name or "").strip()
    if not name:
        return None
    row = db.execute(
        "SELECT id FROM dealers WHERE name = ? COLLATE NOCASE AND is_archived = 0 LIMIT 1",
        (name,),
    ).fetchone()
    if row:
        return row["id"]
    cur = db.execute("INSERT INTO dealers (name) VALUES (?)", (name,))
    return cur.lastrowid


# ── IDs and suggestions ───────────────────────────────────────────────────────

def next_internal_id(db, prefix, table, column):
    row = db.execute(
        f"SELECT MAX(CAST(SUBSTR({column}, LENGTH(?)+2) AS INTEGER)) AS n "
        f"FROM {table} WHERE {column} LIKE ? || '-%'",
        (prefix, prefix),
    ).fetchone()
    n = (row["n"] or 0) + 1
    candidate = f"{prefix}-{n:05d}"
    while db.execute(
        f"SELECT 1 FROM {table} WHERE {column} = ? COLLATE NOCASE", (candidate,)
    ).fetchone():
        n += 1
        candidate = f"{prefix}-{n:05d}"
    return candidate


# ── Movements ─────────────────────────────────────────────────────────────────

def log_movement(db, movement_type, movement_date, **kw):
    db.execute(
        """INSERT INTO movements
           (movement_type, movement_date, machine_id, probe_id, printer_id, part_id,
            workshop_id, dealer_id, customer_id, from_location, to_location,
            reason, notes, group_ref, related_group_ref, reference, reversed_by_ref)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            movement_type,
            movement_date,
            kw.get("machine_id"),
            kw.get("probe_id"),
            kw.get("printer_id"),
            kw.get("part_id"),
            kw.get("workshop_id"),
            kw.get("dealer_id"),
            kw.get("customer_id"),
            kw.get("from_location"),
            kw.get("to_location"),
            kw.get("reason"),
            kw.get("notes"),
            kw.get("group_ref"),
            kw.get("related_group_ref"),
            kw.get("reference"),
            kw.get("reversed_by_ref"),
        ),
    )


def new_group_ref():
    from uuid import uuid4

    return uuid4().hex[:12]


# ── Machine set (machine + its currently attached accessories) ────────────────

def printer_models(db):
    """Printer catalogue models with quantity availability, most recent first."""
    return db.execute(
        """SELECT c.id, c.name_model, b.name AS brand_name,
                  COALESCE(SUM(p.quantity), 0) AS total,
                  COALESCE(SUM(CASE WHEN p.status = 'Available' THEN p.quantity ELSE 0 END), 0) AS available,
                  COALESCE(SUM(CASE WHEN p.status = 'With Machine' THEN p.quantity ELSE 0 END), 0) AS with_machine,
                  COALESCE(SUM(CASE WHEN p.status = 'With Workshop' THEN p.quantity ELSE 0 END), 0) AS with_workshop,
                  COALESCE(SUM(CASE WHEN p.status = 'With Dealer' THEN p.quantity ELSE 0 END), 0) AS with_dealer,
                  COALESCE(SUM(CASE WHEN p.status = 'Sold' THEN p.quantity ELSE 0 END), 0) AS sold,
                  MAX(p.created_at) AS last_used
           FROM catalog_products c
           LEFT JOIN brands b ON b.id = c.brand_id
           LEFT JOIN printers p ON p.catalog_product_id = c.id AND p.is_archived = 0
           WHERE c.is_archived = 0 AND c.category = 'Printer'
           GROUP BY c.id
           ORDER BY last_used IS NULL, last_used DESC, c.name_model COLLATE NOCASE"""
    ).fetchall()


OUT_STATUSES = ("With Workshop", "With Dealer")


def attached_probes(db, machine_id):
    return db.execute(
        """SELECT * FROM probes
           WHERE assigned_machine_id = ? AND is_archived = 0
             AND status NOT IN ('Sold', 'Archived')
           ORDER BY internal_id""",
        (machine_id,),
    ).fetchall()


def attached_printers(db, machine_id):
    return db.execute(
        """SELECT * FROM printers
           WHERE assigned_machine_id = ? AND is_archived = 0
             AND status NOT IN ('Sold', 'Archived')
           ORDER BY internal_id""",
        (machine_id,),
    ).fetchall()


def machine_set(db, machine):
    return {
        "machine": machine,
        "probes": attached_probes(db, machine["id"]),
        "printers": attached_printers(db, machine["id"]),
    }


def probe_location_text(db, probe):
    if probe["assigned_machine_id"]:
        m = db.execute(
            "SELECT machine_id FROM machines WHERE id = ?", (probe["assigned_machine_id"],)
        ).fetchone()
        if m:
            return f"attached to Machine {m['machine_id']}"
    return f"status {probe['status']}, location {probe['current_location']}"


# ── Sales ─────────────────────────────────────────────────────────────────────

def create_sale(db, items, customer_name=None, sale_date=None, price=None,
                invoice_reference=None, notes=None):
    """items: list of dicts {'kind': 'machine'|'probe'|'printer', 'id': pk}."""
    if not items:
        raise ValueError("Select at least one item to sell.")
    sale_date = sale_date or date.today().isoformat()
    customer_id = find_or_create_customer(db, customer_name) if customer_name else None
    cur = db.execute(
        """INSERT INTO sales (customer_id, sale_date, sale_price, invoice_reference, notes)
           VALUES (?, ?, ?, ?, ?)""",
        (customer_id, sale_date, price, (invoice_reference or "").strip() or None,
         (notes or "").strip() or None),
    )
    sale_id = cur.lastrowid
    reference = next_movement_reference(db)
    customer_label = (customer_name or "").strip() or "customer"
    sold_machines = []

    for item in items:
        kind = item["kind"]
        pk = item["id"]
        if kind == "machine":
            row = db.execute(
                "SELECT * FROM machines WHERE id = ? AND is_archived = 0", (pk,)
            ).fetchone()
            if row is None:
                raise ValueError("Machine not found.")
            if row["status"] == "Sold":
                raise ValueError(f"Machine {row['machine_id']} is already sold.")
            if row["status"] in OUT_STATUSES:
                dest = out_destination(db, "machine", row)
                raise ValueError(
                    f"Machine {row['machine_id']} is currently with {dest}. "
                    "Return it before selling."
                )
            db.execute(
                """INSERT INTO sale_items
                   (sale_id, item_type, machine_id, item_description, item_serial,
                    item_price, is_main_item)
                   VALUES (?, 'machine', ?, ?, ?, ?, 1)""",
                (sale_id, pk, row["model"], row["serial_number"], price),
            )
            db.execute(
                "UPDATE machines SET status = 'Sold', current_location = ? WHERE id = ?",
                (customer_label, pk),
            )
            log_movement(
                db, "Sale", sale_date, machine_id=pk,
                from_location=row["current_location"], to_location=customer_label,
                notes=f"Sale #{sale_id}", group_ref=f"sale-{sale_id}", reference=reference,
            )
            sold_machines.append(pk)
        elif kind == "probe":
            row = db.execute(
                "SELECT * FROM probes WHERE id = ? AND is_archived = 0", (pk,)
            ).fetchone()
            if row is None:
                raise ValueError("Probe not found.")
            if row["status"] == "Sold":
                raise ValueError(f"Probe {row['internal_id']} is already sold.")
            if row["status"] in OUT_STATUSES:
                dest = out_destination(db, "probe", row)
                raise ValueError(
                    f"Probe {row['internal_id']} is currently with {dest}. "
                    "Return it before selling."
                )
            db.execute(
                """INSERT INTO sale_items
                   (sale_id, item_type, probe_id, item_description, item_serial, item_price)
                   VALUES (?, 'probe', ?, ?, ?, ?)""",
                (sale_id, pk, row["model"], row["serial_number"], price),
            )
            db.execute(
                """UPDATE probes SET status = 'Sold', current_location = ?,
                   assigned_machine_id = NULL WHERE id = ?""",
                (customer_label, pk),
            )
            log_movement(
                db, "Sale", sale_date, probe_id=pk,
                from_location=row["current_location"], to_location=customer_label,
                notes=f"Sale #{sale_id}", group_ref=f"sale-{sale_id}", reference=reference,
            )
        elif kind == "printer":
            row = db.execute(
                "SELECT * FROM printers WHERE id = ? AND is_archived = 0", (pk,)
            ).fetchone()
            if row is None:
                raise ValueError("Printer not found.")
            if row["status"] == "Sold":
                raise ValueError(f"Printer {row['internal_id']} is already sold.")
            if row["status"] in OUT_STATUSES:
                dest = out_destination(db, "printer", row)
                raise ValueError(
                    f"Printer {row['internal_id']} is currently with {dest}. "
                    "Return it before selling."
                )
            db.execute(
                """INSERT INTO sale_items
                   (sale_id, item_type, printer_id, item_description, item_serial, item_price)
                   VALUES (?, 'printer', ?, ?, ?, ?)""",
                (sale_id, pk, row["name_model"], row["serial_number"], price),
            )
            db.execute(
                """UPDATE printers SET status = 'Sold', current_location = ?,
                   assigned_machine_id = NULL WHERE id = ?""",
                (customer_label, pk),
            )
            log_movement(
                db, "Sale", sale_date, printer_id=pk,
                from_location=row["current_location"], to_location=customer_label,
                notes=f"Sale #{sale_id}", group_ref=f"sale-{sale_id}", reference=reference,
            )

    for machine_pk in sold_machines:
        for probe in attached_probes(db, machine_pk):
            db.execute(
                """UPDATE probes SET assigned_machine_id = NULL, status = 'Available',
                   current_location = 'Company' WHERE id = ?""",
                (probe["id"],),
            )
            log_movement(
                db, "Detached", sale_date, probe_id=probe["id"],
                from_location=probe["current_location"], to_location="Company",
                notes="Not included in the sale",
            )
        for printer in attached_printers(db, machine_pk):
            db.execute(
                """UPDATE printers SET assigned_machine_id = NULL, status = 'Available',
                   current_location = 'Company' WHERE id = ?""",
                (printer["id"],),
            )
            log_movement(
                db, "Detached", sale_date, printer_id=printer["id"],
                from_location=printer["current_location"], to_location="Company",
                notes="Not included in the sale",
            )

    return sale_id


# ═══════════════════════════════════════════════════════════════════════════
# Stage 4 — movement references, destinations, guards, timelines
# ═══════════════════════════════════════════════════════════════════════════

KIND_INFO = {
    "machine": ("machines", "machine_id"),
    "probe": ("probes", "probe_id"),
    "printer": ("printers", "printer_id"),
}

REVERSIBLE_TYPES = ("Send to Workshop", "Send to Dealer", "Return")
SEND_TYPES = ("Send to Workshop", "Send to Dealer")


def next_movement_reference(db):
    """Next human movement number: MOV-00001, MOV-00002, ..."""
    row = db.execute(
        "SELECT MAX(CAST(SUBSTR(reference, 5) AS INTEGER)) AS n "
        "FROM movements WHERE reference LIKE 'MOV-%'"
    ).fetchone()
    n = (row["n"] or 0) + 1
    candidate = f"MOV-{n:05d}"
    while db.execute(
        "SELECT 1 FROM movements WHERE reference = ?", (candidate,)
    ).fetchone():
        n += 1
        candidate = f"MOV-{n:05d}"
    return candidate


def load_item(db, kind, pk, active_only=False):
    table, _ = KIND_INFO[kind]
    query = f"SELECT * FROM {table} WHERE id = ?"
    if active_only:
        query += " AND is_archived = 0"
    return db.execute(query, (pk,)).fetchone()


def item_label(kind, row):
    if kind == "machine":
        return f"Machine {row['machine_id']}"
    if kind == "probe":
        return f"Probe {row['internal_id']}"
    return f"Printer {row['internal_id']}"


def item_detail(kind, row):
    if kind == "machine":
        return f"{row['model']} · {row['serial_number'] or 'no serial'}"
    if kind == "probe":
        return f"{row['model'] or 'probe'} · {row['serial_number'] or 'no serial'}"
    return row["name_model"] or "printer"


def latest_send(db, kind, pk):
    _, col = KIND_INFO[kind]
    return db.execute(
        f"""SELECT * FROM movements
            WHERE {col} = ? AND movement_type IN ('Send to Workshop', 'Send to Dealer')
            ORDER BY id DESC LIMIT 1""",
        (pk,),
    ).fetchone()


def out_destination(db, kind, row):
    """Where this item is currently sitting (name of workshop/dealer), or None."""
    if row["status"] not in OUT_STATUSES:
        return None
    send = latest_send(db, kind, row["id"])
    if send and send["to_location"]:
        return send["to_location"]
    return row["current_location"]


def send_block_reason(db, kind, row, destination=None):
    """Human-readable reason this item cannot be sent, or None when OK."""
    label = item_label(kind, row)
    if row["is_archived"]:
        return f"{label} is archived and cannot be sent."
    if row["status"] == "Sold":
        return f"{label} is sold and cannot be sent."
    if row["status"] in OUT_STATUSES:
        where = out_destination(db, kind, row) or row["current_location"]
        target = f" to {destination}" if destination else ""
        return f"{label} is currently with {where}. It cannot be sent{target}."
    return None


def return_block_reason(db, kind, row, origin=None):
    """Human-readable reason this item cannot be returned here, or None when OK."""
    label = item_label(kind, row)
    if row["status"] == "Sold":
        return f"{label} is sold and cannot be returned."
    if row["status"] not in OUT_STATUSES:
        return f"{label} is not currently away, so it cannot be returned."
    where = out_destination(db, kind, row) or row["current_location"]
    if origin and where and where.lower() != origin.lower():
        return f"{label} is currently with {where} and cannot be returned from {origin}."
    return None


def group_summary(db, group_ref):
    """Human summary of a movement group: 'Machine + 3 probes + printer'."""
    row = db.execute(
        """SELECT COALESCE(SUM(machine_id IS NOT NULL), 0) AS m,
                  COALESCE(SUM(probe_id IS NOT NULL), 0) AS p,
                  COALESCE(SUM(printer_id IS NOT NULL), 0) AS pr,
                  COUNT(*) AS n
           FROM movements WHERE group_ref = ?""",
        (group_ref,),
    ).fetchone()
    parts = []
    if row["m"]:
        parts.append("Machine" + ("s" if row["m"] > 1 else ""))
    if row["p"]:
        parts.append(f"{row['p']} probe" + ("s" if row["p"] > 1 else ""))
    if row["pr"]:
        parts.append("printer" + ("s" if row["pr"] > 1 else ""))
    return " + ".join(parts), row["n"]


def movement_display(db, row):
    """Plain-language title + detail pairs for one movement row."""
    kind = row["movement_type"]
    details = []
    if kind == "Received":
        title = "Received into inventory"
        if row["machine_id"]:
            m = db.execute(
                """SELECT b.code AS batch_code,
                          COALESCE(v.name, bv.name) AS provider_name
                   FROM machines mm
                   JOIN batches b ON b.id = mm.batch_id
                   LEFT JOIN vendors v ON v.id = mm.vendor_id
                   LEFT JOIN vendors bv ON bv.id = b.vendor_id
                   WHERE mm.id = ?""",
                (row["machine_id"],),
            ).fetchone()
            if m:
                details.append(("Provider", m["provider_name"] or "—"))
                details.append(("Batch", m["batch_code"] or "—"))
        if not details and row["notes"]:
            details.append(("Note", row["notes"]))
    elif kind == "Send to Workshop":
        title = "Sent to Workshop"
        details.append(("Workshop", row["to_location"] or "—"))
    elif kind == "Send to Dealer":
        title = "Sent to Dealer"
        details.append(("Dealer", row["to_location"] or "—"))
    elif kind == "Return":
        title = f"Returned from {row['from_location']}" if row["from_location"] else "Returned to the company"
        details.append(("Destination", row["from_location"] or "—"))
        details.append(("Back to", "Company"))
    elif kind == "Sale":
        title = "Sold"
        details.append(("Customer", row["to_location"] or "—"))
    elif kind == "Attachment":
        title = "Attached"
        details.append(("Note", row["to_location"] or row["notes"] or "—"))
    elif kind == "Detached":
        title = "Detached"
        details.append(("Note", row["notes"] or f"Back to {row['to_location'] or 'Company'}"))
    elif kind == "Reversal":
        title = "Movement reversed (correction)"
        if row["notes"]:
            details.append(("Corrects", row["notes"]))
    else:
        title = kind
        if row["to_location"]:
            details.append(("To", row["to_location"]))
    if row["reason"]:
        details.append(("Reason", row["reason"]))
    if row["notes"] and kind != "Reversal":
        if not any(value == row["notes"] for _, value in details):
            details.append(("Notes", row["notes"]))
    return title, details


def movement_events(db, kind, pk):
    """Timeline events for one item, newest first.

    Rows that belong to the same movement group (one user action) collapse
    into a single event so a set move reads as one entry.
    """
    _, col = KIND_INFO[kind]
    rows = db.execute(
        f"SELECT * FROM movements WHERE {col} = ? ORDER BY movement_date DESC, id DESC",
        (pk,),
    ).fetchall()
    events = []
    seen = set()
    for row in rows:
        group_ref = row["group_ref"]
        if group_ref and group_ref in seen:
            continue
        if group_ref:
            seen.add(group_ref)
        title, details = movement_display(db, row)
        items_summary = None
        if group_ref:
            summary, size = group_summary(db, group_ref)
            if size > 1:
                items_summary = summary
        reversed_ref = None
        if row["reversed_by_ref"]:
            rev = db.execute(
                "SELECT reference FROM movements WHERE group_ref = ? LIMIT 1",
                (row["reversed_by_ref"],),
            ).fetchone()
            reversed_ref = rev["reference"] if rev else None
        reversible = (
            row["movement_type"] in REVERSIBLE_TYPES
            and not row["reversed_by_ref"]
            and bool(group_ref)
        )
        events.append({
            "date": row["movement_date"],
            "type": row["movement_type"],
            "title": title,
            "details": details,
            "reference": row["reference"],
            "items_summary": items_summary,
            "reversible": reversible,
            "reversed_ref": reversed_ref,
            "group_ref": group_ref,
            "row": row,
        })
    return events


def days_away(sent_date):
    try:
        sent = date.fromisoformat(sent_date)
    except (TypeError, ValueError):
        return None
    return (date.today() - sent).days


def away_items(db, destination=None, kind=None):
    """Everything currently away from the company (machines, probes, printers).

    Each entry carries its destination, send date, movement reference and
    days-away count, newest send first.
    """
    rows_out = []
    kinds = (kind,) if kind else ("machine", "probe", "printer")
    for k in kinds:
        table, _ = KIND_INFO[k]
        rows = db.execute(
            f"SELECT * FROM {table} WHERE status IN ('With Workshop', 'With Dealer')"
        ).fetchall()
        for row in rows:
            send = latest_send(db, k, row["id"])
            dest = send["to_location"] if send and send["to_location"] else row["current_location"]
            if destination and (dest or "").lower() != destination.lower():
                continue
            rows_out.append({
                "kind": k,
                "id": row["id"],
                "label": item_label(k, row),
                "detail": item_detail(k, row),
                "status": row["status"],
                "destination": dest or "—",
                "sent_date": send["movement_date"] if send else None,
                "reference": send["reference"] if send else None,
                "group_ref": send["group_ref"] if send else None,
                "days": days_away(send["movement_date"]) if send else None,
                "row": row,
            })
    rows_out.sort(key=lambda entry: (entry["sent_date"] or ""), reverse=True)
    return rows_out
