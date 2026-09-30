from datetime import date

from flask import flash, redirect, render_template, request, url_for

from .database import get_db
from .routes import main
from . import helpers


def _today():
    return date.today().isoformat()


def _clean(value):
    return (value or "").strip()


def _load_machine(db, machine_id, must_be_active=True):
    query = "SELECT * FROM machines WHERE id = ?"
    if must_be_active:
        query += " AND is_archived = 0"
    machine = db.execute(query, (machine_id,)).fetchone()
    if machine is None:
        flash("Machine not found.", "error")
        return None
    return machine


def _set_row(db, table, pk, status, location):
    if table not in ("machines", "probes", "printers"):
        raise ValueError("unsupported table")
    db.execute(
        f"UPDATE {table} SET status = ?, current_location = ? WHERE id = ?",
        (status, location, pk),
    )


# ── Send machine + attached set ───────────────────────────────────────────────

def _partner_names(db, kind):
    table = "workshops" if kind == "workshop" else "dealers"
    return [r["name"] for r in db.execute(
        f"SELECT name FROM {table} WHERE is_archived = 0 ORDER BY name COLLATE NOCASE"
    ).fetchall()]


@main.route("/machines/<int:machine_id>/send", methods=("GET", "POST"))
def send_machine(machine_id):
    db = get_db()
    machine = _load_machine(db, machine_id)
    if machine is None:
        return redirect(url_for("main.machines"))
    block = helpers.send_block_reason(db, "machine", machine)
    if block:
        flash(block, "error")
        return redirect(url_for("main.machine_detail", machine_id=machine_id))

    dest_type = request.values.get("type") or "workshop"
    if dest_type not in ("workshop", "dealer"):
        dest_type = "workshop"
    items = helpers.machine_set(db, machine)

    rows = [{
        "key": "machine",
        "label": f"Machine {machine['machine_id']}",
        "detail": f"{machine['model']} · {machine['serial_number'] or 'no serial'}",
        "status": machine["status"],
        "enabled": True,
        "away": None,
    }]
    for probe in items["probes"]:
        away = helpers.out_destination(db, "probe", probe)
        rows.append({
            "key": f"probe:{probe['id']}",
            "label": f"Probe {probe['internal_id']}",
            "detail": f"{probe['model'] or 'probe'} · {probe['serial_number'] or 'no serial'}",
            "status": probe["status"],
            "enabled": away is None,
            "away": away,
        })
    for printer in items["printers"]:
        away = helpers.out_destination(db, "printer", printer)
        rows.append({
            "key": f"printer:{printer['id']}",
            "label": f"Printer {printer['internal_id']}",
            "detail": printer["name_model"] or "printer",
            "status": printer["status"],
            "enabled": away is None,
            "away": away,
        })

    form = {
        "destination_type": dest_type,
        "destination": (request.values.get("destination") or "").strip(),
        "movement_date": _today(),
        "reason": "",
        "notes": "",
        "selected": {r["key"] for r in rows if r["enabled"]},
    }

    if request.method == "POST":
        form["destination_type"] = request.form.get("destination_type") or dest_type
        if form["destination_type"] not in ("workshop", "dealer"):
            form["destination_type"] = "workshop"
        form["destination"] = _clean(request.form.get("destination"))
        form["movement_date"] = _clean(request.form.get("movement_date")) or _today()
        form["reason"] = _clean(request.form.get("reason"))
        form["notes"] = _clean(request.form.get("notes"))
        form["selected"] = set(request.form.getlist("item"))
        if f"machine:{machine['id']}" in form["selected"]:
            form["selected"].add("machine")

        errors = []
        if not form["destination"]:
            errors.append(
                "Select a workshop." if form["destination_type"] == "workshop"
                else "Select a dealer."
            )
        if not form["movement_date"]:
            errors.append("Movement date is required.")
        if not form["selected"]:
            errors.append("Select at least one item to send.")
        for row in rows:
            if row["key"] not in form["selected"]:
                continue
            if not row["enabled"]:
                errors.append(
                    f"{row['label']} is currently with {row['away']}. "
                    f"It cannot be sent to {form['destination'] or 'another location'}."
                )
        if errors:
            for message in errors:
                flash(message, "error")
        else:
            is_workshop = form["destination_type"] == "workshop"
            status = "With Workshop" if is_workshop else "With Dealer"
            location = "Workshop" if is_workshop else "Dealer"
            movement_type = "Send to Workshop" if is_workshop else "Send to Dealer"
            dest_id = (
                helpers.find_or_create_workshop(db, form["destination"])
                if is_workshop
                else helpers.find_or_create_dealer(db, form["destination"])
            )
            group = helpers.new_group_ref()
            reference = helpers.next_movement_reference(db)
            extra = {
                "workshop_id": dest_id if is_workshop else None,
                "dealer_id": dest_id if not is_workshop else None,
                "group_ref": group,
                "reference": reference,
                "reason": form["reason"] or None,
            }
            sent = []

            if "machine" in form["selected"]:
                _set_row(db, "machines", machine["id"], status, location)
                helpers.log_movement(
                    db, movement_type, form["movement_date"], machine_id=machine["id"],
                    from_location=machine["current_location"], to_location=form["destination"],
                    notes=form["notes"] or None, **extra,
                )
                sent.append(f"Machine {machine['machine_id']}")
            for probe in items["probes"]:
                if f"probe:{probe['id']}" in form["selected"]:
                    _set_row(db, "probes", probe["id"], status, location)
                    helpers.log_movement(
                        db, movement_type, form["movement_date"], probe_id=probe["id"],
                        from_location=probe["current_location"], to_location=form["destination"],
                        notes=form["notes"] or None, **extra,
                    )
                    sent.append(f"Probe {probe['internal_id']}")
            for printer in items["printers"]:
                if f"printer:{printer['id']}" in form["selected"]:
                    _set_row(db, "printers", printer["id"], status, location)
                    helpers.log_movement(
                        db, movement_type, form["movement_date"], printer_id=printer["id"],
                        from_location=printer["current_location"], to_location=form["destination"],
                        notes=form["notes"] or None, **extra,
                    )
                    sent.append(f"Printer {printer['internal_id']}")

            db.commit()
            left = sum(
                1 for r in rows
                if r["enabled"] and r["key"] not in form["selected"]
            )
            message = f"{len(sent)} item(s) sent to {form['destination']}."
            if left > 0:
                message += f" {left} item(s) stayed behind."
            message += f" Movement {reference} recorded."
            flash(message, "success")
            return redirect(url_for("main.machine_detail", machine_id=machine_id))

    return render_template(
        "machines/send.html",
        machine=machine,
        rows=rows,
        workshops=_partner_names(db, "workshop"),
        dealers=_partner_names(db, "dealer"),
        form=form,
        today=_today(),
    )


# ── Return machine + set from workshop / dealer ───────────────────────────────

def _out(status):
    return status in helpers.OUT_STATUSES


def _option(key, label, sub, out=True, note=None):
    return {"key": key, "label": label, "sub": sub, "out": out, "note": note}


@main.route("/machines/<int:machine_id>/return", methods=("GET", "POST"))
def return_machine(machine_id):
    db = get_db()
    machine = _load_machine(db, machine_id)
    if machine is None:
        return redirect(url_for("main.machines"))

    set_items = helpers.machine_set(db, machine)

    # Everything currently away, with its own destination.
    out_items = []
    if _out(machine["status"]):
        out_items.append({
            "kind": "machine", "pk": machine["id"], "row": machine,
            "key": f"machine:{machine['id']}",
            "label": f"Machine {machine['machine_id']}",
            "sub": f"{machine['serial_number'] or 'no serial'} · {machine['status']}",
            "dest": helpers.out_destination(db, "machine", machine),
        })
    for probe in set_items["probes"]:
        if _out(probe["status"]):
            out_items.append({
                "kind": "probe", "pk": probe["id"], "row": probe,
                "key": f"probe:{probe['id']}",
                "label": f"Probe {probe['internal_id']}",
                "sub": f"{probe['model'] or ''} · {probe['serial_number'] or 'no serial'} · {probe['status']}",
                "dest": helpers.out_destination(db, "probe", probe),
            })
    for printer in set_items["printers"]:
        if _out(printer["status"]):
            out_items.append({
                "kind": "printer", "pk": printer["id"], "row": printer,
                "key": f"printer:{printer['id']}",
                "label": f"Printer {printer['internal_id']}",
                "sub": f"{printer['name_model'] or ''} · {printer['status']}",
                "dest": helpers.out_destination(db, "printer", printer),
            })

    if not out_items:
        flash(f"Nothing is currently out with machine {machine['machine_id']}.", "error")
        return redirect(url_for("main.machine_detail", machine_id=machine_id))

    # The movement being returned = the send that put the first out item away.
    first = out_items[0]
    send_row = helpers.latest_send(db, first["kind"], first["pk"])
    group_ref = send_row["group_ref"] if send_row else None
    destination = (
        (send_row["to_location"] if send_row else None)
        or first["dest"]
        or machine["current_location"]
    )
    sent_date = send_row["movement_date"] if send_row else None

    eligible = [
        item for item in out_items
        if (item["dest"] or "").lower() == destination.lower()
    ]
    elsewhere = [
        item for item in out_items
        if (item["dest"] or "").lower() != destination.lower()
    ]
    eligible_keys = {item["key"] for item in eligible}

    # What was originally sent with that movement.
    originally_sent = []
    if group_ref:
        rows = db.execute(
            "SELECT * FROM movements WHERE group_ref = ? ORDER BY id", (group_ref,)
        ).fetchall()
        by_key = {item["key"]: item for item in out_items}
        for row in rows:
            if row["machine_id"]:
                current = db.execute(
                    "SELECT machine_id AS code, serial_number, status, id FROM machines WHERE id = ?",
                    (row["machine_id"],),
                ).fetchone()
                if current:
                    key = f"machine:{current['id']}"
                    item = by_key.get(key)
                    originally_sent.append(_option(
                        key, f"Machine {current['code']}",
                        f"{current['serial_number'] or 'no serial'} · {current['status']}",
                        out=key in eligible_keys,
                    ))
            elif row["probe_id"]:
                current = db.execute(
                    "SELECT internal_id, model, serial_number, status, id FROM probes WHERE id = ?",
                    (row["probe_id"],),
                ).fetchone()
                if current:
                    key = f"probe:{current['id']}"
                    originally_sent.append(_option(
                        key, f"Probe {current['internal_id']}",
                        f"{current['model'] or ''} · {current['serial_number'] or 'no serial'} · {current['status']}",
                        out=key in eligible_keys,
                    ))
            elif row["printer_id"]:
                current = db.execute(
                    "SELECT internal_id, name_model, status, id FROM printers WHERE id = ?",
                    (row["printer_id"],),
                ).fetchone()
                if current:
                    key = f"printer:{current['id']}"
                    originally_sent.append(_option(
                        key, f"Printer {current['internal_id']}",
                        f"{current['name_model'] or ''} · {current['status']}",
                        out=key in eligible_keys,
                    ))

    seen = {entry["key"] for entry in originally_sent}
    options = list(originally_sent)
    for item in eligible:
        if item["key"] not in seen:
            options.append(_option(
                item["key"], item["label"],
                f"{item['sub']} · joined later", out=True,
            ))

    form = {
        "movement_date": _today(),
        "reason": "",
        "notes": "",
        "selected": {o["key"] for o in options if o["out"]},
    }

    if request.method == "POST":
        form["movement_date"] = _clean(request.form.get("movement_date")) or _today()
        form["reason"] = _clean(request.form.get("reason"))
        form["notes"] = _clean(request.form.get("notes"))
        form["selected"] = set(request.form.getlist("item"))
        if "machine" in form["selected"]:
            form["selected"].discard("machine")
            form["selected"].add(f"machine:{machine['id']}")

        errors = []
        if not form["movement_date"]:
            errors.append("Return date is required.")
        if not form["selected"]:
            errors.append("Select at least one item to return.")
        out_by_key = {item["key"]: item for item in out_items}
        for key in form["selected"]:
            if key in eligible_keys:
                continue
            item = out_by_key.get(key)
            if item:
                block = helpers.return_block_reason(db, item["kind"], item["row"], destination)
                errors.append(block or f"{item['label']} cannot be returned from {destination}.")
            elif key == f"machine:{machine['id']}":
                block = helpers.return_block_reason(db, "machine", machine, destination)
                errors.append(block or f"Machine {machine['machine_id']} was not part of this movement.")
            else:
                errors.append("One of the selected items was not part of this movement.")
        if errors:
            for message in errors:
                flash(message, "error")
        else:
            group = helpers.new_group_ref()
            reference = helpers.next_movement_reference(db)
            extra = {
                "workshop_id": send_row["workshop_id"] if send_row else None,
                "dealer_id": send_row["dealer_id"] if send_row else None,
                "group_ref": group,
                "related_group_ref": group_ref,
                "reference": reference,
            }
            returned = 0
            for item in eligible:
                if item["key"] not in form["selected"]:
                    continue
                kind, pk = item["kind"], item["pk"]
                if kind == "machine":
                    status = "In Stock"
                else:
                    status = "With Machine" if item["row"]["assigned_machine_id"] else "Available"
                kwargs = (
                    {"machine_id": pk} if kind == "machine"
                    else {"probe_id": pk} if kind == "probe"
                    else {"printer_id": pk}
                )
                _set_row(db, helpers.KIND_INFO[kind][0], pk, status, "Company")
                helpers.log_movement(
                    db, "Return", form["movement_date"],
                    from_location=destination, to_location="Company",
                    reason=form["reason"] or None, notes=form["notes"] or None,
                    **extra, **kwargs,
                )
                returned += 1
            db.commit()
            missing = len(eligible) - returned
            message = f"{returned} item{'' if returned == 1 else 's'} returned to the company."
            if missing > 0:
                message += f" {missing} item{'' if missing == 1 else 's'} ha{'s' if missing == 1 else 've'} not been returned."
                flash(message, "error")
            else:
                flash(message, "success")
            return redirect(url_for("main.machine_detail", machine_id=machine_id))

    return render_template(
        "machines/return.html",
        machine=machine,
        options=options,
        elsewhere=elsewhere,
        originally_sent=originally_sent,
        destination=destination,
        sent_date=sent_date,
        movement_ref=send_row["reference"] if send_row else None,
        form=form,
        today=_today(),
    )


# ── Sales ─────────────────────────────────────────────────────────────────────

def _sale_context(title, subtitle, action_url, back_url, items):
    return {
        "title": title,
        "subtitle": subtitle,
        "action_url": action_url,
        "back_url": back_url,
        "lines": items,
    }


def _customers(db):
    return db.execute(
        "SELECT id, name, phone FROM customers WHERE is_archived = 0 ORDER BY name COLLATE NOCASE"
    ).fetchall()


def _parse_sale_items(form_items, fallback_machine_id=None):
    items = []
    for value in form_items:
        kind, _, pk = value.partition(":")
        if kind == "machine" and not pk and fallback_machine_id:
            items.append({"kind": "machine", "id": fallback_machine_id})
            continue
        if kind in ("machine", "probe", "printer") and pk.isdigit():
            items.append({"kind": kind, "id": int(pk)})
    return items


def _render_sale(template, ctx, form, error=None):
    db = get_db()
    if error:
        flash(error, "error")
    return render_template(template, ctx=ctx, form=form, customers=_customers(db), today=_today())


def _handle_sale_post(template, ctx, form, empty_message, fallback_machine_id=None):
    db = get_db()
    form["sale_date"] = _clean(request.form.get("sale_date")) or _today()
    form["customer_name"] = _clean(request.form.get("customer_name"))
    form["price"] = _clean(request.form.get("price"))
    form["invoice_reference"] = _clean(request.form.get("invoice_reference"))
    form["notes"] = _clean(request.form.get("notes"))
    form["selected"] = set(request.form.getlist("item"))
    chosen = _parse_sale_items(form["selected"], fallback_machine_id)
    if not chosen:
        return _render_sale(template, ctx, form, empty_message)
    if not form["customer_name"]:
        return _render_sale(template, ctx, form, "Customer is required.")
    price = None
    if form["price"]:
        try:
            price = float(form["price"])
        except ValueError:
            return _render_sale(template, ctx, form, "Price must be a number.")
    try:
        sale_id = helpers.create_sale(
            db, chosen, form["customer_name"], form["sale_date"], price,
            form["invoice_reference"], form["notes"],
        )
        db.commit()
    except ValueError as exc:
        db.rollback()
        return _render_sale(template, ctx, form, str(exc))
    flash(f"Sale #{sale_id} recorded.", "success")
    return redirect(url_for("main.sale_detail", sale_id=sale_id))


@main.route("/machines/<int:machine_id>/sell", methods=("GET", "POST"))
def sell_machine(machine_id):
    db = get_db()
    machine = _load_machine(db, machine_id)
    if machine is None:
        return redirect(url_for("main.machines"))
    if machine["status"] == "Sold":
        flash(f"Machine {machine['machine_id']} is already sold.", "error")
        return redirect(url_for("main.machine_detail", machine_id=machine_id))

    items = helpers.machine_set(db, machine)
    rows = [{
        "value": f"machine:{machine['id']}",
        "label": f"Machine {machine['machine_id']}",
        "sub": f"{machine['model']} · {machine['serial_number'] or 'no serial'}",
        "checked": True,
        "locked": True,
    }]
    for probe in items["probes"]:
        rows.append({
            "value": f"probe:{probe['id']}",
            "label": f"Probe {probe['internal_id']}",
            "sub": f"{probe['model'] or ''} · {probe['serial_number'] or 'no serial'}".strip(" ·"),
            "checked": True,
            "locked": False,
        })
    for printer in items["printers"]:
        rows.append({
            "value": f"printer:{printer['id']}",
            "label": f"Printer {printer['internal_id']}",
            "sub": printer["name_model"] or "",
            "checked": True,
            "locked": False,
        })
    ctx = _sale_context(
        f"Sell Machine {machine['machine_id']}",
        "Everything attached to the machine is selected by default. Uncheck anything that stays.",
        url_for("main.sell_machine", machine_id=machine_id),
        url_for("main.machine_detail", machine_id=machine_id),
        rows,
    )
    form = {"sale_date": _today(), "customer_name": "", "price": "", "invoice_reference": "", "notes": "",
            "selected": {r["value"] for r in rows}}

    if request.method == "POST":
        return _handle_sale_post(
            "sales/sell.html", ctx, form, "Select at least one item to sell.",
            fallback_machine_id=machine["id"],
        )

    return render_template(
        "sales/sell.html", ctx=ctx, form=form, customers=_customers(db), today=_today()
    )


@main.route("/probes/<int:probe_id>/sell", methods=("GET", "POST"))
def sell_probe(probe_id):
    db = get_db()
    probe = db.execute(
        "SELECT * FROM probes WHERE id = ? AND is_archived = 0", (probe_id,)
    ).fetchone()
    if probe is None:
        flash("Probe not found.", "error")
        return redirect(url_for("main.probes"))
    if probe["status"] == "Sold":
        flash(f"Probe {probe['internal_id']} is already sold.", "error")
        return redirect(url_for("main.probe_detail", probe_id=probe_id))

    machine = None
    if probe["assigned_machine_id"]:
        machine = db.execute(
            "SELECT machine_id FROM machines WHERE id = ?", (probe["assigned_machine_id"],)
        ).fetchone()
    where = f"Machine {machine['machine_id']}" if machine else probe["current_location"]
    rows = [{
        "value": f"probe:{probe['id']}",
        "label": f"Probe {probe['internal_id']}",
        "sub": f"{probe['model'] or ''} · {probe['serial_number'] or 'no serial'} · currently {where}".strip(" ·"),
        "checked": True,
        "locked": True,
    }]
    ctx = _sale_context(
        f"Sell Probe {probe['internal_id']}",
        "Only this probe is sold. Its machine stays in inventory and stops showing it as attached.",
        url_for("main.sell_probe", probe_id=probe_id),
        url_for("main.probe_detail", probe_id=probe_id),
        rows,
    )
    form = {"sale_date": _today(), "customer_name": "", "price": "", "invoice_reference": "", "notes": "",
            "selected": {r["value"] for r in rows}}

    if request.method == "POST":
        return _handle_sale_post("sales/sell.html", ctx, form, "Select the probe to sell.")

    return render_template(
        "sales/sell.html", ctx=ctx, form=form, customers=_customers(db), today=_today()
    )


@main.route("/printers/<int:printer_id>/sell", methods=("GET", "POST"))
def sell_printer(printer_id):
    db = get_db()
    printer = db.execute(
        "SELECT * FROM printers WHERE id = ? AND is_archived = 0", (printer_id,)
    ).fetchone()
    if printer is None:
        flash("Printer not found.", "error")
        return redirect(url_for("main.printers"))
    if printer["status"] == "Sold":
        flash(f"Printer {printer['internal_id']} is already sold.", "error")
        return redirect(url_for("main.printers"))

    machine = None
    if printer["assigned_machine_id"]:
        machine = db.execute(
            "SELECT machine_id FROM machines WHERE id = ?", (printer["assigned_machine_id"],)
        ).fetchone()
    where = f"Machine {machine['machine_id']}" if machine else printer["current_location"]
    rows = [{
        "value": f"printer:{printer['id']}",
        "label": f"Printer {printer['internal_id']}",
        "sub": f"{printer['name_model'] or ''} · currently {where}".strip(" ·"),
        "checked": True,
        "locked": True,
    }]
    ctx = _sale_context(
        f"Sell Printer {printer['internal_id']}",
        "Only this printer unit is sold. Any machine it was attached to stays in inventory.",
        url_for("main.sell_printer", printer_id=printer_id),
        url_for("main.printers"),
        rows,
    )
    form = {"sale_date": _today(), "customer_name": "", "price": "", "invoice_reference": "", "notes": "",
            "selected": {r["value"] for r in rows}}

    if request.method == "POST":
        return _handle_sale_post("sales/sell.html", ctx, form, "Select the printer to sell.")

    return render_template(
        "sales/sell.html", ctx=ctx, form=form, customers=_customers(db), today=_today()
    )


# ── Probe detail ──────────────────────────────────────────────────────────────

@main.get("/probes/<int:probe_id>")
def probe_detail(probe_id):
    db = get_db()
    probe = db.execute(
        """SELECT p.*, b.name AS brand_name, c.name_model AS catalog_model,
                  m.machine_id AS assigned_machine_code, m.id AS assigned_machine_pk
           FROM probes p
           LEFT JOIN brands b ON b.id = p.brand_id
           LEFT JOIN catalog_products c ON c.id = p.catalog_product_id
           LEFT JOIN machines m ON m.id = p.assigned_machine_id
           WHERE p.id = ? AND p.is_archived = 0""",
        (probe_id,),
    ).fetchone()
    if probe is None:
        flash("Probe not found.", "error")
        return redirect(url_for("main.probes"))
    events = helpers.movement_events(db, "probe", probe_id)
    out_dest = helpers.out_destination(db, "probe", probe)
    sale = db.execute(
        """SELECT s.id, s.sale_date, c.name AS customer_name FROM sale_items si
           JOIN sales s ON s.id = si.sale_id
           LEFT JOIN customers c ON c.id = s.customer_id
           WHERE si.item_type = 'probe' AND si.probe_id = ?
           ORDER BY si.sale_id DESC LIMIT 1""",
        (probe_id,),
    ).fetchone()
    return render_template(
        "probes/detail.html", probe=probe, events=events, out_dest=out_dest, sale=sale
    )
