"""Import the OLD legacy data (asen system + leftover wises stock) into Supabase.

Source : localhost (3).sql  (MySQL databases `gvjxvqtv_asen` + `gvjxvqtv_wises`)
Target : the Supabase project configured in .env

The app already holds the "after 14-09-2026" world (BATCH-3 machines +
BATCH-PARTS). This script adds the "before" world, keeping the two eras
separate through one new batch:

  BATCH-OLD  (letter NULL)  <- every inventory row imported here

What gets imported:
  * wises purchases NOT already imported (the pre-cutoff stock, sold and
    unsold)                         -> machines/probes/printers, batch BATCH-OLD
  * every asen purchase (2020-2022) -> machines/probes/printers, batch BATCH-OLD
  * asen + wises brands/vendors/customers/dealers/catalogue rows missing in
    the app (merged by name / old_source_id)
  * asen + wises sales + sale lines -> sales / sale_items
  * asen + wises events             -> movements (movement_type = 'Legacy')
  * cash / emails / website tables  -> NOT imported (not relevant to the app)

Conventions:
  * wises rows keep their natural legacy id in old_source_id (same scheme as
    import_legacy.py, so nothing is double-imported).
  * asen ids collide with wises ids, so every asen old_source_id is stored as
    id + 1_000_000 (inventory, sales, sale_items, movements, parties...).
  * machine codes: wises M-01234, asen A-00319 (both below the app's
    next_machine_code() range which starts at 10000).
  * dealer/branch sales cannot use sales.customer_id (it only references the
    customers table), so they carry a machine readable first line in notes:
        party:dealer:NAME   /   party:branch:NAME   /   party:customer:NAME
    The app parses this prefix to show sales under the right Records tab.

Usage:
  python scripts/import_asen.py            # run the import
  python scripts/import_asen.py --dry-run  # print the plan, change nothing
"""
import argparse
import datetime
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from import_legacy import (  # noqa: E402
    PROBE_TYPES, display_date, legacy_date, load_env, map_condition,
    parse_dump, product_category,
)

ROOT = Path(__file__).resolve().parent.parent
DUMP = ROOT / 'localhost (3).sql'
ASEN_DB = 'gvjxvqtv_asen'
WISES_DB = 'gvjxvqtv_wises'

BATCH_OLD = 'BATCH-OLD'
ASEN_OFFSET = 1_000_000
# Synthetic invoice ids for sale lines whose purchase has no invoice. Far above
# any real id in either database so they can never collide with a real sale.
ORPHAN_OFFSET = 9_000_000
UNDATED_CREATED = datetime.datetime(2019, 1, 1)


def asen_oid(old_id):
    return int(old_id) + ASEN_OFFSET


def bulk_insert(cur, sql, rows, cols=6):
    """Multi-row INSERT. executemany takes minutes per thousand rows on this
    pool (and dies mid-batch), so send one VALUES list per ~1000 rows."""
    if not rows:
        return
    sql = sql.rstrip()
    if sql.endswith(') VALUES %s'):
        sql = sql[:-len(' VALUES %s')]
    chunk = 1000
    for i in range(0, len(rows), chunk):
        part = rows[i:i + chunk]
        placeholders = ','.join(['(' + ','.join(['%s'] * cols) + ')'] * len(part))
        cur.execute(sql + ' VALUES ' + placeholders,
                    [v for r in part for v in r])


def num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def build_products(src):
    """catalogue id -> product dict (same mapping as import_legacy)."""
    t = src.get('catalogue', {'cols': [], 'rows': []})
    brands_t = src.get('brands', {'cols': [], 'rows': []})
    brand_name = {}
    if brands_t['rows']:
        bi, ni = brands_t['cols'].index('id'), brands_t['cols'].index('name')
        brand_name = {r[bi]: (r[ni] or '').strip() for r in brands_t['rows']}
    ci = {c: i for i, c in enumerate(t['cols'])}
    products = {}
    for r in t['rows']:
        p_type = (r[ci['type']] or '').strip()
        product_type = (r[ci['product_type']] or '').strip()
        category = product_category(p_type, product_type)
        brand_raw = (r[ci['brand']] or '').strip()
        meta = []
        if product_type:
            meta.append(f'legacy_product_type={product_type}')
        for key in ('image', 'url', 'spec'):
            val = (r[ci[key]] or '').strip()
            if val:
                meta.append(f'{key}={val}')
        products[int(r[ci['id']])] = {
            'name_model': (r[ci['model']] or '').strip(),
            'category': category,
            'old_brand': int(brand_raw) if brand_raw.isdigit() else None,
            'brand_name': brand_name.get(int(brand_raw)) if brand_raw.isdigit() else None,
            'probe_type': PROBE_TYPES.get(product_type) if category == 'Probe' else None,
            'source_info': '; '.join(meta) or None,
        }
    return products


def table_rows(src, name):
    t = src.get(name, {'cols': [], 'rows': []})
    return [{c: r[i] for i, c in enumerate(t['cols'])} for r in t['rows']]


def parse_event(details):
    """Return (from_location, to_location) for a legacy event note."""
    d = (details or '').strip()
    if not d:
        return None, None
    m = re.search(r'(?i)was at (.+?) and now transferred to (.+?)\.?\s*$', d)
    if m:
        return m.group(1).strip(), m.group(2).strip()
    m = re.search(r'(?i)previously attached to (.+?) and now attached to (.+?)(?:\.|$)', d)
    if m:
        a, b = m.group(1).strip(), m.group(2).strip()
        return a, (f'attached to {b}' if a != b else 'attachment updated')
    return None, d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    if not DUMP.exists():
        sys.exit(f'dump not found: {DUMP}')

    env = load_env(ROOT / '.env')
    dsn = {
        'host': env.get('SUPABASE_DB_HOST'),
        'port': int(env.get('SUPABASE_DB_PORT', '5432')),
        'dbname': env.get('SUPABASE_DB_NAME', 'postgres'),
        'user': env.get('SUPABASE_DB_USER'),
        'password': env.get('SUPABASE_DB_PASSWORD'),
        'sslmode': 'require',
        'connect_timeout': 20,
    }
    if not all(dsn[k] for k in ('host', 'user', 'password')):
        sys.exit('SUPABASE_DB_HOST / SUPABASE_DB_USER / SUPABASE_DB_PASSWORD missing from .env')

    print(f'reading {DUMP.name} ...')
    data = parse_dump(DUMP)
    for name in (ASEN_DB, WISES_DB):
        if name not in data:
            sys.exit(f'database {name} not found in dump')
    asen, wises = data[ASEN_DB], data[WISES_DB]

    # ---------------------------------------------------------------- plan
    a_products = build_products(asen)
    w_products = build_products(wises)

    def inventory_plan(src, products, offset=0):
        rows = table_rows(src, 'purchases')
        plan = []
        skipped_product = 0
        for r in rows:
            product_id = int(r['machine'])
            product = products.get(product_id)
            if not product:
                skipped_product += 1
                continue
            plan.append((r, product, offset))
        return plan, skipped_product

    a_plan, a_skip_prod = inventory_plan(asen, a_products, ASEN_OFFSET)
    w_all, w_skip_prod = inventory_plan(wises, w_products, 0)

    import psycopg2
    from psycopg2.extras import execute_values
    conn = psycopg2.connect(**dsn)
    conn.autocommit = False
    cur = conn.cursor()
    try:
        cur.execute('SELECT id FROM imports WHERE batch_code = %s', (BATCH_OLD,))
        if cur.fetchone():
            sys.exit(f'import marker {BATCH_OLD} already exists - aborting (nothing written).')

        cur.execute('SELECT old_source_id FROM machines WHERE old_source_id IS NOT NULL')
        have_m = {r[0] for r in cur.fetchall()}
        cur.execute('SELECT old_source_id FROM probes WHERE old_source_id IS NOT NULL')
        have_p = {r[0] for r in cur.fetchall()}
        cur.execute('SELECT old_source_id FROM printers WHERE old_source_id IS NOT NULL')
        have_r = {r[0] for r in cur.fetchall()}
        cur.execute('SELECT old_source_id FROM parts WHERE old_source_id IS NOT NULL')
        have_part = {r[0] for r in cur.fetchall()}
        have_all = have_m | have_p | have_r | have_part

        w_plan = [(r, p, 0) for r, p, _ in w_all if int(r['id']) not in have_all]

        print()
        print(f'  asen purchases      {len(a_plan)}  (skipped, unknown product: {a_skip_prod})')
        print(f'  wises leftover      {len(w_plan)}  (of {len(w_all)} total, '
              f'skipped unknown product: {w_skip_prod})')
        a_counts, w_counts = {}, {}
        for r, p, off in a_plan:
            a_counts[p['category']] = a_counts.get(p['category'], 0) + 1
        for r, p, off in w_plan:
            w_counts[p['category']] = w_counts.get(p['category'], 0) + 1
        print(f'    asen  by category  {a_counts}')
        print(f'    wises by category  {w_counts}')

        undated = sum(1 for r, p, off in a_plan + w_plan
                      if not display_date(r['arrival_date']))
        print(f'  undated arrivals (created_at <- 2019-01-01): {undated}')

        a_sales = table_rows(asen, 'sale_inv')
        w_sales = table_rows(wises, 'sale_inv')
        a_lines = table_rows(asen, 'sale_temp_inv')
        w_lines = table_rows(wises, 'sale_temp_inv')
        a_events = table_rows(asen, 'events')
        w_events = table_rows(wises, 'events')
        print(f'  sales  asen {len(a_sales)} / wises {len(w_sales)}')
        print(f'  lines  asen {len(a_lines)} / wises {len(w_lines)}')
        print(f'  events asen {len(a_events)} / wises {len(w_events)}')

        a_cust = {int(r['id']): r for r in table_rows(asen, 'customer')}
        w_cust = {int(r['id']): r for r in table_rows(wises, 'customer')}
        a_pids = {int(r['id']) for r, p, off in a_plan}
        w_pids = {int(r['id']) for r, p, off in w_plan}
        print(f'  events with unknown item: '
              f'asen {sum(1 for e in a_events if int(e["inventory_id"]) not in a_pids)} '
              f'wises {sum(1 for e in w_events if int(e["inventory_id"]) not in w_pids)}')

        if args.dry_run:
            print('\n(dry run - nothing written)')
            return

        # ------------------------------------------------------------- brands
        cur.execute('SELECT upper(name), id FROM brands')
        brand_by_name = {r[0]: r[1] for r in cur.fetchall()}
        cur.execute('SELECT old_source_id FROM brands WHERE old_source_id IS NOT NULL')
        have_brands = {r[0] for r in cur.fetchall()}
        a_brand_map, w_brand_map = {}, {}
        for src, products, offset, bmap in ((asen, a_products, ASEN_OFFSET, a_brand_map),
                                            (wises, w_products, 0, w_brand_map)):
            for p in products.values():
                if not p['brand_name']:
                    continue
                name = p['brand_name'].strip()
                key = name.upper()
                old_id = p['old_brand']
                if key in brand_by_name:
                    bmap[old_id] = brand_by_name[key]
                    continue
                oid = old_id + offset if old_id is not None else None
                cur.execute(
                    'INSERT INTO brands (name, old_source_id) VALUES (%s, %s) RETURNING id',
                    (name, oid))
                bid = cur.fetchone()[0]
                brand_by_name[key] = bid
                bmap[old_id] = bid

        # ------------------------------------------------------------- vendors
        cur.execute('SELECT upper(name), id FROM vendors')
        vendor_by_name = {r[0]: r[1] for r in cur.fetchall()}
        a_vendor_map, w_vendor_map = {}, {}
        for src, offset, vmap in ((asen, ASEN_OFFSET, a_vendor_map),
                                  (wises, 0, w_vendor_map)):
            for r in table_rows(src, 'vendors'):
                name = (r['name'] or '').strip()
                if not name:
                    continue
                old_id = int(r['id'])
                key = name.upper()
                if key in vendor_by_name:
                    vmap[old_id] = vendor_by_name[key]
                    continue
                address = (r['address'] or '').strip() or None
                phone = (r['cell'] or '').strip() or None
                cur.execute(
                    'INSERT INTO vendors (name, phone, address, old_source_id) '
                    'VALUES (%s, %s, %s, %s) RETURNING id',
                    (name, phone, address, old_id + offset))
                vid = cur.fetchone()[0]
                vendor_by_name[key] = vid
                vmap[old_id] = vid

        # --------------------------------------------------------- catalogues
        cur.execute('SELECT old_source_id, id FROM catalog_products '
                    'WHERE old_source_id IS NOT NULL')
        catalog_map = {r[0]: r[1] for r in cur.fetchall()}
        cur.execute('SELECT name_model, brand_id, category, id FROM catalog_products')
        key_to_new_id = {((r[0] or '').upper(), r[1], r[2]): r[3] for r in cur.fetchall()}
        a_cat_map, w_cat_map = {}, {}
        for src, products, offset, bmap, cmap in (
                (asen, a_products, ASEN_OFFSET, a_brand_map, a_cat_map),
                (wises, w_products, 0, w_brand_map, w_cat_map)):
            pending_cat, catalog_pending = [], {}
            for old_id, p in products.items():
                oid = old_id + offset
                if oid in catalog_map:
                    cmap[old_id] = catalog_map[oid]
                    continue
                brand_id = bmap.get(p['old_brand'])
                key = (p['name_model'].upper(), brand_id, p['category'])
                if key in key_to_new_id:
                    cmap[old_id] = key_to_new_id[key]
                    catalog_map[oid] = key_to_new_id[key]
                    continue
                pending_cat.append((p['name_model'], p['category'], brand_id,
                                    p['probe_type'], p['source_info'], oid))
                catalog_pending[key] = (old_id, offset, cmap)
            if pending_cat:
                execute_values(
                    cur,
                    'INSERT INTO catalog_products '
                    '(name_model, category, brand_id, probe_type, source_info, old_source_id) '
                    'VALUES %s RETURNING id, old_source_id',
                    pending_cat, page_size=500)
                for pid, oid in cur.fetchall():
                    catalog_map[oid] = pid
                for key, (old_id, offset, cmap) in catalog_pending.items():
                    pid = catalog_map[old_id + offset]
                    cmap[old_id] = pid
                    key_to_new_id[key] = pid

        # -------------------------------------------------- customers/dealers
        cur.execute('SELECT upper(name), id FROM customers')
        cust_by_name = {r[0]: r[1] for r in cur.fetchall()}
        cur.execute('SELECT old_source_id, id FROM customers '
                    'WHERE old_source_id IS NOT NULL')
        cust_by_oid = {r[0]: r[1] for r in cur.fetchall()}
        cur.execute('SELECT upper(name), id FROM dealers')
        deal_by_name = {r[0]: r[1] for r in cur.fetchall()}
        cur.execute('SELECT old_source_id, id FROM dealers '
                    'WHERE old_source_id IS NOT NULL')
        deal_by_oid = {r[0]: r[1] for r in cur.fetchall()}

        def import_parties(src, offset):
            """Return {old_customer_id: (kind, app_id, name)} kind: customer|dealer|branch|none."""
            mapping = {}
            for r in table_rows(src, 'customer'):
                old_id = int(r['id'])
                name = (r['name'] or '').strip()
                ctype = (r['customer_type'] or '').strip()
                if not name:
                    mapping[old_id] = ('none', None, '')
                    continue
                if ctype == 'Customer':
                    app_id = cust_by_oid.get(old_id + offset) if offset == 0 else None
                    if app_id is None:
                        app_id = cust_by_name.get(name.upper())
                    if app_id is None:
                        cur.execute(
                            'INSERT INTO customers (name, phone, address, city, '
                            'customer_type, old_source_id) VALUES (%s, %s, %s, %s, %s, %s) '
                            'RETURNING id',
                            (name, (r['cell'] or '').strip() or None,
                             (r['address'] or '').strip() or None,
                             (r['city'] or '').strip() or None,
                             'Customer', old_id + offset))
                        app_id = cur.fetchone()[0]
                        cust_by_name[name.upper()] = app_id
                        cust_by_oid[old_id + offset] = app_id
                    mapping[old_id] = ('customer', app_id, name)
                elif ctype == 'Dealer':
                    app_id = deal_by_oid.get(old_id + offset) if offset == 0 else None
                    if app_id is None:
                        app_id = deal_by_name.get(name.upper())
                    if app_id is None:
                        cur.execute(
                            'INSERT INTO dealers (name, phone, address, city, '
                            'old_source_id) VALUES (%s, %s, %s, %s, %s) RETURNING id',
                            (name, (r['cell'] or '').strip() or None,
                             (r['address'] or '').strip() or None,
                             (r['city'] or '').strip() or None, old_id + offset))
                        app_id = cur.fetchone()[0]
                        deal_by_name[name.upper()] = app_id
                        deal_by_oid[old_id + offset] = app_id
                    mapping[old_id] = ('dealer', app_id, name)
                else:
                    mapping[old_id] = ('branch', None, name)
            return mapping

        a_party = import_parties(asen, ASEN_OFFSET)
        w_party = import_parties(wises, 0)

        # -------------------------------------------------------------- batch
        cur.execute('SELECT id FROM batches WHERE code = %s', (BATCH_OLD,))
        row = cur.fetchone()
        if row:
            batch_id = row[0]
        else:
            cur.execute(
                'INSERT INTO batches (code, arrival_date, notes) VALUES (%s, %s, %s) '
                'RETURNING id',
                (BATCH_OLD, 'Unknown',
                 'Old data imported from localhost (3).sql '
                 '(gvjxvqtv_asen 2020-2022 + pre-14-09-2026 gvjxvqtv_wises stock).'))
            batch_id = cur.fetchone()[0]

        # ---------------------------------------------------------- inventory
        def created_at_of(r):
            d = legacy_date(r['arrival_date'])
            return datetime.datetime(d.year, d.month, d.day) if d else UNDATED_CREATED

        machine_by_serial = {}
        stats = {'Machine': 0, 'Probe': 0, 'Printer': 0}

        def insert_machines(plan, bmap, cmap, vmap, prefix):
            pending = []
            for r, product, offset in plan:
                if product['category'] != 'Machine':
                    continue
                old_id = int(r['id'])
                oid = old_id + offset
                if oid in have_m:
                    continue
                serial = (r['sr'] or '').strip()
                if serial in ('', '-', 'None'):
                    serial = (r['m_sr'] or '').strip()
                if serial in ('-', 'None'):
                    serial = None
                location = (r['location'] or '').strip() or 'Company'
                arrival = display_date(r['arrival_date'])
                vendor_id = vmap.get(int(r['vendors']) if (r['vendors'] or '').isdigit() else -1)
                sold = (r['sold'] or '0') == '1'
                pending.append((
                    f'{prefix}-{old_id:05d}', batch_id, cmap.get(int(r['machine'])),
                    bmap.get(product['old_brand']), product['name_model'] or None, serial,
                    (r['model_year'] or '').strip() or None, vendor_id, arrival,
                    'Sold' if sold else 'In Stock', location,
                    map_condition(r['status'], True), oid, created_at_of(r)))
                have_m.add(oid)
                stats['Machine'] += 1
            if pending:
                execute_values(
                    cur,
                    'INSERT INTO machines (machine_id, batch_id, catalog_product_id, '
                    'brand_id, model, serial_number, year_of_manufacture, vendor_id, '
                    'acquisition_date, status, current_location, condition, old_source_id, '
                    'created_at) VALUES %s RETURNING id, serial_number',
                    pending, page_size=500)
                for mid, serial in cur.fetchall():
                    if serial:
                        machine_by_serial.setdefault(serial, mid)

        print('\ninserting inventory ...')
        insert_machines(w_plan, w_brand_map, w_cat_map, w_vendor_map, 'M')
        insert_machines(a_plan, a_brand_map, a_cat_map, a_vendor_map, 'A')

        def insert_rest(plan, bmap, cmap, vmap, prefix):
            pend_probe, pend_printer = [], []
            for r, product, offset in plan:
                category = product['category']
                if category == 'Machine':
                    continue
                old_id = int(r['id'])
                oid = old_id + offset
                have = have_p if category == 'Probe' else have_r
                if oid in have:
                    continue
                serial = (r['sr'] or '').strip()
                if serial in ('', '-', 'None'):
                    serial = (r['m_sr'] or '').strip()
                if serial in ('-', 'None'):
                    serial = None
                parent_serial = (r['m_sr'] or '').strip()
                if parent_serial in ('-', 'None'):
                    parent_serial = None
                location = (r['location'] or '').strip() or 'Company'
                arrival = display_date(r['arrival_date'])
                vendor_id = vmap.get(int(r['vendors']) if (r['vendors'] or '').isdigit() else -1)
                sold = (r['sold'] or '0') == '1'
                assigned = None
                if not sold and parent_serial:
                    assigned = machine_by_serial.get(parent_serial)
                status = 'Sold' if sold else 'Available'
                if assigned and not sold:
                    status = 'With Machine'
                condition = map_condition(r['status'], False)
                if category == 'Probe':
                    pend_probe.append((
                        f'PRB-{prefix}{old_id:05d}', cmap.get(int(r['machine'])),
                        product['name_model'] or None, bmap.get(product['old_brand']),
                        serial, batch_id, vendor_id, arrival, status, location, assigned,
                        condition, oid, created_at_of(r)))
                    have_p.add(oid)
                    stats['Probe'] += 1
                else:
                    pend_printer.append((
                        f'PRT-{prefix}{old_id:05d}', cmap.get(int(r['machine'])),
                        product['name_model'] or None, bmap.get(product['old_brand']),
                        serial, batch_id, vendor_id, arrival, status, location, assigned,
                        condition, oid, created_at_of(r)))
                    have_r.add(oid)
                    stats['Printer'] += 1
            if pend_probe:
                execute_values(
                    cur,
                    'INSERT INTO probes (internal_id, catalog_product_id, model, brand_id, '
                    'serial_number, batch_id, vendor_id, acquisition_date, status, '
                    'current_location, assigned_machine_id, condition, old_source_id, '
                    'created_at) VALUES %s',
                    pend_probe, page_size=500)
            if pend_printer:
                execute_values(
                    cur,
                    'INSERT INTO printers (internal_id, catalog_product_id, name_model, '
                    'brand_id, serial_number, batch_id, vendor_id, acquisition_date, status, '
                    'current_location, assigned_machine_id, condition, old_source_id, '
                    'created_at) VALUES %s',
                    pend_printer, page_size=500)

        insert_machines(w_plan, w_brand_map, w_cat_map, w_vendor_map, 'M')
        insert_machines(a_plan, a_brand_map, a_cat_map, a_vendor_map, 'A')

        print('\ninserting inventory ...')
        insert_rest(w_plan, w_brand_map, w_cat_map, w_vendor_map, 'L')
        insert_rest(a_plan, a_brand_map, a_cat_map, a_vendor_map, 'A')
        print(f'  {stats}')

        # item lookup: legacy purchase old_source_id -> (table, id)
        item_map = {}
        for table, fk in (('machines', 'machine'), ('probes', 'probe'),
                          ('printers', 'printer'), ('parts', 'part')):
            cur.execute(f'SELECT id, old_source_id FROM {table} '
                        'WHERE old_source_id IS NOT NULL')
            for iid, oid in cur.fetchall():
                item_map[oid] = (fk, table, iid)

        # -------------------------------------------------------------- sales
        def import_sales(sales, lines, party_map, label):
            # Keyed by old_source_id (unique) rather than trno: trno is NOT
            # unique in the dump ('' and '0' each appear more than once).
            sale_id_by_oid = {}
            skipped = 0
            pend_sale = []
            for s in sales:
                old_id = int(s['id'])
                party = party_map.get(int(s['customer'])) if s['customer'] else None
                if party is None and s['customer']:
                    skipped += 1
                    continue
                kind, app_id, name = party if party else ('none', None, '')
                notes = []
                # The tag stores the name uppercased: the client looks it up
                # against a case-insensitive map keyed on upper(name).
                if kind in ('dealer', 'branch', 'none') and name:
                    notes.append(f'party:{kind}:{name.upper()}')
                if (s['notes'] or '').strip():
                    notes.append((s['notes'] or '').strip())
                if (s['rcvd'] or '').strip() not in ('', '0', '0.00'):
                    notes.append(f"Received: {s['rcvd']}")
                pend_sale.append((
                    app_id if kind == 'customer' else None,
                    (s['date'] or '').strip() or '0001-01-01', num(s['price']),
                    '\n'.join(notes) or None, old_id + label,
                    (s['trno'] or '').strip() or None))
            if pend_sale:
                bulk_insert(
                    cur,
                    'INSERT INTO sales (customer_id, sale_date, sale_price, notes, '
                    'old_source_id, old_trno) VALUES %s', pend_sale)
                cur.execute(
                    'SELECT id, old_source_id FROM sales WHERE old_source_id = ANY(%s)',
                    ([row[4] for row in pend_sale],))
                sale_id_by_oid = dict(cur.fetchall())
                if len(sale_id_by_oid) != len(pend_sale):
                    raise RuntimeError(
                        f'sale insert lost rows: {len(sale_id_by_oid)} '
                        f'of {len(pend_sale)}')
            inserted = len(pend_sale)

            # Lines whose purchase maps to a sale keep that invoice. A line whose
            # purchase has no invoice at all is an orphan; group each orphan
            # purchase under one synthetic invoice.
            orphan_purchases = []
            seen_orphan = set()
            pend_line = []
            for ln in lines:
                purchase_old = int(ln['purchase_id']) if (ln['purchase_id'] or '').isdigit() else None
                sale_oid = purchase_old + label if purchase_old is not None else None
                sid = sale_id_by_oid.get(sale_oid)
                item = item_map.get(purchase_old + label) if purchase_old is not None else None
                fk, table, iid = item if item else (None, None, None)
                item_type = fk if fk else 'other'
                if sid is None:
                    # One synthetic invoice per distinct orphan purchase id; lines
                    # with no purchase id share a single invoice for the batch.
                    key = (purchase_old + label
                           if purchase_old is not None else ORPHAN_OFFSET + label)
                    if key not in seen_orphan:
                        seen_orphan.add(key)
                        orphan_purchases.append(key)
                    sid = ('orphan', key)
                pend_line.append((
                    sid, item_type,
                    iid if table == 'machines' else None,
                    iid if table == 'probes' else None,
                    iid if table == 'printers' else None,
                    iid if table == 'parts' else None,
                    (ln['name'] or '').strip() or None,
                    (ln['serial'] or '').strip() or None,
                    num(ln['price']),
                    1 if (ln['main_machine'] or '0') == '1' else 0,
                    int(ln['id']) + label))
            line_inserted = len(pend_line)

            # One synthetic invoice per distinct orphan purchase. Inserted before
            # the line inserts so every orphan line resolves on the first lookup.
            # Orphan old_source_id is keyed by the purchase id offset into a range
            # no real sale can occupy, and is scoped per call so the asen and
            # wises id spaces stay distinct.
            orphan_map = {}
            if orphan_purchases:
                bulk_insert(
                    cur,
                    'INSERT INTO sales (customer_id, sale_date, sale_price, notes, '
                    'old_source_id, old_trno) VALUES %s',
                    [(None, '0001-01-01', None,
                      'Imported legacy line (no invoice).', oid, None)
                     for oid in orphan_purchases])
                cur.execute(
                    'SELECT old_source_id, id FROM sales WHERE old_source_id = ANY(%s)',
                    (orphan_purchases,))
                by_src = dict(cur.fetchall())
                orphan_map = {oid: by_src.get(oid)
                              for oid in set(orphan_purchases)}
                if any(v is None for v in orphan_map.values()):
                    raise RuntimeError(
                        f'orphan invoices lost rows: '
                        f'{sum(1 for v in orphan_map.values() if v is None)} '
                        f'of {len(orphan_map)}')
            resolved = []
            for sid, *rest in pend_line:
                if isinstance(sid, tuple):
                    sid = orphan_map.get(sid[1])
                    if sid is None:
                        raise RuntimeError(
                            f'unresolved orphan sale line for key {sid}')
                resolved.append((sid, *rest))
            bulk_insert(
                cur,
                'INSERT INTO sale_items (sale_id, item_type, machine_id, probe_id, '
                'printer_id, part_id, item_description, item_serial, item_price, '
                'is_main_item, old_source_id) VALUES %s', resolved, cols=11)
            cur.execute(
                'SELECT count(*) FROM sale_items WHERE old_source_id = ANY(%s)',
                ([p[-1] for p in resolved],))
            line_inserted = cur.fetchone()[0]
            if line_inserted != len(resolved):
                raise RuntimeError(
                    f'sale_items insert lost rows: {line_inserted} of {len(resolved)}')
            print(f'  {label}: sales +{inserted} (skipped unknown party {skipped}), '
                  f'lines +{line_inserted} '
                  f'({len(orphan_map)} orphan invoices grouped)')
            return inserted, line_inserted, skipped

        print('\ninserting sales ...')
        ws = import_sales(w_sales, w_lines, w_party, 0)
        as_ = import_sales(a_sales, a_lines, a_party, ASEN_OFFSET)

        # ----------------------------------------------------------- movements
        def import_events(events, plan, label):
            inserted = 0
            skipped = 0
            undated_count = 0
            pend = []
            for e in events:
                purchase_old = int(e['inventory_id'])
                item = item_map.get(purchase_old + label)
                if item is None:
                    skipped += 1
                    continue
                fk, table, iid = item
                details = (e['event_details'] or '').strip()
                from_loc, to_loc = parse_event(details)
                notes = [(e['remarks'] or '').strip(), details]
                notes = [n for n in notes if n]
                d = legacy_date(e['date'])
                if d is None:
                    movement_date = '01-01-2000'
                    created = UNDATED_CREATED
                    undated_count += 1
                else:
                    movement_date = d.strftime('%d-%m-%Y')
                    created = datetime.datetime(d.year, d.month, d.day)
                pend.append((
                    'Legacy', movement_date,
                    iid if table == 'machines' else None,
                    iid if table == 'probes' else None,
                    iid if table == 'printers' else None,
                    iid if table == 'parts' else None,
                    from_loc, to_loc or None, '\n'.join(notes) or None,
                    int(e['id']) + label, created))
                inserted += 1
            if pend:
                bulk_insert(
                    cur,
                    'INSERT INTO movements (movement_type, movement_date, machine_id, '
                    'probe_id, printer_id, part_id, from_location, to_location, notes, '
                    'old_source_id, created_at) VALUES %s', pend, cols=11)
                cur.execute(
                    'SELECT count(*) FROM movements WHERE old_source_id = ANY(%s)',
                    ([p[-2] for p in pend],))
                inserted = cur.fetchone()[0]
                if inserted != len(pend):
                    raise RuntimeError(
                        f'movements insert lost rows: {inserted} of {len(pend)}')
            print(f'  {label}: movements +{inserted} '
                  f'(skipped orphan items {skipped}, undated {undated_count})')
            return inserted, skipped

        print('\ninserting movements ...')
        wm = import_events(w_events, w_plan, 0)
        am = import_events(a_events, a_plan, ASEN_OFFSET)

        # -------------------------------------------------------------- audit
        total_inserted = (stats['Machine'] + stats['Probe'] + stats['Printer']
                          + ws[0] + ws[1] + as_[0] + as_[1] + wm[0] + am[0])
        total_skipped = (a_skip_prod + w_skip_prod + ws[2] + as_[2] + wm[1] + am[1])
        cur.execute(
            'INSERT INTO imports (batch_code, source_filename, source_type, imported_by, '
            'records_total, records_inserted, records_skipped, notes) '
            'VALUES (%s, %s, %s, %s, %s, %s, %s, %s)',
            (BATCH_OLD, DUMP.name, 'SQL', 'import_asen.py',
             len(a_plan) + len(w_plan) + len(a_sales) + len(w_sales)
             + len(a_lines) + len(w_lines) + len(a_events) + len(w_events),
             total_inserted, total_skipped,
             f'old era: machines={stats["Machine"]} probes={stats["Probe"]} '
             f'printers={stats["Printer"]} sales={ws[0] + as_[0]} '
             f'sale_items={ws[1] + as_[1]} movements={wm[0] + am[0]}; '
             f'asen old_source_id offset +{ASEN_OFFSET}'))

        for t in ('brands', 'vendors', 'catalog_products', 'customers', 'dealers',
                  'batches', 'machines', 'probes', 'printers', 'parts',
                  'sales', 'sale_items', 'movements', 'imports'):
            cur.execute(f'SELECT count(*) FROM {t}')
            print(f'  {t:20} {cur.fetchone()[0]}')

        conn.commit()
        print('\ncommitted.')
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()


if __name__ == '__main__':
    main()
