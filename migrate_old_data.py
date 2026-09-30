#!/usr/bin/env python3
"""
Stage 3 Data Migration Script
==============================
Reads the old MySQL/phpMyAdmin dump (`localhost (1).sql`) — the SECOND
database section only (`gvjxvqtv_wises`, the current/superset data) — and
migrates:

  brands       -> brands            (typo fixes + review flags)
  articles     -> in-memory map     (product-type classification only)
  catalogue    -> catalog_products  (unified: Machine/Probe/Printer/Part/Other)
  customer     -> customers         (internal Branch record skipped)
  vendors      -> vendors           (duplicate names flagged)
  purchases    -> machines / probes / printers / parts + batches
  sale_inv     -> sales             (zero prices imported as NULL)
  sale_temp_inv-> sale_items        (orphans skipped + reported)
  events       -> movements         (old-system history)

The PDF (`WISE-TECH.pdf`) is used only as an optional cross-validation
source (--pdf); it contains no records beyond the SQL catalogue.

Website/CMS tables (about_us, admin, contact_us, delivery, email, emails,
how_buy, slider, stories, more_images, cash, branch, show_web/user_id/url/
image/spec fields) are intentionally NOT imported.

Usage:
  python migrate_old_data.py --preview          Show what would be imported
  python migrate_old_data.py --execute          Import (backs up DB first)
  python migrate_old_data.py --execute --force  Re-run even if already done
  python migrate_old_data.py --preview --pdf    Also cross-check vs PDF

Guarantees:
  - The original SQL file is NEVER modified.
  - instance/inventory.db is backed up to backups/ before --execute.
  - Re-runs are idempotent: existing rows (matched by old_source_id / natural
    key) are skipped, never overwritten.
  - Ambiguous values are preserved and flagged needs_review — never guessed.
"""

import argparse
import re
import shutil
import sqlite3
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent
SQL_FILE     = PROJECT_ROOT / "localhost (1).sql"
DB_FILE      = PROJECT_ROOT / "instance" / "inventory.db"
BACKUP_DIR   = PROJECT_ROOT / "backups"
PDF_FILE     = PROJECT_ROOT / "WISE-TECH.pdf"

# ── Import batch code (for audit log) ─────────────────────────────────────
IMPORT_BATCH_CODE = "OLD-SQL-MIGRATION-001"

# ── Brand typo corrections ─────────────────────────────────────────────────
BRAND_CORRECTIONS = {
    "SEIMENS":        "SIEMENS",
    "ESOATE":         "ESAOTE",
    "KONIKA MINOLTA": "KONICA MINOLTA",
}
BRAND_NEEDS_REVIEW = {
    "MOCHIDA SEIMENS": "Verify: Mochida-Seimens is a Japanese brand; check if correct name",
    "HITACHI-ALOKA":   "Verify: Hitachi-Aloka is a post-merger brand name; confirm still in use",
    "USMAN":           "Verify: personal name used as brand — likely wrong",
    "MALIK":           "Verify: personal name used as brand — likely wrong",
    "SHAMIL":          "Verify: personal name used as brand — likely wrong",
}

# ── Product-type classification (old articles/catalogue codes) ────────────
# 1255 = Ultrasound Machine, 1256 = B&W Printer, everything else with
# articles.type == 'Accessory' is a probe; 'Spare Part' is a part;
# remaining 'Product' rows (EDEN, X-ray, Bed, …) are category Other.
MACHINE_TYPES = {"1255"}
PRINTER_TYPES = {"1256"}
PROBE_TYPES = {"1251", "1252", "1253", "1254", "1259", "1262", "1264",
               "1265", "1270", "1271", "1272", "1273", "1276", "1291", "1307"}

# ── Internal-ID prefixes ──────────────────────────────────────────────────
MACHINE_ID_PREFIX = "M"     # M-0319 (old purchase id, zero-padded to 4)
PROBE_ID_PREFIX   = "PRB"   # PRB-00001
PRINTER_ID_PREFIX = "PRT"   # PRT-00001
PART_ID_PREFIX    = "PART"  # PART-00001

LEGACY_BATCH_CODE = "LEGACY"
PLACEHOLDER_VALUES = {"", "-", "None", "NILL", "NIL", "0", "NULL"}


# ══════════════════════════════════════════════════════════════════════════
# PARSING HELPERS
# ══════════════════════════════════════════════════════════════════════════

def read_sql() -> str:
    print(f"Reading SQL dump: {SQL_FILE}")
    with open(SQL_FILE, "r", encoding="latin-1", errors="replace") as f:
        return f.read()


def wises_section(content: str) -> str:
    """Return ONLY the gvjxvqtv_wises section (the current database)."""
    uses = [m.start() for m in re.finditer(r"USE `gvjxvqtv_\w+`", content)]
    if len(uses) < 2:
        raise RuntimeError("Expected two USE statements (asen + wises) in dump.")
    return content[uses[1]:]


def clean_str(s) -> str | None:
    """Strip whitespace; None for empty/placeholder strings."""
    if s is None:
        return None
    s = str(s).strip().rstrip("\t")
    if s in PLACEHOLDER_VALUES:
        return None
    s = re.sub(r"  +", " ", s)
    return s or None


def parse_rows(content: str, table: str) -> list[list]:
    """
    Extract all data rows for a given table from the SQL dump.
    Returns a list of rows; each row is a list of cell strings (None for NULL).
    NOTE: positional — assumes the INSERT column list matches CREATE TABLE
    order (true for every table used from this dump).
    """
    pattern = re.compile(
        r"INSERT INTO `" + re.escape(table) + r"`.+?VALUES\s*\n?(.+?)(?=;\s*(?:\n|$))",
        re.DOTALL,
    )
    all_rows = []
    for m in pattern.finditer(content):
        all_rows.extend(_split_value_rows(m.group(1)))
    return all_rows


def _split_value_rows(block: str) -> list[list[str]]:
    rows = []
    depth = 0
    in_string = False
    escape_next = False
    current_row_start = None
    i = 0
    cells = []
    cell_start = None
    while i < len(block):
        ch = block[i]
        if escape_next:
            escape_next = False
            i += 1
            continue
        if ch == "\\" and in_string:
            escape_next = True
            i += 1
            continue
        if ch == "'" and not in_string:
            in_string = True
            i += 1
            continue
        if ch == "'" and in_string:
            in_string = False
            i += 1
            continue
        if in_string:
            i += 1
            continue
        if ch == "(":
            depth += 1
            if depth == 1:
                current_row_start = i + 1
                cells = []
                cell_start = i + 1
        elif ch == ")":
            depth -= 1
            if depth == 0 and current_row_start is not None:
                cells.append(_parse_cell(block[cell_start:i]))
                rows.append(cells)
                current_row_start = None
                cells = []
        elif ch == "," and depth == 1:
            cells.append(_parse_cell(block[cell_start:i]))
            cell_start = i + 1
        i += 1
    return rows


def _parse_cell(raw: str):
    raw = raw.strip()
    if raw.upper() == "NULL":
        return None
    if raw.startswith("'") and raw.endswith("'"):
        inner = raw[1:-1]
        inner = inner.replace("\\'", "'")
        inner = inner.replace("\\\\", "\\")
        inner = inner.replace("\\n", "\n")
        inner = inner.replace("\\r", "\r")
        inner = inner.replace("\\t", "\t")
        return inner
    return raw  # numeric


def _normalize_date(s) -> str | None:
    """Normalize date formats to YYYY-MM-DD. Returns None if unparseable."""
    if s is None:
        return None
    s = str(s).strip()
    if s in PLACEHOLDER_VALUES or s in ("01-01-1970", "1970-01-01"):
        return None
    if re.match(r"^\d{4}-\d{2}-\d{2}$", s):
        return s
    m = re.match(r"^(\d{2})-(\d{2})-(\d{4})$", s)   # DD-MM-YYYY
    if m:
        d, mo, y = m.groups()
        return f"{y}-{mo}-{d}"
    m = re.match(r"^(\d{2})/(\d{2})/(\d{4})$", s)   # DD/MM/YYYY
    if m:
        d, mo, y = m.groups()
        return f"{y}-{mo}-{d}"
    m = re.match(r"^(\d{4})/(\d{2})/(\d{2})$", s)   # YYYY/MM/DD
    if m:
        return s.replace("/", "-")
    return None


def _to_int(v):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return None


def _to_price(v):
    if v is None:
        return None
    try:
        pf = float(str(v).replace(",", ""))
        return pf if pf > 0 else None
    except ValueError:
        return None


def _is_placeholder_serial(s: str) -> bool:
    return bool(re.match(r"^(NIL|NILL)[-_ ]?\d*$", s.strip(), re.IGNORECASE))


def _next_seq(existing: set, prefix: str) -> str:
    """Next free ID like PRB-00001 given already-used IDs."""
    n = 1
    while f"{prefix}-{n:05d}" in existing:
        n += 1
    return f"{prefix}-{n:05d}"


# ══════════════════════════════════════════════════════════════════════════
# CLASSIFICATION
# ══════════════════════════════════════════════════════════════════════════

def classify_category(product_type, article_type, article_name):
    """Map old product_type/article info -> catalog category string."""
    pt = str(product_type or "")
    if pt in MACHINE_TYPES or (article_name or "").upper() == "ULTRASOUND MACHINE":
        return "Machine"
    if pt in PRINTER_TYPES or "PRINTER" in (article_name or "").upper():
        return "Printer"
    if pt in PROBE_TYPES:
        return "Probe"
    if (article_type or "").lower() == "spare part":
        return "Part"
    if (article_type or "").lower() == "accessory":
        return "Probe"       # all remaining accessories in this dump are probes
    return "Other"


# ══════════════════════════════════════════════════════════════════════════
# EXTRACTION (pure — no DB access; returns data + report counters)
# ══════════════════════════════════════════════════════════════════════════

def build_plan(content: str) -> dict:
    wises = wises_section(content)
    plan = {"report": {}, "skip": []}

    # ── articles (in-memory map only) ─────────────────────────────────────
    articles = {}
    for r in parse_rows(wises, "articles"):
        if len(r) >= 3:
            articles[str(r[0])] = {"name": r[1] or "", "type": r[2] or ""}
    plan["articles"] = articles

    # ── brands ────────────────────────────────────────────────────────────
    brands, brand_dups = [], []
    seen_brand = {}
    for r in parse_rows(wises, "brands"):
        if len(r) < 2 or not clean_str(r[1]):
            continue
        old_id = _to_int(r[0])
        raw = r[1].strip()
        name = BRAND_CORRECTIONS.get(raw, raw)
        name_key = name.upper()
        note_parts = []
        if name_key in BRAND_NEEDS_REVIEW:
            note_parts.append(BRAND_NEEDS_REVIEW[name_key])
        if raw != name:
            note_parts.append(f"Corrected from '{raw}'")
        if name_key in seen_brand:
            note_parts.append(f"Name collides with old brand id {seen_brand[name_key]}")
            brand_dups.append(name)
        else:
            seen_brand[name_key] = old_id
        brands.append({
            "name": name,
            "old_source_id": old_id,
            "notes": "; ".join(note_parts) or None,
        })
    plan["brands"] = brands

    # ── catalogue ─────────────────────────────────────────────────────────
    cat_rows = parse_rows(wises, "catalogue")
    brand_by_old = {b["old_source_id"]: b for b in brands}
    catalogue, cat_dedup_hits = [], 0
    seen_cat = {}          # dedup key -> kept old_source_id
    cat_alias = {}         # dropped old_source_id -> kept old_source_id
    for r in cat_rows:
        if len(r) < 9:
            continue
        old_id = _to_int(r[0])
        pt = str(r[1] or "")
        model_raw = (r[2] or "").strip()
        brand_old = _to_int(r[4])
        if not model_raw:
            continue
        art = articles.get(pt, {})
        category = classify_category(pt, art.get("type"), art.get("name"))

        # Normalize model: strip trailing dot, underscore->dash for dedup key
        model_norm = model_raw.rstrip(".").strip().replace("_", "-")
        brand = brand_by_old.get(brand_old)

        key = (model_norm.upper(), brand_old, category)
        if key in seen_cat:
            cat_dedup_hits += 1
            cat_alias[old_id] = seen_cat[key]
            continue
        seen_cat[key] = old_id

        needs_review, notes = 0, []
        if model_raw.rstrip(".").strip() != model_raw or "_" in model_raw:
            notes.append(f"Normalized from '{model_raw}'")
        if re.search(r"^(S|CK)$", model_norm):
            needs_review = 1
            notes.append("Single/short model name — verify")
        if re.search(r"RTFINO|SARANO", model_norm, re.IGNORECASE):
            needs_review = 1
            notes.append("Unknown/unusual model name — verify")
        if category == "Other":
            needs_review = 1
            notes.append(f"Product type '{art.get('name', pt)}' is not machine/probe/printer/part")
        catalogue.append({
            "name_model": model_norm,
            "category": category,
            "brand_old_id": brand_old,
            "brand_name": brand["name"] if brand else None,
            "probe_type": art.get("name") if category == "Probe" else None,
            "old_source_id": old_id,
            "needs_review": needs_review,
            "review_note": "; ".join(notes) or None,
            "source_info": f"Old catalogue id {old_id}; type: {art.get('name', pt)}",
        })
    plan["catalogue"] = catalogue
    cat_by_old = {c["old_source_id"]: c for c in catalogue}
    # Purchases may reference a catalogue row that was deduped away —
    # alias those ids to the row that was kept.
    for dropped_id, kept_id in cat_alias.items():
        if kept_id in cat_by_old:
            cat_by_old[dropped_id] = cat_by_old[kept_id]
    plan["_cat_alias"] = cat_alias

    # ── customers ─────────────────────────────────────────────────────────
    customers, cust_skipped_branch, cust_dup = [], 0, 0
    name_seen = Counter()
    raw_customers = []
    for r in parse_rows(wises, "customer"):
        if len(r) < 6:
            continue
        name = clean_str(r[1])
        if not name:
            continue
        ctype_raw = (r[3] or "").strip()
        if ctype_raw.lower() == "branch":
            cust_skipped_branch += 1
            continue
        ctype = ctype_raw if ctype_raw in ("Customer", "Dealer") else "Other"
        raw_customers.append({
            "old_source_id": _to_int(r[0]),
            "name": name,
            "phone": clean_str(r[2]),
            "customer_type": ctype,
            "address": clean_str(r[4]),
            "city": clean_str(r[5]),
        })
        name_seen[name.upper()] += 1
    for c in raw_customers:
        if name_seen[c["name"].upper()] > 1:
            c["notes"] = "Possible duplicate — another customer has the same name"
            cust_dup += 1
        else:
            c["notes"] = None
    customers = raw_customers
    plan["customers"] = customers
    cust_old_ids = {c["old_source_id"] for c in customers}

    # ── vendors ───────────────────────────────────────────────────────────
    vendors = []
    vname_seen = Counter()
    for r in parse_rows(wises, "vendors"):
        if len(r) < 1:
            continue
        name = clean_str(r[1])
        if not name:
            continue
        vendors.append({
            "old_source_id": _to_int(r[0]),
            "name": name,
            "phone": clean_str(r[2]) if len(r) > 2 else None,
            "address": clean_str(r[3]) if len(r) > 3 else None,
        })
        vname_seen[name.upper()] += 1
    vendor_dup = 0
    for v in vendors:
        if vname_seen[v["name"].upper()] > 1:
            v["notes"] = "Possible duplicate vendor — same name appears twice"
            vendor_dup += 1
        else:
            v["notes"] = None
    plan["vendors"] = vendors

    # ── batches (distinct arrival dates + LEGACY) ─────────────────────────
    purchases = parse_rows(wises, "purchases")
    arrival_dates = Counter()
    for r in purchases:
        if len(r) > 6:
            d = _normalize_date(r[6])
            arrival_dates[d] += 1
    plan["_arrival_dates"] = arrival_dates  # None key = LEGACY

    # ── purchases -> machines / probes / printers / parts ─────────────────
    machines, probes, printers, parts = [], [], [], []
    counts = Counter()
    serial_dups = defaultdict(int)
    for r in purchases:
        if len(r) < 12:
            counts["too_short"] += 1
            continue
        old_id = _to_int(r[0])
        location = clean_str(r[1]) or "Company"
        cat_old = _to_int(r[2])
        cond_raw = clean_str(r[3])
        sr = clean_str(r[4])
        m_sr = clean_str(r[5])
        arr_date = _normalize_date(r[6])
        issue_date = _normalize_date(r[7])
        vendor_old = _to_int(r[9])          # `vendors` column (index 9)
        model_year = clean_str(r[10])
        sold = str(r[11]).strip() == "1" if len(r) > 11 else False

        cat_row = cat_by_old.get(cat_old)
        if cat_row is None:
            counts["missing_catalogue"] += 1
            continue
        category = cat_row["category"]
        counts[category] += 1

        review_notes = []
        needs_review = 0
        if cat_row["needs_review"]:
            needs_review = 1
            review_notes.append(cat_row["review_note"] or "")

        # serial flags
        if sr and _is_placeholder_serial(sr):
            needs_review = 1
            review_notes.append(f"Placeholder serial '{sr}'")
        if sr:
            serial_dups[sr.upper()] += 1
            if serial_dups[sr.upper()] > 1:
                needs_review = 1
                review_notes.append(f"Duplicate serial in source: '{sr}'")

        # acquisition date flags
        if arr_date and arr_date > datetime.now().strftime("%Y-%m-%d"):
            needs_review = 1
            review_notes.append(f"Future acquisition date {arr_date}")

        # year
        year = None
        if model_year and re.match(r"^(19|20)\d{2}$", model_year):
            year = model_year
        elif model_year:
            needs_review = 1
            review_notes.append(f"Unrecognized model_year '{model_year}'")

        # condition mapping (deterministic; originals preserved)
        if category == "Machine":
            cond_map = {"OK": "Good", "Faulty": "Faulty"}
            if cond_raw in cond_map:
                condition = cond_map[cond_raw]
            elif cond_raw is None:
                condition = None
            else:
                condition = "Unknown"
                needs_review = 1
                review_notes.append(f"Old condition: '{cond_raw}'")
        else:
            cond_map = {"OK": "Good", "Faulty": "Damaged"}
            if cond_raw in cond_map:
                condition = cond_map[cond_raw]
            elif cond_raw is None:
                condition = None
            else:
                condition = "Needs Inspection"
                needs_review = 1
                review_notes.append(f"Old condition: '{cond_raw}'")

        status = "Sold" if sold else None  # final status set per category below
        notes_bits = []
        if issue_date:
            notes_bits.append(f"Old issue date: {issue_date}")
        notes = "; ".join(notes_bits) or None
        review_note = "; ".join(x for x in review_notes if x) or None

        base = {
            "old_source_id": old_id,
            "catalog_old_id": cat_old,
            "model": cat_row["name_model"],
            "brand_name": cat_row["brand_name"],
            "serial": sr,
            "m_sr": m_sr,
            "arrival": arr_date,
            "vendor_old": vendor_old,
            "year": year,
            "location": location,
            "condition": condition,
            "sold": sold,
            "status": status,
            "notes": notes,
            "needs_review": needs_review,
            "review_note": review_note,
        }

        if category == "Machine":
            base["machine_id"] = f"{MACHINE_ID_PREFIX}-{old_id:04d}"
            machines.append(base)
        elif category == "Probe":
            probes.append(base)
        elif category == "Printer":
            printers.append(base)
        else:  # Part + Other physical rows
            if category == "Other":
                needs_review = 1
                review_note = ((review_note + "; ") if review_note else "") + \
                    "Non-spare product imported into parts — verify"
                base["needs_review"] = needs_review
                base["review_note"] = review_note
            parts.append(base)

    plan["machines"] = machines
    plan["probes"] = probes
    plan["printers"] = printers
    plan["parts"] = parts

    # ── sales (sale_inv) ──────────────────────────────────────────────────
    sales = []
    trno_counter = Counter()
    internal_branch_sales = 0
    for r in parse_rows(wises, "sale_inv"):
        if len(r) < 7:
            continue
        old_id = _to_int(r[0])
        cust_old = _to_int(r[1])
        date = _normalize_date(r[2])
        price = _to_price(r[3])
        notes = clean_str(r[4])
        trno = clean_str(r[5])
        if cust_old == 6:               # internal Branch customer (skipped)
            internal_branch_sales += 1
            notes = ((notes + "; ") if notes else "") + "Internal branch sale"
        if trno:
            trno_counter[trno] += 1
        sales.append({
            "old_source_id": old_id,
            "customer_old_id": cust_old,
            "sale_date": date or "1970-01-01",
            "sale_price": price,
            "notes": notes,
            "old_trno": trno,
            "date_missing": date is None,
        })
    plan["sales"] = sales
    plan["_trno_dups"] = [t for t, n in trno_counter.items() if n > 1]

    # ── sale items (sale_temp_inv) ────────────────────────────────────────
    sale_items = []
    orphan_items = 0
    orphan_trnos = set()
    no_trno_items = 0
    pur_ids = {m["old_source_id"] for m in machines} | \
              {p["old_source_id"] for p in probes} | \
              {p["old_source_id"] for p in printers} | \
              {p["old_source_id"] for p in parts}
    trno_set = set(trno_counter)
    for r in parse_rows(wises, "sale_temp_inv"):
        if len(r) < 10:
            continue
        old_id = _to_int(r[0])
        purchase_old = _to_int(r[1])
        name = clean_str(r[2])
        serial = clean_str(r[3])
        trno = clean_str(r[4])
        price = _to_price(r[6]) if len(r) > 6 else None
        main = str(r[7]).strip() == "1" if len(r) > 7 else False
        if not trno:
            no_trno_items += 1
            continue
        if trno not in trno_set:
            orphan_items += 1
            orphan_trnos.add(trno)
            continue
        name_l = (name or "").lower()
        if "ultrasound machine" in name_l or name_l.startswith("machine"):
            itype = "machine"
        elif "probe" in name_l:
            itype = "probe"
        elif "printer" in name_l:
            itype = "printer"
        else:
            itype = "other"
        sale_items.append({
            "old_source_id": old_id,
            "old_purchase_id": purchase_old,
            "old_trno": trno,
            "item_type": itype,
            "item_description": name,
            "item_serial": serial,
            "item_price": price,
            "is_main_item": 1 if main else 0,
            "purchase_exists": purchase_old in pur_ids,
        })
    plan["sale_items"] = sale_items

    # ── events -> movements ───────────────────────────────────────────────
    movements, orphan_events = [], 0
    for r in parse_rows(wises, "events"):
        if len(r) < 5:
            continue
        old_id = _to_int(r[0])
        inv_id = _to_int(r[1])
        date = _normalize_date(r[2])
        details = clean_str(r[4]) or ""
        remarks = clean_str(r[5]) if len(r) > 5 else None
        if inv_id is None or inv_id not in pur_ids:
            orphan_events += 1
            continue
        d_low = details.lower()
        if "previously attached" in d_low or "now attached" in d_low:
            mtype = "Attachment"
        elif "transferred" in d_low:
            mtype = "Transfer"
        elif "sold" in d_low:
            mtype = "Sale"
        else:
            mtype = "Note"
        from_loc = to_loc = None
        m = re.search(r"was at (.+?) and now transferred to (.+)$", details)
        if m:
            from_loc = m.group(1).strip()
            to_loc = m.group(2).strip()
        note = details
        if remarks and remarks not in ("-", ""):
            note = f"{details} [{remarks}]"
        movements.append({
            "old_source_id": old_id,
            "purchase_old_id": inv_id,
            "movement_type": mtype,
            "movement_date": date,
            "from_location": from_loc,
            "to_location": to_loc,
            "reason": details or None,
            "notes": note or None,
        })
    plan["movements"] = movements

    # ── report ────────────────────────────────────────────────────────────
    plan["report"] = {
        "brands": len(brands),
        "brand_dups": brand_dups,
        "catalogue_raw": len(cat_rows),
        "catalogue": len(catalogue),
        "catalogue_dedup": cat_dedup_hits,
        "catalogue_by_cat": Counter(c["category"] for c in catalogue),
        "customers": len(customers),
        "customers_branch_skipped": cust_skipped_branch,
        "customers_dup_names": cust_dup,
        "vendors": len(vendors),
        "vendors_dups": vendor_dup,
        "batches_from_dates": len(arrival_dates),
        "purchases_total": len(purchases),
        "machines": len(machines),
        "probes": len(probes),
        "printers": len(printers),
        "parts": len(parts),
        "purchases_missing_catalogue": counts["missing_catalogue"],
        "purchases_too_short": counts["too_short"],
        "sales": len(sales),
        "sales_internal_branch": internal_branch_sales,
        "sales_missing_date": sum(1 for s in sales if s["date_missing"]),
        "sales_unknown_customer": sum(
            1 for s in sales
            if s["customer_old_id"] not in (None, 6)
            and s["customer_old_id"] not in cust_old_ids
        ),
        "sales_dup_trnos": plan["_trno_dups"],
        "sale_items": len(sale_items),
        "sale_items_orphan_trno": orphan_items,
        "sale_items_orphan_distinct": len(orphan_trnos),
        "sale_items_no_trno": no_trno_items,
        "movements": len(movements),
        "movements_orphan": orphan_events,
        "flagged_machines": sum(m["needs_review"] for m in machines),
        "flagged_probes": sum(p["needs_review"] for p in probes),
        "flagged_printers": sum(p["needs_review"] for p in printers),
        "flagged_parts": sum(p["needs_review"] for p in parts),
        "flagged_catalogue": sum(c["needs_review"] for c in catalogue),
        "sold_machines": sum(1 for m in machines if m["sold"]),
        "sold_probes": sum(1 for p in probes if p["sold"]),
        "sold_printers": sum(1 for p in printers if p["sold"]),
        "sold_parts": sum(1 for p in parts if p["sold"]),
        "probe_parents_linked": 0,   # filled during execute (needs SR map)
    }

    plan["skip"] = [
        "about_us", "admin", "cash", "contact_us", "delivery", "email",
        "emails", "how_buy", "more_images", "slider", "stories",
        "branch (reference only)", "show_web/user_id/url/image/spec fields",
        "instance/pdf_import_candidates.json (stale broken extraction)",
    ]
    return plan


# ══════════════════════════════════════════════════════════════════════════
# PDF CROSS-VALIDATION (optional, non-fatal)
# ══════════════════════════════════════════════════════════════════════════

def validate_pdf(plan: dict) -> bool:
    if not PDF_FILE.exists():
        print("PDF not found — skipping cross-validation.")
        return True
    try:
        import pymupdf
    except ImportError:
        try:
            import fitz as pymupdf
        except ImportError:
            print("PyMuPDF not installed — skipping PDF cross-validation.")
            return True

    doc = pymupdf.open(PDF_FILE)

    # pages 1-21: numbered brand + article-type rows
    numbered = []
    for pno in range(0, 21):
        lines = [l.strip() for l in doc[pno].get_text("text").splitlines() if l.strip()]
        i = 0
        while i < len(lines):
            m = re.match(r"^(\d+)\s+(.*)$", lines[i])
            if m and i + 1 < len(lines):
                numbered.append((m.group(2).strip(), lines[i + 1].strip()))
                i += 2
            else:
                i += 1

    # pages 22-42: model lines
    model_lines = []
    for pno in range(21, 42):
        for l in doc[pno].get_text("text").splitlines():
            l = l.strip()
            if l and l not in ("Model", "Image"):
                model_lines.append(l)
    doc.close()

    def norm(s):
        return re.sub(r"\s+", " ", s.strip().rstrip(".")).replace("_", "-").upper()

    def correct_brand(b):
        b = b.strip()
        return BRAND_CORRECTIONS.get(b, b)

    # Dedup dropped rows + <=2 junk footer lines are the allowed PDF extras.
    allowed_extra = plan["report"]["catalogue_dedup"] + 2

    # brand+type multiset from plan catalogue vs PDF (both typo-corrected)
    cat_bt = Counter()
    for c in plan["catalogue"]:
        src = c.get("source_info") or ""
        tname = src.split("type: ", 1)[1] if "type: " in src else c["category"]
        cat_bt[((correct_brand(c["brand_name"] or "?")).upper().strip(),
                tname.upper().strip())] += 1
    pdf_bt = Counter((correct_brand(b).upper().strip(), t.upper().strip())
                     for b, t in numbered)

    cat_models = Counter(norm(c["name_model"]) for c in plan["catalogue"])
    pdf_models = Counter(norm(m) for m in model_lines)

    ok = True
    print("\n" + "=" * 60)
    print("  PDF CROSS-VALIDATION (WISE-TECH.pdf)")
    print("=" * 60)
    print(f"  PDF numbered brand+type rows : {sum(pdf_bt.values())}")
    print(f"  SQL catalogue rows           : {sum(cat_bt.values())}")
    d1, d2 = pdf_bt - cat_bt, cat_bt - pdf_bt
    bt_ok = sum(d2.values()) == 0 and sum(d1.values()) <= allowed_extra
    print(f"  Brand+type: SQL-only={sum(d2.values())}  "
          f"PDF-extra={sum(d1.values())} (allowed <= {allowed_extra})  "
          f"-> {'PASS' if bt_ok else 'FAIL'}")
    if not bt_ok:
        ok = False
        print(f"    only in PDF e.g. {list(d1.items())[:5]}")
        print(f"    only in SQL e.g. {list(d2.items())[:5]}")
    elif sum(d1.values()):
        print(f"    PDF extras are the known deduped variants: {list(d1.items())[:6]}")

    print(f"  PDF model lines              : {sum(pdf_models.values())}")
    print(f"  SQL catalogue models         : {sum(cat_models.values())}")
    m1, m2 = pdf_models - cat_models, cat_models - pdf_models
    m_ok = sum(m2.values()) == 0 and sum(m1.values()) <= allowed_extra
    print(f"  Models     : SQL-only={sum(m2.values())}  "
          f"PDF-extra={sum(m1.values())} (allowed <= {allowed_extra})  "
          f"-> {'PASS' if m_ok else 'FAIL'}")
    if not m_ok:
        ok = False
        print(f"    only in PDF: {sorted(m1)[:8]}")
        print(f"    only in SQL: {sorted(m2)[:8]}")
    elif sum(m1.values()):
        print(f"    PDF extras: {sorted(m1)}")

    print("  Result:",
          "PASS — PDF adds no records beyond SQL (dedup/junk footer only)."
          if ok else "MISMATCH — review before executing.")
    print("=" * 60)
    return ok


# ══════════════════════════════════════════════════════════════════════════
# PREVIEW
# ══════════════════════════════════════════════════════════════════════════

def show_preview(plan: dict):
    r = plan["report"]
    print("\n" + "=" * 60)
    print("  MIGRATION PREVIEW  (source: gvjxvqtv_wises only)")
    print("=" * 60)

    print(f"\n{'BRANDS':─<50}")
    print(f"  Total                    : {r['brands']}")
    print(f"  Typo corrections         : {len(BRAND_CORRECTIONS)} applied by name")
    flagged = [b for b in plan["brands"] if b.get("notes")]
    print(f"  With review notes        : {len(flagged)}")
    for b in flagged[:8]:
        print(f"    ⚠  {b['name']}: {b['notes']}")
    if len(flagged) > 8:
        print(f"    ... and {len(flagged) - 8} more")

    print(f"\n{'CATALOGUE':─<50}")
    print(f"  Raw rows                 : {r['catalogue_raw']}")
    print(f"  After dedup              : {r['catalogue']}  (dropped {r['catalogue_dedup']})")
    for cat, n in sorted(r["catalogue_by_cat"].items()):
        print(f"    {cat:<10}: {n:>4}")
    print(f"  Flagged for review       : {r['flagged_catalogue']}")

    print(f"\n{'CUSTOMERS':─<50}")
    print(f"  Imported                 : {r['customers']}")
    print(f"  Internal Branch skipped  : {r['customers_branch_skipped']}")
    print(f"  Duplicate-name flagged   : {r['customers_dup_names']}")

    print(f"\n{'VENDORS':─<50}")
    print(f"  Imported                 : {r['vendors']}")
    print(f"  Duplicate-name flagged   : {r['vendors_dups']}")

    print(f"\n{'BATCHES':─<50}")
    print(f"  Batches to create        : {r['batches_from_dates']}")
    dates = plan["_arrival_dates"]
    legacy = dates.get(None, 0)
    print(f"  Rows without arrival date: {legacy} -> {LEGACY_BATCH_CODE} batch")

    print(f"\n{'PHYSICAL INVENTORY (purchases)':─<50}")
    print(f"  Source rows              : {r['purchases_total']}")
    print(f"  Machines                 : {r['machines']:>5}  (sold {r['sold_machines']}, flagged {r['flagged_machines']})")
    print(f"  Probes                   : {r['probes']:>5}  (sold {r['sold_probes']}, flagged {r['flagged_probes']})")
    print(f"  Printers                 : {r['printers']:>5}  (sold {r['sold_printers']}, flagged {r['flagged_printers']})")
    print(f"  Parts                    : {r['parts']:>5}  (sold {r['sold_parts']}, flagged {r['flagged_parts']})")
    if r["purchases_missing_catalogue"]:
        print(f"  ⚠ missing catalogue ref  : {r['purchases_missing_catalogue']}  -> SKIPPED")
    if r["purchases_too_short"]:
        print(f"  ⚠ malformed rows         : {r['purchases_too_short']}  -> SKIPPED")

    print(f"\n{'SALES':─<50}")
    print(f"  Sale headers             : {r['sales']}")
    print(f"  Internal branch sales    : {r['sales_internal_branch']}  (customer kept NULL + noted)")
    if r.get("sales_unknown_customer"):
        print(f"  Unknown old customer ids : {r['sales_unknown_customer']}  (NULL + noted)")
    print(f"  Missing/invalid dates    : {r['sales_missing_date']}  -> 1970-01-01 + review")
    print(f"  Duplicate trnos          : {len(r['sales_dup_trnos'])}  {r['sales_dup_trnos'][:5]}")
    print(f"  Sale items               : {r['sale_items']}")
    print(f"  Orphan trno items skipped: {r['sale_items_orphan_trno']}"
          f" rows / {r['sale_items_orphan_distinct']} distinct trnos")
    if r["sale_items_no_trno"]:
        print(f"  Items without trno skipped: {r['sale_items_no_trno']}")
    if r["purchases_missing_catalogue"]:
        print(f"  ⚠ purchases with unresolved catalogue ref: {r['purchases_missing_catalogue']} -> SKIPPED")

    print(f"\n{'MOVEMENT HISTORY (events)':─<50}")
    print(f"  Imported                 : {r['movements']}")
    print(f"  Orphan (unknown item)    : {r['movements_orphan']}  -> SKIPPED")

    print(f"\n{'NOT IMPORTED (by design)':─<50}")
    for t in plan["skip"]:
        print(f"  ✗ {t}")

    print("\n" + "=" * 60)


# ══════════════════════════════════════════════════════════════════════════
# EXECUTE
# ══════════════════════════════════════════════════════════════════════════

def backup_db() -> Path:
    BACKUP_DIR.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = BACKUP_DIR / f"pre-import-{IMPORT_BATCH_CODE}-{stamp}.db"
    shutil.copy2(DB_FILE, dest)
    print(f"Backup created: {dest}")
    return dest


def execute_migration(plan: dict) -> dict:
    backup_db()
    db = sqlite3.connect(DB_FILE)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    s = Counter()
    brand_old_to_new = {}
    cat_old_to_new = {}
    cust_old_to_new = {}
    vend_old_to_new = {}
    batch_date_to_new = {}
    pur_old_to_new = {}      # old purchase id -> ("machines"/"probes"/..., new id)
    trno_to_sale = {}
    used_probe_ids = {row[0] for row in db.execute(
        "SELECT internal_id FROM probes WHERE internal_id IS NOT NULL")}
    used_print_ids = {row[0] for row in db.execute(
        "SELECT internal_id FROM printers WHERE internal_id IS NOT NULL")}
    used_part_ids = {row[0] for row in db.execute(
        "SELECT internal_id FROM parts WHERE internal_id IS NOT NULL")}

    try:
        # 1. Brands ────────────────────────────────────────────────────────
        for b in plan["brands"]:
            try:
                cur = db.execute(
                    "INSERT INTO brands (name, old_source_id, notes, created_at) VALUES (?, ?, ?, ?)",
                    (b["name"], b["old_source_id"], b["notes"], now),
                )
                brand_old_to_new[b["old_source_id"]] = cur.lastrowid
                s["brands_inserted"] += 1
            except sqlite3.IntegrityError:
                row = db.execute(
                    "SELECT id FROM brands WHERE name = ? COLLATE NOCASE", (b["name"],)
                ).fetchone()
                if row:
                    brand_old_to_new[b["old_source_id"]] = row["id"]
                s["brands_skipped"] += 1

        # resolve brand ids for catalogue (by old brand id -> new brand id)
        # (brand_old_to_new already maps old -> new from insert above)

        # 2. Catalogue ─────────────────────────────────────────────────────
        for c in plan["catalogue"]:
            brand_new = brand_old_to_new.get(c["brand_old_id"])
            exists = db.execute(
                """SELECT id FROM catalog_products
                   WHERE name_model = ? COLLATE NOCASE AND brand_id IS ? AND category = ?""",
                (c["name_model"], brand_new, c["category"]),
            ).fetchone()
            if exists:
                cat_old_to_new[c["old_source_id"]] = exists["id"]
                s["catalogue_skipped"] += 1
                continue
            try:
                cur = db.execute(
                    """INSERT INTO catalog_products
                       (name_model, category, brand_id, probe_type, source_info,
                        old_source_id, needs_review, review_note, created_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (c["name_model"], c["category"], brand_new, c["probe_type"],
                     c["source_info"], c["old_source_id"], c["needs_review"],
                     c["review_note"], now),
                )
                cat_old_to_new[c["old_source_id"]] = cur.lastrowid
                s["catalogue_inserted"] += 1
                if c["needs_review"]:
                    s["catalogue_flagged"] += 1
            except sqlite3.IntegrityError:
                s["catalogue_skipped"] += 1

        # 3. Customers ─────────────────────────────────────────────────────
        for c in plan["customers"]:
            exists = db.execute(
                "SELECT id FROM customers WHERE old_source_id = ?", (c["old_source_id"],)
            ).fetchone()
            if exists:
                cust_old_to_new[c["old_source_id"]] = exists["id"]
                s["customers_skipped"] += 1
                continue
            try:
                cur = db.execute(
                    """INSERT INTO customers
                       (name, phone, address, city, customer_type, notes,
                        old_source_id, created_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                    (c["name"], c["phone"], c["address"], c["city"],
                     c["customer_type"], c["notes"], c["old_source_id"], now),
                )
                cust_old_to_new[c["old_source_id"]] = cur.lastrowid
                s["customers_inserted"] += 1
            except sqlite3.IntegrityError:
                s["customers_skipped"] += 1

        # 4. Vendors ───────────────────────────────────────────────────────
        for v in plan["vendors"]:
            exists = db.execute(
                "SELECT id FROM vendors WHERE old_source_id = ?", (v["old_source_id"],)
            ).fetchone()
            if exists:
                vend_old_to_new[v["old_source_id"]] = exists["id"]
                s["vendors_skipped"] += 1
                continue
            try:
                cur = db.execute(
                    """INSERT INTO vendors (name, phone, address, notes, old_source_id, created_at)
                       VALUES (?, ?, ?, ?, ?, ?)""",
                    (v["name"], v["phone"], v["address"], v["notes"],
                     v["old_source_id"], now),
                )
                vend_old_to_new[v["old_source_id"]] = cur.lastrowid
                s["vendors_inserted"] += 1
            except sqlite3.IntegrityError:
                s["vendors_skipped"] += 1

        # 5. Batches ───────────────────────────────────────────────────────
        existing_batch = {row["code"].upper(): row["id"]
                          for row in db.execute("SELECT id, code FROM batches")}
        dates = plan["_arrival_dates"]
        for arr_date in sorted(dates, key=lambda d: (d is None, d or "")):
            code = LEGACY_BATCH_CODE if arr_date is None else arr_date
            key = code.upper()
            if key in existing_batch:
                batch_date_to_new[arr_date] = existing_batch[key]
                s["batches_skipped"] += 1
                continue
            arrival = arr_date if arr_date is not None else ""
            notes = ("Imported from old system (no arrival date recorded)"
                     if arr_date is None else "Imported from old system arrival date")
            try:
                cur = db.execute(
                    "INSERT INTO batches (code, arrival_date, notes, created_at) VALUES (?, ?, ?, ?)",
                    (code, arrival, notes, now),
                )
                batch_date_to_new[arr_date] = cur.lastrowid
                existing_batch[key] = cur.lastrowid
                s["batches_inserted"] += 1
            except sqlite3.IntegrityError:
                s["batches_skipped"] += 1

        # catalogue brand lookup: old catalogue id -> old brand id
        cat_brand_old = {c["old_source_id"]: c["brand_old_id"] for c in plan["catalogue"]}

        def _brand_new(row):
            bo = cat_brand_old.get(row["catalog_old_id"])
            return brand_old_to_new.get(bo) if bo is not None else None

        # 6. Machines ──────────────────────────────────────────────────────
        for m in plan["machines"]:
            exists = db.execute(
                "SELECT id FROM machines WHERE old_source_id = ?", (m["old_source_id"],)
            ).fetchone()
            if exists:
                pur_old_to_new[m["old_source_id"]] = ("machines", exists["id"])
                s["machines_skipped"] += 1
                continue
            batch_id = batch_date_to_new.get(m["arrival"])
            if batch_id is None:
                batch_id = batch_date_to_new.get(None)
            try:
                cur = db.execute(
                    """INSERT INTO machines
                       (machine_id, batch_id, catalog_product_id, brand_id, model,
                        serial_number, year_of_manufacture, vendor_id, acquisition_date,
                        status, current_location, condition, notes, needs_review,
                        review_note, old_source_id, created_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (m["machine_id"], batch_id, cat_old_to_new.get(m["catalog_old_id"]),
                     _brand_new(m), m["model"], m["serial"], m["year"],
                     vend_old_to_new.get(m["vendor_old"]), m["arrival"],
                     "Sold" if m["sold"] else "In Stock",
                     m["location"], m["condition"], m["notes"],
                     m["needs_review"], m["review_note"], m["old_source_id"], now),
                )
                pur_old_to_new[m["old_source_id"]] = ("machines", cur.lastrowid)
                s["machines_inserted"] += 1
                if m["needs_review"]:
                    s["machines_flagged"] += 1
            except sqlite3.IntegrityError as e:
                s["machines_error"] += 1
                print(f"  ⚠ machine {m['machine_id']} skipped: {e}")

        # parent-serial -> machine row id (for probe/printer assignment)
        machine_by_sr = {}
        for row in db.execute(
            "SELECT id, serial_number FROM machines WHERE serial_number IS NOT NULL AND serial_number != ''"
        ):
            machine_by_sr[row["serial_number"].upper()] = row["id"]

        # 7. Probes ────────────────────────────────────────────────────────
        for p in plan["probes"]:
            exists = db.execute(
                "SELECT id FROM probes WHERE old_source_id = ?", (p["old_source_id"],)
            ).fetchone()
            if exists:
                pur_old_to_new[p["old_source_id"]] = ("probes", exists["id"])
                s["probes_skipped"] += 1
                continue
            batch_id = batch_date_to_new.get(p["arrival"]) or batch_date_to_new.get(None)
            assigned = None
            if p["m_sr"] and p["m_sr"].upper() != (p["serial"] or "").upper():
                assigned = machine_by_sr.get(p["m_sr"].upper())
            if p["sold"]:
                status = "Sold"
            elif assigned:
                status = "With Machine"
            else:
                status = "Available"
            if assigned:
                s["probe_parents_linked"] += 1
            iid = _next_seq(used_probe_ids, PROBE_ID_PREFIX)
            used_probe_ids.add(iid)
            try:
                cur = db.execute(
                    """INSERT INTO probes
                       (internal_id, catalog_product_id, model, brand_id, serial_number,
                        batch_id, vendor_id, acquisition_date, status, current_location,
                        assigned_machine_id, condition, notes, needs_review, review_note,
                        old_source_id, created_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (iid, cat_old_to_new.get(p["catalog_old_id"]), p["model"],
                     _brand_new(p), p["serial"], batch_id,
                     vend_old_to_new.get(p["vendor_old"]), p["arrival"], status,
                     p["location"], assigned, p["condition"], p["notes"],
                     p["needs_review"], p["review_note"], p["old_source_id"], now),
                )
                pur_old_to_new[p["old_source_id"]] = ("probes", cur.lastrowid)
                s["probes_inserted"] += 1
                if p["needs_review"]:
                    s["probes_flagged"] += 1
            except sqlite3.IntegrityError as e:
                s["probes_error"] += 1
                print(f"  ⚠ probe {p['model']} skipped: {e}")

        # 8. Printers ──────────────────────────────────────────────────────
        for p in plan["printers"]:
            exists = db.execute(
                "SELECT id FROM printers WHERE old_source_id = ?", (p["old_source_id"],)
            ).fetchone()
            if exists:
                pur_old_to_new[p["old_source_id"]] = ("printers", exists["id"])
                s["printers_skipped"] += 1
                continue
            batch_id = batch_date_to_new.get(p["arrival"]) or batch_date_to_new.get(None)
            assigned = None
            if p["m_sr"] and p["m_sr"].upper() != (p["serial"] or "").upper():
                assigned = machine_by_sr.get(p["m_sr"].upper())
            status = "Sold" if p["sold"] else ("With Machine" if assigned else "Available")
            if assigned:
                s["probe_parents_linked"] += 1
            iid = _next_seq(used_print_ids, PRINTER_ID_PREFIX)
            used_print_ids.add(iid)
            try:
                cur = db.execute(
                    """INSERT INTO printers
                       (internal_id, catalog_product_id, name_model, brand_id,
                        serial_number, quantity, batch_id, vendor_id, acquisition_date,
                        status, current_location, assigned_machine_id, condition,
                        notes, needs_review, review_note, old_source_id, created_at)
                       VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (iid, cat_old_to_new.get(p["catalog_old_id"]), p["model"],
                     _brand_new(p), p["serial"], batch_id,
                     vend_old_to_new.get(p["vendor_old"]), p["arrival"], status,
                     p["location"], assigned, p["condition"], p["notes"],
                     p["needs_review"], p["review_note"], p["old_source_id"], now),
                )
                pur_old_to_new[p["old_source_id"]] = ("printers", cur.lastrowid)
                s["printers_inserted"] += 1
                if p["needs_review"]:
                    s["printers_flagged"] += 1
            except sqlite3.IntegrityError as e:
                s["printers_error"] += 1
                print(f"  ⚠ printer {p['model']} skipped: {e}")

        # 9. Parts ─────────────────────────────────────────────────────────
        for p in plan["parts"]:
            exists = db.execute(
                "SELECT id FROM parts WHERE old_source_id = ?", (p["old_source_id"],)
            ).fetchone()
            if exists:
                pur_old_to_new[p["old_source_id"]] = ("parts", exists["id"])
                s["parts_skipped"] += 1
                continue
            batch_id = batch_date_to_new.get(p["arrival"]) or batch_date_to_new.get(None)
            status = "Sold" if p["sold"] else "Available"
            iid = _next_seq(used_part_ids, PART_ID_PREFIX)
            used_part_ids.add(iid)
            try:
                cur = db.execute(
                    """INSERT INTO parts
                       (internal_id, catalog_product_id, name_model, brand_id,
                        serial_number, quantity, batch_id, vendor_id, acquisition_date,
                        status, current_location, condition, notes, needs_review,
                        review_note, old_source_id, created_at)
                       VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (iid, cat_old_to_new.get(p["catalog_old_id"]), p["model"],
                     _brand_new(p), p["serial"], batch_id,
                     vend_old_to_new.get(p["vendor_old"]), p["arrival"], status,
                     p["location"], p["condition"], p["notes"],
                     p["needs_review"], p["review_note"], p["old_source_id"], now),
                )
                pur_old_to_new[p["old_source_id"]] = ("parts", cur.lastrowid)
                s["parts_inserted"] += 1
                if p["needs_review"]:
                    s["parts_flagged"] += 1
            except sqlite3.IntegrityError as e:
                s["parts_error"] += 1
                print(f"  ⚠ part {p['model']} skipped: {e}")

        # 10. Sales ────────────────────────────────────────────────────────
        for sale in plan["sales"]:
            exists = db.execute(
                "SELECT id FROM sales WHERE old_source_id = ?", (sale["old_source_id"],)
            ).fetchone()
            if exists:
                trno_to_sale[sale["old_trno"]] = exists["id"] if sale["old_trno"] else None
                s["sales_skipped"] += 1
                continue
            cust = cust_old_to_new.get(sale["customer_old_id"])
            sale_notes = sale["notes"]
            if cust is None and sale["customer_old_id"] not in (None, 6):
                # old DB referenced a customer id that no longer exists
                sale_notes = ((sale_notes + "; ") if sale_notes else "") + \
                    f"Unknown old customer id {sale['customer_old_id']}"
                s["sales_flagged"] += 1
            try:
                cur = db.execute(
                    """INSERT INTO sales
                       (customer_id, sale_date, sale_price, notes, old_source_id,
                        old_trno, created_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?)""",
                    (cust, sale["sale_date"], sale["sale_price"], sale_notes,
                     sale["old_source_id"], sale["old_trno"], now),
                )
                if sale["old_trno"]:
                    trno_to_sale[sale["old_trno"]] = cur.lastrowid
                s["sales_inserted"] += 1
                if sale["date_missing"]:
                    s["sales_flagged"] += 1
            except sqlite3.IntegrityError:
                s["sales_skipped"] += 1

        # 11. Sale items ───────────────────────────────────────────────────
        for si in plan["sale_items"]:
            exists = db.execute(
                "SELECT id FROM sale_items WHERE old_source_id = ?", (si["old_source_id"],)
            ).fetchone()
            if exists:
                s["sale_items_skipped"] += 1
                continue
            sale_id = trno_to_sale.get(si["old_trno"])
            if not sale_id:
                s["sale_items_no_sale"] += 1
                continue
            fk_table = fk_id = None
            if si["old_purchase_id"] is not None:
                hit = pur_old_to_new.get(si["old_purchase_id"])
                if hit:
                    fk_table, fk_id = hit
            machine_fk = probe_fk = printer_fk = None
            if fk_table == "machines":
                machine_fk = fk_id
            elif fk_table == "probes":
                probe_fk = fk_id
            elif fk_table == "printers":
                printer_fk = fk_id
            # Explicit FK-duplicate guard (same item twice on one invoice)
            dup = False
            for col, val in (("machine_id", machine_fk),
                             ("probe_id", probe_fk),
                             ("printer_id", printer_fk)):
                if val is not None and db.execute(
                    f"SELECT 1 FROM sale_items WHERE sale_id = ? AND {col} = ?",
                    (sale_id, val),
                ).fetchone():
                    dup = True
                    break
            if dup:
                s["sale_items_dup_fk"] += 1
                continue
            try:
                db.execute(
                    """INSERT INTO sale_items
                       (sale_id, item_type, machine_id, probe_id, printer_id,
                        item_description, item_serial, item_price, is_main_item,
                        old_source_id, old_purchase_id)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (sale_id, si["item_type"], machine_fk, probe_fk, printer_fk,
                     si["item_description"], si["item_serial"], si["item_price"],
                     si["is_main_item"], si["old_source_id"], si["old_purchase_id"]),
                )
                s["sale_items_inserted"] += 1
            except sqlite3.IntegrityError:
                s["sale_items_skipped"] += 1

        # 12. Movements ────────────────────────────────────────────────────
        for mv in plan["movements"]:
            exists = db.execute(
                "SELECT id FROM movements WHERE old_source_id = ?", (mv["old_source_id"],)
            ).fetchone()
            if exists:
                s["movements_skipped"] += 1
                continue
            hit = pur_old_to_new.get(mv["purchase_old_id"])
            if not hit:
                s["movements_orphaned"] += 1
                continue
            fk_table, fk_id = hit
            machine_fk = probe_fk = printer_fk = part_fk = None
            if fk_table == "machines":
                machine_fk = fk_id
            elif fk_table == "probes":
                probe_fk = fk_id
            elif fk_table == "printers":
                printer_fk = fk_id
            else:
                part_fk = fk_id
            try:
                db.execute(
                    """INSERT INTO movements
                       (movement_type, movement_date, machine_id, probe_id,
                        printer_id, part_id, from_location, to_location,
                        reason, notes, old_source_id, created_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (mv["movement_type"], mv["movement_date"] or "1970-01-01",
                     machine_fk, probe_fk, printer_fk, part_fk,
                     mv["from_location"], mv["to_location"], mv["reason"],
                     mv["notes"], mv["old_source_id"], now),
                )
                s["movements_inserted"] += 1
            except sqlite3.IntegrityError:
                s["movements_skipped"] += 1

        # 13. Audit — recompute from actual DB state so force re-runs
        #     report cumulative totals, not just this run's delta.
        def _cnt(sql):
            return db.execute(sql).fetchone()[0]

        imported = (
            _cnt("SELECT COUNT(*) FROM brands WHERE old_source_id IS NOT NULL") +
            _cnt("SELECT COUNT(*) FROM catalog_products WHERE old_source_id IS NOT NULL") +
            _cnt("SELECT COUNT(*) FROM customers WHERE old_source_id IS NOT NULL") +
            _cnt("SELECT COUNT(*) FROM vendors WHERE old_source_id IS NOT NULL") +
            _cnt("SELECT COUNT(*) FROM batches WHERE notes LIKE 'Imported from old system%'") +
            _cnt("SELECT COUNT(*) FROM machines WHERE old_source_id IS NOT NULL") +
            _cnt("SELECT COUNT(*) FROM probes WHERE old_source_id IS NOT NULL") +
            _cnt("SELECT COUNT(*) FROM printers WHERE old_source_id IS NOT NULL") +
            _cnt("SELECT COUNT(*) FROM parts WHERE old_source_id IS NOT NULL") +
            _cnt("SELECT COUNT(*) FROM sales WHERE old_source_id IS NOT NULL") +
            _cnt("SELECT COUNT(*) FROM sale_items WHERE old_source_id IS NOT NULL") +
            _cnt("SELECT COUNT(*) FROM movements WHERE old_source_id IS NOT NULL")
        )
        rp = plan["report"]
        flagged = (rp["flagged_catalogue"] + rp["flagged_machines"] +
                   rp["flagged_probes"] + rp["flagged_printers"] +
                   rp["flagged_parts"] + rp["sales_missing_date"])
        planned = (len(plan["brands"]) + len(plan["catalogue"]) +
                   len(plan["customers"]) + len(plan["vendors"]) +
                   rp["batches_from_dates"] + len(plan["machines"]) +
                   len(plan["probes"]) + len(plan["printers"]) +
                   len(plan["parts"]) + len(plan["sales"]) +
                   len(plan["sale_items"]) + len(plan["movements"]))
        total = planned
        skipped = max(planned - imported, 0)
        note = (
            f"Stage 3 migration (wises): brands, catalogue, customers, vendors, "
            f"batches, machines, probes, printers, parts, sales, sale_items, movements. "
            f"Skipped-by-design: CMS/website tables. "
            f"Skipped duplicates/failed: {skipped}."
        )
        existing = db.execute(
            "SELECT id FROM imports WHERE batch_code = ?", (IMPORT_BATCH_CODE,)
        ).fetchone()
        if existing:
            db.execute(
                """UPDATE imports SET records_total = ?, records_inserted = ?,
                   records_skipped = ?, records_flagged = ?, imported_at = ?, notes = ?
                   WHERE id = ?""",
                (total, imported, skipped, flagged, now, note, existing["id"]),
            )
        else:
            db.execute(
                """INSERT INTO imports
                   (batch_code, source_filename, source_type, imported_at,
                    records_total, records_inserted, records_skipped,
                    records_flagged, notes)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (IMPORT_BATCH_CODE, SQL_FILE.name, "SQL", now,
                 total, imported, skipped, flagged, note),
            )

        db.commit()
    except Exception:
        db.rollback()
        db.close()
        raise
    db.close()
    return s


# ══════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════

def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description="Stage 3 Data Migration (wises)")
    parser.add_argument("--preview", action="store_true", help="Show what would be imported")
    parser.add_argument("--execute", action="store_true", help="Actually import the data")
    parser.add_argument("--force", action="store_true", help="Re-run even if already done")
    parser.add_argument("--pdf", action="store_true", help="Cross-validate catalogue vs WISE-TECH.pdf")
    args = parser.parse_args()

    if not args.preview and not args.execute:
        print("Usage: migrate_old_data.py --preview | --execute [--force] [--pdf]")
        sys.exit(1)
    if not SQL_FILE.exists():
        print(f"ERROR: SQL file not found: {SQL_FILE}")
        sys.exit(1)
    if not DB_FILE.exists():
        print(f"ERROR: Database not found: {DB_FILE}")
        print("       Start the Flask app first to initialize the database.")
        sys.exit(1)

    content = read_sql()
    print("Building migration plan (wises section only)…")
    plan = build_plan(content)
    r = plan["report"]
    print("\nExtraction complete:")
    print(f"  Brands     : {r['brands']}")
    print(f"  Catalogue  : {r['catalogue']} (from {r['catalogue_raw']}, dedup -{r['catalogue_dedup']})")
    print(f"  Customers  : {r['customers']} (+{r['customers_branch_skipped']} branch skipped)")
    print(f"  Vendors    : {r['vendors']}")
    print(f"  Machines   : {r['machines']}")
    print(f"  Probes     : {r['probes']}")
    print(f"  Printers   : {r['printers']}")
    print(f"  Parts      : {r['parts']}")
    print(f"  Sales      : {r['sales']}  SaleItems: {r['sale_items']}")
    print(f"  Movements  : {r['movements']}")

    if args.preview:
        show_preview(plan)

    if args.pdf:
        ok = validate_pdf(plan)
        if not ok and args.execute:
            print("\nERROR: PDF cross-validation failed — aborting --execute.")
            sys.exit(2)

    if args.execute:
        if not args.force:
            db = sqlite3.connect(DB_FILE)
            existing = db.execute(
                "SELECT id FROM imports WHERE batch_code = ?", (IMPORT_BATCH_CODE,)
            ).fetchone()
            db.close()
            if existing:
                print(f"\nImport '{IMPORT_BATCH_CODE}' already exists in audit log.")
                print("Use --force to re-run (existing rows are skipped, not overwritten).")
                sys.exit(0)
        print(f"\nExecuting migration into: {DB_FILE}")
        stats = execute_migration(plan)
        print("\nMigration complete!")
        order = [
            "brands", "catalogue", "customers", "vendors", "batches",
            "machines", "probes", "printers", "parts",
            "sales", "sale_items", "movements",
        ]
        for name in order:
            ins = stats.get(f"{name}_inserted", 0)
            skp = stats.get(f"{name}_skipped", 0)
            flg = stats.get(f"{name}_flagged", 0)
            err = stats.get(f"{name}_error", 0)
            line = f"  {name:<13} inserted: {ins:<6} skipped: {skp:<6}"
            if flg:
                line += f" flagged: {flg}"
            if err:
                line += f" ERROR: {err}"
            print(line)
        if stats.get("probe_parents_linked"):
            print(f"  probe/printer parent links created: {stats['probe_parents_linked']}")
        if stats.get("sale_items_no_sale"):
            print(f"  sale items without matching sale  : {stats['sale_items_no_sale']}")
        if stats.get("sale_items_dup_fk"):
            print(f"  duplicate sale+item rows skipped  : {stats['sale_items_dup_fk']}")


if __name__ == "__main__":
    main()
