"""Repair old-sale links: attach every sale_item to its real invoice.

The original import_asen.py matched sale_temp_inv lines to sale_inv invoices
by purchase_id (and via a reversed dict), so nearly every line landed on a
fake 'Imported legacy line (no invoice).' sale while the real invoices
(date + customer + trno) stayed empty. This script fixes that in place:

  * inserts the 4 invoices skipped for unknown customers,
  * relinks every imported sale_item to the sale whose old_trno matches
    the line's dump trno (per source: wises offset 0, asen offset 1M),
  * groups leftover lines (trno with no invoice row) under one synthetic
    sale per trno, dated from the line's purchase_date when known,
  * fills undated real invoices from their main line's purchase_date,
  * deletes fake sales that no longer hold any items.

Only rows with old_source_id IS NULL are off-limits: current-side sales
are never touched.

Usage:  python scripts/fix_sale_links.py           # apply
        python scripts/fix_sale_links.py --dry-run  # print the plan
"""
import argparse
import datetime
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from import_legacy import ROOT, legacy_date, load_env, parse_dump  # noqa: E402

DUMP = ROOT / 'localhost (3).sql'
ASEN_OFFSET = 1_000_000
ORPHAN_BASE = 9_000_000
FAKE_NOTE = 'Imported legacy line (no invoice).'
SYNTH_NOTE = 'Imported legacy sale (no invoice row).'
UNKNOWN_NOTE = 'Unknown legacy customer (id {cid}).'


def table_rows(src, name):
    t = src.get(name, {'cols': [], 'rows': []})
    return [{c: r[i] for i, c in enumerate(t['cols'])} for r in t['rows']]


def num(value):
    v = (value or '0').strip()
    try:
        return float(v)
    except ValueError:
        return None


def iso_or_dump_date(value):
    """purchase_date is dd-mm-yyyy in the dump; keep ISO for sale_date."""
    v = (value or '').strip()
    if not v or v == '-':
        return None
    d = legacy_date(v)
    if d:
        return d.isoformat()
    # already ISO?
    try:
        datetime.date.fromisoformat(v)
        return v
    except ValueError:
        return None


def bulk_update_sale_items(cur, updates):
    """Batch UPDATE sale_items.sale_id. executemany round-trips die on this
    pool (minutes per thousand rows), so send one UPDATE per ~1000 pairs."""
    if not updates:
        return
    chunk = 1000
    for i in range(0, len(updates), chunk):
        part = updates[i:i + chunk]
        values = ','.join(['(%s, %s)'] * len(part))
        cur.execute(
            'UPDATE sale_items si SET sale_id = v.new_sale_id '
            'FROM (VALUES ' + values + ') AS v(new_sale_id, id) '
            'WHERE si.id = v.id',
            [v for pair in part for v in pair])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    if not DUMP.exists():
        sys.exit(f'dump not found: {DUMP}')

    dumps = parse_dump(DUMP)
    env = load_env(ROOT / '.env')
    import psycopg2
    conn = psycopg2.connect(
        host=env['SUPABASE_DB_HOST'],
        port=int(env.get('SUPABASE_DB_PORT', '5432')),
        dbname=env.get('SUPABASE_DB_NAME', 'postgres'),
        user=env['SUPABASE_DB_USER'],
        password=env['SUPABASE_DB_PASSWORD'],
        sslmode='require',
        connect_timeout=20,
    )
    cur = conn.cursor()

    # ---------------------------------------------------- dump side maps
    # source -> {line_old_id: trno} and source -> {trno: invoice_old_id}
    line_trno = {'w': {}, 'a': {}}
    line_pdate = {'w': {}, 'a': {}}
    inv_by_trno = {'w': {}, 'a': {}}
    missing_invoices = []  # (source, invoice row dict)
    for src_key, db_name, label in (('w', 'gvjxvqtv_wises', 0),
                                    ('a', 'gvjxvqtv_asen', ASEN_OFFSET)):
        src = dumps.get(db_name, {})
        cust_ids = {int(c['id']) for c in table_rows(src, 'customer')}
        for s in table_rows(src, 'sale_inv'):
            trno = (s.get('trno') or '').strip()
            cid = (s.get('customer') or '').strip()
            if trno and trno != '0':
                # only claim the trno when unambiguous
                inv_by_trno[src_key].setdefault(trno, int(s['id']))
            if cid.isdigit() and int(cid) not in cust_ids:
                missing_invoices.append((src_key, label, s))
        for ln in table_rows(src, 'sale_temp_inv'):
            lid = int(ln['id'])
            line_trno[src_key][lid] = (ln.get('trno') or '').strip()
            line_pdate[src_key][lid] = iso_or_dump_date(ln.get('purchase_date'))
    print(f'dump: {sum(len(v) for v in line_trno.values())} lines, '
          f'{sum(len(v) for v in inv_by_trno.values())} trnos, '
          f'{len(missing_invoices)} invoices missing their customer')

    # ---------------------------------------------------------- db state
    cur.execute("""
        SELECT id, old_source_id, old_trno, notes, sale_date
        FROM sales WHERE old_source_id IS NOT NULL""")
    db_sales = cur.fetchall()  # id, oid, trno, notes, date
    real_sales = []       # (id, src, trno)
    fake_ids = []
    for sid, oid, trno, notes, date in db_sales:
        if notes == FAKE_NOTE:
            fake_ids.append(sid)
            continue
        src = 'a' if oid >= ASEN_OFFSET and oid < ORPHAN_BASE else 'w'
        real_sales.append((sid, src, (trno or '').strip()))
    print(f'db: {len(db_sales)} imported sales '
          f'({len(real_sales)} real, {len(fake_ids)} fake)')

    # (source, trno) -> sale id for real invoices with a trno
    real_by_trno = {}
    for sid, src, trno in real_sales:
        if trno and trno != '0':
            real_by_trno.setdefault((src, trno), sid)

    # -------------------------------------------- insert missing invoices
    new_sales = []  # (old_source_id, trno) -> new sale id
    if not args.dry_run and missing_invoices:
        pend = []
        meta = []
        for src_key, label, s in missing_invoices:
            trno = (s.get('trno') or '').strip() or None
            date = (s.get('date') or '').strip() or '0001-01-01'
            cid = (s.get('customer') or '').strip()
            pend.append((None, date, num(s.get('price')),
                         UNKNOWN_NOTE.format(cid=cid),
                         int(s['id']) + label, trno))
            meta.append((src_key, trno, int(s['id']) + label))
        cur.executemany(
            'INSERT INTO sales (customer_id, sale_date, sale_price, notes, '
            'old_source_id, old_trno) VALUES (%s, %s, %s, %s, %s, %s)',
            pend)
        for (src_key, trno, oid) in meta:
            cur.execute('SELECT id FROM sales WHERE old_source_id = %s', (oid,))
            new_id = cur.fetchone()[0]
            if trno:
                real_by_trno.setdefault((src_key, trno), new_id)
        print(f'inserted {len(pend)} invoices whose customer was missing')

    # ------------------------------------------- relink items by dump trno
    cur.execute("""
        SELECT si.id, si.sale_id, si.old_source_id
        FROM sale_items si WHERE si.old_source_id IS NOT NULL""")
    items = cur.fetchall()
    updates = []          # (new_sale_id, item_id)
    unmatched = {}        # (src, trno) -> [item ids]
    line_missing = 0
    still_same = 0
    for item_id, sale_id, oid in items:
        if oid >= ORPHAN_BASE:
            src, lid = ('a' if oid >= ORPHAN_BASE + ASEN_OFFSET else 'w',
                        oid - ORPHAN_BASE - (ASEN_OFFSET if oid >= ORPHAN_BASE + ASEN_OFFSET else 0))
        else:
            src = 'a' if oid >= ASEN_OFFSET else 'w'
            lid = oid - (ASEN_OFFSET if src == 'a' else 0)
        trno = line_trno[src].get(lid)
        if trno is None:
            line_missing += 1
            continue
        target = real_by_trno.get((src, trno)) if trno and trno != '0' else None
        if target is not None:
            if target != sale_id:
                updates.append((target, item_id))
            else:
                still_same += 1
        else:
            key = (src, trno or '')
            unmatched.setdefault(key, []).append(item_id)
    print(f'items: {len(items)} total, {len(updates)} to relink, '
          f'{still_same} already correct, {len(unmatched)} trno groups unmatched, '
          f'{line_missing} line rows missing from dump')

    # ------------------------- synthetic sales for trnos without an invoice
    synth = []  # (old_source_id, trno, sale_date) -> filled after insert
    synth_keys = sorted(unmatched.keys(),
                        key=lambda k: (k[0], int(k[1]) if k[1].isdigit() else 0))
    next_oid = { 'w': ORPHAN_BASE, 'a': ORPHAN_BASE + ASEN_OFFSET }
    synth_plan = []  # (src, trno, item_ids, sale_date, old_source_id)
    for src, trno in synth_keys:
        ids = unmatched[(src, trno)]
        # best date from the group's dump lines
        best = _best_date_for_group(src, trno, line_trno, line_pdate, items)
        synth_plan.append((src, trno, ids, best, next_oid[src]))
        next_oid[src] += 1

    if not args.dry_run and synth_plan:
        pend = [(None, plan[3] or '0001-01-01', None, SYNTH_NOTE,
                 plan[4], plan[1] or None) for plan in synth_plan]
        cur.executemany(
            'INSERT INTO sales (customer_id, sale_date, sale_price, notes, '
            'old_source_id, old_trno) VALUES (%s, %s, %s, %s, %s, %s)',
            pend)
        for plan, row in zip(synth_plan, pend):
            cur.execute('SELECT id FROM sales WHERE old_source_id = %s',
                        (row[4],))
            new_id = cur.fetchone()[0]
            for item_id in plan[2]:
                updates.append((new_id, item_id))
        print(f'created {len(pend)} synthetic sales for unmatched trnos')

    # ------------------------- undated real invoices: date from main line
    date_fixes = []
    if not args.dry_run:
        cur.execute("""
            SELECT s.id, s.old_source_id, min(si.old_source_id) AS min_oid
            FROM sales s JOIN sale_items si ON si.sale_id = s.id
            WHERE s.old_source_id IS NOT NULL AND s.sale_date <= '0010'
            GROUP BY s.id, s.old_source_id""")
        for sid, oid, min_oid in cur.fetchall():
            src = 'a' if (min_oid or 0) >= ASEN_OFFSET and (min_oid or 0) < ORPHAN_BASE else 'w'
            lid = (min_oid or 0) - (ASEN_OFFSET if src == 'a' else 0)
            if (min_oid or 0) >= ORPHAN_BASE:
                continue
            pdate = line_pdate[src].get(lid)
            if pdate:
                date_fixes.append((pdate, sid))
        if date_fixes:
            chunk = 1000
            for i in range(0, len(date_fixes), chunk):
                part = date_fixes[i:i + chunk]
                values = ','.join(['(%s, %s)'] * len(part))
                cur.execute(
                    'UPDATE sales s SET sale_date = v.d '
                    'FROM (VALUES ' + values + ') AS v(d, id) '
                    'WHERE s.id = v.id',
                    [v for pair in part for v in pair])
        print(f'dated {len(date_fixes)} undated invoices from line purchase_date')

    # ------------------------------------------------- apply item relinks
    if not args.dry_run and updates:
        bulk_update_sale_items(cur, updates)

    # ------------------------------------------ delete emptied fake sales
    deleted = 0
    if not args.dry_run:
        cur.execute(f"""
            DELETE FROM sales s
            WHERE s.notes = %s
              AND NOT EXISTS (SELECT 1 FROM sale_items si WHERE si.sale_id = s.id)""",
                    (FAKE_NOTE,))
        deleted = cur.rowcount
        print(f'deleted {deleted} empty fake sales')

    # ------------------------------------------------------------ verify
    cur.execute('SELECT count(*) FROM sales WHERE old_source_id IS NOT NULL')
    total = cur.fetchone()[0]
    cur.execute("""
        SELECT count(*) FROM sales s
        WHERE s.old_source_id IS NOT NULL
          AND EXISTS (SELECT 1 FROM sale_items si WHERE si.sale_id = s.id)""")
    with_items = cur.fetchone()[0]
    cur.execute("""
        SELECT count(*) FROM sale_items si JOIN sales s ON s.id = si.sale_id
        WHERE si.old_source_id IS NOT NULL AND s.notes = %s""", (FAKE_NOTE,))
    on_fake = cur.fetchone()[0]
    print(f'\nresult: {total} imported sales, {with_items} with items, '
          f'{on_fake} items still on fake sales')
    cur.execute("""
        SELECT s.old_trno, s.sale_date, count(si.id)
        FROM sales s JOIN sale_items si ON si.sale_id = s.id
        WHERE s.old_trno = '12895484'
        GROUP BY s.id, s.old_trno, s.sale_date""")
    print('spot check trno 12895484:', cur.fetchall())

    if args.dry_run:
        conn.rollback()
        print('\nDRY RUN - nothing written')
    else:
        conn.commit()
        print('committed')
    conn.close()


def _best_date_for_group(src, trno, line_trno, line_pdate, items):
    """Earliest known purchase_date among the group's dump lines."""
    best = None
    for _item_id, _sale_id, oid in items:
        if oid >= ORPHAN_BASE:
            continue
        s = 'a' if oid >= ASEN_OFFSET else 'w'
        if s != src:
            continue
        lid = oid - (ASEN_OFFSET if s == 'a' else 0)
        if line_trno[s].get(lid) != trno:
            continue
        d = line_pdate[s].get(lid)
        if d and (best is None or d < best):
            best = d
    return best


if __name__ == '__main__':
    main()
