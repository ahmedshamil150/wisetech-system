from datetime import date
import json, os, re, tempfile, uuid
from pathlib import Path

from flask import Blueprint, flash, redirect, render_template, request, url_for, jsonify, abort
from sqlite3 import IntegrityError

from .database import get_db
from . import helpers

main = Blueprint("main", __name__)

MACHINE_STATUSES = ("In Stock", "Sold", "With Workshop", "With Dealer")
MACHINE_LOCATIONS = ("Company", "Workshop", "Dealer", "Customer")
PROBE_STATUSES = ("Available", "With Machine", "With Workshop", "With Dealer", "Sold", "Archived")
PROBE_LOCATIONS = ("Company", "Workshop", "Dealer", "Customer")
PROBE_CONDITIONS = ("Good", "Used", "Needs Inspection", "Damaged", "Under Repair")
PROBE_TYPE_OPTIONS = ("Convex", "Micro Convex", "Medium Convex", "3D Convex", "Linear",
                      "Phased Array", "Sector/Phased Array", "Endocavity", "Transvaginal",
                      "Transrectal", "Volume", "Cardiac", "Pediatric", "Other")
PRINTER_STATUSES = ("Available", "With Machine", "With Workshop", "With Dealer", "Sold", "Archived")
PRINTER_LOCATIONS = ("Company", "Workshop", "Dealer", "Customer")
PRINTER_CONDITIONS = ("Good", "Used", "Needs Inspection", "Damaged", "Under Repair")
CATALOG_CATEGORIES = ("Machine", "Probe", "Printer", "Accessory", "Part", "Other")
CUSTOMER_TYPES = ("Customer", "Dealer", "Other")


def _next_internal_id(db, prefix, table, column):
    """Generate next formatted ID like PRB-00001, PRT-00001."""
    row = db.execute(f"SELECT MAX(CAST(SUBSTR({column}, LENGTH(?)+2) AS INTEGER)) AS n "
                     f"FROM {table} WHERE {column} LIKE ? || '-%'", (prefix, prefix)).fetchone()
    n = (row["n"] or 0) + 1
    return f"{prefix}-{n:05d}"


def _suggest_machine_id(db, batch_id):
    """Suggest next machine ID inside a batch: batch T -> 5T (after 1T..4T)."""
    if not batch_id:
        return ""
    batch = db.execute(
        "SELECT code FROM batches WHERE id = ? AND is_archived = 0", (batch_id,)
    ).fetchone()
    if not batch:
        return ""
    code = (batch["code"] or "").strip()
    if not code.isalnum() or len(code) > 6:
        # long/complex batch codes (e.g. imported date codes) don't compose well
        return ""
    rows = db.execute(
        "SELECT machine_id FROM machines WHERE batch_id = ? AND is_archived = 0",
        (batch_id,),
    ).fetchall()
    top = 0
    suffix = code.upper()
    for row in rows:
        mid = (row["machine_id"] or "").strip()
        if mid.upper().endswith(suffix) and mid[: -len(code)].isdigit():
            top = max(top, int(mid[: -len(code)]))
    n = top + 1
    while db.execute(
        "SELECT 1 FROM machines WHERE machine_id = ? COLLATE NOCASE", (f"{n}{code}",)
    ).fetchone():
        n += 1
    return f"{n}{code}"


@main.get("/")
def dashboard():
    db = get_db()
    machine_counts = dict(db.execute(
        "SELECT status, COUNT(*) FROM machines WHERE is_archived = 0 GROUP BY status"
    ).fetchall())
    probe_counts = dict(db.execute(
        "SELECT status, COUNT(*) FROM probes WHERE is_archived = 0 GROUP BY status"
    ).fetchall())
    printer_counts = dict(db.execute(
        "SELECT status, COUNT(*) FROM printers WHERE is_archived = 0 GROUP BY status"
    ).fetchall())
    counts = {
        "machines": {
            "total": sum(machine_counts.values()),
            "company": machine_counts.get("In Stock", 0),
            "workshop": machine_counts.get("With Workshop", 0),
            "dealer": machine_counts.get("With Dealer", 0),
            "sold": machine_counts.get("Sold", 0),
        },
        "probes": {
            "total": sum(probe_counts.values()),
            "available": probe_counts.get("Available", 0),
            "attached": db.execute(
                """SELECT COUNT(*) FROM probes WHERE is_archived = 0
                   AND assigned_machine_id IS NOT NULL AND status != 'Sold'"""
            ).fetchone()[0],
            "workshop": probe_counts.get("With Workshop", 0),
            "dealer": probe_counts.get("With Dealer", 0),
            "sold": probe_counts.get("Sold", 0),
        },
        "printers": {
            "total": sum(printer_counts.values()),
            "available": printer_counts.get("Available", 0),
            "attached": printer_counts.get("With Machine", 0),
            "workshop": printer_counts.get("With Workshop", 0),
            "dealer": printer_counts.get("With Dealer", 0),
            "sold": printer_counts.get("Sold", 0),
        },
        "total_batches": db.execute(
            "SELECT COUNT(*) FROM batches WHERE is_archived = 0"
        ).fetchone()[0],
    }
    active = helpers.away_items(db)
    for entry in active:
        if entry["kind"] == "machine":
            entry["url"] = url_for("main.machine_detail", machine_id=entry["id"])
        elif entry["kind"] == "probe":
            entry["url"] = url_for("main.probe_detail", probe_id=entry["id"])
        else:
            entry["url"] = url_for("main.printer_detail", printer_id=entry["id"])
    recent = db.execute(
        """SELECT mv.*, m.machine_id AS machine_code, p.internal_id AS probe_code,
                  pr.internal_id AS printer_code
           FROM movements mv
           LEFT JOIN machines m ON m.id = mv.machine_id
           LEFT JOIN probes p ON p.id = mv.probe_id
           LEFT JOIN printers pr ON pr.id = mv.printer_id
           ORDER BY mv.id DESC LIMIT 8"""
    ).fetchall()
    return render_template(
        "dashboard.html",
        counts=counts,
        recent=recent,
        active=active[:10],
        away_total=len(active),
    )


def _clean(value):
    value = (value or "").strip()
    return value or None


def _machine_form_data():
    return {
        "machine_id": (request.form.get("machine_id") or "").strip(),
        "batch_id": (request.form.get("batch_id") or "").strip(),
        "model": (request.form.get("model") or "").strip(),
        "serial_number": _clean(request.form.get("serial_number")),
        "acquisition_date": _clean(request.form.get("acquisition_date")),
        "notes": _clean(request.form.get("notes")),
    }


@main.get("/batches")
def batches():
    db = get_db()
    search = (request.args.get("search") or "").strip()
    query = """
        SELECT b.*, COUNT(m.id) AS machine_count
        FROM batches b
        LEFT JOIN machines m ON m.batch_id = b.id AND m.is_archived = 0
        WHERE b.is_archived = 0
    """
    params = []
    if search:
        query += " AND (b.code LIKE ? OR b.supplier_source LIKE ? OR b.notes LIKE ?)"
        pattern = f"%{search}%"
        params.extend((pattern, pattern, pattern))
    query += " GROUP BY b.id ORDER BY b.arrival_date DESC, b.code"
    rows = db.execute(query, params).fetchall()
    return render_template("batches/list.html", batches=rows, search=search)


@main.route("/batches/new", methods=("GET", "POST"))
def new_batch():
    if request.method == "POST":
        code = (request.form.get("code") or "").strip()
        arrival_date = (request.form.get("arrival_date") or "").strip()
        supplier_source = _clean(request.form.get("supplier_source"))
        notes = _clean(request.form.get("notes"))
        if not code or not arrival_date:
            flash("Batch code and date received are required.", "error")
        else:
            try:
                db = get_db()
                db.execute(
                    "INSERT INTO batches (code, arrival_date, supplier_source, notes) VALUES (?, ?, ?, ?)",
                    (code, arrival_date, supplier_source, notes),
                )
                db.commit()
                flash(f"Batch {code} was added.", "success")
                return redirect(url_for("main.batches"))
            except IntegrityError:
                flash("That batch code already exists.", "error")
    return render_template("batches/form.html", batch=None, today=date.today().isoformat())


@main.route("/batches/<int:batch_id>/edit", methods=("GET", "POST"))
def edit_batch(batch_id):
    db = get_db()
    batch = db.execute("SELECT * FROM batches WHERE id = ? AND is_archived = 0", (batch_id,)).fetchone()
    if batch is None:
        flash("Batch not found.", "error")
        return redirect(url_for("main.batches"))
    if request.method == "POST":
        arrival_date = (request.form.get("arrival_date") or "").strip()
        supplier_source = _clean(request.form.get("supplier_source"))
        notes = _clean(request.form.get("notes"))
        if not arrival_date:
            flash("Date received is required.", "error")
        else:
            db.execute(
                "UPDATE batches SET arrival_date = ?, supplier_source = ?, notes = ? WHERE id = ?",
                (arrival_date, supplier_source, notes, batch_id),
            )
            db.commit()
            flash(f"Batch {batch['code']} was updated.", "success")
            return redirect(url_for("main.batch_detail", batch_id=batch_id))
    return render_template("batches/form.html", batch=batch, today=date.today().isoformat())


@main.post("/batches/<int:batch_id>/archive")
def archive_batch(batch_id):
    db = get_db()
    batch = db.execute("SELECT code FROM batches WHERE id = ? AND is_archived = 0", (batch_id,)).fetchone()
    if batch is None:
        flash("Batch not found.", "error")
    elif db.execute("SELECT 1 FROM machines WHERE batch_id = ? AND is_archived = 0 LIMIT 1", (batch_id,)).fetchone():
        flash("A batch with active machines cannot be archived.", "error")
    else:
        db.execute("UPDATE batches SET is_archived = 1 WHERE id = ?", (batch_id,))
        db.commit()
        flash(f"Batch {batch['code']} was archived.", "success")
    return redirect(url_for("main.batches"))


@main.get("/batches/<int:batch_id>")
def batch_detail(batch_id):
    db = get_db()
    batch = db.execute("SELECT * FROM batches WHERE id = ? AND is_archived = 0", (batch_id,)).fetchone()
    if batch is None:
        flash("Batch not found.", "error")
        return redirect(url_for("main.batches"))
    machines = db.execute(
        "SELECT * FROM machines WHERE batch_id = ? AND is_archived = 0 ORDER BY machine_id", (batch_id,)
    ).fetchall()
    return render_template("batches/detail.html", batch=batch, machines=machines)


@main.get("/machines")
def machines():
    db = get_db()
    search = (request.args.get("search") or "").strip()
    status = request.args.get("status") or ""
    location = request.args.get("location") or ""
    batch_id = request.args.get("batch_id") or ""
    query = """
        SELECT m.*, b.code AS batch_code, bd.name AS brand_name
        FROM machines m
        JOIN batches b ON b.id = m.batch_id
        LEFT JOIN brands bd ON bd.id = m.brand_id
        WHERE m.is_archived = 0 AND b.is_archived = 0
    """
    params = []
    if search:
        query += " AND (m.machine_id LIKE ? OR m.model LIKE ? OR m.serial_number LIKE ? OR b.code LIKE ?)"
        pattern = f"%{search}%"
        params.extend((pattern, pattern, pattern, pattern))
    if status in MACHINE_STATUSES:
        query += " AND m.status = ?"
        params.append(status)
    if location in MACHINE_LOCATIONS:
        query += " AND m.current_location = ?"
        params.append(location)
    if batch_id.isdigit():
        query += " AND m.batch_id = ?"
        params.append(int(batch_id))
    query += " ORDER BY m.machine_id COLLATE NOCASE"
    machine_rows = db.execute(query, params).fetchall()
    batch_rows = db.execute("SELECT id, code FROM batches WHERE is_archived = 0 ORDER BY code").fetchall()
    return render_template(
        "machines/list.html",
        machines=machine_rows,
        batches=batch_rows,
        statuses=MACHINE_STATUSES,
        locations=MACHINE_LOCATIONS,
        filters={"search": search, "status": status, "location": location, "batch_id": batch_id},
    )


@main.route("/machines/new", methods=("GET", "POST"))
def new_machine():
    return redirect(url_for("main.receive"))


def _validate_machine(db, form, machine_id=None):
    if not form["machine_id"] or not form["batch_id"] or not form["model"] or not form["serial_number"]:
        return "Machine ID, batch, model, and serial number are required."
    if not form["batch_id"].isdigit() or not db.execute(
        "SELECT 1 FROM batches WHERE id = ? AND is_archived = 0", (int(form["batch_id"]),)
    ).fetchone():
        return "Select an active batch."
    duplicate_id = db.execute(
        "SELECT 1 FROM machines WHERE machine_id = ? COLLATE NOCASE AND id != COALESCE(?, 0)",
        (form["machine_id"], machine_id),
    ).fetchone()
    if duplicate_id:
        return "That machine ID already exists."
    duplicate_serial = db.execute(
        "SELECT 1 FROM machines WHERE serial_number = ? COLLATE NOCASE AND id != COALESCE(?, 0)",
        (form["serial_number"], machine_id),
    ).fetchone()
    if duplicate_serial:
        return "That machine serial number already exists."
    return None


@main.route("/machines/<int:machine_id>/edit", methods=("GET", "POST"))
def edit_machine(machine_id):
    db = get_db()
    machine = db.execute("SELECT * FROM machines WHERE id = ? AND is_archived = 0", (machine_id,)).fetchone()
    if machine is None:
        flash("Machine not found.", "error")
        return redirect(url_for("main.machines"))
    batches = db.execute("SELECT id, code FROM batches WHERE is_archived = 0 OR id = ? ORDER BY code", (machine["batch_id"],)).fetchall()
    form = _machine_form_data() if request.method == "POST" else dict(machine)
    if request.method == "POST":
        error = _validate_machine(db, form, machine_id)
        if error:
            flash(error, "error")
        else:
            db.execute(
                """UPDATE machines SET machine_id = ?, batch_id = ?, model = ?, serial_number = ?,
                acquisition_date = ?, notes = ? WHERE id = ?""",
                (form["machine_id"], int(form["batch_id"]), form["model"], form["serial_number"], form["acquisition_date"], form["notes"], machine_id),
            )
            db.commit()
            flash(f"Machine {form['machine_id']} was updated.", "success")
            return redirect(url_for("main.machine_detail", machine_id=machine_id))
    return render_template("machines/form.html", machine=form, batches=batches, editing=True)


@main.get("/machines/<int:machine_id>")
def machine_detail(machine_id):
    db = get_db()
    machine = db.execute(
        """SELECT m.*, b.code AS batch_code, b.arrival_date AS batch_arrival_date,
                  bd.name AS brand_name, v.name AS vendor_name,
                  COALESCE(v.name, bv.name) AS provider_name
           FROM machines m
           JOIN batches b ON b.id = m.batch_id
           LEFT JOIN brands bd ON bd.id = m.brand_id
           LEFT JOIN vendors v ON v.id = m.vendor_id
           LEFT JOIN vendors bv ON bv.id = b.vendor_id
           WHERE m.id = ? AND m.is_archived = 0""",
        (machine_id,),
    ).fetchone()
    if machine is None:
        flash("Machine not found.", "error")
        return redirect(url_for("main.machines"))
    events = helpers.movement_events(db, "machine", machine_id)
    set_items = helpers.machine_set(db, machine)
    out_dest = helpers.out_destination(db, "machine", machine)
    probe_dests = {
        p["id"]: helpers.out_destination(db, "probe", p) for p in set_items["probes"]
    }
    printer_dests = {
        p["id"]: helpers.out_destination(db, "printer", p) for p in set_items["printers"]
    }
    sale = None
    sale_items = []
    sale_row = db.execute(
        """SELECT si.sale_id FROM sale_items si
           JOIN sales s ON s.id = si.sale_id
           WHERE si.item_type = 'machine' AND si.machine_id = ?
           ORDER BY si.sale_id DESC LIMIT 1""",
        (machine_id,),
    ).fetchone()
    if sale_row:
        sale = db.execute(
            """SELECT s.*, c.name AS customer_name FROM sales s
               LEFT JOIN customers c ON c.id = s.customer_id WHERE s.id = ?""",
            (sale_row["sale_id"],),
        ).fetchone()
        sale_items = db.execute(
            "SELECT * FROM sale_items WHERE sale_id = ? ORDER BY is_main_item DESC, id",
            (sale["id"],),
        ).fetchall()
    return render_template(
        "machines/detail.html",
        machine=machine,
        events=events,
        set_items=set_items,
        out_dest=out_dest,
        probe_dests=probe_dests,
        printer_dests=printer_dests,
        sale=sale,
        sale_items=sale_items,
    )


# ══════════════════════════════════════════════════════════════════════════
# Stage 3 — read-only list pages (catalogue, customers, vendors,
# probes, printers, parts, sales)
# ══════════════════════════════════════════════════════════════════════════

@main.get("/catalogue")
def catalogue():
    db = get_db()
    search = (request.args.get("search") or "").strip()
    category = request.args.get("category") or ""
    brand_id = request.args.get("brand_id") or ""
    review = request.args.get("review") or ""
    query = """
        SELECT c.*, b.name AS brand_name
        FROM catalog_products c
        LEFT JOIN brands b ON b.id = c.brand_id
        WHERE c.is_archived = 0
    """
    params = []
    if search:
        query += " AND (c.name_model LIKE ? OR b.name LIKE ? OR c.source_info LIKE ?)"
        pattern = f"%{search}%"
        params.extend((pattern, pattern, pattern))
    if category in CATALOG_CATEGORIES:
        query += " AND c.category = ?"
        params.append(category)
    if brand_id.isdigit():
        query += " AND c.brand_id = ?"
        params.append(int(brand_id))
    if review == "1":
        query += " AND c.needs_review = 1"
    query += " ORDER BY c.category, b.name COLLATE NOCASE, c.name_model COLLATE NOCASE"
    rows = db.execute(query, params).fetchall()
    brands = db.execute("SELECT id, name FROM brands ORDER BY name COLLATE NOCASE").fetchall()
    counts = db.execute("""
        SELECT category, COUNT(*) AS n, SUM(needs_review) AS flagged
        FROM catalog_products WHERE is_archived = 0 GROUP BY category
    """).fetchall()
    return render_template(
        "catalogue/list.html",
        items=rows,
        brands=brands,
        categories=CATALOG_CATEGORIES,
        counts={r["category"]: r for r in counts},
        filters={"search": search, "category": category, "brand_id": brand_id, "review": review},
    )


@main.get("/customers")
def customers():
    db = get_db()
    search = (request.args.get("search") or "").strip()
    ctype = request.args.get("type") or ""
    query = "SELECT * FROM customers WHERE is_archived = 0"
    params = []
    if search:
        query += " AND (name LIKE ? OR phone LIKE ? OR city LIKE ? OR address LIKE ?)"
        pattern = f"%{search}%"
        params.extend((pattern, pattern, pattern, pattern))
    if ctype in CUSTOMER_TYPES:
        query += " AND customer_type = ?"
        params.append(ctype)
    query += " ORDER BY name COLLATE NOCASE"
    rows = db.execute(query, params).fetchall()
    type_counts = dict(db.execute(
        "SELECT customer_type, COUNT(*) FROM customers WHERE is_archived = 0 GROUP BY customer_type"
    ).fetchall())
    return render_template(
        "customers/list.html",
        items=rows,
        types=CUSTOMER_TYPES,
        type_counts=type_counts,
        filters={"search": search, "type": ctype},
    )


@main.get("/vendors")
def vendors():
    db = get_db()
    search = (request.args.get("search") or "").strip()
    query = "SELECT * FROM vendors WHERE is_archived = 0"
    params = []
    if search:
        query += " AND (name LIKE ? OR phone LIKE ? OR address LIKE ?)"
        pattern = f"%{search}%"
        params.extend((pattern, pattern, pattern))
    query += " ORDER BY name COLLATE NOCASE"
    rows = db.execute(query, params).fetchall()
    return render_template("vendors/list.html", items=rows, filters={"search": search})


@main.get("/probes")
def probes():
    db = get_db()
    search = (request.args.get("search") or "").strip()
    status = request.args.get("status") or ""
    review = request.args.get("review") or ""
    query = """
        SELECT p.*, b.name AS brand_name, c.name_model AS catalog_model,
               m.machine_id AS assigned_machine_code
        FROM probes p
        LEFT JOIN brands b ON b.id = p.brand_id
        LEFT JOIN catalog_products c ON c.id = p.catalog_product_id
        LEFT JOIN machines m ON m.id = p.assigned_machine_id
        WHERE p.is_archived = 0
    """
    params = []
    if search:
        query += " AND (p.internal_id LIKE ? OR p.model LIKE ? OR p.serial_number LIKE ? OR b.name LIKE ?)"
        pattern = f"%{search}%"
        params.extend((pattern, pattern, pattern, pattern))
    if status in PROBE_STATUSES:
        query += " AND p.status = ?"
        params.append(status)
    if review == "1":
        query += " AND p.needs_review = 1"
    query += " ORDER BY p.internal_id"
    rows = db.execute(query, params).fetchall()
    status_counts = dict(db.execute(
        "SELECT status, COUNT(*) FROM probes WHERE is_archived = 0 GROUP BY status"
    ).fetchall())
    return render_template(
        "probes/list.html",
        items=rows,
        statuses=PROBE_STATUSES,
        status_counts=status_counts,
        filters={"search": search, "status": status, "review": review},
    )


@main.get("/printers")
def printers():
    db = get_db()
    search = (request.args.get("search") or "").strip()
    status = request.args.get("status") or ""
    review = request.args.get("review") or ""
    query = """
        SELECT p.*, b.name AS brand_name
        FROM printers p
        LEFT JOIN brands b ON b.id = p.brand_id
        WHERE p.is_archived = 0
    """
    params = []
    if search:
        query += " AND (p.internal_id LIKE ? OR p.name_model LIKE ? OR p.serial_number LIKE ? OR b.name LIKE ?)"
        pattern = f"%{search}%"
        params.extend((pattern, pattern, pattern, pattern))
    if status in PRINTER_STATUSES:
        query += " AND p.status = ?"
        params.append(status)
    if review == "1":
        query += " AND p.needs_review = 1"
    query += " ORDER BY p.internal_id"
    rows = db.execute(query, params).fetchall()
    status_counts = dict(db.execute(
        "SELECT status, COUNT(*) FROM printers WHERE is_archived = 0 GROUP BY status"
    ).fetchall())
    availability = helpers.printer_models(db)
    return render_template(
        "printers/list.html",
        items=rows,
        statuses=PRINTER_STATUSES,
        status_counts=status_counts,
        availability=availability,
        filters={"search": search, "status": status, "review": review},
    )


@main.get("/printers/<int:printer_id>")
def printer_detail(printer_id):
    db = get_db()
    printer = db.execute(
        """SELECT p.*, b.name AS brand_name, m.machine_id AS assigned_machine_code
           FROM printers p
           LEFT JOIN brands b ON b.id = p.brand_id
           LEFT JOIN machines m ON m.id = p.assigned_machine_id
           WHERE p.id = ? AND p.is_archived = 0""",
        (printer_id,),
    ).fetchone()
    if printer is None:
        flash("Printer not found.", "error")
        return redirect(url_for("main.printers"))
    events = helpers.movement_events(db, "printer", printer_id)
    out_dest = helpers.out_destination(db, "printer", printer)
    model_stats = db.execute(
        """SELECT COALESCE(SUM(quantity), 0) AS total,
                  COALESCE(SUM(CASE WHEN status = 'Available' THEN quantity ELSE 0 END), 0) AS company,
                  COALESCE(SUM(CASE WHEN status = 'With Machine' THEN quantity ELSE 0 END), 0) AS with_machine,
                  COALESCE(SUM(CASE WHEN status = 'With Workshop' THEN quantity ELSE 0 END), 0) AS workshop,
                  COALESCE(SUM(CASE WHEN status = 'With Dealer' THEN quantity ELSE 0 END), 0) AS dealer,
                  COALESCE(SUM(CASE WHEN status = 'Sold' THEN quantity ELSE 0 END), 0) AS sold
           FROM printers
           WHERE name_model = ? COLLATE NOCASE AND is_archived = 0""",
        (printer["name_model"],),
    ).fetchone()
    return render_template(
        "printers/detail.html",
        printer=printer,
        events=events,
        out_dest=out_dest,
        model_stats=model_stats,
    )


@main.get("/parts")
def parts():
    db = get_db()
    search = (request.args.get("search") or "").strip()
    status = request.args.get("status") or ""
    query = """
        SELECT p.*, b.name AS brand_name
        FROM parts p
        LEFT JOIN brands b ON b.id = p.brand_id
        WHERE p.is_archived = 0
    """
    params = []
    if search:
        query += " AND (p.internal_id LIKE ? OR p.name_model LIKE ? OR p.serial_number LIKE ? OR b.name LIKE ?)"
        pattern = f"%{search}%"
        params.extend((pattern, pattern, pattern, pattern))
    if status in ("Available", "With Machine", "Sold", "Archived"):
        query += " AND p.status = ?"
        params.append(status)
    query += " ORDER BY p.internal_id"
    rows = db.execute(query, params).fetchall()
    status_counts = dict(db.execute(
        "SELECT status, COUNT(*) FROM parts WHERE is_archived = 0 GROUP BY status"
    ).fetchall())
    return render_template(
        "parts/list.html",
        items=rows,
        status_counts=status_counts,
        filters={"search": search, "status": status},
    )


@main.route("/parts/add", methods=("GET", "POST"))
def part_add():
    db = get_db()
    if request.method == "POST":
        name_model = _clean(request.form.get("name_model"))
        brand_name = _clean(request.form.get("brand_name"))
        serial_number = _clean(request.form.get("serial_number"))
        acquisition_date = _clean(request.form.get("acquisition_date"))
        condition = _clean(request.form.get("condition"))
        notes = _clean(request.form.get("notes"))
        batch_raw = (request.form.get("batch_id") or "").strip()
        quantity_raw = (request.form.get("quantity") or "").strip()
        quantity = None
        valid = True
        if not name_model:
            flash("Part name / model is required.", "error")
            valid = False
        else:
            try:
                quantity = int(quantity_raw or "1")
                if quantity < 0:
                    raise ValueError
            except ValueError:
                flash("Quantity must be a whole number of zero or more.", "error")
                valid = False
        if condition and condition not in PROBE_CONDITIONS:
            flash("Choose a valid condition.", "error")
            valid = False
        if valid:
            internal = helpers.next_internal_id(db, "PART", "parts", "internal_id")
            brand_id = helpers.find_or_create_brand(db, brand_name)
            catalog_id = helpers.find_or_create_catalog(db, name_model, "Part", brand_id)
            batch_id = int(batch_raw) if batch_raw.isdigit() else None
            if batch_id and not db.execute(
                "SELECT 1 FROM batches WHERE id = ? AND is_archived = 0", (batch_id,)
            ).fetchone():
                batch_id = None
            db.execute(
                """INSERT INTO parts (internal_id, catalog_product_id, name_model, brand_id,
                       serial_number, quantity, batch_id, acquisition_date, condition, notes)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (internal, catalog_id, name_model, brand_id, serial_number, quantity,
                 batch_id, acquisition_date, condition, notes),
            )
            db.commit()
            flash(f"Part {internal} added.", "success")
            return redirect(url_for("main.parts"))
    return render_template(
        "parts/form.html",
        form=request.form,
        batches=db.execute(
            "SELECT id, code FROM batches WHERE is_archived = 0 ORDER BY code"
        ).fetchall(),
        conditions=PROBE_CONDITIONS,
        today=date.today().isoformat(),
    )


@main.get("/inventory")
def inventory():
    db = get_db()
    machines = db.execute(
        """SELECT m.*, b.code AS batch_code, bd.name AS brand_name
           FROM machines m
           JOIN batches b ON b.id = m.batch_id
           LEFT JOIN brands bd ON bd.id = m.brand_id
           WHERE m.is_archived = 0 AND b.is_archived = 0
           ORDER BY m.created_at DESC, m.id DESC"""
    ).fetchall()
    groups = [{"machine": m, "probes": [], "printers": [], "parts": []} for m in machines]
    owners = {g["machine"]["id"]: g for g in groups}
    loose = {"probes": [], "printers": [], "parts": []}
    for table in ("probes", "printers", "parts"):
        kind = table[:-1]
        for row in db.execute(
            f"SELECT * FROM {table} WHERE is_archived = 0 ORDER BY created_at DESC, id DESC"
        ).fetchall():
            owner = owners.get(row["assigned_machine_id"])
            if owner is not None:
                owner[table].append(row)
            else:
                loose[table].append((kind, row))
    counts = {
        table: db.execute(
            f"SELECT COUNT(*) FROM {table} WHERE is_archived = 0"
        ).fetchone()[0]
        for table in ("machines", "probes", "printers", "parts")
    }
    counts["total"] = sum(counts.values())
    destinations = {}
    candidates = [
        ("machine", g["machine"])
        for g in groups
        if g["machine"]["status"] in helpers.OUT_STATUSES
    ]
    for kind in ("probe", "printer"):
        rows = [r for g in groups for r in g[kind + "s"]] + [
            r for _, r in loose[kind + "s"]
        ]
        candidates += [(kind, r) for r in rows if r["status"] in helpers.OUT_STATUSES]
    for kind, row in candidates:
        destinations[(kind, row["id"])] = (
            helpers.out_destination(db, kind, row) or row["current_location"]
        )
    return render_template(
        "inventory/list.html",
        groups=groups,
        loose=loose,
        counts=counts,
        destinations=destinations,
        batches={b["id"]: b["code"] for b in db.execute("SELECT id, code FROM batches")},
    )


@main.get("/sales")
def sales():
    db = get_db()
    search = (request.args.get("search") or "").strip()
    query = """
        SELECT s.*, c.name AS customer_name,
               (SELECT COUNT(*) FROM sale_items si WHERE si.sale_id = s.id) AS item_count
        FROM sales s
        LEFT JOIN customers c ON c.id = s.customer_id
        WHERE 1 = 1
    """
    params = []
    if search:
        query += " AND (s.old_trno LIKE ? OR c.name LIKE ? OR s.notes LIKE ? OR s.sale_date LIKE ?)"
        pattern = f"%{search}%"
        params.extend((pattern, pattern, pattern, pattern))
    query += " ORDER BY s.sale_date DESC, s.id DESC"
    rows = db.execute(query, params).fetchall()
    return render_template("sales/list.html", items=rows, filters={"search": search})


@main.get("/sales/<int:sale_id>")
def sale_detail(sale_id):
    db = get_db()
    sale = db.execute(
        """SELECT s.*, c.name AS customer_name FROM sales s
           LEFT JOIN customers c ON c.id = s.customer_id WHERE s.id = ?""",
        (sale_id,),
    ).fetchone()
    if sale is None:
        flash("Sale not found.", "error")
        return redirect(url_for("main.sales"))
    items = db.execute(
        "SELECT * FROM sale_items WHERE sale_id = ? ORDER BY is_main_item DESC, id",
        (sale_id,),
    ).fetchall()
    return render_template("sales/detail.html", sale=sale, items=items)


# ══════════════════════════════════════════════════════════════════════════
# Stage 4 — global search
# ══════════════════════════════════════════════════════════════════════════

@main.get("/search")
def search():
    db = get_db()
    q = (request.args.get("q") or "").strip()
    results = {
        "machines": [], "probes": [], "printers": [],
        "workshops": [], "dealers": [], "movements": [],
    }
    if q:
        pattern = f"%{q}%"
        results["machines"] = db.execute(
            """SELECT m.*, b.code AS batch_code, bd.name AS brand_name
               FROM machines m
               JOIN batches b ON b.id = m.batch_id
               LEFT JOIN brands bd ON bd.id = m.brand_id
               WHERE m.is_archived = 0
                 AND (m.machine_id LIKE ? OR m.serial_number LIKE ? OR m.model LIKE ?)
               ORDER BY m.machine_id COLLATE NOCASE LIMIT 20""",
            (pattern, pattern, pattern),
        ).fetchall()
        results["probes"] = db.execute(
            """SELECT p.*, m.machine_id AS assigned_machine_code
               FROM probes p
               LEFT JOIN machines m ON m.id = p.assigned_machine_id
               WHERE p.is_archived = 0
                 AND (p.internal_id LIKE ? OR p.serial_number LIKE ? OR p.model LIKE ?)
               ORDER BY p.internal_id LIMIT 20""",
            (pattern, pattern, pattern),
        ).fetchall()
        results["printers"] = db.execute(
            """SELECT p.*, m.machine_id AS assigned_machine_code
               FROM printers p
               LEFT JOIN machines m ON m.id = p.assigned_machine_id
               WHERE p.is_archived = 0
                 AND (p.internal_id LIKE ? OR p.name_model LIKE ? OR p.serial_number LIKE ?)
               ORDER BY p.internal_id LIMIT 20""",
            (pattern, pattern, pattern),
        ).fetchall()
        results["workshops"] = db.execute(
            "SELECT * FROM workshops WHERE name LIKE ? ORDER BY name COLLATE NOCASE LIMIT 10",
            (pattern,),
        ).fetchall()
        results["dealers"] = db.execute(
            "SELECT * FROM dealers WHERE name LIKE ? ORDER BY name COLLATE NOCASE LIMIT 10",
            (pattern,),
        ).fetchall()
        movement_rows = db.execute(
            """SELECT mv.*, m.machine_id AS machine_code, pr.internal_id AS probe_code,
                      pt.internal_id AS printer_code
               FROM movements mv
               LEFT JOIN machines m ON m.id = mv.machine_id
               LEFT JOIN probes pr ON pr.id = mv.probe_id
               LEFT JOIN printers pt ON pt.id = mv.printer_id
               WHERE mv.reference LIKE ?
               ORDER BY mv.id DESC LIMIT 20""",
            (pattern,),
        ).fetchall()
        for row in movement_rows:
            if row["machine_id"]:
                row = dict(row)
                row["url"] = url_for("main.machine_detail", machine_id=row["machine_id"])
                row["subject"] = f"Machine {row['machine_code']}"
            elif row["probe_id"]:
                row = dict(row)
                row["url"] = url_for("main.probe_detail", probe_id=row["probe_id"])
                row["subject"] = f"Probe {row['probe_code']}"
            elif row["printer_id"]:
                row = dict(row)
                row["url"] = url_for("main.printer_detail", printer_id=row["printer_id"])
                row["subject"] = f"Printer {row['printer_code']}"
            else:
                row = dict(row)
                row["url"] = None
                row["subject"] = "—"
            results["movements"].append(row)
    return render_template("search/results.html", q=q, results=results)


@main.get("/api/machine-id-suggestion")
def api_machine_id_suggestion():
    db = get_db()
    batch_id = request.args.get("batch_id") or ""
    batch_code = (request.args.get("batch_code") or "").strip()
    if not batch_id.isdigit() and batch_code:
        row = db.execute(
            "SELECT id FROM batches WHERE code = ? COLLATE NOCASE", (batch_code,)
        ).fetchone()
        if row:
            batch_id = str(row["id"])
    if not batch_id.isdigit():
        return jsonify({"machine_id": ""})
    return jsonify({"machine_id": _suggest_machine_id(db, int(batch_id))})


# Datalist data for brand/model resolution on forms
@main.get("/api/brands")
def api_brands():
    rows = get_db().execute(
        "SELECT id, name FROM brands WHERE is_active = 1 ORDER BY name COLLATE NOCASE"
    ).fetchall()
    return jsonify([{"id": r["id"], "name": r["name"]} for r in rows])


@main.get("/api/catalog-products")
def api_catalog_products():
    category = request.args.get("category") or ""
    brand_id = request.args.get("brand_id") or ""
    search = (request.args.get("q") or "").strip()
    query = """
        SELECT c.id, c.name_model, c.category, c.probe_type, b.name AS brand_name
        FROM catalog_products c
        LEFT JOIN brands b ON b.id = c.brand_id
        WHERE c.is_archived = 0
    """
    params = []
    if category in CATALOG_CATEGORIES:
        query += " AND c.category = ?"
        params.append(category)
    if brand_id.isdigit():
        query += " AND c.brand_id = ?"
        params.append(int(brand_id))
    if search:
        query += " AND c.name_model LIKE ?"
        params.append(f"%{search}%")
    query += " ORDER BY c.name_model COLLATE NOCASE"
    rows = get_db().execute(query, params).fetchall()
    return jsonify([dict(r) for r in rows])


@main.get("/api/printer-models")
def api_printer_models():
    """Printer models with quantity availability, most recently used first."""
    return jsonify([dict(r) for r in helpers.printer_models(get_db())])


@main.get("/api/probe-serial-check")
def api_probe_serial_check():
    serial = (request.args.get("serial") or "").strip()
    if not serial:
        return jsonify({"exists": False})
    db = get_db()
    row = db.execute(
        """SELECT p.*, m.machine_id AS attached_machine
           FROM probes p
           LEFT JOIN machines m ON m.id = p.assigned_machine_id
           WHERE p.serial_number = ? COLLATE NOCASE AND p.is_archived = 0
           LIMIT 1""",
        (serial,),
    ).fetchone()
    if row is None:
        return jsonify({"exists": False})
    if row["attached_machine"]:
        where = f"attached to Machine {row['attached_machine']}"
    else:
        where = f"status {row['status']} · {row['current_location']}"
    return jsonify({
        "exists": True,
        "internal_id": row["internal_id"],
        "model": row["model"],
        "where": where,
    })

