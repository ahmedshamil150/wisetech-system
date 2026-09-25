from datetime import date

from flask import flash, redirect, render_template, request, url_for

from .database import get_db
from .routes import main
from . import helpers


def _today():
    return date.today().isoformat()


def _clean(value):
    return (value or "").strip()


def _partner_names(db, kind):
    table = "workshops" if kind == "workshop" else "dealers"
    rows = db.execute(
        f"SELECT name FROM {table} WHERE is_archived = 0 ORDER BY name COLLATE NOCASE"
    ).fetchall()
    return [r["name"] for r in rows]


# ═══════════════════════════════════════════════════════════════════════════
# Movement centre (hub + pickers)
# ═══════════════════════════════════════════════════════════════════════════

@main.get("/movements")
def movement_center():
    db = get_db()
    counts = {
        "at_workshop": db.execute(
            "SELECT COUNT(*) FROM machines WHERE is_archived = 0 AND status = 'With Workshop'"
        ).fetchone()[0],
        "at_dealer": db.execute(
            "SELECT COUNT(*) FROM machines WHERE is_archived = 0 AND status = 'With Dealer'"
        ).fetchone()[0],
        "away": len(helpers.away_items(db)),
        "workshops": db.execute(
            "SELECT COUNT(*) FROM workshops WHERE is_archived = 0"
        ).fetchone()[0],
        "dealers": db.execute(
            "SELECT COUNT(*) FROM dealers WHERE is_archived = 0"
        ).fetchone()[0],
    }
    return render_template("movements/index.html", counts=counts)


def _pick(kind):
    """Machine/probe/printer picker used by the movement centre."""
    db = get_db()
    dest_type = request.args.get("type") or "workshop"
    if dest_type not in ("workshop", "dealer"):
        dest_type = "workshop"
    q = (request.args.get("q") or "").strip()
    ctx = {
        "dest_type": dest_type,
        "q": q,
        "rows": [],
        "kind": kind,
    }

    if kind == "send-machine":
        ctx.update({
            "title": "Send to Workshop" if dest_type == "workshop" else "Send to Dealer",
            "eyebrow": "Movement · select a machine",
            "subtitle": "Pick a machine at the company. Its attached probes and printer travel with it by default.",
            "empty": "No machines at the company match your search.",
        })
        query = """SELECT m.*, b.code AS batch_code, bd.name AS brand_name
                   FROM machines m
                   JOIN batches b ON b.id = m.batch_id
                   LEFT JOIN brands bd ON bd.id = m.brand_id
                   WHERE m.is_archived = 0 AND m.status = 'In Stock'"""
        params = []
        if q:
            query += " AND (m.machine_id LIKE ? OR m.model LIKE ? OR m.serial_number LIKE ? OR bd.name LIKE ?)"
            params.extend([f"%{q}%"] * 4)
        query += " ORDER BY m.machine_id COLLATE NOCASE LIMIT 60"
        for m in db.execute(query, params).fetchall():
            ctx["rows"].append({
                "label": f"Machine {m['machine_id']}",
                "detail": f"{m['brand_name'] or ''} {m['model']} · {m['serial_number'] or 'no serial'}".strip(" ·"),
                "status": m["status"],
                "where": m["current_location"],
                "url": url_for("main.send_machine", machine_id=m["id"], type=dest_type),
                "action": "Select",
            })
    elif kind == "return-machine":
        status = "With Workshop" if dest_type == "workshop" else "With Dealer"
        ctx.update({
            "title": "Return from Workshop" if dest_type == "workshop" else "Return from Dealer",
            "eyebrow": "Movement · select a machine",
            "subtitle": "Pick a machine currently away. The original movement is shown before anything returns.",
            "empty": f"No machines are currently at a {dest_type}.",
        })
        query = """SELECT m.*, b.code AS batch_code, bd.name AS brand_name
                   FROM machines m
                   JOIN batches b ON b.id = m.batch_id
                   LEFT JOIN brands bd ON bd.id = m.brand_id
                   WHERE m.is_archived = 0 AND m.status = ?"""
        params = [status]
        if q:
            query += " AND (m.machine_id LIKE ? OR m.model LIKE ? OR m.serial_number LIKE ? OR bd.name LIKE ?)"
            params.extend([f"%{q}%"] * 4)
        query += " ORDER BY m.machine_id COLLATE NOCASE LIMIT 60"
        for m in db.execute(query, params).fetchall():
            ctx["rows"].append({
                "label": f"Machine {m['machine_id']}",
                "detail": f"{m['brand_name'] or ''} {m['model']} · {m['serial_number'] or 'no serial'}".strip(" ·"),
                "status": m["status"],
                "where": helpers.out_destination(db, "machine", m) or m["current_location"],
                "url": url_for("main.return_machine", machine_id=m["id"]),
                "action": "Return",
            })
    elif kind == "send-probe":
        ctx.update({
            "title": "Send Probe",
            "eyebrow": "Movement · individual probe",
            "subtitle": "Pick a probe that is at the company. Its machine (if any) stays where it is.",
            "empty": "No probes at the company match your search.",
        })
        query = """SELECT p.*, m.machine_id AS machine_code
                   FROM probes p
                   LEFT JOIN machines m ON m.id = p.assigned_machine_id
                   WHERE p.is_archived = 0 AND p.status IN ('Available', 'With Machine')"""
        params = []
        if q:
            query += " AND (p.internal_id LIKE ? OR p.model LIKE ? OR p.serial_number LIKE ?)"
            params.extend([f"%{q}%"] * 3)
        query += " ORDER BY p.internal_id LIMIT 60"
        for p in db.execute(query, params).fetchall():
            ctx["rows"].append({
                "label": f"Probe {p['internal_id']}",
                "detail": f"{p['model'] or 'probe'} · {p['serial_number'] or 'no serial'}" +
                          (f" · attached to {p['machine_code']}" if p["machine_code"] else ""),
                "status": p["status"],
                "where": p["current_location"],
                "url": url_for("main.send_probe", probe_id=p["id"]),
                "action": "Select",
            })
    elif kind == "send-printer":
        ctx.update({
            "title": "Send Printer",
            "eyebrow": "Movement · individual printer",
            "subtitle": "Pick a printer unit that is at the company.",
            "empty": "No printer units at the company match your search.",
        })
        query = """SELECT p.*, m.machine_id AS machine_code
                   FROM printers p
                   LEFT JOIN machines m ON m.id = p.assigned_machine_id
                   WHERE p.is_archived = 0 AND p.status IN ('Available', 'With Machine')"""
        params = []
        if q:
            query += " AND (p.internal_id LIKE ? OR p.name_model LIKE ? OR p.serial_number LIKE ?)"
            params.extend([f"%{q}%"] * 3)
        query += " ORDER BY p.internal_id LIMIT 60"
        for p in db.execute(query, params).fetchall():
            ctx["rows"].append({
                "label": f"Printer {p['internal_id']}",
                "detail": f"{p['name_model'] or 'printer'}" +
                          (f" · with {p['machine_code']}" if p["machine_code"] else ""),
                "status": p["status"],
                "where": p["current_location"],
                "url": url_for("main.send_printer", printer_id=p["id"]),
                "action": "Select",
            })
    elif kind == "sell":
        ctx.update({
            "title": "Sell to Customer",
            "eyebrow": "Sales · select an item",
            "subtitle": "Pick an item that is at the company. The next screen records the customer, date and price.",
            "empty": "No items at the company match your search.",
            "dest_type": None,
        })
        machine_sql = """SELECT m.*, bd.name AS brand_name
                         FROM machines m
                         LEFT JOIN brands bd ON bd.id = m.brand_id
                         WHERE m.is_archived = 0 AND m.status = 'In Stock'"""
        probe_sql = """SELECT p.* FROM probes p
                       WHERE p.is_archived = 0 AND p.status IN ('Available', 'With Machine')"""
        printer_sql = """SELECT p.* FROM printers p
                         WHERE p.is_archived = 0 AND p.status IN ('Available', 'With Machine')"""
        params = []
        if q:
            machine_sql += """ AND (m.machine_id LIKE ? OR m.model LIKE ? OR m.serial_number LIKE ?
                                    OR bd.name LIKE ?)"""
            probe_sql += " AND (p.internal_id LIKE ? OR p.model LIKE ? OR p.serial_number LIKE ?)"
            printer_sql += " AND (p.internal_id LIKE ? OR p.name_model LIKE ? OR p.serial_number LIKE ?)"
            params = [f"%{q}%"] * 4
        for m in db.execute(machine_sql + " ORDER BY m.machine_id COLLATE NOCASE LIMIT 40",
                            params[:4] if q else []).fetchall():
            ctx["rows"].append({
                "label": f"Machine {m['machine_id']}",
                "detail": f"{m['brand_name'] or ''} {m['model']} · {m['serial_number'] or 'no serial'}".strip(" ·"),
                "status": m["status"],
                "where": m["current_location"],
                "url": url_for("main.sell_machine", machine_id=m["id"]),
                "action": "Sell",
            })
        for p in db.execute(probe_sql + " ORDER BY p.internal_id LIMIT 25",
                            params[:3] if q else []).fetchall():
            ctx["rows"].append({
                "label": f"Probe {p['internal_id']}",
                "detail": f"{p['model'] or 'probe'} · {p['serial_number'] or 'no serial'}",
                "status": p["status"],
                "where": p["current_location"],
                "url": url_for("main.sell_probe", probe_id=p["id"]),
                "action": "Sell",
            })
        for p in db.execute(printer_sql + " ORDER BY p.internal_id LIMIT 15",
                            params[:3] if q else []).fetchall():
            ctx["rows"].append({
                "label": f"Printer {p['internal_id']}",
                "detail": p["name_model"],
                "status": p["status"],
                "where": p["current_location"],
                "url": url_for("main.sell_printer", printer_id=p["id"]),
                "action": "Sell",
            })
    return render_template("movements/pick.html", **ctx)


@main.get("/movements/send")
def pick_send():
    return _pick("send-machine")


@main.get("/movements/return")
def pick_return():
    return _pick("return-machine")


@main.get("/movements/send-probe")
def pick_send_probe():
    return _pick("send-probe")


@main.get("/movements/send-printer")
def pick_send_printer():
    return _pick("send-printer")


@main.get("/movements/sell")
def pick_sell():
    return _pick("sell")


# ═══════════════════════════════════════════════════════════════════════════
# Individual probe movements
# ═══════════════════════════════════════════════════════════════════════════

def _single_send(kind, pk):
    db = get_db()
    item = helpers.load_item(db, kind, pk, active_only=True)
    if item is None:
        flash(f"{kind.capitalize()} not found.", "error")
        return redirect(url_for(f"main.{kind}s"))
    label = helpers.item_label(kind, item)
    detail = helpers.item_detail(kind, item)
    back = url_for(f"main.{kind}_detail", **{f"{kind}_id": pk})

    block = helpers.send_block_reason(db, kind, item)
    if block:
        flash(block, "error")
        return redirect(back)

    dest_type = request.values.get("type") or "workshop"
    if dest_type not in ("workshop", "dealer"):
        dest_type = "workshop"
    form = {
        "destination_type": dest_type,
        "destination": (request.values.get("destination") or "").strip(),
        "movement_date": _today(),
        "reason": "",
        "notes": "",
    }

    if request.method == "POST":
        form["destination_type"] = request.form.get("destination_type") or dest_type
        if form["destination_type"] not in ("workshop", "dealer"):
            form["destination_type"] = "workshop"
        form["destination"] = _clean(request.form.get("destination"))
        form["movement_date"] = _clean(request.form.get("movement_date")) or _today()
        form["reason"] = _clean(request.form.get("reason"))
        form["notes"] = _clean(request.form.get("notes"))

        errors = []
        if not form["destination"]:
            errors.append(
                "Select a workshop." if form["destination_type"] == "workshop"
                else "Select a dealer."
            )
        if not form["movement_date"]:
            errors.append("Movement date is required.")
        block = helpers.send_block_reason(db, kind, item, form["destination"])
        if block:
            errors.append(block)
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
            kwargs = {}
            if kind == "probe":
                kwargs["probe_id"] = pk
            else:
                kwargs["printer_id"] = pk
            helpers.log_movement(
                db, movement_type, form["movement_date"],
                from_location=item["current_location"], to_location=form["destination"],
                workshop_id=dest_id if is_workshop else None,
                dealer_id=dest_id if not is_workshop else None,
                reason=form["reason"] or None, notes=form["notes"] or None,
                group_ref=group, reference=reference, **kwargs,
            )
            db.execute(
                f"UPDATE {helpers.KIND_INFO[kind][0]} SET status = ?, current_location = ? WHERE id = ?",
                (status, location, pk),
            )
            db.commit()
            flash(
                f"{reference}: {label} sent to {form['destination']}.",
                "success",
            )
            return redirect(back)

    return render_template(
        "movements/send_item.html",
        kind=kind,
        item=item,
        label=label,
        detail=detail,
        form=form,
        workshops=_partner_names(db, "workshop"),
        dealers=_partner_names(db, "dealer"),
        back_url=back,
        today=_today(),
    )


def _single_return(kind, pk):
    db = get_db()
    item = helpers.load_item(db, kind, pk, active_only=True)
    if item is None:
        flash(f"{kind.capitalize()} not found.", "error")
        return redirect(url_for(f"main.{kind}s"))
    label = helpers.item_label(kind, item)
    back = url_for(f"main.{kind}_detail", **{f"{kind}_id": pk})

    block = helpers.return_block_reason(db, kind, item)
    if block:
        flash(block, "error")
        return redirect(back)

    origin = helpers.out_destination(db, kind, item) or item["current_location"]
    send = helpers.latest_send(db, kind, pk)

    form = {"movement_date": _today(), "reason": "", "notes": ""}
    if request.method == "POST":
        form["movement_date"] = _clean(request.form.get("movement_date")) or _today()
        form["reason"] = _clean(request.form.get("reason"))
        form["notes"] = _clean(request.form.get("notes"))
        errors = []
        if not form["movement_date"]:
            errors.append("Return date is required.")
        block = helpers.return_block_reason(db, kind, item, origin)
        if block:
            errors.append(block)
        if errors:
            for message in errors:
                flash(message, "error")
        else:
            status = "Available"
            if kind == "probe" and item["assigned_machine_id"]:
                status = "With Machine"
            elif kind == "printer" and item["assigned_machine_id"]:
                status = "With Machine"
            kwargs = {}
            if kind == "probe":
                kwargs["probe_id"] = pk
            else:
                kwargs["printer_id"] = pk
            group = helpers.new_group_ref()
            reference = helpers.next_movement_reference(db)
            helpers.log_movement(
                db, "Return", form["movement_date"],
                from_location=origin, to_location="Company",
                workshop_id=send["workshop_id"] if send else None,
                dealer_id=send["dealer_id"] if send else None,
                reason=form["reason"] or None, notes=form["notes"] or None,
                group_ref=group, related_group_ref=send["group_ref"] if send else None,
                reference=reference, **kwargs,
            )
            db.execute(
                f"UPDATE {helpers.KIND_INFO[kind][0]} SET status = ?, current_location = 'Company' WHERE id = ?",
                (status, pk),
            )
            db.commit()
            flash(f"{reference}: {label} returned to the company.", "success")
            return redirect(back)

    return render_template(
        "movements/return_item.html",
        kind=kind,
        item=item,
        label=label,
        detail=helpers.item_detail(kind, item),
        form=form,
        origin=origin,
        sent_date=send["movement_date"] if send else None,
        reference=send["reference"] if send else None,
        back_url=back,
        today=_today(),
    )


@main.route("/probes/<int:probe_id>/send", methods=("GET", "POST"))
def send_probe(probe_id):
    return _single_send("probe", probe_id)


@main.route("/probes/<int:probe_id>/return", methods=("GET", "POST"))
def return_probe(probe_id):
    return _single_return("probe", probe_id)


# ═══════════════════════════════════════════════════════════════════════════
# Individual printer movements
# ═══════════════════════════════════════════════════════════════════════════

@main.route("/printers/<int:printer_id>/send", methods=("GET", "POST"))
def send_printer(printer_id):
    return _single_send("printer", printer_id)


@main.route("/printers/<int:printer_id>/return", methods=("GET", "POST"))
def return_printer(printer_id):
    return _single_return("printer", printer_id)


# ═══════════════════════════════════════════════════════════════════════════
# Inventory away from the company
# ═══════════════════════════════════════════════════════════════════════════

@main.get("/away")
def away():
    db = get_db()
    item_type = request.args.get("type") or ""
    workshop = (request.args.get("workshop") or "").strip()
    dealer = (request.args.get("dealer") or "").strip()
    search = (request.args.get("search") or "").strip()
    date_from = (request.args.get("date_from") or "").strip()

    destination = workshop or dealer or None
    items = helpers.away_items(db, destination=destination)

    if item_type in ("machine", "probe", "printer"):
        items = [i for i in items if i["kind"] == item_type]
    if search:
        needle = search.lower()
        items = [
            i for i in items
            if needle in (i["label"] or "").lower()
            or needle in (i["detail"] or "").lower()
            or needle in (i["destination"] or "").lower()
        ]
    if date_from:
        items = [i for i in items if i["sent_date"] and i["sent_date"] >= date_from]

    for entry in items:
        if entry["kind"] == "machine":
            entry["url"] = url_for("main.machine_detail", machine_id=entry["id"])
            entry["return_url"] = url_for("main.return_machine", machine_id=entry["id"])
        elif entry["kind"] == "probe":
            entry["url"] = url_for("main.probe_detail", probe_id=entry["id"])
            entry["return_url"] = url_for("main.return_probe", probe_id=entry["id"])
        else:
            entry["url"] = url_for("main.printer_detail", printer_id=entry["id"])
            entry["return_url"] = url_for("main.return_printer", printer_id=entry["id"])

    return render_template(
        "movements/away.html",
        items=items,
        workshops=_partner_names(db, "workshop"),
        dealers=_partner_names(db, "dealer"),
        filters={"type": item_type, "workshop": workshop, "dealer": dealer,
                 "search": search, "date_from": date_from},
        total=len(items),
    )


# ═══════════════════════════════════════════════════════════════════════════
# Reversal (correction) — history is never deleted
# ═══════════════════════════════════════════════════════════════════════════

def _redirect_back():
    from urllib.parse import urlparse

    target = request.form.get("next") or request.referrer or ""
    parsed = urlparse(target)
    if parsed.scheme or parsed.netloc:
        if parsed.netloc and parsed.netloc != request.host:
            target = ""
        else:
            target = parsed.path + (f"?{parsed.query}" if parsed.query else "")
    if not target or not target.startswith("/") or target.startswith("//"):
        target = url_for("main.dashboard")
    return redirect(target)


@main.post("/movements/<group_ref>/reverse")
def reverse_movement(group_ref):
    db = get_db()
    rows = db.execute(
        "SELECT * FROM movements WHERE group_ref = ?", (group_ref,)
    ).fetchall()
    if not rows:
        flash("Movement not found.", "error")
        return _redirect_back()
    original_ref = rows[0]["reference"]
    name = original_ref or "this movement"

    if any(row["reversed_by_ref"] for row in rows):
        flash(f"Movement {name} has already been reversed.", "error")
        return _redirect_back()

    movement_type = rows[0]["movement_type"]
    if movement_type not in helpers.REVERSIBLE_TYPES:
        flash(
            f"Movement {name} ({movement_type}) cannot be reversed. "
            "Only send and return movements can be corrected.",
            "error",
        )
        return _redirect_back()

    errors = []
    plan = []  # (kind, item_row, new_status, new_location)

    for row in rows:
        if row["machine_id"]:
            kind, pk = "machine", row["machine_id"]
        elif row["probe_id"]:
            kind, pk = "probe", row["probe_id"]
        elif row["printer_id"]:
            kind, pk = "printer", row["printer_id"]
        else:
            continue
        item = helpers.load_item(db, kind, pk)
        if item is None:
            errors.append("An item from this movement no longer exists.")
            continue
        label = helpers.item_label(kind, item)
        if item["status"] in ("Sold", "Archived"):
            errors.append(
                f"{label} is {item['status'].lower()} after this movement, "
                f"so {name} can no longer be reversed."
            )
            continue

        if movement_type in helpers.SEND_TYPES:
            if item["status"] not in helpers.OUT_STATUSES:
                errors.append(
                    f"{label} is no longer with {row['to_location']}, "
                    f"so {name} can no longer be reversed."
                )
                continue
            where = helpers.out_destination(db, kind, item) or item["current_location"]
            if row["to_location"] and where and where.lower() != row["to_location"].lower():
                errors.append(
                    f"{label} is now with {where}, so {name} can no longer be reversed."
                )
                continue
            if kind == "machine":
                plan.append((kind, item, "In Stock", "Company"))
            elif item["assigned_machine_id"]:
                plan.append((kind, item, "With Machine", "Company"))
            else:
                plan.append((kind, item, "Available", "Company"))
        else:  # Return
            if item["status"] in helpers.OUT_STATUSES:
                errors.append(
                    f"{label} is away again, so {name} can no longer be reversed."
                )
                continue
            workshop = row["workshop_id"] is not None
            dealer = row["dealer_id"] is not None
            if not workshop and not dealer and row["related_group_ref"]:
                origin_row = db.execute(
                    """SELECT workshop_id, dealer_id FROM movements
                       WHERE group_ref = ? AND workshop_id IS NOT NULL
                          OR group_ref = ? AND dealer_id IS NOT NULL
                       LIMIT 1""",
                    (row["related_group_ref"], row["related_group_ref"]),
                ).fetchone()
                if origin_row:
                    workshop = origin_row["workshop_id"] is not None
                    dealer = origin_row["dealer_id"] is not None
            if workshop:
                plan.append((kind, item, "With Workshop", "Workshop"))
            else:
                plan.append((kind, item, "With Dealer", "Dealer"))

    if errors:
        for message in errors:
            flash(message, "error")
        return _redirect_back()

    if not plan:
        flash(f"Movement {name} has nothing left to reverse.", "error")
        return _redirect_back()

    today = _today()
    group = helpers.new_group_ref()
    reference = helpers.next_movement_reference(db)
    for kind, item, new_status, new_location in plan:
        pk = item["id"]
        kwargs = {"machine_id": pk} if kind == "machine" else (
            {"probe_id": pk} if kind == "probe" else {"printer_id": pk}
        )
        from_location = item["current_location"]
        if item["status"] in helpers.OUT_STATUSES:
            from_location = helpers.out_destination(db, kind, item) or from_location
        helpers.log_movement(
            db, "Reversal", today,
            from_location=from_location, to_location=new_location,
            notes=original_ref or group_ref,
            group_ref=group, related_group_ref=group_ref, reference=reference,
            **kwargs,
        )
        db.execute(
            f"UPDATE {helpers.KIND_INFO[kind][0]} SET status = ?, current_location = ? WHERE id = ?",
            (new_status, new_location, pk),
        )
    db.execute(
        "UPDATE movements SET reversed_by_ref = ? WHERE group_ref = ?",
        (group, group_ref),
    )
    db.commit()
    flash(
        f"Movement {name} was reversed. Correction {reference} was recorded — "
        "the original history stays visible.",
        "success",
    )
    return _redirect_back()
