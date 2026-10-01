-- ============================================================
-- 0012: system-generated serial numbers. Machines, probes and
-- printers are often entered without a serial — the system
-- gives them one (WT-000001 style) on insert and whenever the
-- stored value is empty/anonymous. The app shows the generated
-- number in the success message and everywhere serials display.
-- ============================================================

CREATE SEQUENCE IF NOT EXISTS public.serial_seq START 1;
GRANT USAGE, SELECT ON SEQUENCE public.serial_seq
    TO authenticated, anon, service_role;

CREATE OR REPLACE FUNCTION public.fill_serial()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.serial_number IS NULL
       OR lower(btrim(NEW.serial_number)) IN
          ('', 'unknown', 'n/a', 'na', '-', 'none', 'no serial',
           'anonymous') THEN
        NEW.serial_number :=
            'WT-' || LPAD(nextval('public.serial_seq')::text, 6, '0');
    END IF;
    RETURN NEW;
END;
$$;

DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['machines', 'probes', 'printers'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_fill_serial ON %I', t);
        EXECUTE format(
            'CREATE TRIGGER trg_fill_serial '
            'BEFORE INSERT OR UPDATE ON %I '
            'FOR EACH ROW EXECUTE FUNCTION public.fill_serial()', t);
    END LOOP;
END $$;

-- existing rows with a blank/anonymous serial get a system number
-- (the trigger does the replacement: setting the column to itself
-- makes the BEFORE UPDATE trigger fire on those rows)
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['machines', 'probes', 'printers'] LOOP
        EXECUTE format($fmt$
            UPDATE %I SET serial_number = serial_number
            WHERE serial_number IS NULL
               OR btrim(serial_number) = ''
               OR lower(btrim(serial_number)) IN
                  ('unknown', 'n/a', 'na', '-', 'none', 'no serial',
                   'anonymous')
        $fmt$, t);
    END LOOP;
END $$;
