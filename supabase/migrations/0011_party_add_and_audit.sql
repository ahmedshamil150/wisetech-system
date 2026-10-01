-- ============================================================
-- 0011: anyone (admin or viewer) may ADD a customer/dealer
-- straight from the movement form — typed a name that is not in
-- the list? It is created on save. Remember who added each row
-- so the admin dashboard can show it. Editing/deleting stays
-- admin-only (the "admin write" policy still covers that).
-- ============================================================

-- who added this row (null for legacy-imported records)
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS created_by UUID
    REFERENCES public.profiles(id);
ALTER TABLE public.dealers   ADD COLUMN IF NOT EXISTS created_by UUID
    REFERENCES public.profiles(id);

ALTER TABLE public.customers ALTER COLUMN created_by SET DEFAULT auth.uid();
ALTER TABLE public.dealers   ALTER COLUMN created_by SET DEFAULT auth.uid();

-- any signed-in member may insert a row; the row must be their own
DROP POLICY IF EXISTS "add party" ON public.customers;
CREATE POLICY "add party" ON public.customers
    FOR INSERT TO authenticated
    WITH CHECK (created_by = auth.uid() AND length(btrim(name)) > 0);

DROP POLICY IF EXISTS "add party" ON public.dealers;
CREATE POLICY "add party" ON public.dealers
    FOR INSERT TO authenticated
    WITH CHECK (created_by = auth.uid() AND length(btrim(name)) > 0);
