-- ============================================================
-- ROLES: admin (can write everything) / viewer (read + movements)
-- ============================================================
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'viewer'
    CHECK (role IN ('admin', 'viewer'));

UPDATE profiles SET role = 'admin' WHERE username = 'ahmedshamil';

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
    );
$$;

-- nobody may promote/demote themselves except through an admin session
CREATE OR REPLACE FUNCTION public.protect_profile_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NEW;            -- SQL console / service role
    END IF;
    IF TG_OP = 'INSERT' AND NEW.role <> 'viewer' AND NOT public.is_admin() THEN
        RAISE EXCEPTION 'only an admin can create admin accounts';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.role IS DISTINCT FROM OLD.role
       AND NOT public.is_admin() THEN
        RAISE EXCEPTION 'only an admin can change roles';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_profile_role ON profiles;
CREATE TRIGGER protect_profile_role
    BEFORE INSERT OR UPDATE ON profiles
    FOR EACH ROW EXECUTE FUNCTION public.protect_profile_role();

-- ============================================================
-- SEED: the one workshop + the batch used by items added in the app
-- ============================================================
INSERT INTO workshops (name, notes)
SELECT 'Workshop', 'The company workshop (single location).'
WHERE NOT EXISTS (SELECT 1 FROM workshops);

INSERT INTO batches (code, arrival_date, notes)
SELECT 'BATCH-4', to_char(now(), 'DD-MM-YYYY'),
       'Items added from the app (not part of the legacy import).'
WHERE NOT EXISTS (SELECT 1 FROM batches WHERE code = 'BATCH-4');

-- code generator for items added from the app (legacy codes start at M-01000ish)
CREATE SEQUENCE IF NOT EXISTS machine_code_seq START 10000;

CREATE OR REPLACE FUNCTION next_machine_code()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN 'M-' || LPAD(nextval('machine_code_seq')::text, 5, '0');
END;
$$;

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'brands','vendors','catalog_products','batches','customers',
        'workshops','dealers','machines','probes','printers','parts',
        'sales','sale_items','movements','repair_jobs','repair_items',
        'app_settings','imports'
    ] LOOP
        EXECUTE format('DROP POLICY IF EXISTS "members full access" ON %I', t);
        EXECUTE format('DROP POLICY IF EXISTS "read all" ON %I', t);
        EXECUTE format('DROP POLICY IF EXISTS "admin write" ON %I', t);
        EXECUTE format('DROP POLICY IF EXISTS "insert movement" ON %I', t);
    END LOOP;
END $$;

-- everyone authenticated reads; only admins change the reference + inventory data
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'brands','vendors','catalog_products','batches','customers',
        'workshops','dealers','machines','probes','printers','parts',
        'sales','sale_items','repair_jobs','repair_items',
        'app_settings','imports'
    ] LOOP
        EXECUTE format(
            'CREATE POLICY "read all" ON %I FOR SELECT TO authenticated USING (true)', t);
        EXECUTE format(
            'CREATE POLICY "admin write" ON %I FOR ALL TO authenticated '
            'USING (public.is_admin()) WITH CHECK (public.is_admin())', t);
    END LOOP;
END $$;

-- movements: everybody (admin + viewer) may record a move, nobody edits history
CREATE POLICY "read all" ON movements
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "insert movement" ON movements
    FOR INSERT TO authenticated
    WITH CHECK (actor_id = auth.uid());

CREATE POLICY "admin write" ON movements
    FOR ALL TO authenticated
    USING (public.is_admin()) WITH CHECK (public.is_admin());

-- ============================================================
-- create_movement: one call = movement row + item status/location update
--   p_kind : Workshop | Dealer | Customer
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_movement(
    p_item_type   text,
    p_item_id     bigint,
    p_kind        text,
    p_dealer_id   bigint DEFAULT NULL,
    p_customer_id bigint DEFAULT NULL,
    p_workshop_id bigint DEFAULT NULL,
    p_date        text   DEFAULT NULL,
    p_notes       text   DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_table      text;
    v_label_col  text;
    v_rec        record;
    v_to         text;
    v_new_status text;
    v_id         bigint;
BEGIN
    IF p_kind NOT IN ('Workshop', 'Dealer', 'Customer') THEN
        RAISE EXCEPTION 'unknown movement type: %', p_kind;
    END IF;
    IF p_kind = 'Dealer' AND p_dealer_id IS NULL THEN
        RAISE EXCEPTION 'a dealer must be chosen';
    END IF;
    IF p_kind = 'Customer' AND p_customer_id IS NULL THEN
        RAISE EXCEPTION 'a customer must be chosen';
    END IF;
    IF p_kind = 'Workshop' THEN
        SELECT id INTO p_workshop_id FROM workshops
          WHERE is_archived = 0 ORDER BY id LIMIT 1;
        IF p_workshop_id IS NULL THEN
            RAISE EXCEPTION 'no workshop configured';
        END IF;
    END IF;

    v_table := CASE p_item_type
                   WHEN 'machine' THEN 'machines'
                   WHEN 'probe'   THEN 'probes'
                   WHEN 'printer' THEN 'printers'
                   WHEN 'part'    THEN 'parts'
                   ELSE NULL END;
    IF v_table IS NULL THEN
        RAISE EXCEPTION 'unknown item type: %', p_item_type;
    END IF;
    v_label_col := CASE WHEN v_table IN ('machines', 'probes')
                        THEN 'model' ELSE 'name_model' END;

    EXECUTE format(
        'SELECT id, status, current_location, serial_number, %I FROM %I WHERE id = $1',
        v_label_col, v_table)
        INTO v_rec USING p_item_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'item % not found in %', p_item_id, v_table;
    END IF;

    SELECT CASE WHEN p_kind = 'Workshop' THEN 'Workshop'
                WHEN p_kind = 'Dealer'
                    THEN (SELECT name FROM dealers WHERE id = p_dealer_id)
                ELSE (SELECT name FROM customers WHERE id = p_customer_id) END
      INTO v_to;

    IF v_to IS NULL THEN
        RAISE EXCEPTION 'destination not found';
    END IF;

    -- status changes for workshop / dealer, customer only changes location
    IF p_kind = 'Workshop' THEN
        v_new_status := 'With Workshop';
    ELSIF p_kind = 'Dealer' THEN
        v_new_status := 'With Dealer';
    ELSE
        v_new_status := v_rec.status;
    END IF;

    EXECUTE format(
        'UPDATE %I SET status = $1, current_location = $2 WHERE id = $3',
        v_table)
        USING v_new_status, v_to, p_item_id;

    INSERT INTO movements (
        movement_type, movement_date,
        machine_id, probe_id, printer_id, part_id,
        workshop_id, dealer_id, customer_id,
        from_location, to_location, reason, notes,
        actor_id, group_ref, reference
    ) VALUES (
        p_kind,
        COALESCE(p_date, to_char(now(), 'DD-MM-YYYY')),
        CASE WHEN p_item_type = 'machine' THEN p_item_id END,
        CASE WHEN p_item_type = 'probe'   THEN p_item_id END,
        CASE WHEN p_item_type = 'printer' THEN p_item_id END,
        CASE WHEN p_item_type = 'part'    THEN p_item_id END,
        CASE WHEN p_kind = 'Workshop' THEN p_workshop_id END,
        CASE WHEN p_kind = 'Dealer'   THEN p_dealer_id   END,
        CASE WHEN p_kind = 'Customer' THEN p_customer_id END,
        v_rec.current_location, v_to,
        'Sent to ' || CASE WHEN p_kind = 'Workshop' THEN 'workshop'
                           WHEN p_kind = 'Dealer' THEN 'dealer'
                           ELSE 'customer' END,
        p_notes,
        auth.uid(), new_group_ref(), next_movement_reference()
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- ============================================================
-- create_sale: header + items + mark items sold, in one transaction
--   p_items: [{"type":"machine","id":12,"price":100000}, ...]
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_sale(
    p_customer_id bigint,
    p_date        text,
    p_price       numeric,
    p_invoice     text,
    p_notes       text,
    p_items       jsonb DEFAULT '[]'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_sale_id   bigint;
    v_customer  text;
    v_entry     record;
    v_type      text;
    v_item_id   bigint;
    v_table     text;
    v_label_col text;
    v_first     boolean := true;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'only an admin can record a sale';
    END IF;

    SELECT name INTO v_customer FROM customers WHERE id = p_customer_id;
    IF v_customer IS NULL THEN
        RAISE EXCEPTION 'customer not found';
    END IF;

    INSERT INTO sales (customer_id, sale_date, sale_price, invoice_reference,
                       notes, actor_id)
    VALUES (p_customer_id, COALESCE(p_date, to_char(now(), 'DD-MM-YYYY')),
            p_price, p_invoice, p_notes, auth.uid())
    RETURNING id INTO v_sale_id;

    FOR v_entry IN SELECT value FROM jsonb_array_elements(p_items) LOOP
        v_type   := v_entry.value ->> 'type';
        v_item_id := (v_entry.value ->> 'id')::bigint;
        v_table := CASE v_type
                       WHEN 'machine' THEN 'machines'
                       WHEN 'probe'   THEN 'probes'
                       WHEN 'printer' THEN 'printers'
                       WHEN 'part'    THEN 'parts'
                       ELSE NULL END;
        IF v_table IS NULL OR v_item_id IS NULL THEN
            RAISE EXCEPTION 'bad sale item: %', v_entry.value;
        END IF;
        v_label_col := CASE WHEN v_table IN ('machines', 'probes')
                            THEN 'model' ELSE 'name_model' END;

        EXECUTE format(
            'UPDATE %I SET status = %L, current_location = %L WHERE id = $1',
            v_table, 'Sold', v_customer)
            USING v_item_id;

        EXECUTE format(
            'INSERT INTO sale_items (sale_id, item_type, machine_id, probe_id, '
            'printer_id, part_id, item_description, item_serial, item_price, '
            'is_main_item) '
            'SELECT $1, $2, $3, $4, $5, $6, %I, serial_number, $7, $8 '
            'FROM %I WHERE id = $9',
            v_label_col, v_table)
            USING v_sale_id, v_type,
                  CASE WHEN v_type = 'machine' THEN v_item_id END,
                  CASE WHEN v_type = 'probe'   THEN v_item_id END,
                  CASE WHEN v_type = 'printer' THEN v_item_id END,
                  CASE WHEN v_type = 'part'    THEN v_item_id END,
                  (v_entry.value ->> 'price')::numeric,
                  CASE WHEN v_first THEN 1 ELSE 0 END,
                  v_item_id;
        v_first := false;
    END LOOP;

    RETURN v_sale_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_movement(text, bigint, text, bigint, bigint,
                                                  bigint, text, text)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_sale(bigint, text, numeric, text, text, jsonb)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION next_machine_code() TO authenticated;
GRANT EXECUTE ON FUNCTION next_internal_id(text) TO authenticated;
