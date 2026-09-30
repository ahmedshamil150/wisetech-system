"""Import legacy data from the phpMyAdmin dump into Supabase.

Source : localhost (2).sql  (MySQL databases `gvjxvqtv_asen` + `gvjxvqtv_wises`)
Target : the Supabase project configured in .env

What gets imported (from `gvjxvqtv_wises` only - the Wise Tech Services site):
  * all 996 products        -> catalog_products
  * all 30 brands           -> brands
  * all 102 vendors         -> vendors (suppliers referenced by inventory)
  * all 288 customers       -> customers   (customer_type = 'Customer')
  * all 122 dealers         -> dealers     (customer_type = 'Dealer')
  * inventory items
        - uploaded on/after 14-09-2026            -> batch BATCH-3
        - every spare part, regardless of date    -> batch BATCH-PARTS
Workshops / branch / sales / movements are NOT imported.

Usage:
  python scripts/import_legacy.py            # run the import
  python scripts/import_legacy.py --dry-run  # print the plan, change nothing
"""
import argparse
import datetime
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DUMP = ROOT / 'localhost (2).sql'
SOURCE_DB = 'gvjxvqtv_wises'
CUTOFF = datetime.date(2026, 9, 14)

BATCH_RECENT = 'BATCH-3'
BATCH_PARTS = 'BATCH-PARTS'
LEGACY_PART_ID = 9180  # purchases uploaded after this id have no arrival date

# ---------------------------------------------------------------- dump parsing


def parse_dump(path):
    text = path.read_text(encoding='utf-8', errors='replace')
    starts = [(m.group(1), m.start()) for m in
              re.finditer(r'CREATE DATABASE IF NOT EXISTS `(\w+)`', text)]
    starts.append(('__end__', len(text)))
    data = {}
    for idx in range(len(starts) - 1):
        name, begin = starts[idx]
        end = starts[idx + 1][1]
        blocks = _parse_inserts(text[begin:end])
        acc = {}
        for table, cols, rows in blocks:
            if table in acc:
                acc[table]['rows'].extend(rows)
            else:
                acc[table] = {'cols': cols, 'rows': rows}
        data[name] = acc
    return data


def _parse_inserts(text):
    out = []
    pos = 0
    pat = re.compile(r"INSERT INTO `(\w+)`\s*\(([^)]*)\)\s*VALUES", re.S)
    while True:
        m = pat.search(text, pos)
        if not m:
            break
        table = m.group(1)
        cols = [c.strip().strip('`') for c in m.group(2).split(',')]
        i, n = m.end(), len(text)
        rows = []
        while i < n:
            while i < n and text[i] in ' \r\n\t,':
                i += 1
            if i >= n or text[i] != '(':
                break
            i += 1
            vals, cur, in_str = [], [], False
            while i < n:
                ch = text[i]
                if in_str:
                    if ch == '\\':
                        cur.append(text[i:i + 2]); i += 2; continue
                    if ch == "'":
                        in_str = False; i += 1; continue
                    cur.append(ch); i += 1; continue
                if ch == "'":
                    in_str = True; i += 1; continue
                if ch == ',':
                    vals.append(''.join(cur).strip()); cur = []; i += 1; continue
                if ch == ')':
                    vals.append(''.join(cur).strip()); i += 1; break
                cur.append(ch); i += 1
            rows.append([_unquote(v) for v in vals])
            j = i
            while j < n and text[j] in ' \r\n\t':
                j += 1
            if j < n and text[j] == ',':
                i = j + 1
                continue
            i = j
            break
        out.append((table, cols, rows))
        pos = i
    return out


def _unquote(v):
    v = v.strip()
    if v.upper() == 'NULL':
        return None
    if len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        s = v[1:-1]
        for a, b in (("\\'", "'"), ('\\"', '"'), ('\\\\', '\\'),
                     ('\\r', '\r'), ('\\n', '\n'), ('\\t', '\t')):
            s = s.replace(a, b)
        return s
    return v


# ---------------------------------------------------------------- helpers

PROBE_TYPES = {
    '1251': 'Convex', '1252': 'Micro Convex', '1253': 'Linear',
    '1254': 'Phased Array', '1259': 'Phased Array', '1262': 'Endocavity',
    '1264': '3D/4D', '1265': '3D/4D', '1270': 'Convex', '1271': 'Endocavity',
    '1272': 'Linear', '1273': 'Linear', '1276': 'Linear', '1291': '3D/4D',
    '1307': 'Convex',
}


def legacy_date(value):
    if not value:
        return None
    m = re.match(r'^(\d{2})-(\d{2})-(\d{4})$', value.strip())
    if not m:
        return None
    day, month, year = (int(x) for x in m.groups())
    try:
        return datetime.date(year, month, day)
    except ValueError:
        return None


def display_date(value):
    d = legacy_date(value)
    return d.strftime('%d-%m-%Y') if d else None


def product_category(p_type, product_type):
    if p_type == 'Product':
        return 'Machine'
    if p_type == 'Spare Part':
        return 'Part'
    if product_type == '1256':
        return 'Printer'
    return 'Probe'


def map_condition(old_status, is_machine):
    s = (old_status or '').strip().lower()
    if s == 'ok':
        return 'Good'
    if s == 'faulty':
        return 'Faulty' if is_machine else 'Damaged'
    if s in ('cracks',):
        return 'Used' if is_machine else 'Damaged'
    if s in ('air shadows',):
        return 'Used' if is_machine else 'Needs Inspection'
    return 'Unknown' if is_machine else 'Needs Inspection'


def load_env(path):
    env = {}
    if not path.exists():
        return env
    for line in path.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, _, value = line.partition('=')
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


# ---------------------------------------------------------------- import

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
    if SOURCE_DB not in data:
        sys.exit(f'database {SOURCE_DB} not found in dump')
    src = data[SOURCE_DB]

    def table(name):
        return src.get(name, {'cols': [], 'rows': []})

    def col(t, name):
        return t['cols'].index(name)

    catalogue_t = table('catalogue')
    brands_t = table('brands')
    vendors_t = table('vendors')
    customers_t = table('customer')
    purchases_t = table('purchases')

    C = catalogue_t['cols']
    Br = brands_t['cols']
    V = vendors_t['cols']
    Cu = customers_t['cols']
    P = purchases_t['cols']

    cat_rows = catalogue_t['rows']
    brand_rows = brands_t['rows']
    vendor_rows = vendors_t['rows']
    customer_rows = customers_t['rows']
    purchase_rows = purchases_t['rows']

    products = []
    for r in cat_rows:
        old_id = int(r[col(catalogue_t, 'id')])
        model = (r[col(catalogue_t, 'model')] or '').strip()
        p_type = (r[col(catalogue_t, 'type')] or '').strip()
        product_type = (r[col(catalogue_t, 'product_type')] or '').strip()
        brand_raw = (r[col(catalogue_t, 'brand')] or '').strip()
        category = product_category(p_type, product_type)
        meta = []
        if product_type:
            meta.append(f'legacy_product_type={product_type}')
        for key in ('image', 'url', 'spec'):
            val = (r[col(catalogue_t, key)] or '').strip()
            if val:
                meta.append(f'{key}={val}')
        products.append({
            'old_id': old_id,
            'name_model': model,
            'category': category,
            'old_brand': int(brand_raw) if brand_raw.isdigit() else None,
            'probe_type': PROBE_TYPES.get(product_type) if category == 'Probe' else None,
            'source_info': '; '.join(meta) or None,
        })

    brands = [{'old_id': int(r[col(brands_t, 'id')]),
               'name': (r[col(brands_t, 'name')] or '').strip()}
              for r in brand_rows if (r[col(brands_t, 'name')] or '').strip()]

    vendors = [{'old_id': int(r[col(vendors_t, 'id')]),
                'name': (r[col(vendors_t, 'name')] or '').strip(),
                'phone': (r[col(vendors_t, 'cell')] or '').strip() or None,
                'address': (r[col(vendors_t, 'address')] or '').strip() or None}
               for r in vendor_rows if (r[col(vendors_t, 'name')] or '').strip()]

    customers, dealers, skipped_types = [], [], []
    for r in customer_rows:
        name = (r[col(customers_t, 'name')] or '').strip()
        ctype = (r[col(customers_t, 'customer_type')] or '').strip()
        if not name:
            skipped_types.append('(blank name)')
            continue
        row = {
            'old_id': int(r[col(customers_t, 'id')]),
            'name': name,
            'phone': (r[col(customers_t, 'cell')] or '').strip() or None,
            'address': (r[col(customers_t, 'address')] or '').strip() or None,
            'city': (r[col(customers_t, 'city')] or '').strip() or None,
        }
        if ctype == 'Dealer':
            dealers.append(row)
        elif ctype == 'Customer':
            customers.append(row)
        else:
            skipped_types.append(f"{name} ({ctype})")

    # ---- pick the inventory rows
    recent, undated_recent, parts_all = [], [], []
    spare_ids = {p['old_id'] for p in products if p['category'] == 'Part'}
    for r in purchase_rows:
        old_id = int(r[col(purchases_t, 'id')])
        arrival = legacy_date(r[col(purchases_t, 'arrival_date')])
        product_id = int(r[col(purchases_t, 'machine')])
        if arrival and arrival >= CUTOFF:
            recent.append(r)
        elif old_id > LEGACY_PART_ID:
            undated_recent.append(r)
        elif product_id in spare_ids:
            parts_all.append(r)

    batch3_rows = recent + undated_recent
    batch_part_rows = parts_all

    counts = {'Machine': 0, 'Probe': 0, 'Printer': 0, 'Part': 0}
    product_by_id = {p['old_id']: p for p in products}
    row_category = {}
    for r in batch3_rows + batch_part_rows:
        old_id = int(r[col(purchases_t, 'id')])
        cat = product_by_id[int(r[col(purchases_t, 'machine')])]['category']
        row_category[old_id] = cat
        counts[cat] = counts.get(cat, 0) + 1

    def category_of(row):
        return row_category[int(row[col(purchases_t, 'id')])]

    print()
    print(f'  products            {len(products)}')
    print(f'  brands              {len(brands)}')
    print(f'  vendors             {len(vendors)}')
    print(f'  customers           {len(customers)}')
    print(f'  dealers             {len(dealers)}')
    print(f'  skipped customers   {len(skipped_types)}  {skipped_types}')
    print(f'  inventory BATCH-3   {len(batch3_rows)} '
          f'({len(recent)} dated {CUTOFF.strftime("%d-%m-%Y")}, '
          f'{len(undated_recent)} uploaded after)')
    print(f'  inventory BATCH-PARTS {len(batch_part_rows)}')
    print(f'  inventory totals    {counts}')
    print(f'  total inventory     {len(batch3_rows) + len(batch_part_rows)}')

    if args.dry_run:
        print('\n(dry run - nothing written)')
        return

    import psycopg2
    conn = psycopg2.connect(**dsn)
    conn.autocommit = False
    cur = conn.cursor()
    try:
        existing = {}
        for t in ('brands', 'vendors', 'catalog_products', 'customers',
                  'dealers', 'machines', 'probes', 'printers', 'parts', 'batches'):
            cur.execute(f'SELECT count(*) FROM {t}')
            existing[t] = cur.fetchone()[0]
        if any(existing.values()):
            print('\ntable row counts before import:', existing)

        # brands -------------------------------------------------------------
        cur.execute('SELECT old_source_id FROM brands WHERE old_source_id IS NOT NULL')
        have = {r[0] for r in cur.fetchall()}
        brand_map = {}
        for b in brands:
            if b['old_id'] in have:
                brand_map[b['old_id']] = None
                continue
            cur.execute(
                'INSERT INTO brands (name, old_source_id) VALUES (%s, %s) RETURNING id',
                (b['name'], b['old_id']))
            brand_map[b['old_id']] = cur.fetchone()[0]
        cur.execute('SELECT old_source_id, id FROM brands WHERE old_source_id IS NOT NULL')
        brand_map.update({r[0]: r[1] for r in cur.fetchall()})

        # vendors ------------------------------------------------------------
        cur.execute('SELECT old_source_id FROM vendors WHERE old_source_id IS NOT NULL')
        have = {r[0] for r in cur.fetchall()}
        for v in vendors:
            if v['old_id'] in have:
                continue
            address = v['address']
            city = address if address and len(address) <= 20 and ',' not in address else None
            street = address if address and (len(address) > 20 or ',' in address) else None
            cur.execute(
                'INSERT INTO vendors (name, phone, address, city, old_source_id) '
                'VALUES (%s, %s, %s, %s, %s) RETURNING id',
                (v['name'], v['phone'], street, city, v['old_id']))
        cur.execute('SELECT old_source_id, id FROM vendors WHERE old_source_id IS NOT NULL')
        vendor_map = {r[0]: r[1] for r in cur.fetchall()}

        # catalog_products ---------------------------------------------------
        cur.execute('SELECT old_source_id, id FROM catalog_products '
                    'WHERE old_source_id IS NOT NULL')
        catalog_map = {r[0]: r[1] for r in cur.fetchall()}
        # the legacy dump holds 4 duplicate (model, brand, category) combinations
        key_to_new_id = {}
        cur.execute('SELECT name_model, brand_id, category, id FROM catalog_products')
        for name_model, brand_id, category, pid in cur.fetchall():
            key_to_new_id[(name_model, brand_id, category)] = pid
        for p in products:
            if p['old_id'] in catalog_map:
                continue
            brand_id = brand_map.get(p['old_brand'])
            key = (p['name_model'], brand_id, p['category'])
            if key in key_to_new_id:
                catalog_map[p['old_id']] = key_to_new_id[key]
                continue
            cur.execute(
                'INSERT INTO catalog_products '
                '(name_model, category, brand_id, probe_type, source_info, old_source_id) '
                'VALUES (%s, %s, %s, %s, %s, %s) RETURNING id',
                (p['name_model'], p['category'], brand_id, p['probe_type'],
                 p['source_info'], p['old_id']))
            pid = cur.fetchone()[0]
            catalog_map[p['old_id']] = pid
            key_to_new_id[key] = pid

        # batches ------------------------------------------------------------
        batch_ids = {}
        for code, arrival, notes in (
            (BATCH_RECENT, CUTOFF.strftime('%d-%m-%Y'),
             'Legacy stock uploaded on/after 14-09-2026 (gvjxvqtv_wises).'),
            (BATCH_PARTS, 'Unknown',
             'All legacy spare parts regardless of upload date (gvjxvqtv_wises).'),
        ):
            cur.execute('SELECT id FROM batches WHERE code = %s', (code,))
            row = cur.fetchone()
            if row:
                batch_ids[code] = row[0]
            else:
                vendor_id = vendor_map.get(6) if code == BATCH_RECENT else None
                cur.execute(
                    'INSERT INTO batches (code, arrival_date, vendor_id, notes) '
                    'VALUES (%s, %s, %s, %s) RETURNING id',
                    (code, arrival, vendor_id, notes))
                batch_ids[code] = cur.fetchone()[0]

        # customers / dealers ------------------------------------------------
        cur.execute('SELECT old_source_id FROM customers WHERE old_source_id IS NOT NULL')
        have = {r[0] for r in cur.fetchall()}
        for row in customers:
            if row['old_id'] in have:
                continue
            cur.execute(
                'INSERT INTO customers (name, phone, address, city, customer_type, '
                'old_source_id) VALUES (%s, %s, %s, %s, %s, %s)',
                (row['name'], row['phone'], row['address'], row['city'],
                 'Customer', row['old_id']))
        cur.execute('SELECT old_source_id FROM dealers WHERE old_source_id IS NOT NULL')
        have = {r[0] for r in cur.fetchall()}
        for row in dealers:
            if row['old_id'] in have:
                continue
            cur.execute(
                'INSERT INTO dealers (name, phone, address, city, old_source_id) '
                'VALUES (%s, %s, %s, %s, %s)',
                (row['name'], row['phone'], row['address'], row['city'], row['old_id']))

        # inventory ----------------------------------------------------------
        def insert_inventory(rows, batch_code):
            # machines first so probes/printers/parts can point at them
            machine_by_serial = {}
            cur.execute('SELECT serial_number, id FROM machines '
                        'WHERE serial_number IS NOT NULL AND serial_number <> %s', ('',))
            for serial, mid in cur.fetchall():
                machine_by_serial.setdefault(serial, mid)
            cur.execute('SELECT old_source_id FROM machines WHERE old_source_id IS NOT NULL')
            have_machines = {r[0] for r in cur.fetchall()}
            cur.execute('SELECT old_source_id FROM probes WHERE old_source_id IS NOT NULL')
            have_probes = {r[0] for r in cur.fetchall()}
            cur.execute('SELECT old_source_id FROM printers WHERE old_source_id IS NOT NULL')
            have_printers = {r[0] for r in cur.fetchall()}
            cur.execute('SELECT old_source_id FROM parts WHERE old_source_id IS NOT NULL')
            have_parts = {r[0] for r in cur.fetchall()}

            stats = {'Machine': 0, 'Probe': 0, 'Printer': 0, 'Part': 0}
            for r in rows:
                old_id = int(r[col(purchases_t, 'id')])
                product_id = int(r[col(purchases_t, 'machine')])
                category = category_of(r)
                product = product_by_id[product_id]
                serial = (r[col(purchases_t, 'sr')] or '').strip()
                if serial in ('', '-', 'None'):
                    serial = (r[col(purchases_t, 'm_sr')] or '').strip()
                if serial in ('-', 'None'):
                    serial = None
                parent_serial = (r[col(purchases_t, 'm_sr')] or '').strip()
                if parent_serial in ('-', 'None'):
                    parent_serial = None
                location = (r[col(purchases_t, 'location')] or '').strip() or 'Company'
                sold = (r[col(purchases_t, 'sold')] or '0') == '1'
                old_status = r[col(purchases_t, 'status')]
                arrival = display_date(r[col(purchases_t, 'arrival_date')])
                vendor_id = vendor_map.get(int(r[col(purchases_t, 'vendors')])
                                           if (r[col(purchases_t, 'vendors')] or '').isdigit()
                                           else -1)
                catalog_id = catalog_map.get(product_id)
                brand_id = brand_map.get(product['old_brand'])
                if sold:
                    status = 'Sold'
                elif category == 'Machine':
                    status = 'In Stock'
                else:
                    status = 'Available'

                if category == 'Machine':
                    if old_id in have_machines:
                        continue
                    machine_id = f'M-{old_id:05d}'
                    cur.execute(
                        'INSERT INTO machines (machine_id, batch_id, catalog_product_id, '
                        'brand_id, model, serial_number, vendor_id, acquisition_date, '
                        'status, current_location, condition, old_source_id) '
                        'VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) '
                        'RETURNING id',
                        (machine_id, batch_ids[batch_code], catalog_id, brand_id,
                         product['name_model'], serial, vendor_id, arrival,
                         status, location, map_condition(old_status, True), old_id))
                    mid = cur.fetchone()[0]
                    if serial:
                        machine_by_serial.setdefault(serial, mid)
                    stats['Machine'] += 1
                    continue

                assigned = None
                if not sold and parent_serial:
                    assigned = machine_by_serial.get(parent_serial)
                if assigned and not sold:
                    status = 'With Machine'

                if category == 'Probe':
                    if old_id in have_probes:
                        continue
                    cur.execute(
                        'INSERT INTO probes (internal_id, catalog_product_id, model, '
                        'brand_id, serial_number, batch_id, vendor_id, acquisition_date, '
                        'status, current_location, assigned_machine_id, condition, '
                        'old_source_id) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, '
                        '%s, %s, %s)',
                        (f'PRB-L{old_id:05d}', catalog_id, product['name_model'], brand_id,
                         serial, batch_ids[batch_code], vendor_id, arrival, status,
                         location, assigned, map_condition(old_status, False), old_id))
                    stats['Probe'] += 1
                elif category == 'Printer':
                    if old_id in have_printers:
                        continue
                    cur.execute(
                        'INSERT INTO printers (internal_id, catalog_product_id, name_model, '
                        'brand_id, serial_number, batch_id, vendor_id, acquisition_date, '
                        'status, current_location, assigned_machine_id, condition, '
                        'old_source_id) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, '
                        '%s, %s, %s)',
                        (f'PRT-L{old_id:05d}', catalog_id, product['name_model'], brand_id,
                         serial, batch_ids[batch_code], vendor_id, arrival, status,
                         location, assigned, map_condition(old_status, False), old_id))
                    stats['Printer'] += 1
                else:
                    if old_id in have_parts:
                        continue
                    cur.execute(
                        'INSERT INTO parts (internal_id, catalog_product_id, name_model, '
                        'brand_id, serial_number, batch_id, vendor_id, acquisition_date, '
                        'status, current_location, assigned_machine_id, condition, '
                        'old_source_id) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, '
                        '%s, %s, %s)',
                        (f'PART-L{old_id:05d}', catalog_id, product['name_model'], brand_id,
                         serial, batch_ids[batch_code], vendor_id, arrival, status,
                         location, assigned, map_condition(old_status, False), old_id))
                    stats['Part'] += 1
            return stats

        print('\ninserting inventory ...')
        s1 = insert_inventory(batch3_rows, BATCH_RECENT)
        print('  BATCH-3     ', s1)
        s2 = insert_inventory(batch_part_rows, BATCH_PARTS)
        print('  BATCH-PARTS ', s2)

        # audit --------------------------------------------------------------
        totals = {'Machine': 0, 'Probe': 0, 'Printer': 0, 'Part': 0}
        for code, rows, stats in ((BATCH_RECENT, batch3_rows, s1),
                                  (BATCH_PARTS, batch_part_rows, s2)):
            for k in totals:
                totals[k] += stats[k]
            inserted = sum(stats.values())
            cur.execute('SELECT id FROM imports WHERE batch_code = %s', (code,))
            if cur.fetchone():
                cur.execute(
                    'UPDATE imports SET records_total = %s, records_inserted = %s, '
                    'imported_at = now() WHERE batch_code = %s',
                    (len(rows), inserted, code))
            else:
                cur.execute(
                    'INSERT INTO imports (batch_code, source_filename, source_type, '
                    'imported_by, records_total, records_inserted, notes) '
                    'VALUES (%s, %s, %s, %s, %s, %s, %s)',
                    (code, DUMP.name, 'SQL', 'import_legacy.py',
                     len(rows), inserted,
                     f'legacy {SOURCE_DB}; machines={stats["Machine"]} '
                     f'probes={stats["Probe"]} printers={stats["Printer"]} '
                     f'parts={stats["Part"]}'))

        for t in ('brands', 'vendors', 'catalog_products', 'customers', 'dealers',
                  'batches', 'machines', 'probes', 'printers', 'parts', 'imports'):
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
