import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import psycopg2
from import_legacy import load_env

env = load_env(Path(__file__).resolve().parent.parent / '.env')
conn = psycopg2.connect(
    host=env['SUPABASE_DB_HOST'], port=int(env.get('SUPABASE_DB_PORT', '5432')),
    dbname=env.get('SUPABASE_DB_NAME', 'postgres'), user=env['SUPABASE_DB_USER'],
    password=env['SUPABASE_DB_PASSWORD'], sslmode='require')
cur = conn.cursor()

def q(sql):
    cur.execute(sql)
    return cur.fetchall()

print('batches:')
for r in q('select id, code, arrival_date, vendor_id from batches order by id'):
    print('  ', r)

print('\nrows per batch / table:')
for t in ('machines', 'probes', 'printers', 'parts'):
    for r in q(f'select b.code, count(*) from {t} i join batches b on b.id=i.batch_id '
               f'group by b.code order by b.code'):
        print(f'  {t:9} {r[0]:14} {r[1]}')

print('\nstatus mix:')
for t in ('machines', 'probes', 'printers', 'parts'):
    for r in q(f'select status, count(*) from {t} group by status order by 2 desc'):
        print(f'  {t:9} {r[0]:14} {r[1]}')

print('\nprobes linked to a machine:', q("select count(*) from probes where assigned_machine_id is not null")[0][0])
print('printers linked to a machine:', q("select count(*) from printers where assigned_machine_id is not null")[0][0])
print('items with no catalog link:', q("select (select count(*) from machines where catalog_product_id is null) + "
                                       "(select count(*) from probes where catalog_product_id is null) + "
                                       "(select count(*) from printers where catalog_product_id is null) + "
                                       "(select count(*) from parts where catalog_product_id is null)")[0][0])
print('items with no brand:', q("select (select count(*) from machines where brand_id is null) + "
                                "(select count(*) from probes where brand_id is null) + "
                                "(select count(*) from printers where brand_id is null) + "
                                "(select count(*) from parts where brand_id is null)")[0][0])

print('\ncatalogue by category:')
for r in q('select category, count(*) from catalog_products group by category order by 2 desc'):
    print('  ', r)

print('\nsample machines (batch 3):')
for r in q("select m.machine_id, m.model, m.serial_number, m.status, m.current_location, "
           "m.acquisition_date, b.code from machines m join batches b on b.id=m.batch_id "
           "order by m.id limit 5"):
    print('  ', r)

print('\nsample probes:')
for r in q("select p.internal_id, p.model, p.serial_number, p.status, p.current_location, b.code "
           "from probes p join batches b on b.id=p.batch_id order by p.id limit 5"):
    print('  ', r)

print('\nimports audit:')
for r in q('select batch_code, records_total, records_inserted, notes from imports order by id'):
    print('  ', r)

print('\ncounters:', q('select (select count(*) from brands), (select count(*) from vendors), '
                       '(select count(*) from customers), (select count(*) from dealers), '
                       '(select count(*) from catalog_products)')[0])

conn.close()
