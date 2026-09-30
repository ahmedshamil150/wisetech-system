from flask import flash, jsonify, redirect, render_template, request, url_for

from .database import get_db
from .routes import main
from . import helpers


PARTNERS = {
    "workshop": {
        "table": "workshops",
        "label": "Workshop",
        "plural": "Workshops",
        "endpoint": "workshops",
        "nav": "Operations",
    },
    "dealer": {
        "table": "dealers",
        "label": "Dealer",
        "plural": "Dealers",
        "endpoint": "dealers",
        "nav": "Operations",
    },
}


def _clean(value):
    return (value or "").strip()


def _form_data():
    return {
        "name": _clean(request.form.get("name")),
        "contact": _clean(request.form.get("contact")),
        "phone": _clean(request.form.get("phone")),
        "address": _clean(request.form.get("address")),
        "city": _clean(request.form.get("city")),
        "notes": _clean(request.form.get("notes")),
        "is_active": request.form.get("is_active", "1") == "1",
    }


def _partner_list(kind, cfg):
    db = get_db()
    search = (request.args.get("search") or "").strip()
    show = request.args.get("show") or "active"
    query = f"SELECT * FROM {cfg['table']}"
    params = []
    clauses = []
    if search:
        clauses.append("(name LIKE ? OR contact LIKE ? OR phone LIKE ? OR city LIKE ? OR address LIKE ?)")
        pattern = f"%{search}%"
        params.extend([pattern] * 5)
    if show == "active":
        clauses.append("is_archived = 0")
    elif show == "inactive":
        clauses.append("is_archived = 1")
    if clauses:
        query += " WHERE " + " AND ".join(clauses)
    query += " ORDER BY name COLLATE NOCASE"
    items = db.execute(query, params).fetchall()
    counts = dict(db.execute(
        f"SELECT is_archived, COUNT(*) FROM {cfg['table']} GROUP BY is_archived"
    ).fetchall())
    away = helpers.away_items(db)
    here = {}
    for entry in away:
        here.setdefault(entry["destination"], 0)
        here[entry["destination"]] += 1
    return render_template(
        "partners/list.html",
        kind=kind,
        cfg=cfg,
        items=items,
        search=search,
        show=show,
        counts=counts,
        current_counts=here,
    )


def _partner_form(kind, cfg, row=None, next_url=None, creating=False):
    form = dict(row) if row else {
        "name": "", "contact": "", "phone": "", "address": "",
        "city": "", "notes": "", "is_archived": 0,
    }
    if request.method == "POST":
        form = _form_data()
        if not form["name"]:
            flash(f"{cfg['label']} name is required.", "error")
        else:
            db = get_db()
            existing = db.execute(
                f"SELECT id FROM {cfg['table']} WHERE name = ? COLLATE NOCASE AND id != COALESCE(?, 0)",
                (form["name"], row["id"] if row else None),
            ).fetchone()
            if existing:
                flash(f"A {cfg['label'].lower()} named {form['name']} already exists.", "error")
            elif row:
                db.execute(
                    f"""UPDATE {cfg['table']} SET name = ?, contact = ?, phone = ?,
                        address = ?, city = ?, notes = ?, is_archived = ? WHERE id = ?""",
                    (form["name"], form["contact"], form["phone"], form["address"],
                     form["city"], form["notes"], 0 if form["is_active"] else 1, row["id"]),
                )
                db.commit()
                flash(f"{cfg['label']} {form['name']} was updated.", "success")
                return redirect(next_url or url_for(f"main.{cfg['endpoint']}"))
            else:
                db.execute(
                    f"""INSERT INTO {cfg['table']} (name, contact, phone, address, city, notes, is_archived)
                        VALUES (?, ?, ?, ?, ?, ?, ?)""",
                    (form["name"], form["contact"], form["phone"], form["address"],
                     form["city"], form["notes"], 0 if form["is_active"] else 1),
                )
                db.commit()
                flash(f"{cfg['label']} {form['name']} was added.", "success")
                if next_url:
                    from urllib.parse import quote
                    sep = "&" if "?" in next_url else "?"
                    if "destination=" not in next_url:
                        next_url = f"{next_url}{sep}destination={quote(form['name'])}"
                    return redirect(next_url)
                return redirect(url_for(f"main.{cfg['endpoint']}"))
    return render_template(
        "partners/form.html",
        kind=kind,
        cfg=cfg,
        form=form,
        row=row,
        creating=creating,
        next_url=next_url or "",
    )


def _toggle(kind, cfg, partner_id):
    db = get_db()
    row = db.execute(
        f"SELECT * FROM {cfg['table']} WHERE id = ?", (partner_id,)
    ).fetchone()
    if row is None:
        flash(f"{cfg['label']} not found.", "error")
    else:
        new_state = 1 if row["is_archived"] == 0 else 0
        db.execute(
            f"UPDATE {cfg['table']} SET is_archived = ? WHERE id = ?", (new_state, partner_id)
        )
        db.commit()
        state = "activated" if new_state == 0 else "deactivated"
        flash(f"{cfg['label']} {row['name']} was {state}.", "success")
    return redirect(request.referrer or url_for(f"main.{cfg['endpoint']}"))


# ── Workshops ─────────────────────────────────────────────────────────────────

@main.get("/workshops")
def workshops():
    return _partner_list("workshop", PARTNERS["workshop"])


@main.route("/workshops/new", methods=("GET", "POST"))
def new_workshop():
    return _partner_form(
        "workshop", PARTNERS["workshop"],
        next_url=request.values.get("next") or None,
        creating=True,
    )


@main.route("/workshops/<int:partner_id>/edit", methods=("GET", "POST"))
def edit_workshop(partner_id):
    db = get_db()
    row = db.execute("SELECT * FROM workshops WHERE id = ?", (partner_id,)).fetchone()
    if row is None:
        flash("Workshop not found.", "error")
        return redirect(url_for("main.workshops"))
    return _partner_form("workshop", PARTNERS["workshop"], row=row,
                         next_url=request.values.get("next") or None)


@main.post("/workshops/<int:partner_id>/toggle")
def toggle_workshop(partner_id):
    return _toggle("workshop", PARTNERS["workshop"], partner_id)


# ── Dealers ───────────────────────────────────────────────────────────────────

@main.get("/dealers")
def dealers():
    return _partner_list("dealer", PARTNERS["dealer"])


@main.route("/dealers/new", methods=("GET", "POST"))
def new_dealer():
    return _partner_form(
        "dealer", PARTNERS["dealer"],
        next_url=request.values.get("next") or None,
        creating=True,
    )


@main.route("/dealers/<int:partner_id>/edit", methods=("GET", "POST"))
def edit_dealer(partner_id):
    db = get_db()
    row = db.execute("SELECT * FROM dealers WHERE id = ?", (partner_id,)).fetchone()
    if row is None:
        flash("Dealer not found.", "error")
        return redirect(url_for("main.dealers"))
    return _partner_form("dealer", PARTNERS["dealer"], row=row,
                         next_url=request.values.get("next") or None)


@main.post("/dealers/<int:partner_id>/toggle")
def toggle_dealer(partner_id):
    return _toggle("dealer", PARTNERS["dealer"], partner_id)


# ── Quick-add JSON endpoints (movement screens) ──────────────────────────────

def _api_create(kind, cfg):
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": f"{cfg['label']} name is required."}), 400
    db = get_db()
    existing = db.execute(
        f"SELECT id FROM {cfg['table']} WHERE name = ? COLLATE NOCASE AND is_archived = 0 LIMIT 1",
        (name,),
    ).fetchone()
    if existing:
        return jsonify({"id": existing["id"], "name": name, "existing": True})
    cur = db.execute(
        f"""INSERT INTO {cfg['table']} (name, contact, phone, address, city, notes)
            VALUES (?, ?, ?, ?, ?, ?)""",
        (
            name,
            (data.get("contact") or "").strip() or None,
            (data.get("phone") or "").strip() or None,
            (data.get("address") or "").strip() or None,
            (data.get("city") or "").strip() or None,
            (data.get("notes") or "").strip() or None,
        ),
    )
    db.commit()
    return jsonify({"id": cur.lastrowid, "name": name, "existing": False})


@main.post("/api/workshops")
def api_create_workshop():
    return _api_create("workshop", PARTNERS["workshop"])


@main.post("/api/dealers")
def api_create_dealer():
    return _api_create("dealer", PARTNERS["dealer"])
