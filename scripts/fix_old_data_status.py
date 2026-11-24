#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fix_old_data_status.py
Fixes BATCH-OLD item statuses in Supabase based on localhost (3).sql.

Rules:
  - sold=1 in old SQL  -> status='Sold'  (machines, probes, printers)
  - sold=0 machine, not in Workshop/Basement/Branch -> status='Missing' + Missing flag
  - sold=0 probe/printer -> keep in inventory tab (no change needed)
  - Probes/printers with m_sr matching a non-Missing machine -> attach to it
  - BATCH-T, BATCH-U, BATCH-LOCAL items -> NOT TOUCHED
  - Movements -> NOT TOUCHED

Usage:
  python scripts/fix_old_data_status.py --preview
  python scripts/fix_old_data_status.py --execute
"""

import argparse
import re
import sys
from pathlib import Path

import requests
import psycopg2

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SQL_FILE = PROJECT_ROOT / "localhost (3).sql"

env = {}
env_file = PROJECT_ROOT / ".env"
if env_file.exists():
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()

SUPABASE_URL = env.get("SUPABASE_URL", "")
SERVICE_KEY = env.get("SUPABASE_SERVICE_ROLE_KEY", "")
HEADERS = {
    "apikey": SERVICE_KEY,
    "Authorization": "Bearer " + SERVICE_KEY,
    "Content-Type": "application/json",
    "Prefer": "return=minimal",
}

KOLD_BATCH_ID = 30

PLACEHOLDER_VALUES = {"", "-", "None", "NILL", "NIL", "0", "NULL", "none"}
BRANCH_KEYWORDS = ["LAHORE"]
WORKSHOP_KEYWORDS = ["WORKSHOP"]
BASEMENT_KEYWORDS = ["BASEMENT"]


def _clean(s):
    if s is None:
        return None
    s = str(s).strip().rstrip("\t")
    if s in PLACEHOLDER_VALUES:
        return None
    return s or None


def _parse_cell(raw):
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
    return raw


def _split_value_rows(block):
    rows = []
    depth = 0
    in_string = False
    escape_next = False
    cells = []
    cell_start = None
    i = 0
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
                cells = []
                cell_start = i + 1
        elif ch == ")":
            depth -= 1
            if depth == 0 and cell_start is not None:
                cells.append(_parse_cell(block[cell_start:i]))
                rows.append(cells)
                cells = []
                cell_start = None
        elif ch == "," and depth == 1:
            cells.append(_parse_cell(block[cell_start:i]))
            cell_start = i + 1
        i += 1
    return rows


def parse_rows(content, table):
    pattern = re.compile(
        r"INSERT INTO `" + re.escape(table) + r"`.+?VALUES\s*\n?(.+?)(?=;\s*(?:\n|$))",
        re.DOTALL,
    )
    all_rows = []
    for m in pattern.finditer(content):
        all_rows.extend(_split_value_rows(m.group(1)))
    return all_rows


def get_db_section(content, db_name):
    uses = [m.start() for m in re.finditer(r"USE `" + re.escape(db_name) + r"`", content)]
    if not uses:
        return content
    start = uses[0]
    rest = content[start + 1:]
    next_uses = [m.start() for m in re.finditer(r"USE `\w+`", rest)]
    if next_uses:
        return content[start: start + 1 + next_uses[0]]
    return content[start:]


def fetch_all(table, params):
    page_size = 1000
    all_rows = []
    offset = 0
    while True:
        url = SUPABASE_URL + "/rest/v1/" + table + "?" + params + "&limit=" + str(page_size) + "&offset=" + str(offset)
        r = requests.get(url, headers=HEADERS)
        r.raise_for_status()
        rows = r.json()
        all_rows.extend(rows)
        if len(rows) < page_size:
            break
        offset += page_size
    return all_rows


def patch(table, item_id, data):
    url = SUPABASE_URL + "/rest/v1/" + table + "?id=eq." + str(item_id)
    r = requests.patch(url, headers=HEADERS, json=data)
    r.raise_for_status()


def get_pg_conn():
    return psycopg2.connect(
        host=env.get("SUPABASE_DB_HOST", ""),
        port=int(env.get("SUPABASE_DB_PORT", 5432)),
        dbname=env.get("SUPABASE_DB_NAME", "postgres"),
        user=env.get("SUPABASE_DB_USER", "postgres"),
        password=env.get("SUPABASE_DB_PASSWORD", ""),
        sslmode="require",
    )


def pg_update_status_batch(table, ids, status):
    """Update status for a list of ids using direct Postgres connection."""
    if not ids:
        return 0
    conn = get_pg_conn()
    try:
        cur = conn.cursor()
        cur.execute(
            "UPDATE " + table + " SET status = %s WHERE id = ANY(%s)",
            (status, ids)
        )
        count = cur.rowcount
        conn.commit()
        return count
    finally:
        conn.close()


def add_flag(item_kind, item_id):
    url = SUPABASE_URL + "/rest/v1/flags"
    r = requests.post(url, headers=HEADERS, json={
        "item_kind": item_kind,
        "item_id": item_id,
        "color": "#E53935",
        "note": "Missing",
    })
    r.raise_for_status()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--preview", action="store_true")
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()

    if not args.preview and not args.execute:
        print("Usage: python scripts/fix_old_data_status.py --preview | --execute")
        sys.exit(1)

    if not SQL_FILE.exists():
        print("ERROR: SQL file not found: " + str(SQL_FILE))
        sys.exit(1)

    print("Reading SQL: " + str(SQL_FILE))
    content = SQL_FILE.read_text(encoding="latin-1", errors="replace")

    section = get_db_section(content, "gvjxvqtv_asen")
    print("  SQL section length: " + str(len(section)) + " chars")

    purchases = parse_rows(section, "purchases")
    print("  Purchases rows: " + str(len(purchases)))

    # columns: 0=id 1=location 2=catalogue_id 3=status 4=serial 5=m_sr
    #          6=arrival 7=issue 8=show_web 9=vendors 10=year 11=sold
    old_data = {}
    for r in purchases:
        if len(r) < 12:
            continue
        try:
            old_id = int(str(r[0]).strip())
        except (ValueError, TypeError):
            continue
        loc = (_clean(r[1]) or "").strip().upper()
        serial = _clean(r[4])
        m_sr = _clean(r[5])
        sold = str(r[11]).strip() == "1"
        old_data[old_id] = {"location": loc, "serial": serial, "m_sr": m_sr, "sold": sold}

    sold_count = sum(1 for v in old_data.values() if v["sold"])
    print("  Parsed: " + str(len(old_data)) + " rows, sold=" + str(sold_count))

    print("\nFetching BATCH-OLD items from Supabase...")
    machines = fetch_all("machines",
        "batch_id=eq." + str(KOLD_BATCH_ID) +
        "&select=id,machine_id,serial_number,status,current_location,old_source_id")
    probes = fetch_all("probes",
        "batch_id=eq." + str(KOLD_BATCH_ID) +
        "&select=id,internal_id,serial_number,status,current_location,old_source_id,assigned_machine_id")
    printers = fetch_all("printers",
        "batch_id=eq." + str(KOLD_BATCH_ID) +
        "&select=id,internal_id,serial_number,status,current_location,old_source_id,assigned_machine_id")
    print("  Machines: " + str(len(machines)))
    print("  Probes:   " + str(len(probes)))
    print("  Printers: " + str(len(printers)))

    print("Fetching existing Missing flags...")
    existing_flags = fetch_all("flags", "note=eq.Missing&select=id,item_kind,item_id")
    already_missing = {(f["item_kind"], f["item_id"]) for f in existing_flags}
    print("  Existing Missing flags: " + str(len(already_missing)))

    # machine serial -> supabase id
    machine_by_serial = {}
    for m in machines:
        sn = (m.get("serial_number") or "").strip().upper()
        if sn:
            machine_by_serial[sn] = m["id"]

    # Classify machines
    to_sold_m = []
    to_missing_m = []
    for m in machines:
        old_id = m.get("old_source_id")
        if old_id is None:
            continue
        old = old_data.get(int(old_id))
        if old is None:
            continue
        cur = m.get("status", "")
        loc = old["location"]
        if old["sold"]:
            if cur != "Sold":
                to_sold_m.append(m)
        else:
            is_branch = any(k in loc for k in BRANCH_KEYWORDS)
            is_workshop = any(k in loc for k in WORKSHOP_KEYWORDS)
            is_basement = any(k in loc for k in BASEMENT_KEYWORDS)
            if not (is_branch or is_workshop or is_basement):
                if cur != "Missing":
                    to_missing_m.append(m)

    # Classify probes/printers (sold only)
    to_sold_p = []
    for p in probes:
        old_id = p.get("old_source_id")
        if old_id is None:
            continue
        old = old_data.get(int(old_id))
        if old and old["sold"] and p.get("status") != "Sold":
            to_sold_p.append(p)

    to_sold_pr = []
    for p in printers:
        old_id = p.get("old_source_id")
        if old_id is None:
            continue
        old = old_data.get(int(old_id))
        if old and old["sold"] and p.get("status") != "Sold":
            to_sold_pr.append(p)

    # Attachments: probes/printers whose m_sr matches a non-Missing machine
    missing_ids = {m["id"] for m in to_missing_m}
    for m in machines:
        if m.get("status") == "Missing":
            missing_ids.add(m["id"])

    probe_attach = []
    for p in probes:
        old_id = p.get("old_source_id")
        if old_id is None or p.get("assigned_machine_id") is not None:
            continue
        old = old_data.get(int(old_id))
        if old is None or old["sold"]:
            continue
        m_sr = (old.get("m_sr") or "").strip().upper()
        own_sr = (old.get("serial") or "").strip().upper()
        if not m_sr or m_sr == own_sr:
            continue
        mid = machine_by_serial.get(m_sr)
        if mid and mid not in missing_ids:
            probe_attach.append((p["id"], mid))

    printer_attach = []
    for p in printers:
        old_id = p.get("old_source_id")
        if old_id is None or p.get("assigned_machine_id") is not None:
            continue
        old = old_data.get(int(old_id))
        if old is None or old["sold"]:
            continue
        m_sr = (old.get("m_sr") or "").strip().upper()
        own_sr = (old.get("serial") or "").strip().upper()
        if not m_sr or m_sr == own_sr:
            continue
        mid = machine_by_serial.get(m_sr)
        if mid and mid not in missing_ids:
            printer_attach.append((p["id"], mid))

    flags_to_add = [
        m for m in to_missing_m
        if ("machine", m["id"]) not in already_missing
    ]

    print("\n=== CHANGES NEEDED ===")
    print("  Machines -> Sold:     " + str(len(to_sold_m)))
    print("  Machines -> Missing:  " + str(len(to_missing_m)))
    print("  Probes   -> Sold:     " + str(len(to_sold_p)))
    print("  Printers -> Sold:     " + str(len(to_sold_pr)))
    print("  Probe attachments:    " + str(len(probe_attach)))
    print("  Printer attachments:  " + str(len(printer_attach)))
    print("  Missing flags to add: " + str(len(flags_to_add)))

    if args.preview:
        print("\nSample machines -> Sold:")
        for m in to_sold_m[:5]:
            print("  id=" + str(m["id"]) + " " + str(m.get("machine_id")) +
                  " serial=" + str(m.get("serial_number")))
        print("\nSample machines -> Missing:")
        for m in to_missing_m[:5]:
            old = old_data.get(int(m.get("old_source_id", 0) or 0))
            print("  id=" + str(m["id"]) + " " + str(m.get("machine_id")) +
                  " old_loc=" + (old["location"] if old else "?"))
        print("\nSample probe attachments:")
        for pid, mid in probe_attach[:5]:
            print("  probe_id=" + str(pid) + " -> machine_id=" + str(mid))
        return

    # Execute
    print("\nExecuting...")

    # Use direct Postgres for machine status (bypasses RLS)
    sold_ids = [m["id"] for m in to_sold_m]
    ok = pg_update_status_batch("machines", sold_ids, "Sold")
    print("  Machines -> Sold: " + str(ok) + "/" + str(len(to_sold_m)))

    missing_ids_list = [m["id"] for m in to_missing_m]
    ok = pg_update_status_batch("machines", missing_ids_list, "Missing")
    print("  Machines -> Missing: " + str(ok) + "/" + str(len(to_missing_m)))

    ok = 0
    for m in flags_to_add:
        try:
            add_flag("machine", m["id"])
            ok += 1
        except Exception as e:
            print("  ERROR flag machine " + str(m["id"]) + ": " + str(e))
    print("  Missing flags added: " + str(ok) + "/" + str(len(flags_to_add)))

    ok = 0
    for p in to_sold_p:
        try:
            patch("probes", p["id"], {"status": "Sold"})
            ok += 1
        except Exception as e:
            print("  ERROR probe " + str(p["id"]) + " sold: " + str(e))
    print("  Probes -> Sold: " + str(ok) + "/" + str(len(to_sold_p)))

    ok = 0
    for p in to_sold_pr:
        try:
            patch("printers", p["id"], {"status": "Sold"})
            ok += 1
        except Exception as e:
            print("  ERROR printer " + str(p["id"]) + " sold: " + str(e))
    print("  Printers -> Sold: " + str(ok) + "/" + str(len(to_sold_pr)))

    ok = 0
    for probe_id, machine_id in probe_attach:
        try:
            patch("probes", probe_id, {"assigned_machine_id": machine_id, "status": "With Machine"})
            ok += 1
        except Exception as e:
            print("  ERROR attach probe " + str(probe_id) + ": " + str(e))
    print("  Probes attached: " + str(ok) + "/" + str(len(probe_attach)))

    ok = 0
    for printer_id, machine_id in printer_attach:
        try:
            patch("printers", printer_id, {"assigned_machine_id": machine_id, "status": "With Machine"})
            ok += 1
        except Exception as e:
            print("  ERROR attach printer " + str(printer_id) + ": " + str(e))
    print("  Printers attached: " + str(ok) + "/" + str(len(printer_attach)))

    print("\nDone.")


if __name__ == "__main__":
    main()
