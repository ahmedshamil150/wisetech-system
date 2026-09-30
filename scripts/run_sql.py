"""Run a SQL file against the Supabase database configured in .env.

Usage:
  python scripts/run_sql.py supabase/migrations/0002_dealers_old_source_id.sql
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from import_legacy import ROOT, load_env  # noqa: E402


def dsn_from_env():
    env = load_env(ROOT / '.env')
    missing = [k for k in ('SUPABASE_DB_HOST', 'SUPABASE_DB_USER', 'SUPABASE_DB_PASSWORD')
               if not env.get(k)]
    if missing:
        sys.exit('missing from .env: ' + ', '.join(missing))
    return dict(
        host=env['SUPABASE_DB_HOST'],
        port=int(env.get('SUPABASE_DB_PORT', '5432')),
        dbname=env.get('SUPABASE_DB_NAME', 'postgres'),
        user=env['SUPABASE_DB_USER'],
        password=env['SUPABASE_DB_PASSWORD'],
        sslmode='require',
        connect_timeout=20,
    )


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = Path(sys.argv[1])
    if not path.exists():
        sys.exit(f'not found: {path}')
    import psycopg2
    sql = path.read_text(encoding='utf-8-sig')
    conn = psycopg2.connect(**dsn_from_env())
    try:
        with conn:
            with conn.cursor() as cur:
                cur.execute(sql)
                if cur.description:
                    for row in cur.fetchall():
                        print(row)
        print(f'applied {path}')
    finally:
        conn.close()


if __name__ == '__main__':
    main()
