"""Remove the asen import duplicates (read-only unless --apply).

The asen database in localhost (3).sql is a snapshot copy of the wises data:
most of its 1,800 purchases have a wises row with the same serial, and every
asen sale/line also exists under wises (same trno/serial). import_asen.py
imported both, so old stock lists most items twice (M-/PRB-L/PRT-L next to
A-/PRB-A/PRT-A).

This script keeps the wises rows and deletes the asen copies, after moving
everything that points at them onto the wises twin:
  * probes/printers/parts.assigned_machine_id
  * movements machine/probe/printer/part links (identical asen-origin
    movements are deleted instead, to avoid double history)
  * sale_items item links
  * flags item links
Asen rows with no wises twin are kept.

Run:  python scripts/fix_serial_duplicates.py            # dry run
      python scripts/fix_serial_duplicates.py --apply    # snapshot + apply
"""
import argparse
import collections
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from import_legacy import ROOT, load_env  # noqa: E402

OFFSET = 1_000_000
STAMP = '20261107'
TABLES = ('machines', 'probes', 'printers', 'parts')
FK_COL = {'machines': 'machine_id', 'probes': 'probe_id',
          'printers': 'printer_id', 'parts': 'part_id'}


def connect():
    env = load_env(ROOT / '.env')
    import psycopg2
    return psycopg2.connect(
        host=env['SUPABASE_DB_HOST'], port=int(env.get('SUPABASE_DB_PORT', '5432')),
        dbname=env.get('SUPABASE_DB_NAME', 'postgres'),
        user=env['SUPABASE_DB_USER'], password=env['SUPABASE_DB_PASSWORD'],
        sslmode='require', connect_timeout=30)


def snapshot(cur):
    tables = ('machines', 'probes', 'printers', 'parts', 'movements',
              'sale_items', 'flags')
    for t in tables:
        bak = f'{t}_bak_{STAMP}'
        cur.execute('SELECT to_regclass(%s)', (f'public.{bak}',))
        if cur.fetchone()[0]:
            sys.exit(f'snapshot {bak} already exists - aborting')
        cur.execute(f'CREATE TABLE public.{bak} AS SELECT * FROM public.{t}')
        cur.execute(f'ALTER TABLE public.{bak} ENABLE ROW LEVEL SECURITY')
        cur.execute(f'SELECT count(*) FROM public.{bak}')
        print(f'  snapshot {bak}: {cur.fetchone()[0]} rows')


def build_map(cur):
    """(table, asen id) -> wises twin id, plus rows kept for lack of a twin."""
    mapping, ambiguous, unique = {}, {}, collections.defaultdict(list)
    for table in TABLES:
        cur.execute(
            f"SELECT id, serial_number FROM {table} "
            "WHERE old_source_id >= %s AND coalesce(btrim(serial_number), '') <> ''",
            (OFFSET,))
        for aid, serial in cur.fetchall():
            cur.execute(
                f"SELECT id FROM {table} WHERE old_source_id < %s "
                "AND upper(btrim(serial_number)) = upper(btrim(%s))",
                (OFFSET, serial))
            twins = [r[0] for r in cur.fetchall()]
            if len(twins) == 1:
                mapping[(table, aid)] = twins[0]
            elif not twins:
                unique[table].append((aid, serial))
            else:
                ambiguous[(table, aid)] = (serial, twins)
    return mapping, ambiguous, unique


def bulk_update(cur, sql, pairs):
    """sql must contain one VALUES placeholder (new, old) used by v.t/v.id."""
    chunk = 500
    for i in range(0, len(pairs), chunk):
        part = pairs[i:i + chunk]
        values = ','.join(['(%s, %s)'] * len(part))
        cur.execute(sql.replace('VALUES', 'VALUES ' + values, 1),
                    [x for pair in part for x in pair])
        yield cur.rowcount


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--apply', action='store_true')
    args = ap.parse_args()

    conn = connect()
    cur = conn.cursor()
    try:
        mapping, ambiguous, unique = build_map(cur)
        print(f'asen rows with a wises twin: {len(mapping)}')
        print('asen-only rows kept: ' +
              ', '.join(f'{t}={len(v)}' for t, v in unique.items()))
        for table in TABLES:
            for aid, serial in unique[table]:
                print(f'  keep {table} id={aid} serial={serial!r}')
        if ambiguous:
            print(f'AMBIGUOUS (kept): {len(ambiguous)}')
            for (table, aid), (serial, twins) in ambiguous.items():
                print(f'  {table} id={aid} serial={serial!r} twins={twins}')

        machine_pairs = [(mapping[('machines', a)], a)
                         for t, a in mapping if t == 'machines']
        assigned_pairs = {}
        for table in ('probes', 'printers', 'parts'):
            cur.execute(
                f'SELECT count(*) FROM {table} WHERE assigned_machine_id = ANY(%s)',
                ([old for _, old in machine_pairs],))
            n = cur.fetchone()[0]
            assigned_pairs[table] = n
        print('\nassigned_machine_id rows to repoint: ' +
              ', '.join(f'{t}={n}' for t, n in assigned_pairs.items()))

        # movements: delete an asen-origin movement when the same movement
        # already exists on the wises twin, otherwise repoint it.
        move_plan = []  # (movement id, table, twin id, is_duplicate)
        for table, fk in FK_COL.items():
            cur.execute(
                f'SELECT id, {fk}, movement_type, movement_date, '
                'coalesce(notes, %s), coalesce(from_location, %s), '
                'coalesce(to_location, %s) FROM movements '
                f'WHERE {fk} = ANY(%s)',
                ('', '', '', [old for (t, old) in mapping if t == table]))
            for mid, iid, mtype, mdate, notes, src, dst in cur.fetchall():
                twin = mapping[(table, iid)]
                cur.execute(
                    'SELECT 1 FROM movements WHERE id <> %s '
                    'AND machine_id IS NOT DISTINCT FROM %s '
                    'AND probe_id IS NOT DISTINCT FROM %s '
                    'AND printer_id IS NOT DISTINCT FROM %s '
                    'AND part_id IS NOT DISTINCT FROM %s '
                    'AND movement_type = %s AND movement_date IS NOT DISTINCT FROM %s '
                    'AND coalesce(notes, %s) = %s AND coalesce(from_location, %s) = %s '
                    'AND coalesce(to_location, %s) = %s LIMIT 1',
                    (mid,
                     twin if table == 'machines' else None,
                     twin if table == 'probes' else None,
                     twin if table == 'printers' else None,
                     twin if table == 'parts' else None,
                     mtype, mdate, '', notes, '', src, '', dst))
                move_plan.append((mid, table, twin, bool(cur.fetchone())))
        delete_moves = [m for m, _, _, dup in move_plan if dup]
        repoint_moves = [(m, t, twin) for m, t, twin, dup in move_plan if not dup]
        print(f'legacy movements on asen items: {len(move_plan)} '
              f'| duplicate -> delete {len(delete_moves)} '
              f'| keep -> repoint {len(repoint_moves)}')

        # sale_items / flags
        sale_pairs = []
        for table, fk in FK_COL.items():
            cur.execute(f'SELECT id, {fk} FROM sale_items WHERE {fk} = ANY(%s)',
                        ([old for (t, old) in mapping if t == table],))
            for sid, iid in cur.fetchall():
                sale_pairs.append((fk, sid, mapping[(table, iid)]))
        cur.execute('SELECT id, item_kind, item_id FROM flags WHERE item_id IS NOT NULL')
        flag_pairs = []
        for fid, fkind, iid in cur.fetchall():
            twin = mapping.get((fkind + 's' if fkind != 'part' else 'parts', iid))
            if twin is not None:
                flag_pairs.append((twin, fid))
        print(f'sale_items to repoint: {len(sale_pairs)} | flags to repoint: {len(flag_pairs)}')

        delete_equipment = collections.defaultdict(list)
        for table, aid in mapping:
            delete_equipment[table].append(aid)
        print('equipment to delete: ' +
              ', '.join(f'{t}={len(ids)}' for t, ids in delete_equipment.items()))

        if not args.apply:
            conn.rollback()
            print('\nDRY RUN - nothing written. Re-run with --apply.')
            return

        print('\nsnapshotting ...')
        snapshot(cur)

        for table, pairs in (('probes', machine_pairs), ('printers', machine_pairs),
                             ('parts', machine_pairs)):
            if not pairs:
                continue
            n = sum(bulk_update(
                cur,
                f'UPDATE {table} t SET assigned_machine_id = v.n '
                'FROM (VALUES) AS v(n, o) WHERE t.assigned_machine_id = v.o',
                pairs))
            print(f'  repointed {table}.assigned_machine_id: {n}')

        for mid, table, twin in repoint_moves:
            cur.execute(
                'UPDATE movements SET '
                'machine_id = COALESCE(%s, machine_id), probe_id = COALESCE(%s, probe_id), '
                'printer_id = COALESCE(%s, printer_id), part_id = COALESCE(%s, part_id) '
                'WHERE id = %s',
                (twin if table == 'machines' else None,
                 twin if table == 'probes' else None,
                 twin if table == 'printers' else None,
                 twin if table == 'parts' else None, mid))
        if repoint_moves:
            print(f'  repointed movements: {len(repoint_moves)}')
        if delete_moves:
            cur.execute('DELETE FROM movements WHERE id = ANY(%s)', (delete_moves,))
            print(f'  deleted duplicate asen movements: {cur.rowcount}')

        for fk in ('machine_id', 'probe_id', 'printer_id', 'part_id'):
            pairs = [(new, sid) for col, sid, new in sale_pairs if col == fk]
            if not pairs:
                continue
            n = sum(bulk_update(
                cur,
                f'UPDATE sale_items si SET {fk} = v.n '
                'FROM (VALUES) AS v(n, o) WHERE si.id = v.o',
                pairs))
            print(f'  repointed sale_items.{fk}: {n}')

        if flag_pairs:
            n = sum(bulk_update(
                cur,
                'UPDATE flags f SET item_id = v.n '
                'FROM (VALUES) AS v(n, o) WHERE f.id = v.o',
                flag_pairs))
            print(f'  repointed flags: {n}')

        for table in TABLES:
            ids = delete_equipment.get(table, [])
            if ids:
                cur.execute(f'DELETE FROM {table} WHERE id = ANY(%s)', (ids,))
                print(f'  deleted {table}: {cur.rowcount}')

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
