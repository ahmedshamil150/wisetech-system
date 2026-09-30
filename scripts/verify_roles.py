import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import psycopg2
from run_sql import dsn_from_env

conn = psycopg2.connect(**dsn_from_env())
conn.autocommit = False
cur = conn.cursor()

def show(title, sql):
    cur.execute(sql)
    print(f'\n== {title}')
    for r in cur.fetchall():
        print('  ', r)

show('roles', "select username, role from profiles order by username")
show('workshops', "select id, name from workshops")
show('batches', "select id, code, arrival_date from batches order by id")
show('policies', """select tablename, policyname, cmd, qual, with_check
                    from pg_policies where schemaname='public'
                    order by tablename, policyname""")
show('functions', """select proname, prosecdef from pg_proc
                     where pronamespace='public'::regnamespace
                       and proname in ('is_admin','create_movement','create_sale',
                                       'next_machine_code','protect_profile_role')
                     order by proname""")

# --- functional test of create_movement on a real machine -------------------
cur.execute("""select id, status, current_location, serial_number, model
                 from machines where status = 'In Stock' and current_location = 'Rawalpindi'
                 order by id limit 1""")
item = cur.fetchone()
print('\n== test item (before):', item)
mid = item[0]

cur.execute("select id from workshops limit 1")
workshop_id = cur.fetchone()[0]

try:
    cur.execute("select public.create_movement('machine', %s, 'Workshop', "
                "p_workshop_id := %s, p_date := '29-09-2026', p_notes := 'rls smoke test')",
                (mid, workshop_id))
    move_id = cur.fetchone()[0]
    print('   movement id:', move_id)
    cur.execute("select id, movement_type, movement_date, to_location, from_location, "
                "actor_id, reference from movements where id = %s", (move_id,))
    print('   movement row:', cur.fetchone())
    cur.execute("select status, current_location from machines where id = %s", (mid,))
    print('   machine after:', cur.fetchone())
    conn.rollback()
    print('   rolled back (test data not kept)')
except Exception as exc:
    conn.rollback()
    print('   ERROR:', exc)

try:
    cur.execute("select public.create_sale(1, '29-09-2026', 100, 'INV-T', 'x', '[]')")
    print('\n== create_sale as anonymous:', cur.fetchone())
    conn.rollback()
except Exception as exc:
    conn.rollback()
    print('\n== create_sale blocked as expected:', str(exc).strip().splitlines()[0])

try:
    cur.execute("select public.is_admin()")
    print('== is_admin() without a JWT:', cur.fetchone())
finally:
    conn.rollback()

conn.close()
