import json
from datetime import date, timedelta

from flask import flash, redirect, render_template, request, url_for
from sqlite3 import IntegrityError

from .database import get_db
from .routes import main, _suggest_machine_id
from . import helpers


def _today():
    return date.today().isoformat()


def _clean(value):
    return (value or "").strip()


class FormErrors(ValueError):
    def __init__(self, errors):
        super().__init__(" ".join(errors))
        self.errors = errors


# ── Form construction ─────────────────────────────────────────────────────────

def _empty_form():
    return {
        "provider_name": "",
        "provider_phone": "",
        "batch_code": "",
        "arrival_date": _today(),
        "brand_name": "",
        "model": "",
        "serial_number": "",
        "machine_id": "",
        "probe_rows": [{"model": "", "serial": ""}],
        "printer_catalog_id": "",
        "printer_model_name": "",
        "notes": "",
    }


def _form_from_post():
    form = _empty_form()
    for key in ("provider_name", "provider_phone", "batch_code", "arrival_date",
                "brand_name", "model", "serial_number", "machine_id",
                "printer_catalog_id", "printer_model_name", "notes"):
        form[key] = _clean(request.form.get(key))
    models = request.form.getlist("probe_model")
    serials = request.form.getlist("probe_serial")
    rows = []
    for i, model in enumerate(models):
        serial = serials[i] if i < len(serials) else ""
        if _clean(model) or _clean(serial):
            rows.append({"model": _clean(model), "serial": _clean(serial)})
    form["probe_rows"] = rows or [{"model": "", "serial": ""}]
    return form


def _resolve_name(db, table, pk):
    if not pk or not str(pk).isdigit():
        return ""
    if table == "brands":
        row = db.execute("SELECT name FROM brands WHERE id = ?", (int(pk),)).fetchone()
    else:
        row = db.execute(
            f"SELECT name FROM {table} WHERE id = ? AND is_archived = 0", (int(pk),)
        ).fetchone()
    return row["name"] if row else ""


def _form_defaults(db):
    settings = helpers.get_settings(db)
    form = _empty_form()

    batch_row = None
    batch_id = settings.get("last_batch_id") or ""
    if batch_id.isdigit():
        batch_row = db.execute(
            "SELECT * FROM batches WHERE id = ? AND is_archived = 0", (int(batch_id),)
        ).fetchone()
    if batch_row:
        form["batch_code"] = batch_row["code"]

    provider_id = settings.get("last_vendor_id") or ""
    if provider_id.isdigit() and not db.execute(
        "SELECT 1 FROM vendors WHERE id = ? AND is_archived = 0", (int(provider_id),)
    ).fetchone():
        provider_id = ""
    if not provider_id and batch_row and batch_row["vendor_id"]:
        provider_id = str(batch_row["vendor_id"])
    form["provider_name"] = _resolve_name(db, "vendors", provider_id)

    last_date = settings.get("last_arrival_date") or ""
    if last_date >= (date.today() - timedelta(days=1)).isoformat():
        form["arrival_date"] = last_date
    elif batch_row and batch_row["arrival_date"]:
        form["arrival_date"] = batch_row["arrival_date"]

    brand_id = settings.get("last_brand_id") or ""
    if brand_id.isdigit() and not db.execute(
        "SELECT 1 FROM brands WHERE id = ?", (int(brand_id),)
    ).fetchone():
        brand_id = ""
    form["brand_name"] = _resolve_name(db, "brands", brand_id)
    form["model"] = settings.get("last_model") or ""

    if batch_row:
        form["machine_id"] = _suggest_machine_id(db, batch_row["id"])
    return form


def _form_from_machine(db, machine_pk):
    form = _form_defaults(db)
    machine = db.execute(
        "SELECT * FROM machines WHERE id = ? AND is_archived = 0", (machine_pk,)
    ).fetchone()
    if machine is None:
        return form
    batch_row = db.execute(
        "SELECT * FROM batches WHERE id = ?", (machine["batch_id"],)
    ).fetchone()
    form["batch_code"] = batch_row["code"] if batch_row else ""
    vendor_id = machine["vendor_id"] or (batch_row["vendor_id"] if batch_row else None)
    form["provider_name"] = _resolve_name(db, "vendors", vendor_id)
    form["arrival_date"] = (
        machine["acquisition_date"]
        or (batch_row["arrival_date"] if batch_row else "")
        or _today()
    )
    form["brand_name"] = _resolve_name(db, "brands", machine["brand_id"])
    form["model"] = machine["model"] or ""
    form["serial_number"] = ""
    form["machine_id"] = _suggest_machine_id(db, machine["batch_id"])
    form["notes"] = ""

    probes = db.execute(
        """SELECT model FROM probes
           WHERE (assigned_machine_id = ? OR batch_id = ?) AND is_archived = 0
             AND model IS NOT NULL AND model != ''
           GROUP BY model COLLATE NOCASE ORDER BY MIN(internal_id)""",
        (machine["id"], machine["batch_id"]),
    ).fetchall()
    rows = [{"model": p["model"], "serial": ""} for p in probes]
    if not rows:
        rows = [{"model": m, "serial": ""} for m in helpers.last_probe_models(helpers.get_settings(db))]
    form["probe_rows"] = rows[:8] or [{"model": "", "serial": ""}]

    printer = db.execute(
        """SELECT catalog_product_id FROM printers
           WHERE assigned_machine_id = ? AND is_archived = 0
             AND catalog_product_id IS NOT NULL LIMIT 1""",
        (machine["id"],),
    ).fetchone()
    if printer:
        form["printer_catalog_id"] = str(printer["catalog_product_id"])
    else:
        form["printer_catalog_id"] = ""
    return form


# ── Saving ────────────────────────────────────────────────────────────────────

def _validate(db, form):
    errors = []
    if not form["provider_name"]:
        errors.append("Provider is required. Select one or type a new provider name.")
    if not form["batch_code"]:
        errors.append("Batch is required. Select one or type a new batch code.")
    if not form["arrival_date"]:
        errors.append("Arrival date is required.")
    if not form["brand_name"]:
        errors.append("Brand is required. Select one or type a new brand name.")
    if not form["model"]:
        errors.append("Model is required.")
    if not form["machine_id"]:
        errors.append("Machine ID is required.")
    if not form["serial_number"]:
        errors.append("Machine serial number is required.")
    if not form["printer_catalog_id"] and form["printer_model_name"] and len(form["printer_model_name"]) < 2:
        errors.append("Enter a full printer model name or select one from the list.")

    if form["machine_id"] and db.execute(
        "SELECT 1 FROM machines WHERE machine_id = ? COLLATE NOCASE", (form["machine_id"],)
    ).fetchone():
        errors.append(f"Machine ID {form['machine_id']} already exists.")
    if form["serial_number"] and db.execute(
        "SELECT 1 FROM machines WHERE serial_number = ? COLLATE NOCASE", (form["serial_number"],)
    ).fetchone():
        errors.append(f"Machine serial {form['serial_number']} already exists.")

    for i, row in enumerate(form["probe_rows"], start=1):
        if row["model"] and row["serial"]:
            existing = db.execute(
                """SELECT p.*, m.machine_id AS attached_machine FROM probes p
                   LEFT JOIN machines m ON m.id = p.assigned_machine_id
                   WHERE p.serial_number = ? COLLATE NOCASE AND p.is_archived = 0 LIMIT 1""",
                (row["serial"],),
            ).fetchone()
            if existing:
                errors.append(
                    f"Probe serial {row['serial']} already exists "
                    f"({existing['internal_id']} is {helpers.probe_location_text(db, existing)})."
                )
        elif row["serial"] and not row["model"]:
            errors.append(f"Probe row {i}: enter a probe model for serial {row['serial']}.")
        elif row["model"] and not row["serial"]:
            errors.append(f"Probe row {i}: enter the serial number for probe model {row['model']}.")
    return errors


def _save(db, form):
    errors = _validate(db, form)
    if errors:
        raise FormErrors(errors)

    vendor_id = helpers.find_or_create_vendor(db, form["provider_name"], form["provider_phone"])
    brand_id = helpers.find_or_create_brand(db, form["brand_name"])
    batch_id = helpers.find_or_create_batch(db, form["batch_code"], form["arrival_date"], vendor_id)
    catalog_id = helpers.find_or_create_catalog(db, form["model"], "Machine", brand_id)
    arrival = form["arrival_date"]
    group = f"rcv-{form['machine_id']}"
    reference = helpers.next_movement_reference(db)

    try:
        cur = db.execute(
            """INSERT INTO machines
               (machine_id, batch_id, catalog_product_id, brand_id, model, serial_number,
                vendor_id, acquisition_date, status, current_location, notes)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'In Stock', 'Company', ?)""",
            (form["machine_id"], batch_id, catalog_id, brand_id, form["model"],
             form["serial_number"], vendor_id, arrival, form["notes"] or None),
        )
    except IntegrityError:
        raise ValueError("That machine ID or serial number already exists.")
    machine_pk = cur.lastrowid

    helpers.log_movement(
        db, "Received", arrival, machine_id=machine_pk, to_location="Company",
        notes=f"Batch {form['batch_code']}", group_ref=group, reference=reference,
    )

    probe_models = []
    for row in form["probe_rows"]:
        if not row["model"]:
            continue
        probe_catalog = helpers.find_or_create_catalog(db, row["model"], "Probe", None)
        internal = helpers.next_internal_id(db, "PRB", "probes", "internal_id")
        cur = db.execute(
            """INSERT INTO probes
               (internal_id, catalog_product_id, model, serial_number, batch_id, vendor_id,
                acquisition_date, status, current_location, assigned_machine_id, condition)
               VALUES (?, ?, ?, ?, ?, ?, ?, 'With Machine', 'Company', ?, 'Good')""",
            (internal, probe_catalog, row["model"], row["serial"], batch_id,
             vendor_id, arrival, machine_pk),
        )
        helpers.log_movement(
            db, "Received", arrival, probe_id=cur.lastrowid, to_location="Company",
            notes=f"With machine {form['machine_id']}", group_ref=group, reference=reference,
        )
        probe_models.append(row["model"])

    if form["printer_catalog_id"].isdigit():
        printer_catalog = int(form["printer_catalog_id"])
    elif form["printer_model_name"]:
        printer_catalog = helpers.find_or_create_catalog(
            db, form["printer_model_name"], "Printer", None
        )
    else:
        printer_catalog = None

    printer_note = ""
    if printer_catalog:
        unit = db.execute(
            """SELECT * FROM printers
               WHERE catalog_product_id = ? AND is_archived = 0 AND status = 'Available'
               ORDER BY id LIMIT 1""",
            (printer_catalog,),
        ).fetchone()
        if unit:
            db.execute(
                """UPDATE printers SET status = 'With Machine', assigned_machine_id = ?,
                   batch_id = COALESCE(batch_id, ?), vendor_id = COALESCE(vendor_id, ?),
                   acquisition_date = COALESCE(acquisition_date, ?) WHERE id = ?""",
                (machine_pk, batch_id, vendor_id, arrival, unit["id"]),
            )
            helpers.log_movement(
                db, "Attachment", arrival, printer_id=unit["id"],
                to_location=f"With machine {form['machine_id']}", group_ref=group, reference=reference,
            )
            printer_note = unit["name_model"]
        else:
            name_model = db.execute(
                "SELECT name_model FROM catalog_products WHERE id = ?", (printer_catalog,)
            ).fetchone()["name_model"]
            internal = helpers.next_internal_id(db, "PRT", "printers", "internal_id")
            cur = db.execute(
                """INSERT INTO printers
                   (internal_id, catalog_product_id, name_model, quantity, batch_id, vendor_id,
                    acquisition_date, status, current_location, assigned_machine_id, condition)
                   VALUES (?, ?, ?, 1, ?, ?, ?, 'With Machine', 'Company', ?, 'Good')""",
                (internal, printer_catalog, name_model, batch_id, vendor_id, arrival, machine_pk),
            )
            helpers.log_movement(
                db, "Received", arrival, printer_id=cur.lastrowid, to_location="Company",
                notes=f"With machine {form['machine_id']}", group_ref=group, reference=reference,
            )
            printer_note = name_model

    helpers.set_settings(db, {
        "last_vendor_id": str(vendor_id or ""),
        "last_batch_id": str(batch_id or ""),
        "last_arrival_date": arrival,
        "last_brand_id": str(brand_id or ""),
        "last_model": form["model"],
        "last_printer_catalog_id": str(printer_catalog or ""),
        "last_probe_models": json.dumps(probe_models),
    })
    db.commit()
    return machine_pk, printer_note


# ── Route ─────────────────────────────────────────────────────────────────────

def _page_data(db, form, saved_machine=None, banner=None):
    batches = db.execute(
        "SELECT id, code, arrival_date FROM batches WHERE is_archived = 0 ORDER BY code COLLATE NOCASE"
    ).fetchall()
    batch_dates = {b["code"]: (b["arrival_date"] or "") for b in batches}
    vendors = db.execute(
        "SELECT name FROM vendors WHERE is_archived = 0 ORDER BY name COLLATE NOCASE"
    ).fetchall()
    brands = db.execute(
        "SELECT name FROM brands WHERE is_active = 1 ORDER BY name COLLATE NOCASE"
    ).fetchall()
    machine_models = db.execute(
        """SELECT name_model FROM catalog_products
           WHERE category = 'Machine' AND is_archived = 0 ORDER BY name_model COLLATE NOCASE"""
    ).fetchall()
    probe_models = db.execute(
        """SELECT name_model FROM catalog_products
           WHERE category = 'Probe' AND is_archived = 0 ORDER BY name_model COLLATE NOCASE"""
    ).fetchall()
    recent_models = helpers.recent_probe_models(db)
    last_machine = db.execute(
        "SELECT id FROM machines WHERE is_archived = 0 ORDER BY id DESC LIMIT 1"
    ).fetchone()
    return {
        "form": form,
        "batch_dates": batch_dates,
        "vendor_names": [v["name"] for v in vendors],
        "brand_names": [b["name"] for b in brands],
        "machine_models": [m["name_model"] for m in machine_models],
        "probe_models": [p["name_model"] for p in probe_models],
        "recent_probe_models": recent_models,
        "printer_models": helpers.printer_models(db),
        "last_machine_id": last_machine["id"] if last_machine else None,
        "today": _today(),
        "saved_machine": saved_machine,
        "banner": banner,
    }


@main.route("/receive", methods=("GET", "POST"))
def receive():
    db = get_db()

    if request.method == "POST":
        form = _form_from_post()
        try:
            machine_pk, _printer = _save(db, form)
        except FormErrors as exc:
            db.rollback()
            for message in exc.errors:
                flash(message, "error")
        except ValueError as exc:
            db.rollback()
            flash(str(exc), "error")
        else:
            return redirect(url_for("main.receive", saved=machine_pk))
        return render_template("receive/index.html", **_page_data(db, form))

    if request.args.get("copy", "").isdigit():
        form = _form_from_machine(db, int(request.args.get("copy")))
    else:
        form = _form_defaults(db)

    if not form["machine_id"] and form["batch_code"]:
        row = db.execute(
            "SELECT id FROM batches WHERE code = ? COLLATE NOCASE", (form["batch_code"],)
        ).fetchone()
        if row:
            form["machine_id"] = _suggest_machine_id(db, row["id"])

    saved_machine = None
    banner = None
    saved_arg = request.args.get("saved") or request.args.get("resume")
    if saved_arg and saved_arg.isdigit():
        saved_machine = db.execute(
            """SELECT m.*, b.code AS batch_code FROM machines m
               JOIN batches b ON b.id = m.batch_id WHERE m.id = ?""",
            (int(saved_arg),),
        ).fetchone()
        if saved_machine:
            banner = "saved" if request.args.get("saved") else "ready"
            if banner == "ready" and not form["machine_id"]:
                form["machine_id"] = _suggest_machine_id(db, saved_machine["batch_id"])

    return render_template(
        "receive/index.html", **_page_data(db, form, saved_machine, banner)
    )
