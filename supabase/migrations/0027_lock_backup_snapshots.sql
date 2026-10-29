-- The 2026-10-28 snapshot copies were created with RLS off, so the
-- public anon key could read (and PostgREST could write) them. The app
-- never reads these tables; they stay usable from SQL and the dashboard
-- as the database owner. With RLS on and no policies, the API roles get
-- nothing: PostgREST maps every request to SELECT/INSERT/UPDATE/DELETE,
-- all of which RLS denies. TRUNCATE has no PostgREST endpoint.
ALTER TABLE public.sales_bak_20261028 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_items_bak_20261028 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movements_bak_20261028 ENABLE ROW LEVEL SECURITY;
